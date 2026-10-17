import AppKit
import Carbon
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Include captures made while startup is waiting for folder permission.
    private let screenshotMonitoringStartedAt = Date()
    private let line: Line
    private let defaults: UserDefaults
    private let capturePasteboard: NSPasteboard
    /// Verification hosts can watch a dedicated fixture folder without
    /// reading Desktop or changing the user's screenshot preferences.
    private let screenshotFolder: URL?
    private var panel: LinePanel!
    private var statusItem: NSStatusItem!
    private var watcher: ScreenshotWatcher!
    private let screenshotThumbnails = ScreenshotThumbnailLoader()
    private var clipboardWatcher: ClipboardWatcher?
    private var screenshotLocationMonitor: ScreenshotLocationMonitor?
    private var clipboardEnabled: Bool {
        defaults.object(forKey: "clipboardEnabled") as? Bool ?? true
    }
    private var hotKey: HotKey?
    private var searchHotKey: HotKey?
    private var library: ClipdLibrary?
    private var libraryStartupTask: Task<Void, Never>?
    private var previousSearchApp: NSRunningApplication?
    private var cancellables = Set<AnyCancellable>()
    private var pointerMonitors: [Any] = []
    private var pointerUpdate: DispatchWorkItem?
    private var deadlineTimer: Timer?
    private var scheduledDeadline: Date?
    private var settledWorkspaceUpdate: DispatchWorkItem?
    private var isTerminating = false

    /// Whether the panel is ordered in. It can be in and still tucked away
    /// above the top edge, like an auto-hiding Dock.
    private var isPresent = false
    /// Whether the line has slid down into view.
    private var isRevealed = false
    /// Opened on purpose with the shortcut or the menu: it stays down until
    /// the cursor has visited it and left, or the shortcut is pressed again.
    private var pinned = false
    /// A new screenshot shows itself for a moment, then tucks away.
    private var capturePreview = CapturePreview()
    private var hotZoneSince: Date?
    private var hoverReveal = HoverReveal()
    private var hoverBlockedUntilExit = false
    /// After a click in the menu bar the line stays up there hidden until the
    /// pointer leaves the menu bar, so it does not come back over a menu.
    private var menuBarSuppressed = false
    private var clickMonitors: [Any] = []
    private var awaySince: Date?
    /// Whether there is a line to show, including in full screen Spaces.
    private var wanted = false
    /// Set when you open the line on purpose, so it stays up while empty.
    private var keepOpen = false
    /// The screen a new capture was taken on: the line goes there.
    private var pendingScreen: NSScreen?

    init(line: Line? = nil, screenshotFolder: URL? = nil, defaults: UserDefaults = .standard, library: ClipdLibrary? = nil,
         capturePasteboard: NSPasteboard = .general) {
        self.line = line ?? Line()
        self.defaults = defaults
        self.capturePasteboard = capturePasteboard
        self.screenshotFolder = screenshotFolder
        self.library = library
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditingMenu()
        let host = NSHostingView(rootView: LineView(line: line))
        host.sizingOptions = []
        panel = LinePanel(content: host)
        panel.placeOnScreen()
        line.maxItems = Line.historyLimit
        updateCapacity()
        line.onCapture = { [weak self] in self?.captureAdded() }
        line.onCopyFeedback = { [weak self] in
            guard let self else { return }
            self.capturePreview.extendForCopyFeedback(at: Date())
            self.requestPointerUpdate()
            if self.line.copiedID != nil {
                self.releaseSearchFocus()
            }
        }
        line.onSearchEnd = { [weak self] in self?.releaseSearchFocus() }
        line.onNavigate = { [weak self] in
            self?.capturePreview.extendForCopyFeedback(at: Date())
            self?.requestPointerUpdate()
        }
        line.onInteractionChange = { [weak self] in self?.requestPointerUpdate() }
        do {
            if library == nil, screenshotFolder == nil { library = try ClipdLibrary() }
            if let library {
                libraryStartupTask = Task { @MainActor [weak self] in
                    guard let self, !self.isTerminating else { return }
                    do {
                        try await library.connectInBackground(to: self.line, trackApplications: self.screenshotFolder == nil)
                    } catch is CancellationError {
                    } catch {
                        guard !self.isTerminating else { return }
                        self.line.libraryStatus = "Clipd 歷史暫時無法開啟，現有卡片仍可使用"
                        log.error("Clipd history loading failed: \(String(describing: error), privacy: .private)")
                    }
                }
            }
        } catch {
            line.libraryStatus = "Clipd 歷史暫時無法開啟，現有卡片仍可使用"
            log.error("Clipd backend startup failed: \(String(describing: error), privacy: .private)")
        }

        if screenshotFolder == nil {
            // Retire legacy takeover settings only while wardrobe still owns
            // them, then follow the user's current macOS screenshot location.
            Inbox.restore()
        }
        startWatcher(startedAt: screenshotMonitoringStartedAt)
        setClipboardEnabled(clipboardEnabled)

        hotKey = HotKey(keyCode: kVK_ANSI_T, modifiers: controlKey | optionKey) { [weak self] in
            self?.toggle()
        }
        searchHotKey = HotKey(keyCode: kVK_ANSI_V, modifiers: cmdKey | shiftKey) { [weak self] in
            self?.showSearch()
        }
        line.$searchFocused.dropFirst().sink { [weak self] focused in
            guard let self else { return }
            self.requestPointerUpdate()
            guard focused else { return }
            self.capturePreview.cancel()
            self.keepOpen = true
            self.wanted = true
            self.refresh()
            self.reveal(pinned: true)
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { self.previousSearchApp = front }
            NSApp.activate(ignoringOtherApps: true)
        }.store(in: &cancellables)

        setUpStatusItem()
        watchMenuBarClicks()

        line.onFall = { [weak self] item in self?.fall(item) }

        line.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.itemsChanged() }
            .store(in: &cancellables)

        // Entering or leaving full screen switches Space. Check again once the
        // switch animation has settled.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.workspaceChanged()
                    self.settledWorkspaceUpdate?.cancel()
                    let update = DispatchWorkItem { [weak self] in self?.workspaceChanged() }
                    self.settledWorkspaceUpdate = update
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: update)
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel.placeOnScreen()
                self?.updateCapacity()
                self?.requestPointerUpdate()
            }
        }

        if !defaults.bool(forKey: "welcomed") {
            defaults.set(true, forKey: "welcomed")
            keepOpen = true
            wanted = true
            refresh()
            reveal(pinned: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.line.liveCount == 0 else { return }
                self.keepOpen = false
                self.wanted = false
                self.refresh()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        libraryStartupTask?.cancel()
        library?.stop()
        clipboardWatcher?.stop()
        line.cancelClipboardPreparation()
        watcher?.stop()
        screenshotThumbnails.cancelAll()
        screenshotLocationMonitor?.stop()
        stopMouseTracking()
        settledWorkspaceUpdate?.cancel()
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors.removeAll()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSearch()
        return false
    }

    private func setClipboardEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: "clipboardEnabled")
        clipboardWatcher?.stop()
        clipboardWatcher = nil
        line.cancelClipboardPreparation()
        guard enabled else { return }
        let watcher = ClipboardWatcher(pasteboard: capturePasteboard, onTextFormats: { [weak self] formats in self?.line.capturedTextFormats = formats }) { [weak self] payload in
            self?.line.ingestClipboardInBackground(payload) ?? false
        }
        clipboardWatcher = watcher
        watcher.start()
    }

    // MARK: Screenshot monitoring

    private func startWatcher(folder: URL? = nil, startedAt: Date = Date()) {
        screenshotThumbnails.cancelAll()
        screenshotLocationMonitor?.stop()
        screenshotLocationMonitor = nil
        watcher?.stop()
        watcher = ScreenshotWatcher(
            folder: screenshotFolder ?? folder,
            startedAt: startedAt,
            onNew: { [weak self] url in self?.hangCapture(url) ?? false },
            onChange: { [weak self] in self?.line.prune() })
        watcher.start()
        if screenshotFolder == nil {
            let monitor = ScreenshotLocationMonitor(folder: watcher.folder, checkedAt: startedAt, onCheck: { [weak self] in
                guard let self, !self.isTerminating else { return }
                self.watcher?.reconcile()
            }) { [weak self] folder, cutoff in
                self?.startWatcher(folder: folder, startedAt: cutoff)
            }
            screenshotLocationMonitor = monitor
            monitor.start()
        }
    }

    // MARK: Showing and hiding

    private func captureAdded() {
        if !isRevealed { line.resetLibraryView() }
        panel.placeOnScreen(pendingScreen)
        pendingScreen = nil
        updateCapacity()
        wanted = true
        refresh()
        requestPointerUpdate()
        reveal(forCapture: true)
    }

    private func itemsChanged() {
        if line.liveCount > 0 {
            wanted = true
            refresh()
        } else if !keepOpen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, self.line.liveCount == 0, !self.keepOpen else { return }
                self.wanted = false
                self.refresh()
            }
        }
    }

    // MARK: Screenshot arrival

    /// Keep screenshot arrival inside the shelf. A screen-sized transparent
    /// flight window and a second large image decode compete with desktop rendering.
    @discardableResult
    func hangCapture(_ url: URL) -> Bool {
        if line.items.contains(where: { $0.url == url && !$0.falling }) { return true }
        screenshotThumbnails.load(url) { [weak self] image in
            guard let self, !self.isTerminating, let image,
                  !self.line.items.contains(where: { $0.url == url && !$0.falling }) else { return }
            self.hangPreparedCapture(url, image: image)
        }
        // Keep the watcher's incomplete-file retry contract. A subsequent scan
        // acknowledges this URL only after preparation actually created a card.
        return false
    }

    private func hangPreparedCapture(_ url: URL, image: CGImage) {
        let from = captureRect(of: url)
        if let from {
            let center = CGPoint(x: from.midX, y: from.midY)
            pendingScreen = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
        }
        let thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        guard line.hang(url, thumbnail: thumbnail) != nil else {
            pendingScreen = nil
            return
        }
    }

    /// A discarded card falls over the whole screen, from where it hangs.
    private func fall(_ item: Pegged) {
        guard isPresent, isRevealed, !item.flying, let screen = panel.screen,
              let card = cardFrame(for: item.id),
              let image = item.thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        CaptureFlight.fall(image: image, card: card, tilt: CGFloat(item.tilt), on: screen)
    }

    /// Where a card will hang, in screen coordinates, using the same layout
    /// as the line view.
    private func cardFrame(for id: UUID) -> CGRect? {
        let visible = line.visibleItems
        guard let index = visible.firstIndex(where: { $0.id == id }) else { return nil }
        let width = panel.frame.width
        let x = Layout.x(index: index, count: visible.count, width: width)
        let viewTop = Layout.ropeY(x: x, width: width) - Layout.pinAbove
        let cardTop = viewTop + PeggedView.cardOffsetBelowTop
        let size = PeggedView.cardSize
        return CGRect(x: panel.frame.minX + x - size.width / 2,
                      y: panel.frame.maxY - cardTop - size.height,
                      width: size.width, height: size.height)
    }

    /// Reposition and reorder the overlay after a Space or application switch.
    /// Keep existing display deadlines; switching apps must not restart them.
    private func workspaceChanged() {
        menuBarSuppressed = false
        hotZoneSince = nil
        panel.placeOnScreen()
        updateCapacity()
        refresh()
        requestPointerUpdate()
    }

    /// Order the panel in whenever there is something to show, in every Space.
    private func refresh() {
        if wanted {
            present()
        } else {
            dismiss()
        }
        // The cursor is watched while there is a line, even tucked away,
        // to notice it pushing against the top edge.
        if wanted { startMouseTracking() } else { stopMouseTracking() }
    }

    private func present() {
        isPresent = true
        if isRevealed { panel.setShelfVisible(true) }
    }

    private func dismiss() {
        guard isPresent else { return }
        isPresent = false
        setRevealed(false)
        panel.setShelfVisible(false)
    }

    private func reveal(pinned: Bool = false, forCapture: Bool = false, fromHover: Bool = false) {
        guard isPresent else { return }
        if forCapture { capturePreview.start(at: Date()) } else { capturePreview.cancel() }
        if fromHover, let screen = panel.screen {
            hoverReveal.start(on: screen.frame)
        } else {
            hoverReveal.cancel()
        }
        if pinned { self.pinned = true }
        awaySince = nil
        setRevealed(true)
        requestPointerUpdate()
    }

    private func setRevealed(_ on: Bool) {
        guard on != isRevealed else { return }
        isRevealed = on
        panel.setShelfVisible(on)
        line.revealed = on
        library?.setOCRPaused(on)
        requestPointerUpdate()
        if !on {
            releaseSearchFocus()
            line.resetLibraryView()
            hoverReveal.cancel()
            pinned = false
            capturePreview.cancel()
            panel.ignoresMouseEvents = true
        }
    }

    @objc private func toggle() {
        if isRevealed {
            setRevealed(false)
            if line.liveCount == 0 {
                keepOpen = false
                wanted = false
                refresh()
            }
        } else {
            line.resetLibraryView()
            keepOpen = true
            wanted = true
            panel.placeOnScreen()
            updateCapacity()
            refresh()
            reveal(pinned: true)
        }
    }

    private func showSearch() {
        if !isRevealed { line.resetLibraryView() }
        keepOpen = true
        wanted = true
        panel.placeOnScreen()
        refresh()
        reveal(pinned: true)
        panel.makeKeyAndOrderFront(nil)
        line.searchFocused = true
    }

    private func releaseSearchFocus() {
        line.searchFocused = false
        panel.makeFirstResponder(nil)
        panel.resignKey()
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            previousSearchApp?.activate(options: [])
        }
        previousSearchApp = nil
    }

    private func installEditingMenu() {
        let main = NSApp.mainMenu ?? NSMenu()
        if main.items.isEmpty {
            let app = NSMenuItem()
            let submenu = NSMenu()
            submenu.addItem(withTitle: "Quit wardrobe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            app.submenu = submenu
            main.addItem(app)
        }
        let edit = NSMenuItem(title: "編輯", action: nil, keyEquivalent: "")
        let commands = NSMenu(title: "編輯")
        commands.addItem(withTitle: "復原", action: Selector(("undo:")), keyEquivalent: "z")
        commands.addItem(.separator())
        commands.addItem(withTitle: "剪下", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        commands.addItem(withTitle: "複製", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        commands.addItem(withTitle: "貼上", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        commands.addItem(withTitle: "全選", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = commands
        main.addItem(edit)
        NSApp.mainMenu = main
    }

    private func startMouseTracking() {
        guard pointerMonitors.isEmpty else { return }
        panel.acceptsMouseMovedEvents = true
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                            .otherMouseDragged, .leftMouseUp, .rightMouseUp, .otherMouseUp]
        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.requestPointerUpdate() }
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: events, handler: handler) { pointerMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: events, handler: { event in handler(event); return event }) { pointerMonitors.append(monitor) }
        requestPointerUpdate()
    }

    private func stopMouseTracking() {
        pointerMonitors.forEach(NSEvent.removeMonitor)
        pointerMonitors.removeAll()
        pointerUpdate?.cancel()
        pointerUpdate = nil
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        scheduledDeadline = nil
        panel.ignoresMouseEvents = true
    }

    /// Coalesce motion into one update per display frame. A still pointer has
    /// no polling cost; only an actual reveal/retract deadline needs a timer.
    private func requestPointerUpdate() {
        guard wanted, !isTerminating, pointerUpdate == nil else { return }
        let update = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pointerUpdate = nil
            self.tick()
        }
        pointerUpdate = update
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60, execute: update)
    }

    private var interactionBusy: Bool {
        GrabView.isDragging || GrabView.isPresentingMenu || line.pressedID != nil ||
            line.searchFocused || line.editingURL != nil
    }

    private func scheduleNextDeadline() {
        let next: Date?
        if !wanted || isTerminating { next = nil }
        else if !isRevealed { next = hotZoneSince?.addingTimeInterval(Self.revealDelay) }
        else if interactionBusy { next = nil }
        else if let preview = capturePreview.nextDeadline { next = preview }
        else { next = awaySince?.addingTimeInterval(Self.retractDelay) }
        guard next != scheduledDeadline else { return }
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        scheduledDeadline = next
        guard let next else { return }
        let timer = Timer(timeInterval: max(0.001, next.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.deadlineTimer = nil
                self?.scheduledDeadline = nil
                self?.tick()
            }
        }
        deadlineTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// How long the cursor rests against the top edge before the line comes
    /// down. Short enough to feel instant, long enough that a quick trip to
    /// the menu bar does not trigger it.
    private static let revealDelay: TimeInterval = 0.08

    /// The menu bar strip at the top of a screen. With an auto-hiding menu
    /// bar the visible frame reaches the top, so the system thickness is used.
    static func menuBarBand(of screen: NSScreen) -> NSRect {
        var h = screen.frame.maxY - screen.visibleFrame.maxY
        if h < 1 { h = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top) }
        return NSRect(x: screen.frame.minX, y: screen.frame.maxY - h, width: screen.frame.width, height: h)
    }

    /// A click anywhere in the top bar of any screen, a menu or an icon, puts the line away.
    private func watchMenuBarClicks() {
        let handler: (NSEvent?) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.requestPointerUpdate()
                let p = NSEvent.mouseLocation
                guard NSScreen.screens.contains(where: { Self.menuBarBand(of: $0).contains(p) }) else { return }
                self.menuBarSuppressed = true
                self.hotZoneSince = nil
                if self.isRevealed {
                    self.pinned = false
                    self.setRevealed(false)
                }
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in handler(e); return e }) {
            clickMonitors.append(local)
        }
    }
    /// How long the cursor is away before the line tucks back up.
    private static let retractDelay: TimeInterval = 5

    private func tick() {
        guard wanted, !isTerminating else { return }
        defer { scheduleNextDeadline() }
        let mouse = NSEvent.mouseLocation
        let now = Date()

        let screenUnderPointer = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        let inMenuBar = screenUnderPointer.map { Self.menuBarBand(of: $0).contains(mouse) } ?? false
        let inRevealZone = screenUnderPointer.map {
            let region = HoverTrigger.region(on: $0.frame,
                                             menuBarHeight: Self.menuBarBand(of: $0).height,
                                             topLeftArea: $0.auxiliaryTopLeftArea,
                                             topRightArea: $0.auxiliaryTopRightArea)
            return HoverTrigger.contains(mouse, in: region)
        } ?? false
        if !inRevealZone { hoverBlockedUntilExit = false }
        if !inMenuBar { menuBarSuppressed = false }

        guard isRevealed else {
            // Only the notch (or a small top-center area without a notch)
            // brings the line down. The rest of the menu bar stays ordinary.
            if let screen = screenUnderPointer, inRevealZone, !menuBarSuppressed, !hoverBlockedUntilExit {
                let since = hotZoneSince ?? now
                hotZoneSince = since
                if now.timeIntervalSince(since) >= Self.revealDelay {
                    hotZoneSince = nil
                    if panel.screen != screen {
                        panel.placeOnScreen()
                        updateCapacity()
                    }
                    refresh()
                    reveal(fromHover: true)
                }
            } else {
                hotZoneSince = nil
            }
            return
        }

        // A deadline may expire during an interaction, but a card must not
        // disappear beneath a held pointer, an active drag, or its menu.
        if interactionBusy {
            updateMousePassThrough(mouse)
            awaySince = nil
            return
        }

        if capturePreview.shouldRetract(at: now) {
            // A pointer left in the hot zone must not immediately reopen a
            // preview whose three-second lifetime has just ended.
            hoverBlockedUntilExit = true
            hotZoneSince = nil
            awaySince = nil
            setRevealed(false)
            return
        }

        if hoverReveal.isActive {
            updateMousePassThrough(mouse)
            if hoverReveal.shouldRetract(pointer: mouse) {
                awaySince = nil
                setRevealed(false)
            }
            // Hover reveals use only the screen's upper-third region, with
            // no three-second limit or five-second pointer-away grace.
            return
        }

        updateMousePassThrough(mouse)

        // The line's zone runs from its lowest point up to the top of the
        // screen, menu bar included, so moving up never hides it.
        var zone = panel.frame
        if let screen = panel.screen { zone.size.height = screen.frame.maxY - zone.minY }
        let inside = NSMouseInRect(mouse, zone, false)
        if inside {
            pinned = false
        }

        let busy = pinned || GrabView.isDragging || line.pressedID != nil
        if inside || busy {
            awaySince = nil
        } else {
            let since = awaySince ?? now
            awaySince = since
            // Space/app changes do not restart the pointer-away deadline.
            if now.timeIntervalSince(since) >= Self.retractDelay {
                awaySince = nil
                setRevealed(false)
            }
        }
    }

    /// The panel spans the whole width of the screen, so it only accepts the
    /// mouse while the cursor is over a photo. Everywhere else, clicks go to
    /// whatever is underneath.
    private func updateMousePassThrough(_ mouse: NSPoint) {
        guard !GrabView.isDragging, !GrabView.isPresentingMenu, line.pressedID == nil else { return }
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        let overPhoto = line.hitRects.values.contains { $0.insetBy(dx: -4, dy: -4).contains(flipped) }
        if panel.ignoresMouseEvents == overPhoto {
            panel.ignoresMouseEvents = !overPhoto
        }
    }

    private func updateCapacity() {
        let capacity = min(6, Layout.capacity(width: panel.frame.width))
        if line.pageSize != capacity { line.pageSize = capacity }
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "wardrobe")
        image?.isTemplate = true
        statusItem.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let toggleItem = ClosureMenuItem(isRevealed ? L("Hide line", "Ocultar tendedero")
                                                 : L("Show line", "Mostrar tendedero")) { [weak self] in
            self?.toggle()
        }
        toggleItem.keyEquivalent = "t"
        toggleItem.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(toggleItem)

        let clearItem = ClosureMenuItem(L("Take everything down", "Descolgar todo")) { [weak self] in
            self?.line.clear()
        }
        clearItem.isEnabled = line.liveCount > 0
        menu.addItem(clearItem)

        let clipboard = ClosureMenuItem(L("Hang copied items", "Colgar elementos copiados")) { [weak self] in
            guard let self else { return }
            self.setClipboardEnabled(!self.clipboardEnabled)
        }
        clipboard.state = clipboardEnabled ? .on : .off
        clipboard.toolTip = L("Keep new copied images, text, links and files locally on the line",
                              "Guarda imágenes, texto, enlaces y archivos copiados en la línea, solo en este Mac")
        menu.addItem(clipboard)

        menu.addItem(.separator())

        let sound = ClosureMenuItem(L("Sounds", "Sonidos")) { [weak self] in
            guard let self else { return }
            self.line.soundOn.toggle()
        }
        sound.state = line.soundOn ? .on : .off
        menu.addItem(sound)
        if library != nil {
            menu.addItem(ClosureMenuItem("搜尋歷史…（⌘⇧V）") { [weak self] in self?.showSearch() })
        }

        let login = ClosureMenuItem(L("Open at login", "Abrir al iniciar sesión")) {
            AppDelegate.toggleLaunchAtLogin()
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Quit wardrobe", "Salir de wardrobe"), key: "q") {
            NSApp.terminate(nil)
        })
    }

    private static func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Could not change the login setting", "No se pudo cambiar el inicio de sesión")
            alert.informativeText = L("Move wardrobe to the Applications folder and try again.",
                                      "Mueve wardrobe a la carpeta Aplicaciones y vuelve a intentarlo.")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
