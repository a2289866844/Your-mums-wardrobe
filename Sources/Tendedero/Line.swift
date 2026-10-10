import AppKit
import Combine
import os

let log = Logger(subsystem: "io.github.a2289866844.clipline", category: "line")

/// One copied item or screenshot hanging on the line.
struct Pegged: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var thumb: NSImage
    var content: ShelfContent
    var kind: ShelfContentKind { content.kind }
    var title: String { content.title }
    var subtitle: String { content.subtitle }
    var previewText: String? { content.previewText }
    var linkURL: URL? { content.linkURL }

    init(url: URL, thumb: NSImage, content: ShelfContent? = nil) {
        self.url = url
        self.thumb = thumb
        self.content = content ?? .image(url)
    }
    /// Every photo hangs a little crooked, like on a real line.
    let tilt = Double.random(in: -2.5...2.5)
    var falling = false
    /// Still flying in from where it was captured; the card waits hidden.
    var flying = false

    static func == (a: Pegged, b: Pegged) -> Bool {
        a.id == b.id && a.falling == b.falling && a.flying == b.flying && a.thumb === b.thumb && a.content == b.content
    }
}

/// The line itself: what hangs on it and what you can do with each item.
/// External files stay in place. Generated clipboard copies live in a separate store.
@MainActor
final class Line: ObservableObject {
    @Published private(set) var items: [Pegged] = []
    @Published private(set) var gust = 0
    @Published var copiedID: UUID?
    @Published var draggingID: UUID? {
        didSet { if oldValue != draggingID { interactionChanged() } }
    }
    @Published var pressedID: UUID? {
        didSet { if oldValue != pressedID { interactionChanged() } }
    }
    /// Whether the line has slid down into view.
    @Published var revealed = false

    /// Card frames in window coordinates, reported by the views. The panel
    /// uses them to only catch clicks over photos and let the rest through.
    var hitRects: [UUID: CGRect] = [:]

    var maxItems = 8
    /// Called for each new capture, even when the line is already at capacity.
    var onCapture: (() -> Void)?
    private let defaults: UserDefaults
    private let clipboardStore: ClipboardStore
    private var dropCompletionTokens: [UUID: UUID] = [:]

    var soundOn: Bool {
        get { !defaults.bool(forKey: "soundOff") }
        set { defaults.set(!newValue, forKey: "soundOff") }
    }

    var liveCount: Int { items.filter { !$0.falling }.count }

    private let storeKey = "pegged"

    init(defaults: UserDefaults = .standard, clipboardFolder: URL = ClipboardStore.defaultFolder) {
        self.defaults = defaults
        clipboardStore = ClipboardStore(folder: clipboardFolder)
        restore()
        clipboardStore.removeUnreferenced(keeping: Set(items.map(\.url)))
        scheduleGust()
    }

    // MARK: Hanging and dropping

    @discardableResult
    func hang(_ url: URL, quietly: Bool = false, flying: Bool = false) -> UUID? {
        guard !items.contains(where: { $0.url == url && !$0.falling }),
              let thumb = makeThumbnail(url) else { return nil }
        var item = Pegged(url: url, thumb: thumb)
        item.flying = flying
        append(item, quietly: quietly)
        return item.id
    }

    private func append(_ item: Pegged, quietly: Bool = false) {
        items.append(item)
        enforceCapacity()
        save()
        if !quietly {
            onCapture?()
            play("Tink", volume: 0.35)
        }
    }

    private func isProtected(_ id: UUID) -> Bool {
        id == draggingID || id == pressedID
    }

    private func isProtectedURL(_ url: URL) -> Bool {
        items.contains { isProtected($0.id) && $0.url.standardizedFileURL == url.standardizedFileURL }
    }

    private func enforceCapacity() {
        // A card in use keeps its place and backing file. Preserve the newest
        // copy as well; the shelf can temporarily exceed capacity until release.
        let newest = maxItems > 0 ? items.last(where: { !$0.falling })?.id : nil
        while liveCount > maxItems,
              let oldest = items.first(where: { !$0.falling && !isProtected($0.id) && $0.id != newest }) {
            drop(oldest.id, quietly: true)
        }
    }

    private func interactionChanged() {
        enforceCapacity()
        // Invalidate pending cleanup while a URL is in use. Once released,
        // give consumers another full animation interval to read a dragged file.
        for id in Array(dropCompletionTokens.keys) {
            guard let item = items.first(where: { $0.id == id }) else { continue }
            if isProtectedURL(item.url) { dropCompletionTokens[id] = UUID() }
            else { scheduleDropCompletion(id) }
        }
    }

    private func scheduleDropCompletion(_ id: UUID) {
        let token = UUID()
        dropCompletionTokens[id] = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.dropCompletionTokens[id] == token,
                  let removed = self.items.first(where: { $0.id == id }),
                  !self.isProtectedURL(removed.url) else { return }
            self.dropCompletionTokens[id] = nil
            self.items.removeAll { $0.id == id }
            if removed.content.originalFileReference != true,
               !self.items.contains(where: { $0.url.standardizedFileURL == removed.url.standardizedFileURL }) {
                self.clipboardStore.remove(removed.url)
            }
        }
    }

    /// The capture has reached the line: the real card takes over.
    func land(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].flying = false
    }

    /// Called just before a photo starts falling, so the fall can be drawn
    /// over the whole screen.
    var onFall: ((Pegged) -> Void)?

    func drop(_ id: UUID, quietly: Bool = false) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].falling else { return }
        onFall?(items[i])
        items[i].falling = true
        hitRects[id] = nil
        save()
        if !quietly { play("Pop", volume: 0.25) }
        scheduleDropCompletion(id)
    }

    func clear() {
        let live = items.filter { !$0.falling }
        for (n, item) in live.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(n)) { [weak self] in
                self?.drop(item.id, quietly: n > 0)
            }
        }
    }

    /// Photos whose file was deleted or moved away fall off by themselves.
    func prune() {
        for item in items where !item.falling && !FileManager.default.fileExists(atPath: item.url.path) {
            drop(item.id, quietly: true)
        }
    }

    /// Returns success for an existing card without revealing the shelf again.
    @discardableResult
    func ingestClipboard(_ payload: ClipboardPayload) -> Bool {
        switch payload {
        case .files(let urls):
            var accepted = false
            for url in urls where url.isFileURL && FileManager.default.fileExists(atPath: url.path) {
                if items.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL && !$0.falling }) {
                    accepted = true
                    continue
                }
                let image = makeThumbnail(url)
                if image != nil, let digest = imageDigest(url), hasImage(with: digest) {
                    accepted = true
                    continue
                }
                var content = image != nil ? ShelfContent.image(url) : ShelfContent(
                    kind: .file, title: url.lastPathComponent,
                    subtitle: url.pathExtension.isEmpty ? "File" : url.pathExtension.uppercased())
                content.originalFileReference = true
                append(Pegged(url: url, thumb: image ?? NSWorkspace.shared.icon(forFile: url.path), content: content))
                accepted = true
            }
            return accepted
        case .image(let data):
            guard let png = ClipboardStore.normalizedPNG(data) else { return false }
            return addManaged(png, kind: .image, extension: "png") { url, digest in
                var content = ShelfContent.image(url, digest: digest)
                content.title = "Copied image"
                return content
            }
        case .text(let text):
            guard !text.isEmpty, text.utf8.count <= ClipboardStore.textLimit else { return false }
            if let link = ClipboardStore.link(in: text) { return ingestClipboard(.link(link)) }
            return addManaged(Data(text.utf8), kind: .text, extension: "txt") { _, digest in
                let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Copied text"
                return ShelfContent(kind: .text, title: String(firstLine.prefix(80)), subtitle: "Text",
                                    previewText: String(text.prefix(800)), digest: digest)
            }
        case .link(let url):
            guard let valid = ClipboardStore.link(in: url.absoluteString),
                  valid.absoluteString.utf8.count <= ClipboardStore.textLimit,
                  let data = try? PropertyListSerialization.data(fromPropertyList: ["URL": valid.absoluteString], format: .xml, options: 0)
            else { return false }
            return addManaged(data, kind: .link, extension: "webloc") { _, digest in
                ShelfContent(kind: .link, title: valid.host ?? valid.absoluteString, subtitle: "Link",
                             previewText: valid.absoluteString, linkURL: valid, digest: digest)
            }
        }
    }

    private func addManaged(_ data: Data, kind: ShelfContentKind, extension ext: String,
                            content: (URL, String) -> ShelfContent) -> Bool {
        let digest = ClipboardStore.digest(data)
        if kind == .image, hasImage(with: digest) { return true }
        if items.contains(where: { !$0.falling && $0.kind == kind && $0.content.digest == digest }) { return true }
        do {
            let (url, digest) = try clipboardStore.write(data, kind: kind, extension: ext)
            let metadata = content(url, digest)
            guard let thumb = thumbnail(for: url, content: metadata) else { clipboardStore.remove(url); return false }
            append(Pegged(url: url, thumb: thumb, content: metadata))
            return true
        } catch {
            return false
        }
    }

    private func imageDigest(_ url: URL) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= ClipboardStore.imageDataLimit,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let png = ClipboardStore.normalizedPNG(data) else { return nil }
        return ClipboardStore.digest(png)
    }

    private func hasImage(with digest: String) -> Bool {
        items.contains { item in
            guard !item.falling, item.kind == .image else { return false }
            let current = clipboardStore.owns(item.url) ? item.content.digest : imageDigest(item.url)
            return current == digest
        }
    }

    private func thumbnail(for url: URL, content: ShelfContent) -> NSImage? {
        switch content.kind {
        case .image: return makeThumbnail(url)
        case .file: return NSWorkspace.shared.icon(forFile: url.path)
        case .text: return NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Text")
        case .link: return NSImage(systemSymbolName: "link", accessibilityDescription: "Link")
        }
    }

    // MARK: Actions on one photo

    func copy(_ id: UUID, to pasteboard: NSPasteboard = .general) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let entry = NSPasteboardItem()
        switch item.kind {
        case .text:
            guard let text = try? String(contentsOf: item.url, encoding: .utf8) else { return }
            entry.setString(text, forType: .string)
        case .link:
            guard let url = item.linkURL else { return }
            entry.setString(url.absoluteString, forType: .URL)
            entry.setString(url.absoluteString, forType: .string)
        case .image:
            if let png = pngData(item.url) { entry.setData(png, forType: .png) }
            entry.setString(item.url.absoluteString, forType: .fileURL)
        case .file:
            entry.setString(item.url.absoluteString, forType: .fileURL)
        }
        entry.setString("1", forType: ClipboardWatcher.ownCopyType)
        pasteboard.clearContents()
        pasteboard.writeObjects([entry])

        copiedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copiedID == id { self?.copiedID = nil }
        }
    }

    func open(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.open(item.linkURL ?? item.url)
    }

    /// Moves the file to the Trash and takes the photo off the line. When a
    /// drag ends on the Dock's Trash, macOS only reports it: deleting the file
    /// is the source app's job, as Finder does.
    func trash(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            log.notice("Trashed \(item.url.lastPathComponent, privacy: .private)")
            if soundOn { Line.trashSound?.play() }
            drop(id, quietly: true)
        } catch {
            log.error("Could not trash \(item.url.path, privacy: .private): \(error.localizedDescription, privacy: .private)")
            NSSound.beep()
        }
    }

    private static let trashSound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif",
        byReference: true)

    /// Whether the file lives in Clipline's own folder. Those are discarded
    /// to the Trash, or the folder would fill up with forgotten screenshots.
    /// Files anywhere else, like the Desktop, stay where they are.
    func isInInbox(_ id: UUID) -> Bool {
        guard let item = items.first(where: { $0.id == id }), item.content.originalFileReference != true else { return false }
        return item.url.standardizedFileURL.path.hasPrefix(Inbox.folder.standardizedFileURL.path + "/")
    }

    /// The corner cross and "Take down" both end up here.
    func discard(_ id: UUID) {
        if isInInbox(id) { trash(id) } else { drop(id) }
    }

    /// Inbox mode: keep a screenshot by moving it to the Desktop.
    func saveToDesktop(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let target = uniqueURL(in: desktop, for: item.url.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: item.url, to: target)
            drop(id, quietly: true)
        } catch {
            log.error("Could not save to Desktop: \(error.localizedDescription, privacy: .private)")
            NSSound.beep()
        }
    }

    private func uniqueURL(in folder: URL, for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    /// Long press: open the photo in the system Markup editor.
    func markup(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), item.kind == .image else { return }
        Markup.shared.edit(item.url)
    }

    /// After editing, the photo on the line shows the new version.
    func reloadThumbnail(for url: URL) {
        guard let i = items.firstIndex(where: { $0.url == url && !$0.falling }),
              let thumb = makeThumbnail(url) else { return }
        items[i].thumb = thumb
        if clipboardStore.owns(url) { items[i].content.digest = imageDigest(url); save() }
    }

    func reveal(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: Breeze

    /// Every so often a little wind moves the line. It is the detail that
    /// makes it feel like an object and not a widget.
    private func scheduleGust() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 7...16)) { [weak self] in
            guard let self else { return }
            if !self.items.isEmpty && self.draggingID == nil { self.gust += 1 }
            self.scheduleGust()
        }
    }

    // MARK: Persistence

    private func save() {
        let paths = items.filter { !$0.falling }.map(\.url.path)
        defaults.set(paths, forKey: storeKey)
        let metadata = items.filter { !$0.falling }.reduce(into: [String: Data]()) { result, item in
            result[item.url.path] = try? JSONEncoder().encode(item.content)
        }
        defaults.set(metadata, forKey: "peggedContent")
    }

    private func restore() {
        let paths = defaults.stringArray(forKey: storeKey) ?? []
        var restored = Set<String>()
        // Loading is not a new capture: do not enforce the default capacity
        // or overwrite the saved list while it is still being restored.
        let metadata = defaults.dictionary(forKey: "peggedContent") ?? [:]
        items = paths.compactMap { path in
            guard restored.insert(path).inserted else { return nil }
            let url = URL(fileURLWithPath: path)
            let content = (metadata[path] as? Data).flatMap { try? JSONDecoder().decode(ShelfContent.self, from: $0) }
                ?? ShelfContent.image(url)
            guard FileManager.default.fileExists(atPath: path),
                  let thumb = thumbnail(for: url, content: content) else { return nil }
            return Pegged(url: url, thumb: thumb, content: content)
        }
    }

    // MARK: Helpers

    private func play(_ name: String, volume: Float) {
        guard soundOn, let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }

    private func pngData(_ url: URL) -> Data? {
        if url.pathExtension.lowercased() == "png" { return try? Data(contentsOf: url) }
        guard let tiff = NSImage(contentsOf: url)?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

func makeThumbnail(_ url: URL, maxPixels: Int = 480) -> NSImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}
