import AppKit
import ClipdCore
import ImageIO
import UniformTypeIdentifiers

enum LibraryScope: String, CaseIterable {
    case recent, pinned
    var title: String {
        switch self {
        case .recent: return "歷史"
        case .pinned: return "釘選"
        }
    }
}

struct CapturedTextFormat: Sendable {
    let uti: String
    let data: Data
}

/// Clipline owns the UI and capture; ClipdCore owns the archive and its text index.
/// No Clipd panel, hot corner, upload queue, or knowledge-base process is started.
@MainActor
final class ClipdLibrary {
    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipd", isDirectory: true)
    }
    let store: Store
    let directory: URL
    private let ring = ActivationRing()
    private let coordinator: CaptureCoordinator
    private weak var line: Line?
    private var pendingWrite: Task<Void, Never>?
    private var ocrDelayTask: Task<Void, Never>?
    private var ocrWorkTask: Task<Void, Never>?
    private var ocrQueue: [String] = []
    private var queuedOCR = Set<String>()
    private var failedOCR = Set<String>()
    private var ocrPaused = false
    private var stopped = false
    private var queryTask: Task<Void, Never>?
    nonisolated static let preparationLimit = 20
    private var cards: [String: Pegged] = [:]
    private var thumbnailRequest: ReadRequest?
    private var thumbnailTask: Task<Void, Never>?
    private var thumbnailWindowKey = ""
    private var generation = 0
    private var connectionGeneration = 0
    private var queryRequest: ReadRequest?
    private var connectionRequest: ReadRequest?
    private let preparationQueue: DispatchQueue
    private let thumbnailCache = ThumbnailCache()

    /// NSCache is thread-safe; its immutable CGImages can be shared between
    /// the synchronous compatibility path and the preparation queue.
    private final class ThumbnailCache: @unchecked Sendable {
        let images = NSCache<NSString, CGImage>()
        private let lock = NSLock()
        private var keys: [URL: NSString] = [:]
        func remember(_ key: NSString, url: URL) {
            lock.lock(); defer { lock.unlock() }
            if let previous = keys[url], previous != key { images.removeObject(forKey: previous) }
            keys[url] = key
        }
        func retain(_ urls: Set<URL>) {
            lock.lock(); defer { lock.unlock() }
            for (url, key) in keys where !urls.contains(url) { images.removeObject(forKey: key); keys[url] = nil }
        }
        init() {
            images.countLimit = ClipdLibrary.preparationLimit
            images.totalCostLimit = 64 * 1_048_576
        }
    }

    /// Cancellation is checked on the serial preparation queue before entering Store.
    /// Superseded queued searches therefore never begin their database work.
    private final class ReadRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        func checkCancellation() throws {
            lock.lock(); let value = cancelled; lock.unlock()
            if value { throw CancellationError() }
        }
    }

    /// Immutable values created on the preparation queue. Only CGImage crosses
    /// queues; NSImage construction and card publication stay on MainActor.
    private struct PreparedCard: @unchecked Sendable {
        let record: ClipItem
        let url: URL
        let content: ShelfContent
        let image: CGImage?
        let symbol: String?
        let thumbnailPrepared: Bool
    }

    convenience init(directory: URL = defaultDirectory, cacheDirectory: URL = ClipboardStore.defaultFolder) throws {
        let store = try Store(directory: directory)
        try self.init(directory: directory, store: store, cacheDirectory: cacheDirectory)
    }

    init(directory: URL, store: Store, cacheDirectory: URL, preparationQueue: DispatchQueue? = nil) throws {
        self.directory = directory
        self.store = store
        self.preparationQueue = preparationQueue ?? DispatchQueue(label: "dev.clipline.archive-preparation", qos: .userInitiated)
        coordinator = CaptureCoordinator(store: store, ring: ring, ocr: OCRService(avoidsGPU: true), bridge: nil, blobDirectory: directory)
    }

    /// Synchronous compatibility entry point for callers requiring an immediate snapshot.
    func connect(to line: Line, trackApplications: Bool = true) throws {
        _ = attach(to: line, trackApplications: trackApplications)
        let records = Array(try store.recent(limit: Line.historyLimit).reversed())
        let recent = records.compactMap { record in
            Self.prepare(record, directory: directory, cache: thumbnailCache, loadThumbnail: false).map(apply)
        }
        finishConnecting(recent, to: line)
    }

    /// Production startup leaves the main actor free while reading and decoding history.
    func connectInBackground(to line: Line, trackApplications: Bool = true) async throws {
        let token = attach(to: line, trackApplications: trackApplications)
        let store = store, limit = Line.historyLimit
        let request = ReadRequest()
        connectionRequest = request
        let prepared = try await loadCards(request: request) {
            Array(try store.recent(limit: limit).reversed())
        }
        try Task.checkCancellation()
        guard token == connectionGeneration, self.line === line else { throw CancellationError() }
        finishConnecting(prepared.map(apply), to: line)
        await waitForThumbnails()
    }

    private func attach(to line: Line, trackApplications: Bool) -> Int {
        connectionGeneration += 1
        connectionRequest?.cancel()
        stopped = false
        thumbnailWindowKey = ""
        ocrPaused = line.revealed
        self.line = line
        if trackApplications { ring.start() }
        line.library = self
        return connectionGeneration
    }

    private func finishConnecting(_ recent: [Pegged], to line: Line) {
        resumePendingOCR()
        // mergeArchivedCards retains captures that arrived while history was loading.
        line.mergeArchivedCards(recent)
        if !line.showingLibraryResults { line.libraryStatus = "" }
        for item in line.items where !item.falling && item.content.historyID == nil {
            archive(item, importing: true)
        }
    }

    func stop() {
        stopped = true
        ocrDelayTask?.cancel()
        ocrDelayTask = nil
        connectionGeneration += 1
        connectionRequest?.cancel()
        queryRequest?.cancel()
        queryTask?.cancel()
        thumbnailRequest?.cancel()
        thumbnailTask?.cancel()
        ring.stop()
    }

    func archive(_ card: Pegged, importing: Bool = false, textFormats: [CapturedTextFormat] = [], fullText: String? = nil) {
        guard card.content.historyID == nil, let line, !line.archivingIDs.contains(card.id) else { return }
        line.archivingIDs.insert(card.id)
        let source = importing ? nil : NSWorkspace.shared.frontmostApplication
        let sourceID = source?.bundleIdentifier
        let sourceName = source?.localizedName
        let previous = pendingWrite
        let store = store, coordinator = coordinator, root = directory
        let url = card.url, kind = card.kind, title = card.title
        let link = card.linkURL?.absoluteString
        let id = card.id
        let capturedAt = importing
            ? ((try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()) : Date()
        pendingWrite = Task { [weak self, weak line] in
            await previous?.value
            do {
                let record = try await Task.detached(priority: .utility) { () -> ClipItem in
                    if kind == .image {
                        return try await coordinator.storeScreenshot(at: url, takenAt: capturedAt,
                            duplicateWindow: importing ? .greatestFiniteMagnitude : CaptureCoordinator.duplicateWindow)
                    }
                    let text: String
                    var reps: [ItemRepresentation]
                    let itemKind: ItemKind
                    switch kind {
                    case .text:
                        guard let value = fullText ?? ClipboardStore.text(at: url) else { throw CocoaError(.fileReadCorruptFile) }
                        text = value; itemKind = .text
                        reps = [ItemRepresentation(uti: UTType.utf8PlainText.identifier, byteCount: text.utf8.count, inlineText: text)]
                    case .link:
                        guard let value = link else { throw CocoaError(.fileReadCorruptFile) }
                        text = value; itemKind = .link
                        reps = [ItemRepresentation(uti: UTType.url.identifier, byteCount: text.utf8.count, inlineText: text),
                                ItemRepresentation(uti: UTType.utf8PlainText.identifier, byteCount: text.utf8.count, inlineText: text)]
                    case .file:
                        text = url.absoluteString; itemKind = .file
                        reps = [ItemRepresentation(uti: UTType.fileURL.identifier, byteCount: text.utf8.count, inlineText: text)]
                    case .image: fatalError("handled above")
                    }
                    let hash = ClipboardStore.digest(Data(text.utf8))
                    if let existing = try store.existingID(contentHash: hash, within: importing ? .greatestFiniteMagnitude : 30),
                       let item = try store.item(id: existing) { return item }
                    for format in textFormats {
                        let path = "blobs/" + ClipboardStore.digest(format.data) + (format.uti == "public.rtf" ? ".rtf" : ".html")
                        let target = root.appendingPathComponent(path)
                        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        try format.data.write(to: target, options: .atomic)
                        reps.append(ItemRepresentation(uti: format.uti, byteCount: format.data.count, blobPath: path))
                    }
                    let result = ClipItem(id: makeItemID(at: capturedAt), kind: itemKind, capturedAt: capturedAt,
                        contentHash: hash, preview: String(title.prefix(240)), searchText: text,
                        sourceBundleID: sourceID, sourceAppName: sourceName, provenance: importing ? .unknown : .low,
                        representations: reps)
                    try store.insert(result)
                    return result
                }.value
                guard let self, let line else { return }
                line.linkArchive(record, cardID: id)
                self.cards[record.id] = line.item(id)
                if kind == .image { self.resumePendingOCR() }
                if !line.showingLibraryResults { line.libraryStatus = "" }
            } catch {
                line?.libraryStatus = "歷史儲存失敗，卡片仍留在浮層"
                log.error("Clipd archive failed: \(String(describing: error), privacy: .private)")
            }
            line?.archivingIDs.remove(id)
        }
    }

    func waitForWrites() async { await pendingWrite?.value }

    func setOCRPaused(_ paused: Bool) {
        ocrPaused = paused
        if paused { ocrDelayTask?.cancel(); ocrDelayTask = nil }
        else { startOCRWhenIdle() }
    }

    private func enqueueOCR(_ id: String) {
        guard !stopped, !queuedOCR.contains(id), !failedOCR.contains(id) else { return }
        queuedOCR.insert(id)
        ocrQueue.append(id)
        startOCRWhenIdle()
    }

    private func resumePendingOCR() {
        let store = store
        Task { [weak self] in
            let ids = (try? await Task.detached(priority: .utility) { try store.pendingImageOCRIDs(limit: 200) }.value) ?? []
            guard let self, !self.stopped else { return }
            for id in ids where self.ocrQueue.count < 20 { self.enqueueOCR(id) }
        }
    }

    private func startOCRWhenIdle() {
        guard !stopped, !ocrPaused, !ocrQueue.isEmpty, ocrDelayTask == nil, ocrWorkTask == nil else { return }
        ocrDelayTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self else { return }
            self.ocrDelayTask = nil
            guard !self.stopped, !self.ocrPaused, !self.ocrQueue.isEmpty else { return }
            let id = self.ocrQueue.removeFirst(), coordinator = self.coordinator
            self.ocrWorkTask = Task { [weak self] in
                let record = await Task.detached(priority: .utility) { await coordinator.recognizeStoredScreenshot(id) }.value
                guard let self else { return }
                self.ocrWorkTask = nil
                self.queuedOCR.remove(id)
                if let record {
                    if !self.stopped { self.line?.updateOCR(record); self.cards[id] = self.line?.items.first { $0.content.historyID == id } }
                } else { self.failedOCR.insert(id) }
                self.resumePendingOCR()
                self.startOCRWhenIdle()
            }
        }
    }

    func refreshResults() {
        guard let line else { return }
        generation += 1
        let token = generation
        queryTask?.cancel()
        queryRequest?.cancel()
        let query = line.libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = line.libraryScope
        guard !query.isEmpty || scope != .recent else {
            line.setLibraryResults([])
            line.libraryStatus = ""
            return
        }
        let request = ReadRequest()
        queryRequest = request
        queryTask = Task { [weak self, weak line] in
            do {
                if !query.isEmpty { try await Task.sleep(for: .milliseconds(70)) }
                guard let self else { return }
                let store = self.store
                let prepared = try await self.loadCards(request: request) {
                    if !query.isEmpty {
                        return try store.search(query, limit: 200, pinnedOnly: scope == .pinned)
                    }
                    return try store.pinned(limit: 200)
                }
                guard !Task.isCancelled, self.generation == token, let line else { return }
                let mapped = prepared.map(self.apply)
                line.setLibraryResults(mapped)
                let retained = Set((line.items + mapped).compactMap { $0.content.historyID })
                self.cards = self.cards.filter { retained.contains($0.key) }
                line.libraryStatus = mapped.isEmpty ? "沒有符合的內容" : "\(mapped.count) 筆結果\(mapped.count == 200 ? "（最多顯示 200 筆）" : "")"
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, self?.generation == token else { return }
                line?.libraryStatus = "無法讀取歷史，請再試一次"
            }
        }
    }

    private func loadCards(request: ReadRequest,
                           records: @escaping @Sendable () throws -> [ClipItem]) async throws -> [PreparedCard] {
        let root = directory, cache = thumbnailCache
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                preparationQueue.async {
                    do {
                        try request.checkCancellation()
                        let records = try records()
                        var prepared: [PreparedCard] = []
                        for record in records {
                            try request.checkCancellation()
                            if let card = Self.prepare(record, directory: root, cache: cache, loadThumbnail: false) { prepared.append(card) }
                        }
                        try request.checkCancellation()
                        continuation.resume(returning: prepared)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { request.cancel() }
    }

    func card(for record: ClipItem) throws -> Pegged? {
        if let cached = cards[record.id], cached.content.digest == record.contentHash,
           cached.content.isPinned == record.isPinned,
           (record.kind == .text || record.kind == .link || FileManager.default.fileExists(atPath: cached.url.path)) { return cached }
        return Self.prepare(record, directory: directory, cache: thumbnailCache).map(apply)
    }

    nonisolated private static func prepare(_ record: ClipItem, directory: URL,
                                           cache: ThumbnailCache, loadThumbnail: Bool = true) -> PreparedCard? {
        let url: URL
        var content: ShelfContent
        var image: CGImage?
        var symbol: String?
        switch record.kind {
        case .text, .link:
            let text = Self.fullText(record)
            guard text.utf8.count <= ClipboardStore.textLimit else { return nil }
            let isLink = record.kind == .link
            let identity = ClipboardStore.digest(Data(record.id.utf8))
            url = directory.appendingPathComponent(".cards/\(identity).\(isLink ? "webloc" : "txt")")
            if isLink, let link = ClipboardStore.link(in: text) {
                content = ShelfContent(kind: .link, title: link.host ?? text, subtitle: "Link", previewText: text, linkURL: link)
            } else {
                // No need to split and allocate every line of a potentially 1 MiB capture.
                let title = text.drop(while: \.isNewline).prefix(80).prefix(while: { !$0.isNewline })
                content = ShelfContent(kind: .text, title: title.isEmpty ? "Text" : String(title), subtitle: "Text", previewText: String(text.prefix(800)))
            }
            symbol = isLink ? "link" : "doc.text"
        case .image:
            guard let path = record.representations.first(where: { $0.blobPath != nil && UTType($0.uti)?.conforms(to: .image) == true })?.blobPath,
                  let imageURL = safeBlobURL(path, directory: directory),
                  FileManager.default.fileExists(atPath: imageURL.path) else { return nil }
            let version = ClipboardPreparation.FileVersion.read(imageURL)
            let key = (imageURL.path + "\n" + String(describing: version)) as NSString
            if !loadThumbnail { symbol = "photo" }
            else {
            if let cached = cache.images.object(forKey: key) { image = cached }
            else {
                guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 480,
                        kCGImageSourceShouldCacheImmediately: true,
                      ] as CFDictionary) else { return nil }
                cache.images.setObject(thumbnail, forKey: key, cost: thumbnail.bytesPerRow * thumbnail.height)
                cache.remember(key, url: imageURL)
                image = thumbnail
            }
            }
            url = imageURL
            content = .image(url)
            content.originalFileReference = true
            content.ocrText = record.searchText
        case .file:
            guard let path = record.representations.first(where: { $0.uti == UTType.fileURL.identifier })?.inlineText,
                  let file = URL(string: path), file.isFileURL,
                  FileManager.default.fileExists(atPath: file.path) else { return nil }
            url = file
            content = ShelfContent(kind: .file, title: file.lastPathComponent, subtitle: file.pathExtension.uppercased())
            content.originalFileReference = true
            if !loadThumbnail { symbol = "doc" }
        case .other: return nil
        }
        content.historyID = record.id
        content.sourceAppName = record.sourceAppName
        content.isPinned = record.isPinned
        content.digest = record.contentHash
        return PreparedCard(record: record, url: url, content: content, image: image, symbol: symbol, thumbnailPrepared: record.kind != .image && record.kind != .file || loadThumbnail)
    }

    private func apply(_ prepared: PreparedCard) -> Pegged {
        if let cached = cards[prepared.record.id], cached.url == prepared.url,
           cached.content == prepared.content, cached.thumbnailPrepared == prepared.thumbnailPrepared { return cached }
        let thumb: NSImage
        if let image = prepared.image {
            thumb = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        } else if let symbol = prepared.symbol {
            thumb = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
        } else {
            thumb = NSWorkspace.shared.icon(forFile: prepared.url.path)
        }
        let result = Pegged(id: cards[prepared.record.id]?.id ?? UUID(), url: prepared.url, thumb: thumb, content: prepared.content, thumbnailPrepared: prepared.thumbnailPrepared)
        cards[prepared.record.id] = result
        return result
    }

    /// Metadata can cover the history/search range; decoded images cover only
    /// the current page and neighbours, with a hard window of twenty cards.
    func prepareVisibleThumbnails() {
        guard let line, !stopped else { return }
        let window = line.thumbnailPreparationWindow(limit: Self.preparationLimit)
        let key = window.map { "\($0.id):\($0.url.path):\(String(describing: ClipboardPreparation.FileVersion.read($0.url)))" }.joined(separator: "\n")
        let needsImages = window.contains { !$0.thumbnailPrepared && ($0.kind == .image || $0.kind == .file) }
        guard key != thumbnailWindowKey || (needsImages && thumbnailTask == nil) else { return }
        thumbnailWindowKey = key
        thumbnailRequest?.cancel()
        thumbnailTask?.cancel()
        let ids = Set(window.map(\.id))
        line.retainPreparedThumbnails(ids)
        for (id, var card) in cards where !ids.contains(card.id) && card.thumbnailPrepared && (card.kind == .image || card.kind == .file) {
            card.thumb = Line.thumbnailPlaceholder(for: card.kind)
            card.thumbnailPrepared = false
            cards[id] = card
        }
        let icons = Dictionary(uniqueKeysWithValues: window.filter { $0.kind == .file && !$0.thumbnailPrepared }.map {
            ($0.id, NSWorkspace.shared.icon(forFile: $0.url.path))
        })
        line.applyPreparedFileIcons(icons)
        for (id, var card) in cards {
            if let icon = icons[card.id] { card.thumb = icon; card.thumbnailPrepared = true; cards[id] = card }
        }
        let requests = window.filter { $0.kind == .image }.map { ($0.id, $0.url) }
        let request = ReadRequest(), cache = thumbnailCache, queue = preparationQueue
        thumbnailRequest = request
        thumbnailTask = Task { [weak self, weak line] in
            let images: [UUID: CGImage] = await withCheckedContinuation { continuation in
                queue.async {
                    guard (try? request.checkCancellation()) != nil else { continuation.resume(returning: [:]); return }
                    cache.retain(Set(requests.map { $0.1 }))
                    var result: [UUID: CGImage] = [:]
                    for (id, url) in requests {
                        guard (try? request.checkCancellation()) != nil else { break }
                        let version = ClipboardPreparation.FileVersion.read(url)
                        let cacheKey = (url.path + "\n" + String(describing: version)) as NSString
                        if let cached = cache.images.object(forKey: cacheKey) { result[id] = cached }
                        else if let image = ClipboardPreparation.thumbnail(url), ClipboardPreparation.FileVersion.read(url) == version {
                            cache.images.setObject(image, forKey: cacheKey, cost: image.bytesPerRow * image.height)
                            cache.remember(cacheKey, url: url)
                            result[id] = image
                        }
                    }
                    continuation.resume(returning: result)
                }
            }
            guard let self, !self.stopped, !Task.isCancelled, self.thumbnailWindowKey == key else { return }
            self.thumbnailTask = nil
            line?.applyPreparedThumbnails(images)
            for (id, var card) in self.cards {
                if let image = images[card.id] {
                    card.thumb = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                    card.thumbnailPrepared = true
                    self.cards[id] = card
                }
            }
        }
    }

    func waitForThumbnails() async { await thumbnailTask?.value }

    func safeBlobURL(_ path: String) -> URL? { Self.safeBlobURL(path, directory: directory) }

    nonisolated private static func safeBlobURL(_ path: String, directory: URL) -> URL? {
        let root = directory.appendingPathComponent("blobs", isDirectory: true).standardizedFileURL
        let candidate = directory.appendingPathComponent(path).standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/"), candidate == candidate.resolvingSymlinksInPath().standardizedFileURL else { return nil }
        return candidate
    }

    func writeCopy(_ id: String, to board: NSPasteboard, plainText: Bool = false) throws -> Bool {
        guard let record = try record(id) else { return false }
        let entry = NSPasteboardItem()
        var count = 0
        if plainText {
            let text = Self.fullText(record)
            guard !text.isEmpty else { return false }
            entry.setString(text, forType: .string); count = 1
        } else {
            for rep in record.representations {
                let type = NSPasteboard.PasteboardType(rep.uti)
                if let text = rep.inlineText { entry.setString(text, forType: type); count += 1 }
                else if let path = rep.blobPath, let url = safeBlobURL(path),
                        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                        size <= ClipboardStore.imageDataLimit, let data = try? Data(contentsOf: url) {
                    entry.setData(data, forType: type); count += 1
                }
            }
        }
        guard count > 0 else { return false }
        entry.setString("1", forType: ClipboardWatcher.ownCopyType)
        board.clearContents()
        return board.writeObjects([entry])
    }

    func record(_ id: String) throws -> ClipItem? {
        return try store.item(id: id)
    }

    func editText(_ id: String, text: String) throws {
        guard text.utf8.count <= ClipboardStore.textLimit else { throw CocoaError(.fileWriteOutOfSpace) }
        guard var record = try store.item(id: id), record.kind == .text else { throw CocoaError(.fileNoSuchFile) }
        record.preview = String(text.prefix(240))
        record.searchText = text
        record.contentHash = ClipboardStore.digest(Data(text.utf8))
        record.representations = [ItemRepresentation(uti: UTType.utf8PlainText.identifier, byteCount: text.utf8.count, inlineText: text)]
        try store.replaceItem(record)
        cards[id] = nil
    }

    func togglePin(_ id: String) throws {
        guard let record = try store.item(id: id) else { return }
        try store.setPinned(!record.isPinned, id: id)
        cards[id] = nil
        line?.setPinned(!record.isPinned, historyID: id)
        refreshResults()
    }

    nonisolated static func fullText(_ item: ClipItem) -> String {
        item.representations.first { $0.uti == UTType.utf8PlainText.identifier }?.inlineText
            ?? item.representations.first { $0.uti == UTType.url.identifier }?.inlineText ?? item.searchText
    }
}
