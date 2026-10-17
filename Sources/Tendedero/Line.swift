import AppKit
import Combine
import Darwin
import os
import ClipdCore

let log = Logger(subsystem: "io.github.a2289866844.clipline", category: "line")

/// One copied item or screenshot hanging on the line.
struct Pegged: Identifiable, Equatable {
    let id: UUID
    let url: URL
    var thumb: NSImage
    var content: ShelfContent
    var kind: ShelfContentKind { content.kind }
    var title: String { content.title }
    var subtitle: String { content.subtitle }
    var previewText: String? { content.previewText }
    var linkURL: URL? { content.linkURL }

    init(id: UUID = UUID(), url: URL, thumb: NSImage, content: ShelfContent? = nil, thumbnailPrepared: Bool = true) {
        self.id = id
        self.url = url
        self.thumb = thumb
        self.content = content ?? .image(url)
        self.thumbnailPrepared = thumbnailPrepared
    }
    /// Every photo hangs a little crooked, like on a real line.
    let tilt = Double.random(in: -2.5...2.5)
    var falling = false
    /// Still flying in from where it was captured; the card waits hidden.
    var flying = false
    var thumbnailPrepared = true

    static func == (a: Pegged, b: Pegged) -> Bool {
        a.id == b.id && a.falling == b.falling && a.flying == b.flying && a.thumb === b.thumb && a.content == b.content && a.thumbnailPrepared == b.thumbnailPrepared
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
    var hitRects: [UUID: CGRect] = [:] {
        didSet { if revealed && hitRects != oldValue { onInteractionChange?() } }
    }

    var maxItems = 8 {
        didSet { enforceCapacity() }
    }
    /// Storage capacity is independent of the number of cards on screen.
    static let historyLimit = 120
    @Published var pageSize = 6 { didSet { pageWindowCount = nil } }
    private var pageWindowCount: Int?
    @Published private(set) var pageEndID: UUID?
    @Published private(set) var pageRevision = 0
    private(set) var pagingOlder = true
    var onNavigate: (() -> Void)?
    var onInteractionChange: (() -> Void)?
    var onSearchEnd: (() -> Void)?
    @Published var library: ClipdLibrary?
    @Published var libraryQuery = "" { didSet { if oldValue != libraryQuery { library?.refreshResults() } } }
    @Published var libraryScope: LibraryScope = .recent { didSet { if oldValue != libraryScope { library?.refreshResults() } } }
    @Published var libraryStatus = ""
    var capturedTextFormats: [CapturedTextFormat] = []
    private var pendingText: [UUID: String] = [:]
    @Published var searchFocused = false
    @Published private(set) var libraryResults: [Pegged] = []
    var archivingIDs = Set<UUID>() { didSet { interactionChanged() } }
    var showingLibraryResults: Bool { library != nil && (!libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || libraryScope != .recent) }
    private var editingItem: Pegged?
    private var actionItems: [Pegged] { items + libraryResults + (editingItem.map { [$0] } ?? []) }
    func item(_ id: UUID) -> Pegged? { actionItems.first { $0.id == id && !$0.falling } }

    func setLibraryResults(_ results: [Pegged]) {
        let end = showingLibraryResults ? results.prefix(max(1, pageSize)).last?.id : nil
        guard libraryResults != results || pageEndID != end || pageWindowCount != nil else { return }
        libraryResults = results
        pageWindowCount = nil
        pageEndID = end
        pageRevision += 1
        library?.prepareVisibleThumbnails()
    }

    /// Each closed shelf ends its search session; the next capture must be visible.
    func resetLibraryView() {
        guard !libraryQuery.isEmpty || libraryScope != .recent || !libraryStatus.isEmpty ||
                pageWindowCount != nil || pageEndID != nil || !libraryResults.isEmpty else { return }
        if !libraryQuery.isEmpty { libraryQuery = "" }
        if libraryScope != .recent { libraryScope = .recent }
        if !libraryStatus.isEmpty { libraryStatus = "" }
        pageWindowCount = nil
        if pageEndID != nil { pageEndID = nil }
        if !libraryResults.isEmpty { libraryResults = [] }
        pageRevision += 1
        hitRects = [:]
        library?.prepareVisibleThumbnails()
    }

    func mergeArchivedCards(_ archived: [Pegged]) {
        let old = items.filter { !$0.falling }
        var reused = Set<UUID>()
        let mapped = archived.map { card in
            guard let existing = old.first(where: { !reused.contains($0.id) &&
                ((card.content.historyID != nil && $0.content.historyID == card.content.historyID) ||
                 ($0.content.historyID == nil && $0.url == card.url)) }) else { return card }
            reused.insert(existing.id)
            // A live capture can finish archiving while the startup snapshot
            // loads. Its URL, edits and flight state are newer than that snapshot.
            var current = existing
            if current.content.historyID == nil { current.content = card.content }
            return current
        }
        let mappedIDs = Set(mapped.map(\.id))
        let mappedURLs = Set(mapped.map(\.url))
        items = mapped + old.filter { !mappedIDs.contains($0.id) && !mappedURLs.contains($0.url) }
        enforceCapacity()
        save()
        library?.prepareVisibleThumbnails()
    }

    func linkArchive(_ record: ClipItem, cardID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == cardID && !$0.falling }) else { return }
        let oldURL = items[index].url
        var record = record
        if let pending = pendingText[cardID], record.kind == .text, pending != ClipdLibrary.fullText(record) {
            do {
                try library?.editText(record.id, text: pending)
                if let updated = try library?.store.item(id: record.id) { record = updated }
            } catch { libraryStatus = "編輯尚未寫入歷史，請保留這張卡片"; return }
        }
        if record.kind == .text || record.kind == .link,
           let archived = try? library?.card(for: record) {
            items[index] = Pegged(id: cardID, url: archived.url, thumb: archived.thumb, content: archived.content)
        } else {
            items[index].content.historyID = record.id
            items[index].content.sourceAppName = record.sourceAppName
            items[index].content.isPinned = record.isPinned
            if record.kind == .image { items[index].content.ocrText = record.searchText }
        }
        pendingText[cardID] = nil
        let archiveURL = items[index].url
        // Both apps may have captured the same copy before unification.
        items.removeAll { $0.id != cardID && $0.content.historyID == record.id && !isProtected($0) }
        save()
        if oldURL != archiveURL { scheduleReleasedClipboardCleanup(oldURL) }
    }

    func updateOCR(_ record: ClipItem) {
        for index in items.indices where items[index].content.historyID == record.id { items[index].content.ocrText = record.searchText }
        for index in libraryResults.indices where libraryResults[index].content.historyID == record.id { libraryResults[index].content.ocrText = record.searchText }
        if showingLibraryResults { library?.refreshResults() }
    }

    func setPinned(_ pinned: Bool, historyID: String) {
        for i in items.indices where items[i].content.historyID == historyID { items[i].content.isPinned = pinned }
        for i in libraryResults.indices where libraryResults[i].content.historyID == historyID { libraryResults[i].content.isPinned = pinned }
        save()
    }

    func copyArchived(_ id: String) throws -> Bool {
        guard let library else { return false }
        let success = try library.writeCopy(id, to: copyPasteboard)
        if success, let card = actionItems.first(where: { $0.content.historyID == id }) { copyFeedback(card.id, success: true) }
        return success
    }

    func copyPlainText(_ id: UUID) {
        guard let card = item(id), let historyID = card.content.historyID, let library else { return }
        do { copyFeedback(id, success: try library.writeCopy(historyID, to: copyPasteboard, plainText: true)) }
        catch { copyFeedback(id, success: false) }
    }

    func textForCard(_ id: UUID) -> String? {
        if let text = pendingText[id] { return text }
        guard let card = item(id) else { return nil }
        if let historyID = card.content.historyID, let library,
           let record = try? library.record(historyID) { return ClipdLibrary.fullText(record) }
        return ClipboardStore.text(at: card.url)
    }

    private var liveItems: [Pegged] { (showingLibraryResults ? libraryResults : items).filter { !$0.falling } }
    private var pageEnd: Int {
        let live = liveItems
        guard let pageEndID, let index = live.firstIndex(where: { $0.id == pageEndID }) else { return live.count }
        return index + 1
    }
    var visibleItems: [Pegged] {
        let live = liveItems
        let end = pageEnd
        return Array(live[max(0, end - max(1, pageWindowCount ?? pageSize))..<end])
    }
    func thumbnailPreparationWindow(limit: Int) -> [Pegged] {
        let live = liveItems
        guard limit > 0, !live.isEmpty else { return [] }
        let visibleStart = max(0, pageEnd - max(1, pageWindowCount ?? pageSize))
        let start = max(0, min(visibleStart - pageSize, live.count - limit))
        return Array(live[start..<min(live.count, start + limit)])
    }

    static func thumbnailPlaceholder(for kind: ShelfContentKind) -> NSImage {
        NSImage(systemSymbolName: kind == .image ? "photo" : "doc", accessibilityDescription: nil)!
    }

    func retainPreparedThumbnails(_ retained: Set<UUID>) {
        func demote(_ values: [Pegged]) -> [Pegged] {
            values.map { item in
                guard item.thumbnailPrepared, !retained.contains(item.id), item.kind == .image || item.kind == .file else { return item }
                var item = item
                item.thumb = Self.thumbnailPlaceholder(for: item.kind)
                item.thumbnailPrepared = false
                return item
            }
        }
        let updated = demote(items), results = demote(libraryResults)
        if updated != items { items = updated }
        if results != libraryResults { libraryResults = results }
    }

    func applyPreparedThumbnails(_ images: [UUID: CGImage]) {
        func hydrate(_ values: [Pegged]) -> [Pegged] {
            values.map { item in
                guard let image = images[item.id] else { return item }
                if item.thumbnailPrepared, item.thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) === image { return item }
                var item = item
                item.thumb = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                item.thumbnailPrepared = true
                return item
            }
        }
        let updated = hydrate(items), results = hydrate(libraryResults)
        if updated != items { items = updated }
        if results != libraryResults { libraryResults = results }
    }

    func applyPreparedFileIcons(_ icons: [UUID: NSImage]) {
        func hydrate(_ values: [Pegged]) -> [Pegged] {
            values.map { card in
                guard let icon = icons[card.id] else { return card }
                var card = card
                card.thumb = icon
                card.thumbnailPrepared = true
                return card
            }
        }
        let updated = hydrate(items), results = hydrate(libraryResults)
        if updated != items { items = updated }
        if results != libraryResults { libraryResults = results }
    }

    var hasOlderPage: Bool { pageEnd > max(1, pageSize) }
    var hasNewerPage: Bool { pageEnd < liveItems.count }
    var canNavigate: Bool { draggingID == nil && pressedID == nil && editingURL == nil }

    func showOlderPage() {
        guard hasOlderPage, canNavigate else { return }
        let live = liveItems
        let end = max(1, pageEnd - max(1, pageWindowCount ?? pageSize))
        pagingOlder = true
        pageWindowCount = nil
        pageEndID = live[end - 1].id
        pageRevision += 1
        hitRects = [:]
        library?.prepareVisibleThumbnails()
        onNavigate?()
    }

    func showNewerPage() {
        guard hasNewerPage, canNavigate else { return }
        let live = liveItems
        let start = pageEnd
        let end = min(live.count, start + max(1, pageSize))
        pagingOlder = false
        pageWindowCount = end - start
        pageEndID = end == live.count ? nil : live[end - 1].id
        pageRevision += 1
        hitRects = [:]
        library?.prepareVisibleThumbnails()
        onNavigate?()
    }
    /// The text editor can outlive a card interaction. Its contents stay alive until dismissal.
    var editingURL: URL? {
        didSet {
            if oldValue != editingURL {
                editingItem = editingURL.flatMap { url in actionItems.first { $0.url.standardizedFileURL == url.standardizedFileURL } }
                interactionChanged()
            }
        }
    }
    /// Called for each new capture, even when the line is already at capacity.
    var onCapture: (() -> Void)?
    var onCopyFeedback: (() -> Void)?
    private let defaults: UserDefaults
    private let copyPasteboard: NSPasteboard
    private var copyFeedbackToken = UUID()
    private let clipboardStore: ClipboardStore
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
    private lazy var clipboardPreparation = ClipboardPreparation(store: clipboardStore)

    var soundOn: Bool {
        get { !defaults.bool(forKey: "soundOff") }
        set { defaults.set(!newValue, forKey: "soundOff") }
    }

    var liveCount: Int { items.filter { !$0.falling }.count }

    private let storeKey = "pegged"

    init(defaults: UserDefaults = .standard, clipboardFolder: URL = ClipboardStore.defaultFolder,
         copyPasteboard: NSPasteboard = .general) {
        self.defaults = defaults
        self.copyPasteboard = copyPasteboard
        clipboardStore = ClipboardStore(folder: clipboardFolder)
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
        return hang(url, thumbnail: thumb, quietly: quietly, flying: flying)
    }

    @discardableResult
    func hang(_ url: URL, thumbnail: NSImage, quietly: Bool = false, flying: Bool = false) -> UUID? {
        guard !items.contains(where: { $0.url == url && !$0.falling }) else { return nil }
        var item = Pegged(url: url, thumb: thumbnail)
        item.flying = flying
        append(item, quietly: quietly)
        return item.id
    }

    private func append(_ item: Pegged, quietly: Bool = false) {
        if pageEndID == nil && !showingLibraryResults { pageWindowCount = nil }
        items.append(item)
        library?.archive(item, textFormats: capturedTextFormats, fullText: pendingText[item.id])
        enforceCapacity()
        save()
        if !quietly {
            onCapture?()
            play("Tink", volume: 0.35)
        }
        library?.prepareVisibleThumbnails()
    }

    private func isProtected(_ item: Pegged) -> Bool {
        archivingIDs.contains(item.id) || item.id == draggingID || item.id == pressedID || item.url.standardizedFileURL == editingURL?.standardizedFileURL
    }

    private func isProtectedURL(_ url: URL) -> Bool {
        actionItems.contains { isProtected($0) && $0.url.standardizedFileURL == url.standardizedFileURL }
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
        onInteractionChange?()
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
            self.pendingText[id] = nil
            if removed.content.originalFileReference != true,
               !self.originalClipboardFiles.contains(removed.url.standardizedFileURL),
               self.clipboardFileLease?.url != removed.url.standardizedFileURL,
               !self.actionItems.contains(where: { $0.url.standardizedFileURL == removed.url.standardizedFileURL }) {
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
        if !items.contains(where: { $0.id == id }), let item = libraryResults.first(where: { $0.id == id }) {
            onFall?(item)
            libraryResults.removeAll { $0.id == id }
            hitRects[id] = nil
            return
        }
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].falling else { return }
        onFall?(items[i])
        items[i].falling = true
        if pageEndID == id {
            pageEndID = items[..<i].last(where: { !$0.falling })?.id
        }
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
        for item in items where !item.falling {
            if item.content.historyID != nil && (item.kind == .text || item.kind == .link) { continue }
            if pendingText[item.id] != nil { continue }
            guard !FileManager.default.fileExists(atPath: item.url.path) else { continue }
            drop(item.id, quietly: true)
        }
    }

    /// Returns success for an existing card without revealing the shelf again.
    @discardableResult
    func ingestClipboard(_ payload: ClipboardPayload) -> Bool {
        prune()
        switch payload {
        case .image, .files:
            return applyPreparedClipboard(clipboardPreparation.prepareSynchronously(payload, candidates: imageCandidates))
        case .text(let text):
            guard !text.isEmpty, text.utf8.count <= ClipboardStore.textLimit else { return false }
            if let link = ClipboardStore.link(in: text) { return ingestClipboard(.link(link)) }
            if library != nil {
                let digest = ClipboardStore.digest(Data(text.utf8))
                if items.contains(where: { !$0.falling && $0.kind == .text && $0.content.digest == digest }) { return true }
                let id = UUID()
                let title = String((text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Text").prefix(80))
                let content = ShelfContent(kind: .text, title: title, subtitle: "Text", previewText: String(text.prefix(800)), digest: digest)
                pendingText[id] = text
                append(Pegged(id: id, url: URL(fileURLWithPath: "/clipline-pending/\(id).txt"),
                              thumb: NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)!, content: content))
                return true
            }
            return addManaged(Data(text.utf8), kind: .text, extension: "txt") { _, digest in
                let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Copied text"
                return ShelfContent(kind: .text, title: String(firstLine.prefix(80)), subtitle: "Text",
                                    previewText: String(text.prefix(800)), digest: digest)
            }
        case .link(let url):
            if library != nil, let valid = ClipboardStore.link(in: url.absoluteString), valid.absoluteString.utf8.count <= ClipboardStore.textLimit {
                if items.contains(where: { !$0.falling && $0.linkURL == valid }) { return true }
                let id = UUID()
                pendingText[id] = valid.absoluteString
                let content = ShelfContent(kind: .link, title: valid.host ?? valid.absoluteString, subtitle: "Link", previewText: valid.absoluteString, linkURL: valid)
                append(Pegged(id: id, url: URL(fileURLWithPath: "/clipline-pending/\(id).webloc"),
                              thumb: NSImage(systemSymbolName: "link", accessibilityDescription: nil)!, content: content))
                return true
            }
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

    private var imageCandidates: [URL] { items.filter { !$0.falling && $0.kind == .image }.map(\.url) }

    /// Main-thread clipboard reads stop at immutable data; conversion, hashing,
    /// deduplication and generated-file writes all happen on the worker.
    func ingestClipboardInBackground(_ payload: ClipboardPayload) -> Bool {
        switch payload {
        case .image, .files:
            prune()
            clipboardPreparation.prepare(payload, candidates: imageCandidates) { [weak self] result in
                guard let self else { return }
                let accepted = self.applyPreparedClipboard(result)
                // A candidate can be dismissed while preparation is in flight.
                if !accepted, case .duplicate = result { _ = self.ingestClipboardInBackground(payload) }
            }
            return true
        default: return ingestClipboard(payload)
        }
    }

    func waitForClipboardPreparation() async { await clipboardPreparation.waitUntilIdle() }

    private func hasImage(with digest: String) -> Bool {
        items.contains { !$0.falling && $0.kind == .image && clipboardPreparation.cachedDigest($0.url) == digest }
    }

    private func applyPreparedClipboard(_ result: ClipboardPreparation.Result?) -> Bool {
        guard let result else { return false }
        switch result {
        case .duplicate(let digest): return hasImage(with: digest)
        case .image(let image):
            guard let digest = image.digest, let thumbnail = image.thumbnail else { return false }
            if hasImage(with: digest) { return true }
            var content = ShelfContent.image(image.url, digest: digest)
            content.title = "Copied image"
            append(Pegged(url: image.url, thumb: NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height)), content: content))
            return true
        case .files(let files):
            var accepted = false
            for file in files where FileManager.default.fileExists(atPath: file.url.path) {
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
                let thumbnail = file.thumbnail.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
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
        guard let item = item(id) else { return }
        let pasteboard = pasteboard ?? copyPasteboard
        if let historyID = item.content.historyID, let library {
            do { copyFeedback(id, success: try library.writeCopy(historyID, to: pasteboard)) }
            catch { copyFeedback(id, success: false) }
            return
        }
        let entry = NSPasteboardItem()
        switch item.kind {
        case .text:
            guard let text = textForCard(id) else { copyFeedback(id, success: false); return }
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
        guard let item = item(id) else { return }
        if item.kind == .text { TextCardEditor.shared.open(item, line: self) }
        else { NSWorkspace.shared.open(item.linkURL ?? item.url) }
    }

    /// Keep the card identity and full backing text when saving an edit.
    func updateText(_ id: UUID, text: String) throws {
        guard var item = item(id), item.kind == .text,
              text.utf8.count <= ClipboardStore.textLimit else { throw CocoaError(.fileWriteInvalidFileName) }
        let data = Data(text.utf8)
        if let historyID = item.content.historyID, let library { try library.editText(historyID, text: text) }
        else if pendingText[id] != nil { pendingText[id] = text }
        else {
            guard clipboardStore.owns(item.url) else { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: item.url, options: .atomic)
        }
        item.content.title = String((text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Text").prefix(80))
        item.content.previewText = String(text.prefix(800))
        item.content.digest = ClipboardStore.digest(data)
        for i in items.indices where items[i].id == id { items[i].content = item.content }
        for i in libraryResults.indices where libraryResults[i].id == id { libraryResults[i].content = item.content }
        if editingItem?.id == id { editingItem?.content = item.content }
        save()
    }

    /// Moves the file to the Trash and takes the photo off the line. When a
    /// drag ends on the Dock's Trash, macOS only reports it: deleting the file
    /// is the source app's job, as Finder does.
    func trash(_ id: UUID) {
        guard let item = item(id) else { return }
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
        guard let item = item(id), item.content.originalFileReference != true else { return false }
        return item.url.standardizedFileURL.path.hasPrefix(Inbox.folder.standardizedFileURL.path + "/")
    }

    /// The corner cross and "Take down" both end up here.
    func discard(_ id: UUID) {
        if isInInbox(id) { trash(id) } else { drop(id) }
    }

    /// Inbox mode: keep a screenshot by moving it to the Desktop.
    func saveToDesktop(_ id: UUID) {
        guard let item = item(id) else { return }
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

    func reveal(_ id: UUID) {
        guard let item = item(id) else { return }
        if item.content.historyID != nil && (item.kind == .text || item.kind == .link), let library {
            NSWorkspace.shared.open(library.directory)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: Breeze

    /// Every so often a little wind moves the line. It is the detail that
    /// makes it feel like an object and not a widget.
    private func scheduleGust() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 7...16)) { [weak self] in
            guard let self else { return }
            if self.revealed && !self.items.isEmpty && self.draggingID == nil { self.gust += 1 }
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
                  !self.isProtectedURL(url),
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
        let local = items.filter { !$0.falling && $0.content.historyID == nil && pendingText[$0.id] == nil }
        let paths = local.map(\.url.path)
        defaults.set(paths, forKey: storeKey)
        let metadata = local.reduce(into: [String: Data]()) { result, item in
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
