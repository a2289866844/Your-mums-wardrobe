import AppKit
import CryptoKit
import ImageIO

/// Public card metadata is kept separate from clipboard formats and storage.
enum ShelfContentKind: String, Codable {
    case image, text, link, file
}

struct ShelfContent: Codable, Equatable {
    var kind: ShelfContentKind
    var title: String
    var subtitle: String
    var previewText: String?
    var linkURL: URL?
    var digest: String?
    /// Finder copies are references, even if the user put the file in Inbox.
    var originalFileReference: Bool?

    static func image(_ url: URL, digest: String? = nil) -> ShelfContent {
        ShelfContent(kind: .image, title: url.lastPathComponent, subtitle: "Image", digest: digest)
    }
}

enum ClipboardPayload: Sendable {
    case image(Data)
    /// Immutable representations from one clipboard change. Decode on the worker.
    case imageRepresentations([Data], fallbackText: String?)
    case text(String)
    case link(URL)
    case files([URL])
}

/// Only content created here is eligible for automatic deletion. External file
/// references, including files in other wardrobe folders, are never owned.
struct ClipboardStore {
    static let textLimit = 1_048_576
    static let imageDataLimit = 64 * 1_048_576
    let folder: URL

    static let defaultFolder: URL = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Clipline/Clipboard", isDirectory: true)

    func write(_ data: Data, kind: ShelfContentKind, extension ext: String, preparedDigest: String? = nil) throws -> (URL, String) {
        let digest = preparedDigest ?? Self.digest(data)
        var url = folder.appendingPathComponent("\(kind.rawValue)-\(digest).\(ext)")
        let fm = FileManager.default
        guard folder.standardizedFileURL == folder.resolvingSymlinksInPath().standardizedFileURL
        else { throw CocoaError(.fileWriteNoPermission) }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        guard safeFolder else { throw CocoaError(.fileWriteNoPermission) }
        if fm.fileExists(atPath: url.path) {
            guard owns(url) else { throw CocoaError(.fileWriteNoPermission) }
            // Markup can modify a generated image in place. Keep that edited
            // card intact if the original bitmap is copied again later.
            if Self.matches(data, at: url) { return (url, digest) }
            url = folder.appendingPathComponent("\(kind.rawValue)-\(digest)-\(UUID().uuidString.lowercased()).\(ext)")
        }
        try data.write(to: url, options: .atomic)
        return (url, digest)
    }

    private var safeFolder: Bool {
        folder.standardizedFileURL == folder.resolvingSymlinksInPath().standardizedFileURL
            && (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false
    }

    func owns(_ url: URL) -> Bool {
        let candidate = url.standardizedFileURL
        guard safeFolder, candidate.deletingLastPathComponent() == folder.standardizedFileURL,
              candidate == candidate.resolvingSymlinksInPath().standardizedFileURL,
              (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]).isSymbolicLink) == false,
              (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return false }
        let parts = candidate.deletingPathExtension().lastPathComponent.split(separator: "-", maxSplits: 2)
        guard (parts.count == 2 || parts.count == 3), parts[1].count == 64,
              parts[1].allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return false }
        if parts.count == 3, UUID(uuidString: String(parts[2])) == nil { return false }
        return ["image": "png", "text": "txt", "link": "webloc"][String(parts[0])] == candidate.pathExtension
    }

    func remove(_ url: URL) {
        guard owns(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Startup also removes generated entries orphaned by a crash between a
    /// saved shelf update and deletion. Give newly written files a grace period
    /// for another process still finishing a save. Unknown filenames remain untouched.
    func removeUnreferenced(keeping urls: Set<URL>, minimumAge: TimeInterval = 24 * 60 * 60) {
        guard safeFolder, let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let kept = Set(urls.map(\.standardizedFileURL))
        for file in files where !kept.contains(file.standardizedFileURL) {
            guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  Date().timeIntervalSince(modified) >= minimumAge else { continue }
            remove(file)
        }
    }

    /// Comparing size first keeps edited collisions from causing an oversized
    /// read. This also checks text cards whose saved digest can become stale.
    static func matches(_ data: Data, at url: URL) -> Bool {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size == data.count,
              let existing = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        return existing == data
    }

    /// Bound the actual read as well as metadata: an editor can grow a backing file.
    static func text(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: textLimit + 1), data.count <= textLimit else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Inspect dimensions before decoding; a tiny compressed input can still
    /// claim a bitmap too large to safely retain on the shelf.
    static func normalizedPNG(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count <= imageDataLimit,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192,
              width * height <= 32_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceShouldCache: false,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
              ] as CFDictionary)
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= imageDataLimit else { return nil }
        return output as Data
    }

    static func link(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: { $0.isWhitespace }),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), ["https", "http", "mailto", "ftp"].contains(scheme),
              (scheme == "mailto" ? !url.path.isEmpty : url.host != nil) else { return nil }
        return url
    }
}
