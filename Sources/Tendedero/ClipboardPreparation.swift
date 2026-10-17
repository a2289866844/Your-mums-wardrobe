import AppKit
import Darwin
import ImageIO

/// Only immutable image/file results cross back to the main actor.
final class ClipboardPreparation: @unchecked Sendable {
    struct FileVersion: Equatable {
        let size: Int64
        let modified: timespec
        let changed: timespec
        let device: Int32
        let inode: UInt64
        static func == (a: Self, b: Self) -> Bool {
            a.size == b.size && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec &&
            a.changed.tv_sec == b.changed.tv_sec && a.changed.tv_nsec == b.changed.tv_nsec && a.device == b.device && a.inode == b.inode
        }
        static func read(_ url: URL) -> Self? {
            var info = stat()
            let status = url.withUnsafeFileSystemRepresentation { pointer in
                pointer.map { fstatat(AT_FDCWD, $0, &info, 0) } ?? -1
            }
            guard status == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= ClipboardStore.imageDataLimit else { return nil }
            return Self(size: info.st_size, modified: info.st_mtimespec, changed: info.st_ctimespec, device: info.st_dev, inode: info.st_ino)
        }
    }
    struct File: @unchecked Sendable {
        let url: URL
        let thumbnail: CGImage?
        let digest: String?
    }
    enum Result: @unchecked Sendable {
        case image(File)
        case files([File])
        case duplicate(digest: String)
    }
    private let store: ClipboardStore
    private let queue = DispatchQueue(label: "dev.clipline.clipboard-preparation", qos: .userInitiated)
    private let lock = NSLock()
    private var digests: [URL: (FileVersion, String?)] = [:]
    private let normalize: @Sendable (Data) -> Data?

    init(store: ClipboardStore, normalize: @escaping @Sendable (Data) -> Data? = { ClipboardStore.normalizedPNG($0) }) {
        self.store = store
        self.normalize = normalize
    }
    func cachedDigest(_ url: URL) -> String? {
        let key = url.standardizedFileURL
        guard let version = FileVersion.read(key) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let entry = digests[key], entry.0 == version else { return nil }
        return entry.1
    }
    private func remember(_ digest: String?, at url: URL, version: FileVersion) {
        lock.lock(); digests[url.standardizedFileURL] = (version, digest); lock.unlock()
    }
    private func digest(_ url: URL) -> String? {
        guard let version = FileVersion.read(url) else { return nil }
        lock.lock(); let old = digests[url.standardizedFileURL]; lock.unlock()
        if let old, old.0 == version { return old.1 }
        let result = autoreleasepool {
            (try? Data(contentsOf: url, options: .mappedIfSafe)).flatMap(normalize).map(ClipboardStore.digest)
        }
        guard FileVersion.read(url) == version else { return nil }
        remember(result, at: url, version: version)
        return result
    }
    func prepare(_ payload: ClipboardPayload, candidates: [URL], completion: @escaping @MainActor (Result?) -> Void) {
        queue.async {
            let result = autoreleasepool { self.make(payload, candidates: candidates) }
            DispatchQueue.main.async { completion(result) }
        }
    }
    /// Compatibility for deterministic model callers; production uses prepare.
    func prepareSynchronously(_ payload: ClipboardPayload, candidates: [URL]) -> Result? {
        queue.sync { autoreleasepool { make(payload, candidates: candidates) } }
    }
    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            queue.async { DispatchQueue.main.async { continuation.resume() } }
        }
    }
    private func make(_ payload: ClipboardPayload, candidates: [URL]) -> Result? {
        let retained = Set(candidates.map(\.standardizedFileURL))
        lock.lock()
        if digests.count > max(160, retained.count + 20) { digests = digests.filter { retained.contains($0.key) } }
        lock.unlock()
        switch payload {
        case .image(let data):
            guard let png = normalize(data) else { return nil }
            let hash = ClipboardStore.digest(png)
            if candidates.contains(where: { digest($0) == hash }) { return .duplicate(digest: hash) }
            guard let (url, _) = try? store.write(png, kind: .image, extension: "png", preparedDigest: hash),
                  let thumbnail = Self.thumbnail(url) else { return nil }
            if let version = FileVersion.read(url) { remember(hash, at: url, version: version) }
            return .image(File(url: url, thumbnail: thumbnail, digest: hash))
        case .files(let urls):
            let files = urls.filter { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }.map { url in
                let thumbnail = Self.thumbnail(url)
                return File(url: url, thumbnail: thumbnail, digest: thumbnail == nil ? nil : digest(url))
            }
            // Warm hashes once on the worker, never while handling a mouse/copy event.
            if files.contains(where: { $0.digest != nil }) { for url in candidates { _ = digest(url) } }
            return files.isEmpty ? nil : .files(files)
        default: return nil
        }
    }
    static func thumbnail(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 480,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}
