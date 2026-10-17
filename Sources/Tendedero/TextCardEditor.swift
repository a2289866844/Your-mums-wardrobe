import AppKit

/// A separate key window lets the shelf remain a nonactivating panel.
@MainActor
final class TextCardEditor: NSObject, NSWindowDelegate {
    static let shared = TextCardEditor()
    private var window: NSWindow?
    private var textView: NSTextView?
    private weak var line: Line?
    private var itemID: UUID?

    func open(_ item: Pegged, line: Line) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard line.editingURL == nil, let text = line.textForCard(item.id) else { NSSound.beep(); return }
        self.line = line
        itemID = item.id
        line.editingURL = item.url
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 430),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L("Edit copied text", "Editar texto copiado")
        window.minSize = NSSize(width: 340, height: 240)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let container = NSView()
        window.contentView = container
        let scroll = NSTextView.scrollableTextView()
        let editor = scroll.documentView as! NSTextView
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.font = .systemFont(ofSize: 14)
        editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.string = text
        editor.setAccessibilityLabel(L("Copied text", "Texto copiado"))
        editor.setAccessibilityIdentifier("history-text-editor")
        let save = NSButton(title: L("Save", "Guardar"), target: self, action: #selector(saveText))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: L("Cancel", "Cancelar"), target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancel, save])
        buttons.spacing = 8
        for view in [scroll, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            buttons.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
        self.window = window
        textView = editor
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func saveText() {
        guard let line, let itemID, let textView else { return }
        do {
            try line.updateText(itemID, text: textView.string)
            window?.close()
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Could not save text", "No se pudo guardar el texto")
            alert.informativeText = L("Keep the text under 1 MB and make sure its file is still available.",
                                      "El texto debe ser menor de 1 MB y su archivo debe estar disponible.")
            if let window { alert.beginSheetModal(for: window) }
        }
    }

    @objc private func cancel() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        line?.editingURL = nil
        line = nil
        itemID = nil
        textView = nil
        window = nil
    }
}
