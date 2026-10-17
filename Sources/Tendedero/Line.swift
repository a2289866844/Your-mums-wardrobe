import AppKit
import Combine
import Darwin
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
    @Published private(set) var copyFailedID: UUID?
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

    var maxItems = 8 {
        didSet { enforceCapacity() }
    }
    /// The system editor can outlive a card interaction. Its file stays alive until dismissal.
    var editingURL: URL? {
        didSet { if oldValue != editingURL { interactionChanged() } }
    }
    /// Called for each new capture, even when the line is already at capacity.
    var onCapture: (() -> Void)?
    var onCopyFeedback: (() -> Void)?
    private let defaults: UserDefaults
    private let copyPasteboard: NSPasteboard
    private var copyFeedbackToken = UUID()
    private let clipboardStore: ClipboardStore
    private let clipboardPreparation: ClipboardPreparation
    private var clipboardPreparationGeneration = 0
    private struct PendingClipboard {
        let id = UUID()
        let payload: ClipboardPayload
        var retries = 2
    }
    private var pendingClipboard: [PendingClipboard] = []
    private var clipboardPreparationActive = false
    private var dropCompletionTokens: [UUID: UUID] = [:]
    private var originalClipboardFiles: Set<URL> = []
    private struct ClipboardFileLease: Codable {
        let url: URL
        let pasteboardName: String
        let changeCount: Int
    }
    private var clipboardFileLease: ClipboardFileLease?
    private var clipboardLeaseTimer: Timer?
    private let clipboardLeaseKey = "clipboardFileLease"

    var soundOn: Bool {
        get { !defaults.bool(forKey: "soundOff") }
        set { defaults.set(!newValue, forKey: "soundOff") }
    }

    var liveCount: Int { items.filter { !$0.falling }.count }

    private let storeKey = "pegged"

    init(defaults: UserDefaults = .standard, clipboardFolder: URL = ClipboardStore.defaultFolder,
         copyPasteboard: NSPasteboard = .general, clipboardPreparation: ClipboardPreparation? = nil) {
        self.defaults = defaults
        self.copyPasteboard = copyPasteboard
        clipboardStore = ClipboardStore(folder: clipboardFolder)
        self.clipboardPreparation = clipboardPreparation ?? ClipboardPreparation(store: clipboardStore)
        originalClipboardFiles = Set((defaults.stringArray(forKey: "clipboardOriginalFiles") ?? [])
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter { FileManager.default.fileExists(atPath: $0.path) })
        restore()
        for item in items where item.content.originalFileReference == true { protectOriginal(item.url) }
        persistOriginalFiles()
        restoreClipboardLease()
        var keptFiles = Set(items.map(\.url)).union(originalClipboardFiles)
        if let lease = clipboardFileLease { keptFiles.insert(lease.url) }
        clipboardStore.removeUnreferenced(keeping: keptFiles)
        scheduleGust()
    }

    deinit { clipboardLeaseTimer?.invalidate() }

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

    private func isProtected(_ item: Pegged) -> Bool {
        item.id == draggingID || item.id == pressedID || item.url.standardizedFileURL == editingURL?.standardizedFileURL
    }

    private func isProtectedURL(_ url: URL) -> Bool {
        items.contains { isProtected($0) && $0.url.standardizedFileURL == url.standardizedFileURL }
    }

    private func enforceCapacity() {
        // A card in use keeps its place and backing file. Preserve the newest
        // copy as well; the shelf can temporarily exceed capacity until release.
        let capacity = max(0, maxItems)
        let newest = capacity > 0 ? items.last(where: { !$0.falling })?.id : nil
        while liveCount > capacity,
              let oldest = items.first(where: { !$0.falling && !isProtected($0) && $0.id != newest }) {
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
               !self.originalClipboardFiles.contains(removed.url.standardizedFileURL),
               self.clipboardFileLease?.url != removed.url.standardizedFileURL,
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
        prune()
        switch payload {
        case .image, .imageRepresentations, .files:
            return applyPreparedClipboard(clipboardPreparation.prepareSynchronously(payload, candidates: imageCandidates))
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
        if kind != .image, items.contains(where: {
            !$0.falling && $0.kind == kind && $0.content.digest == digest
                && (kind != .text || ClipboardStore.matches(data, at: $0.url))
        }) { return true }
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

    private var imageCandidates: [URL] {
        items.filter { !$0.falling && $0.kind == .image }.map(\.url)
    }

    /// Production clipboard capture returns immediately; only immutable results
    /// come back to the main actor. All payloads share the queue to retain order.
    @discardableResult
    func ingestClipboardInBackground(_ payload: ClipboardPayload) -> Bool {
        // Finder references become originals before yielding, even when the
        // prior card is already falling and its cleanup deadline is near.
        if case .files(let urls) = payload {
            var upgraded = false
            for url in urls where url.isFileURL && FileManager.default.fileExists(atPath: url.path) {
                protectOriginal(url)
                let original = url.resolvingSymlinksInPath().standardizedFileURL
                for index in items.indices where items[index].url.resolvingSymlinksInPath().standardizedFileURL == original
                    && items[index].content.originalFileReference != true {
                    items[index].content.originalFileReference = true
                    upgraded = true
                }
            }
            if upgraded { save() }
        }
        pendingClipboard.append(PendingClipboard(payload: payload))
        prepareNextClipboard()
        return true
    }

    private func prepareNextClipboard() {
        guard !clipboardPreparationActive, let request = pendingClipboard.first else { return }
        clipboardPreparationActive = true
        let generation = clipboardPreparationGeneration
        clipboardPreparation.prepare(request.payload, candidates: imageCandidates) { [weak self] result in
            guard let self else { return }
            defer {
                self.clipboardPreparationActive = false
                self.prepareNextClipboard()
            }
            guard self.clipboardPreparationGeneration == generation,
                  self.pendingClipboard.first?.id == request.id else { return }
            self.prune()
            guard self.clipboardPreparationGeneration == generation,
                  self.pendingClipboard.first?.id == request.id else { return }
            let accepted = self.applyPreparedClipboard(result, generation: generation)
            // onCapture can pause capture or enqueue another payload synchronously.
            guard self.clipboardPreparationGeneration == generation,
                  self.pendingClipboard.first?.id == request.id else { return }
            var retry = false
            if !accepted, request.retries > 0 {
                switch result {
                case .duplicate?, .image?, .files?: retry = true
                default: break
                }
            }
            if retry { self.pendingClipboard[0].retries -= 1 }
            else { self.pendingClipboard.removeFirst() }
            // Retry the same logical capture before newer captures are prepared.
        }
    }

    func cancelClipboardPreparation() {
        clipboardPreparationGeneration += 1
        pendingClipboard.removeAll()
    }

    func waitForClipboardPreparation() async {
        while clipboardPreparationActive || !pendingClipboard.isEmpty {
            await clipboardPreparation.waitUntilIdle()
        }
    }

    private func hasImage(with digest: String) -> Bool {
        items.contains { !$0.falling && $0.kind == .image && clipboardPreparation.cachedDigest($0.url) == digest }
    }

    private func applyPreparedClipboard(_ result: ClipboardPreparation.Result?, generation: Int? = nil) -> Bool {
        guard let result else { return false }
        switch result {
        case .passthrough(let payload): return ingestClipboard(payload)
        case .duplicate(let digest): return hasImage(with: digest)
        case .image(let image):
            guard let digest = image.digest, let thumbnail = image.thumbnail,
                  ClipboardPreparation.FileVersion.read(image.url) == image.version else { return false }
            if hasImage(with: digest) { return true }
            var content = ShelfContent.image(image.url, digest: digest)
            content.title = "Copied image"
            append(Pegged(url: image.url, thumb: NSImage(cgImage: thumbnail,
                size: NSSize(width: thumbnail.width, height: thumbnail.height)), content: content))
            return true
        case .files(let files):
            var accepted = false
            for file in files {
                if let generation, generation != clipboardPreparationGeneration { return accepted }
                guard ClipboardPreparation.FileVersion.read(file.url) == file.version else { return false }
                protectOriginal(file.url)
                let original = file.url.resolvingSymlinksInPath().standardizedFileURL
                if let index = items.firstIndex(where: { $0.url.resolvingSymlinksInPath().standardizedFileURL == original && !$0.falling }) {
                    if items[index].content.originalFileReference != true {
                        items[index].content.originalFileReference = true
                        save()
                    }
                    accepted = true
                    continue
                }
                if let digest = file.digest, hasImage(with: digest) { accepted = true; continue }
                var content = file.thumbnail != nil ? ShelfContent.image(file.url) : ShelfContent(
                    kind: .file, title: file.url.lastPathComponent,
                    subtitle: file.url.pathExtension.isEmpty ? "File" : file.url.pathExtension.uppercased())
                content.originalFileReference = true
                let thumbnail = file.thumbnail.map { NSImage(cgImage: $0,
                    size: NSSize(width: $0.width, height: $0.height)) }
                    ?? NSWorkspace.shared.icon(forFile: file.url.path)
                append(Pegged(url: file.url, thumb: thumbnail, content: content))
                accepted = true
            }
            return accepted
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

    func copy(_ id: UUID, to pasteboard: NSPasteboard? = nil) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let pasteboard = pasteboard ?? copyPasteboard
        let entry = NSPasteboardItem()
        switch item.kind {
        case .text:
            guard let text = ClipboardStore.text(at: item.url) else { copyFeedback(id, success: false); return }
            entry.setString(text, forType: .string)
        case .link:
            guard let url = item.linkURL else { copyFeedback(id, success: false); return }
            entry.setString(url.absoluteString, forType: .URL)
            entry.setString(url.absoluteString, forType: .string)
        case .image:
            guard FileManager.default.fileExists(atPath: item.url.path) else { copyFeedback(id, success: false); return }
            if let png = pngData(item.url) { entry.setData(png, forType: .png) }
            entry.setString(item.url.absoluteString, forType: .fileURL)
        case .file:
            guard FileManager.default.fileExists(atPath: item.url.path) else { copyFeedback(id, success: false); return }
            entry.setString(item.url.absoluteString, forType: .fileURL)
        }
        entry.setString("1", forType: ClipboardWatcher.ownCopyType)
        pasteboard.clearContents()
        guard pasteboard.writeObjects([entry]) else {
            refreshClipboardLease()
            copyFeedback(id, success: false)
            return
        }
        let leasedURL = item.kind == .image && item.content.originalFileReference != true
            && !originalClipboardFiles.contains(item.url.standardizedFileURL)
            && clipboardStore.owns(item.url) ? item.url.standardizedFileURL : nil
        replaceClipboardLease(with: leasedURL, on: pasteboard)

        copyFeedback(id, success: true)
    }

    private func copyFeedback(_ id: UUID, success: Bool) {
        let token = UUID()
        copyFeedbackToken = token
        copiedID = success ? id : nil
        copyFailedID = success ? nil : id
        onCopyFeedback?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.copyFeedbackToken == token else { return }
            self.copiedID = nil
            self.copyFailedID = nil
        }
    }

    func open(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if item.kind == .image { PreviewWindowCenterer.shared.open(item.url) }
        else { NSWorkspace.shared.open(item.linkURL ?? item.url) }
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

    /// Whether the file lives in wardrobe's own folder. Those are discarded
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
        guard let id = items.first(where: { $0.url == url && !$0.falling })?.id else { return }
        clipboardPreparation.prepare(.files([url]), candidates: []) { [weak self] result in
            guard let self, case .files(let files) = result, let file = files.first,
                  let thumbnail = file.thumbnail,
                  ClipboardPreparation.FileVersion.read(url) == file.version,
                  let index = self.items.firstIndex(where: { $0.id == id && $0.url == url && !$0.falling }) else { return }
            self.items[index].thumb = NSImage(cgImage: thumbnail,
                size: NSSize(width: thumbnail.width, height: thumbnail.height))
            if self.clipboardStore.owns(url) {
                self.items[index].content.digest = file.digest
                self.save()
            }
        }
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

    // MARK: Clipboard file lifetime

    /// File consumers may use the copied file URL long after the card falls.
    /// Poll only the pasteboard counter; private clipboard data is never read.
    func refreshClipboardLease() {
        guard let lease = clipboardFileLease else { return }
        let board = NSPasteboard(name: .init(lease.pasteboardName))
        guard board.changeCount != lease.changeCount || !clipboardStore.owns(lease.url) else { return }
        replaceClipboardLease(with: nil, on: board)
    }

    private func replaceClipboardLease(with url: URL?, on pasteboard: NSPasteboard) {
        let previous = clipboardFileLease?.url
        clipboardLeaseTimer?.invalidate()
        clipboardLeaseTimer = nil
        clipboardFileLease = url.map {
            ClipboardFileLease(url: $0, pasteboardName: pasteboard.name.rawValue, changeCount: pasteboard.changeCount)
        }
        if let lease = clipboardFileLease, let encoded = try? JSONEncoder().encode(lease) {
            defaults.set(encoded, forKey: clipboardLeaseKey)
            startClipboardLeaseTimer()
        } else {
            defaults.removeObject(forKey: clipboardLeaseKey)
        }
        if let previous, previous != url { scheduleReleasedClipboardCleanup(previous) }
    }

    private func restoreClipboardLease() {
        guard let encoded = defaults.data(forKey: clipboardLeaseKey),
              let lease = try? JSONDecoder().decode(ClipboardFileLease.self, from: encoded),
              clipboardStore.owns(lease.url) else {
            defaults.removeObject(forKey: clipboardLeaseKey)
            return
        }
        let url = lease.url.standardizedFileURL
        guard NSPasteboard(name: .init(lease.pasteboardName)).changeCount == lease.changeCount else {
            defaults.removeObject(forKey: clipboardLeaseKey)
            scheduleReleasedClipboardCleanup(url)
            return
        }
        clipboardFileLease = ClipboardFileLease(url: url,
            pasteboardName: lease.pasteboardName, changeCount: lease.changeCount)
        startClipboardLeaseTimer()
    }

    private func startClipboardLeaseTimer() {
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshClipboardLease() }
        }
        clipboardLeaseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func scheduleReleasedClipboardCleanup(_ url: URL) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.clipboardFileLease?.url != url,
                  !self.originalClipboardFiles.contains(url),
                  !self.items.contains(where: { $0.url.standardizedFileURL == url }) else { return }
            self.clipboardStore.remove(url)
        }
    }

    // MARK: Persistence

    /// A Finder reference never becomes disposable just because its card was
    /// removed. Keep this exclusion across restarts without modifying the file.
    private func protectOriginal(_ url: URL) {
        let target = url.resolvingSymlinksInPath().standardizedFileURL
        guard clipboardStore.owns(target), originalClipboardFiles.insert(target).inserted else { return }
        persistOriginalFiles()
    }

    private func persistOriginalFiles() {
        defaults.set(originalClipboardFiles.map(\.path).sorted(), forKey: "clipboardOriginalFiles")
    }

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
        var restored = Set<URL>()
        // Loading is not a new capture: do not enforce the default capacity
        // or overwrite the saved list while it is still being restored.
        let metadata = defaults.dictionary(forKey: "peggedContent") ?? [:]
        items = paths.compactMap { path in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard restored.insert(url).inserted else { return nil }
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
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= ClipboardStore.imageDataLimit,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return ClipboardStore.normalizedPNG(data)
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
