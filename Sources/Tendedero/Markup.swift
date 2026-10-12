import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Opens a screenshot in the system Markup editor, the window macOS shows
/// when you click the thumbnail of a screenshot you just took. It is a
/// system extension, reached through the sharing service it registers.
@MainActor
final class Markup: NSObject, NSSharingServiceDelegate {
    static let shared = Markup()

    /// Called with the file once the edited image has been written back.
    var onSaved: (URL) -> Void = { _ in }
    var onEditingChanged: (URL?) -> Void = { _ in }

    private var editing: URL?
    private var service: NSSharingService?
    private var editingToken: UUID?
    private static let serviceName = NSSharingService.Name("com.apple.MarkupUI.Markup")

    func edit(_ url: URL) {
        guard editing == nil else { NSSound.beep(); return }
        guard let service = NSSharingService(named: Markup.serviceName),
              service.canPerform(withItems: [url]) else {
            // Without the extension, Preview is the closest thing.
            NSWorkspace.shared.open(url)
            return
        }
        guard beginEditing(url, service: service) else { return }
        service.delegate = self
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: [url])
    }

    /// A second editor must never redirect the first editor's result to another file.
    @discardableResult
    func beginEditing(_ url: URL, service: NSSharingService) -> Bool {
        guard editing == nil else { return false }
        editing = url
        self.service = service
        editingToken = UUID()
        onEditingChanged(url)
        return true
    }

    private func finishEditing() {
        service?.delegate = nil
        service = nil
        editingToken = nil
        editing = nil
        onEditingChanged(nil)
    }

    // MARK: NSSharingServiceDelegate

    /// Done was pressed. The extension hands back the edited image and the
    /// host app is the one that writes it over the original file.
    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        MainActor.assumeIsolated {
            guard self.service === sharingService else { return }
            self.save(items)
        }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService,
                                    didFailToShareItems items: [Any], error: Error) {
        MainActor.assumeIsolated {
            guard self.service === sharingService else { return }
            self.finishEditing()
            log.notice("Markup ended without saving: \(error.localizedDescription, privacy: .private)")
        }
    }

    // MARK: Writing back

    private func save(_ items: [Any]) {
        guard let target = editing, let item = items.first else { finishEditing(); return }
        log.notice("Markup returned \(String(describing: type(of: item)), privacy: .public)")

        switch item {
        case let url as URL:
            write(from: url, to: target)
        case let image as NSImage:
            write(data: pngData(image), to: target)
        case let provider as NSItemProvider:
            load(provider, into: target)
        default:
            log.error("Markup returned an unexpected item")
            finishEditing()
        }
    }

    private func load(_ provider: NSItemProvider, into target: URL) {
        guard let token = editingToken else { return }
        let types = provider.registeredTypeIdentifiers
        log.notice("Markup provider types: \(types.joined(separator: ", "), privacy: .public)")

        if types.contains(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    guard self.editingToken == token else { return }
                    if let url { self.write(from: url, to: target) }
                    else { self.finishEditing() }
                }
            }
            return
        }
        // Prefer the original format, then any image format.
        let original = UTType(filenameExtension: target.pathExtension)?.identifier
        let imageType = types.first { $0 == original }
            ?? types.first { UTType($0)?.conforms(to: .image) == true }
        guard let imageType else { finishEditing(); return }
        provider.loadDataRepresentation(forTypeIdentifier: imageType) { data, _ in
            DispatchQueue.main.async {
                guard self.editingToken == token else { return }
                self.write(data: data, to: target)
            }
        }
    }

    private func write(from source: URL, to target: URL) {
        if source.standardizedFileURL == target.standardizedFileURL {
            onSaved(target)
            finishEditing()
        } else {
            write(data: try? Data(contentsOf: source), to: target)
        }
    }

    private func write(data: Data?, to target: URL) {
        defer { finishEditing() }
        guard let data, FileManager.default.fileExists(atPath: target.path),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = UTType(filenameExtension: target.pathExtension), type.conforms(to: .image),
              CGImageSourceGetCount(source) > 0 else { return }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString,
                                                                 CGImageSourceGetCount(source), nil) else { return }
        for index in 0..<CGImageSourceGetCount(source) {
            CGImageDestinationAddImageFromSource(destination, source, index, nil)
        }
        guard CGImageDestinationFinalize(destination) else { return }
        do {
            try (output as Data).write(to: target, options: .atomic)
            onSaved(target)
        } catch {
            log.error("Could not save markup: \(error.localizedDescription, privacy: .private)")
            NSSound.beep()
        }
    }

    private func pngData(_ image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }
}
