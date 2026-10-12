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
/// The footer button copies; the card opens or drags, an image hold opens Markup.
struct GrabArea: NSViewRepresentable {
    let item: Pegged
    let line: Line
    let copied: Bool
    let copyFailed: Bool

    func makeNSView(context: Context) -> GrabView {
        let view = GrabView()
        configure(view)
        return view
    }

    func updateNSView(_ view: GrabView, context: Context) {
        configure(view)
    }

    static func dismantleNSView(_ view: GrabView, coordinator: ()) {
        view.cancelPress()
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
        view.onCopy = { line.copy(id) }
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel(item.title)
        view.toolTip = L("Open \(item.title)", "Abrir \(item.title)")
        view.configureAccessibility(title: item.title)
        view.configureCopyButton(title: item.title, copied: copied, failed: copyFailed)
        view.openElement.setAccessibilityHelp(item.kind == .image
            ? L("Open this image. Drag the card to another app. Hold the image for Markup.", "Abre esta imagen. Arrastra la tarjeta a otra app. Mantén pulsada la imagen para Marcación.")
            : L("Open this item. Drag the card to another app.", "Abre este elemento. Arrastra la tarjeta a otra app."))
        view.onDragStart = { line.draggingID = id }
        view.onDragEnd = {
            if line.draggingID == id { line.draggingID = nil }
            // Moved into a folder: it is saved where you wanted it.
            line.prune()
        }
        view.onMoveSettled = { line.prune() }
        view.onTrash = { line.trash(id) }
        view.onDiscard = { line.discard(id) }
        view.onLongPress = { line.markup(id) }
        view.onPressChange = { pressed in
            if pressed { line.pressedID = id }
            else if line.pressedID == id { line.pressedID = nil }
        }
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
    var onCopy: () -> Void = {}
    var onDragStart: () -> Void = {}
    var onDragEnd: () -> Void = {}
    var onMoveSettled: () -> Void = {}
    var onTrash: () -> Void = {}
    var onDiscard: () -> Void = {}
    var onLongPress: () -> Void = {}
    var onPressChange: (Bool) -> Void = { _ in }
    var menuProvider: () -> NSMenu = { NSMenu() }

    let copyButton = CardCopyButton()
    lazy var openElement: CardOpenElement = {
        let element = CardOpenElement()
        element.setAccessibilityRole(.button)
        element.setAccessibilityEnabled(true)
        element.setAccessibilityParent(self)
        element.onPress = { [weak self] in self?.onClick() }
        return element
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        copyButton.target = self
        copyButton.action = #selector(copyItem)
        copyButton.onPressChange = { [weak self] pressed in self?.onPressChange(pressed) }
        addSubview(copyButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        copyButton.frame = NSRect(x: max(0, bounds.width - Frame.inset - 7 - CardCopyButton.width),
                                  y: Frame.inset + (32 - CardCopyButton.height) / 2,
                                  width: CardCopyButton.width, height: CardCopyButton.height)
    }

    func configureAccessibility(title: String) {
        openElement.setAccessibilityLabel(L("Open \(title)", "Abrir \(title)"))
    }

    func configureCopyButton(title: String, copied: Bool, failed: Bool) {
        needsLayout = true
        copyButton.title = copied ? L("Copied", "Copiado") : failed ? L("Retry", "Reintentar") : L("Copy", "Copiar")
        copyButton.image = NSImage(systemSymbolName: copied ? "checkmark" : failed ? "exclamationmark.circle" : "doc.on.doc",
                                   accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        copyButton.contentTintColor = copied ? .systemGreen : failed ? .systemOrange : .labelColor
        copyButton.toolTip = failed
            ? L("Could not copy this item. Click to try again.", "No se pudo copiar este elemento. Haz clic para reintentar.")
            : L("Copy to clipboard", "Copiar al portapapeles")
        copyButton.setAccessibilityLabel(copied ? L("Copied \(title)", "Copiado \(title)")
            : failed ? L("Retry copying \(title)", "Reintentar copiar \(title)") : L("Copy \(title)", "Copiar \(title)"))
    }

    override func accessibilityChildren() -> [Any]? {
        let body = NSRect(x: 0, y: 36, width: bounds.width, height: max(0, bounds.height - 36))
        openElement.setAccessibilityFrame(window?.convertToScreen(convert(body, to: nil)) ?? .zero)
        return [openElement, copyButton]
    }

    @objc private func copyItem() { onCopy() }

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
        let timer = Timer(timeInterval: Self.holdDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.downPoint != nil, !self.startedDrag else { return }
                self.holdTimer = nil
                self.didLongPress = true
                self.onLongPress()
                self.onPressChange(false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func endPress() {
        holdTimer?.invalidate()
        holdTimer = nil
        onPressChange(false)
    }

    /// A removed card must not keep a delayed Markup action or press protection.
    func cancelPress() {
        endPress()
        downPoint = nil
        didLongPress = false
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { cancelPress() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, !startedDrag, !didLongPress else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        // A failed drag still cancels a click/hold. Read text backing files only
        // after crossing the threshold, rather than on every pointer movement.
        guard let writer = dragPasteboardWriter() else { cancelPress(); return }
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
        let releasedInside = bounds.contains(convert(event.locationInWindow, from: nil))
        if downPoint != nil && !startedDrag && !didLongPress && event.clickCount == 1 && releasedInside { onClick() }
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
            if let url { text = ClipboardStore.text(at: url) }
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
        finishDrag(operation: operation)
    }

    func finishDrag(operation: NSDragOperation) {
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
            let done = onMoveSettled
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

/// A real button routes copy presses independently from opening, dragging and Markup.
final class CardCopyButton: NSButton {
    static let width: CGFloat = 86
    static let height: CGFloat = 24
    var onPressChange: (Bool) -> Void = { _ in }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        controlSize = .small
        font = .systemFont(ofSize: 11, weight: .semibold)
        imagePosition = .imageLeading
        imageScaling = .scaleProportionallyDown
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilityPerformPress() -> Bool { performClick(nil); return true }
    override func mouseDown(with event: NSEvent) {
        onPressChange(true)
        defer { onPressChange(false) }
        super.mouseDown(with: event)
    }
}

final class CardOpenElement: NSAccessibilityElement {
    var onPress: () -> Void = {}
    override func accessibilityPerformPress() -> Bool { onPress(); return true }
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
