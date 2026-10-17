import CoreGraphics
import Darwin
import Foundation
import ImageIO

/// ScreenshotWatcher retries until the card is accepted. Decode on a serial
/// worker, then publish an immutable image on the main actor in capture order.
@MainActor
final class ScreenshotThumbnailLoader {
    private final class Request: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    private struct Revision: Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        static func read(_ url: URL) -> Self? {
            var info = stat()
            let status = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return fstatat(AT_FDCWD, path, &info, 0)
            }
            guard status == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
            return Self(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec,
                changedSeconds: info.st_ctimespec.tv_sec, changedNanoseconds: info.st_ctimespec.tv_nsec)
        }
    }

    private let queue: DispatchQueue
    private let decode: @Sendable (URL) -> CGImage?
    private var pending: [URL: Request] = [:]

    init(queue: DispatchQueue = DispatchQueue(label: "dev.clipline.screenshot-thumbnails", qos: .utility),
         decode: @escaping @Sendable (URL) -> CGImage? = { ScreenshotThumbnailLoader.decodeImage($0) }) {
        self.queue = queue
        self.decode = decode
    }

    func load(_ url: URL, completion: @escaping @MainActor (CGImage?) -> Void) {
        guard pending[url] == nil else { return }
        let request = Request(), decode = decode
        pending[url] = request
        queue.async {
            let prepared: (CGImage, Revision)? = autoreleasepool {
                guard !request.isCancelled, let revision = Revision.read(url),
                      let image = decode(url), !request.isCancelled,
                      Revision.read(url) == revision else { return nil }
                return (image, revision)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pending[url] === request else { return }
                self.pending[url] = nil
                guard !request.isCancelled else { return }
                guard let (image, revision) = prepared, Revision.read(url) == revision else {
                    completion(nil)
                    return
                }
                completion(image)
            }
        }
    }

    func cancelAll() {
        for request in pending.values { request.cancel() }
        pending.removeAll()
    }

    nonisolated private static func decodeImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 480,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}
