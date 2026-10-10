import AppKit
import SwiftUI

/// Bridges each photo to AppKit's drag and drop, so it can be dragged into
/// any app as a real file. Each destination means one thing:
///
/// - An app gets a copy, and the photo stays on the line.
/// - A folder or the Desktop keeps the file, and the photo leaves the line.
/// - The Trash discards it.
/// - Nowhere that accepts it: the photo flies back to the line.
///
/// Click opens, press and hold an image opens Markup, the corner cross discards.
struct GrabArea: NSViewRepresentable {
    let item: Pegged
    let line: Line

    func makeNSView(context: Context) -> GrabView {
        let view = GrabView()
        configure(view)
        return view
    }

    func updateNSView(_ view: GrabView, context: Context) {
        configure(view)
    }

    private func configure(_ view: GrabView) {
        let id = item.id
        let line = line
        view.url = item.url
        view.kind = item.kind
        view.previewText = item.previewText
        view.linkURL = item.linkURL
        view.dragImage = item.thumb
        view.onClick = { line.open(id) }
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(item.title)
        view.setAccessibilityHelp(item.kind == .image
            ? L("Click to open. Drag to another app. Hold for Markup.", "Haz clic para abrir. Arrastra a otra app. Mantén pulsado para Marcación.")
            : L("Click to open. Drag to another app.", "Haz clic para abrir. Arrastra a otra app."))
        view.onDragStart = { line.draggingID = id }
        view.onDragEnd = {
            line.draggingID = nil
            // Moved into a folder: it is saved where you wanted it.
            line.prune()
        }
        view.onTrash = { line.trash(id) }
        view.onDiscard = { line.discard(id) }
        view.onLongPress = { line.markup(id) }
        view.onPressChange = { pressed in line.pressedID = pressed ? id : nil }
        view.menuProvider = {
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem(L("Copy", "Copiar")) { line.copy(id) })
            menu.addItem(ClosureMenuItem(L("Open", "Abrir")) { line.open(id) })
            if item.kind == .image {
                menu.addItem(ClosureMenuItem(L("Markup", "Marcación")) { line.markup(id) })
            }
            menu.addItem(ClosureMenuItem(L("Show in Finder", "Mostrar en Finder")) { line.reveal(id) })
            let inInbox = line.isInInbox(id)
            if inInbox {
                menu.addItem(ClosureMenuItem(L("Save to Desktop", "Guardar en el Escritorio")) { line.saveToDesktop(id) })
            }
            menu.addItem(.separator())
            if inInbox {
                menu.addItem(ClosureMenuItem(L("Discard", "Descartar")) { line.discard(id) })
            } else {
                menu.addItem(ClosureMenuItem(L("Take down", "Descolgar")) { line.discard(id) })
                menu.addItem(ClosureMenuItem(L("Move to Trash", "Mover a la Papelera")) { line.trash(id) })
            }
            return menu
        }
    }
}

final class GrabView: NSView, NSDraggingSource {
    static var isDragging = false
    static var isPresentingMenu = false

    var url: URL?
    var kind: ShelfContentKind = .image
    var previewText: String?
    var linkURL: URL?
    var dragImage: NSImage?
    var onClick: () -> Void = {}
    var onDragStart: () -> Void = {}
    var onDragEnd: () -> Void = {}
    var onTrash: () -> Void = {}
    var onDiscard: () -> Void = {}
    var onLongPress: () -> Void = {}
    var onPressChange: (Bool) -> Void = { _ in }
    var menuProvider: () -> NSMenu = { NSMenu() }

    private var downPoint: NSPoint?
    private var startedDrag = false
    private var holdTimer: Timer?
    private var didLongPress = false

    /// How long you hold before Markup opens. Long enough not to fire on a
    /// slow click, short enough to feel deliberate.
    private static let holdDuration: TimeInterval = 0.45

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The discard cross drawn in the top left corner of the card. It is
    /// handled here because this view sits on top of the SwiftUI card.
    static let crossHitSize: CGFloat = 26

    private func isInCross(_ event: NSEvent) -> Bool {
        let p = convert(event.locationInWindow, from: nil)
        let corner = NSRect(x: 0, y: isFlipped ? 0 : bounds.height - Self.crossHitSize,
                            width: Self.crossHitSize, height: Self.crossHitSize)
        return corner.contains(p)
    }

    override func mouseDown(with event: NSEvent) {
        endPress()
        downPoint = nil
        startedDrag = false
        didLongPress = false
        // The first click already opened the card; a second click must not
        // launch a second window or a second browser navigation.
        guard event.clickCount == 1 else { return }
        if isInCross(event) {
            downPoint = nil
            onDiscard()
            return
        }
        downPoint = event.locationInWindow
        startedDrag = false
        didLongPress = false
        onPressChange(true)
        guard kind == .image else { return }
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.downPoint != nil, !self.startedDrag else { return }
                self.didLongPress = true
                self.onPressChange(false)
                self.onLongPress()
            }
        }
    }

    private func endPress() {
        holdTimer?.invalidate()
        holdTimer = nil
        onPressChange(false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, !startedDrag, let writer = dragPasteboardWriter() else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4, !didLongPress else { return }
        startedDrag = true
        // Transfer protection before releasing the press. Capacity can have
        // changed while the pointer was held, so there must be no unprotected gap.
        GrabView.isDragging = true
        onDragStart()
        endPress()

        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(imageFrame(), contents: dragImage)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        // Released where nothing accepts it: it flies back to the line.
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        endPress()
        if downPoint != nil && !startedDrag && !didLongPress && event.clickCount == 1 { onClick() }
        downPoint = nil
        didLongPress = false
    }

    override func rightMouseDown(with event: NSEvent) {
        endPress()
        downPoint = nil
        Self.isPresentingMenu = true
        onPressChange(true)
        defer { Self.isPresentingMenu = false; onPressChange(false) }
        NSMenu.popUpContextMenu(menuProvider(), with: event, for: self)
    }

    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }

    /// Use the original clipboard semantics instead of leaking managed text
    /// or link backing files to the destination app.
    func dragPasteboardWriter() -> NSPasteboardWriting? {
        switch kind {
        case .image, .file:
            return url.map { $0 as NSURL }
        case .text:
            // Card previews are deliberately shortened; dragging must retain
            // the full stored text rather than only those visible characters.
            let text: String?
            if let url { text = try? String(contentsOf: url, encoding: .utf8) }
            else { text = previewText }
            guard let text else { return nil }
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            return item
        case .link:
            guard let linkURL else { return nil }
            let item = NSPasteboardItem()
            item.setString(linkURL.absoluteString, forType: .URL)
            item.setString(linkURL.absoluteString, forType: .string)
            return item
        }
    }

    func sourceOperations(for context: NSDraggingContext) -> NSDragOperation {
        guard context == .outsideApplication else { return [] }
        return kind == .text || kind == .link ? .copy : [.copy, .move, .delete]
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Apps pick copy. Finder picks move, so a folder or the Desktop keeps
        // the file. Delete is what lets the Dock's Trash accept it.
        sourceOperations(for: context)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        GrabView.isDragging = false
        startedDrag = false
        downPoint = nil
        log.notice("Drag ended with operation \(operation.rawValue, privacy: .public)")
        // Dropped on the Trash: macOS only tells us, we move the file.
        if operation.contains(.delete) {
            onDragEnd()
            onTrash()
            return
        }
        onDragEnd()
        // Finder finishes a move a moment later. Check again then, so a photo
        // saved into a folder leaves the line.
        if operation.contains(.move) {
            let done = onDragEnd
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { done() }
        }
    }

    /// The drag preview keeps the photo's aspect ratio inside the card.
    private func imageFrame() -> NSRect {
        guard let size = dragImage?.size, size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
