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
    /// In inbox mode, a second watcher on the Desktop. If a macOS version
    /// ignores the screenshot settings (macOS 27 renamed one), captures keep
    /// landing on the Desktop, and they still hang on the line.
    private var safetyWatcher: ScreenshotWatcher?
    private var clipboardWatcher: ClipboardWatcher?
    private var screenshotLocationMonitor: ScreenshotLocationMonitor?
    private var clipboardEnabled: Bool {
        defaults.object(forKey: "clipboardEnabled") as? Bool ?? true
    }
    private var signalSources: [DispatchSourceSignal] = []
    private var hotKey: HotKey?
    private var cancellables = Set<AnyCancellable>()
    private var mouseTimer: Timer?

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

    init(line: Line? = nil, screenshotFolder: URL? = nil, defaults: UserDefaults = .standard,
         capturePasteboard: NSPasteboard = .general) {
        self.line = line ?? Line()
        self.defaults = defaults
        self.capturePasteboard = capturePasteboard
        self.screenshotFolder = screenshotFolder
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        PreviewWindowCenterer.shared.promptsForAccess = screenshotFolder == nil
        let host = NSHostingView(rootView: LineView(line: line))
        host.sizingOptions = []
        panel = LinePanel(content: host)
        panel.placeOnScreen()
        updateCapacity()
        line.onCapture = { [weak self] in self?.captureAdded() }
        line.onCopyFeedback = { [weak self] in self?.capturePreview.extendForCopyFeedback(at: Date()) }

        if screenshotFolder == nil {
            if Inbox.isEnabled { applyInbox() }
            else { Inbox.restore(); prepareScreenshotFolder() }
        }
        restoreSettingsOnTermination()
        startWatcher(startedAt: screenshotMonitoringStartedAt)
        setClipboardEnabled(clipboardEnabled)

        hotKey = HotKey(keyCode: kVK_ANSI_T, modifiers: controlKey | optionKey) { [weak self] in
            self?.toggle()
        }

        setUpStatusItem()
        watchMenuBarClicks()

        Markup.shared.onSaved = { [weak self] url in self?.line.reloadThumbnail(for: url) }
        Markup.shared.onEditingChanged = { [weak self] url in self?.line.editingURL = url }
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
                    self?.workspaceChanged()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.workspaceChanged() }
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel.placeOnScreen()
                self?.updateCapacity()
            }
        }

        if screenshotFolder == nil, !Inbox.wasOffered {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.offerInbox() }
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
        clipboardWatcher?.stop()
        line.cancelClipboardPreparation()
        watcher?.stop()
        safetyWatcher?.stop()
        screenshotLocationMonitor?.stop()
        stopMouseTracking()
        if screenshotFolder == nil { Inbox.restore() }
        prepareScreenshotFolder()
    }

    private func setClipboardEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: "clipboardEnabled")
        clipboardWatcher?.stop()
        clipboardWatcher = nil
        line.cancelClipboardPreparation()
        guard enabled else { return }
        let watcher = ClipboardWatcher(pasteboard: capturePasteboard) { [weak self] payload in
            self?.line.ingestClipboardInBackground(payload) ?? false
        }
        clipboardWatcher = watcher
        watcher.start()
    }

    // MARK: Inbox mode

    private func prepareScreenshotFolder() {
        guard screenshotFolder == nil else { return }
        do { try ScreenshotLocation.prepare() }
        catch {
            log.error("Could not prepare the Desktop screenshot folder: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func startWatcher(folder: URL? = nil, startedAt: Date = Date()) {
        screenshotLocationMonitor?.stop()
        screenshotLocationMonitor = nil
        watcher?.stop()
        safetyWatcher?.stop()
        safetyWatcher = nil
        watcher = ScreenshotWatcher(
            folder: screenshotFolder ?? folder,
            startedAt: startedAt,
            onNew: { [weak self] url in self?.hangCapture(url) ?? false },
            onChange: { [weak self] in self?.line.prune() })
        watcher.start()
        if screenshotFolder == nil {
            let monitor = ScreenshotLocationMonitor(folder: watcher.folder, checkedAt: startedAt) { [weak self] folder, cutoff in
                self?.startWatcher(folder: folder, startedAt: cutoff)
            }
            screenshotLocationMonitor = monitor
            monitor.start()
        }
        if screenshotFolder == nil, Inbox.isEnabled, watcher.folder.standardizedFileURL != ScreenshotWatcher.desktop.standardizedFileURL {
            let safety = ScreenshotWatcher(
                folder: ScreenshotWatcher.desktop,
                startedAt: startedAt,
                onNew: { [weak self] url in
                    log.notice("Screenshot landed on the Desktop despite inbox mode: \(url.lastPathComponent, privacy: .public)")
                    return self?.hangCapture(url) ?? false
                },
                onChange: { [weak self] in self?.line.prune() })
            safety.start()
            safetyWatcher = safety
        }
    }

    private func setInbox(_ on: Bool) {
        guard screenshotFolder == nil else { return }
        Inbox.isEnabled = on
        if on { applyInbox() }
        else {
            Inbox.restore()
            prepareScreenshotFolder()
        }
        startWatcher()
    }

    private func applyInbox() {
        do { try Inbox.apply() }
        catch {
            Inbox.restore()
            Inbox.isEnabled = false
            prepareScreenshotFolder()
            log.error("Could not prepare the screenshot inbox: \(error.localizedDescription, privacy: .private)")
            NSSound.beep()
        }
    }

    /// Asked once. Changing system settings is the user's call, never ours.
    private func offerInbox() {
        guard screenshotFolder == nil else { return }
        Inbox.wasOffered = true
        let alert = NSAlert()
        alert.messageText = L("Let Clipline handle your screenshots?",
                              "¿Quieres que Clipline se encargue de tus capturas?")
        alert.informativeText = L(
            "Screenshots will hang on the line the instant you take them, without the floating thumbnail, and will not pile up on your Desktop. Drag one to a folder to keep it, or discard it with the cross. You can turn this off from the menu bar, and your settings come back when Clipline quits.",
            "Las capturas se colgarán al instante, sin la miniatura flotante, y no se acumularán en el Escritorio. Arrastra una a una carpeta para guardarla, o descártala con la cruz. Puedes desactivarlo desde la barra de menús, y tus ajustes vuelven a ser los de antes al salir de Clipline.")
        alert.addButton(withTitle: L("Turn on", "Activar"))
        alert.addButton(withTitle: L("Not now", "Ahora no"))
        if let icon = NSImage(named: "Clipline") ?? NSApp.applicationIconImage { alert.icon = icon }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { setInbox(true) }
    }

    /// Quitting from the menu or logging out runs applicationWillTerminate.
    /// A plain kill does not, so settings are also restored on those signals.
    private func restoreSettingsOnTermination() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                if self?.screenshotFolder == nil { Inbox.restore() }
                self?.prepareScreenshotFolder()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Showing and hiding

    private func captureAdded() {
        panel.placeOnScreen(pendingScreen)
        pendingScreen = nil
        updateCapacity()
        wanted = true
        refresh()
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

    // MARK: The capture flying to the line

    /// A new screenshot lifts off from where it was taken and flies to its
    /// place on the line. Without a known capture area it simply drops in.
    @discardableResult
    private func hangCapture(_ url: URL) -> Bool {
        if line.items.contains(where: { $0.url == url && !$0.falling }) { return true }
        let from = captureRect(of: url)
        if let from {
            let center = CGPoint(x: from.midX, y: from.midY)
            pendingScreen = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
        }
        guard let id = line.hang(url, flying: from != nil) else {
            pendingScreen = nil
            return false
        }
        guard let from else { return true }
        // Let the line come down and lay out before measuring the landing spot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.fly(id, from: from)
        }
        return true
    }

    private func fly(_ id: UUID, from: CGRect) {
        guard isPresent, isRevealed, let screen = panel.screen,
              let to = cardFrame(for: id),
              let item = line.items.first(where: { $0.id == id }) else {
            line.land(id)
            return
        }
        let pixels = Int(max(from.width, from.height) * screen.backingScaleFactor)
        guard let image = makeThumbnail(item.url, maxPixels: min(3000, max(400, pixels)))?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            line.land(id)
            return
        }
        CaptureFlight.fly(image: image, from: from, to: to, tilt: CGFloat(item.tilt), on: screen,
                          destination: { [weak self] in self?.cardFrame(for: id) }) { [weak self] in
            self?.line.land(id)
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
        guard let index = line.items.firstIndex(where: { $0.id == id }) else { return nil }
        let width = panel.frame.width
        let x = Layout.x(index: index, count: line.items.count, width: width)
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
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func dismiss() {
        guard isPresent else { return }
        isPresent = false
        setRevealed(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.isPresent else { return }
            self.panel.orderOut(nil)
        }
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
    }

    private func setRevealed(_ on: Bool) {
        guard on != isRevealed else { return }
        isRevealed = on
        line.revealed = on
        if !on {
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
            keepOpen = true
            wanted = true
            panel.placeOnScreen()
            updateCapacity()
            refresh()
            reveal(pinned: true)
        }
    }

    private func startMouseTracking() {
        guard mouseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func stopMouseTracking() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        panel.ignoresMouseEvents = true
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
        if GrabView.isDragging || GrabView.isPresentingMenu || line.pressedID != nil {
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
        line.maxItems = Layout.capacity(width: panel.frame.width)
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Clipline")
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

        let inbox = ClosureMenuItem(L("Handle screenshots", "Encargarse de las capturas")) { [weak self] in
            self?.setInbox(!Inbox.isEnabled)
        }
        inbox.state = Inbox.isEnabled ? .on : .off
        inbox.isEnabled = screenshotFolder == nil
        inbox.toolTip = L("Screenshots hang instantly and skip the Desktop",
                          "Las capturas se cuelgan al instante y no pasan por el Escritorio")
        menu.addItem(inbox)

        menu.addItem(ClosureMenuItem(L("Open screenshots folder", "Abrir carpeta de capturas")) { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.watcher.folder)
        })

        menu.addItem(.separator())

        let sound = ClosureMenuItem(L("Sounds", "Sonidos")) { [weak self] in
            guard let self else { return }
            self.line.soundOn.toggle()
        }
        sound.state = line.soundOn ? .on : .off
        menu.addItem(sound)

        let login = ClosureMenuItem(L("Open at login", "Abrir al iniciar sesión")) {
            AppDelegate.toggleLaunchAtLogin()
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Quit Clipline", "Salir de Clipline"), key: "q") {
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
            alert.informativeText = L("Move Clipline to the Applications folder and try again.",
                                      "Mueve Clipline a la carpeta Aplicaciones y vuelve a intentarlo.")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
