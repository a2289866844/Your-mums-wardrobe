import Foundation
import ImageIO

/// Watches the folder macOS saves screenshots to and reports new ones.
/// Clipline never takes screenshots itself: you keep your usual shortcut
/// (or CleanShot, or anything else) and the line just picks them up.
final class ScreenshotWatcher {
    let folder: URL
    /// On the Desktop we only accept images with screenshot metadata, either
    /// the macOS extended attribute or EXIF comment. In a dedicated folder,
    /// any image counts.
    private let onlyTaggedScreenshots: Bool
    private var known = Set<String>()
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var recovery: DispatchWorkItem?
    private var active = false
    private var generation = 0
    private var attachment = 0
    private var initializedBaseline = false
    private var reportedOpenFailure = false
    private var retryCounts: [String: Int] = [:]
    private var incompleteSources: [String: DispatchSourceFileSystemObject] = [:]
    private let onNew: (URL) -> Bool
    private let onChange: () -> Void
    private let launchDate: Date
    private let recoveryInterval: TimeInterval
    private let openDirectory: (String) -> Int32
    private let listDirectory: (URL) throws -> [URL]

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp"]

    static let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")

    /// Watches the folder macOS saves screenshots to, or a given folder.
    init(folder: URL? = nil, onlyTaggedScreenshots: Bool? = nil, startedAt: Date = Date(),
         recoveryInterval: TimeInterval = 1,
         openDirectory: @escaping (String) -> Int32 = { open($0, O_EVTONLY) },
         listDirectory: @escaping (URL) throws -> [URL] = {
             try FileManager.default.contentsOfDirectory(
                 at: $0, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])
         },
         onNew: @escaping (URL) -> Bool, onChange: @escaping () -> Void) {
        self.onNew = onNew
        self.onChange = onChange
        self.launchDate = startedAt
        self.recoveryInterval = max(0.01, recoveryInterval)
        self.openDirectory = openDirectory
        self.listDirectory = listDirectory
        self.folder = folder ?? Self.screenshotFolder()
        self.onlyTaggedScreenshots = onlyTaggedScreenshots
            ?? (self.folder.standardizedFileURL.path == Self.desktop.standardizedFileURL.path)
    }

    static func screenshotFolder() -> URL {
        // Read fresh through cfprefsd: inbox mode changes this value at runtime.
        CFPreferencesAppSynchronize("com.apple.screencapture" as CFString)
        // macOS 27 keeps it in "location-screenshot"; earlier versions in "location".
        let domain = "com.apple.screencapture" as CFString
        let raw = (CFPreferencesCopyAppValue("location-screenshot" as CFString, domain) as? String)
            ?? (CFPreferencesCopyAppValue("location" as CFString, domain) as? String)
        return screenshotFolder(configuredPath: raw)
    }

    static func screenshotFolder(configuredPath: String?) -> URL {
        // A missing or temporarily inaccessible destination is still the
        // user's selection. Retry that path instead of getting stuck on Desktop.
        guard let configuredPath, !configuredPath.isEmpty else { return desktop }
        return URL(fileURLWithPath: (configuredPath as NSString).expandingTildeInPath, isDirectory: true)
    }

    func start() {
        stop()
        known = []
        retryCounts = [:]
        initializedBaseline = false
        reportedOpenFailure = false
        active = true
        attach()
    }

    private func attach() {
        guard active, source == nil else { return }
        let fd = openDirectory(folder.path)
        guard fd >= 0 else {
            if !reportedOpenFailure {
                NSLog("Clipline: cannot watch \(folder.path); retrying")
                reportedOpenFailure = true
            }
            scheduleRecovery()
            return
        }
        reportedOpenFailure = false
        attachment += 1
        let currentAttachment = attachment
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .revoke], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self, self.active, self.attachment == currentAttachment,
                  let events = self.source?.data else { return }
            if !events.intersection([.rename, .delete, .revoke]).isEmpty {
                self.source?.cancel()
                self.source = nil
                self.attachment += 1
                self.scheduleRecovery()
            } else {
                self.scheduleScan()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        // Watch before listing, so a capture arriving during startup still
        // generates an event rather than falling into the listing/open gap.
        scan()
    }

    func stop() {
        active = false
        generation += 1
        attachment += 1
        recovery?.cancel()
        recovery = nil
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
        for incomplete in incompleteSources.values { incomplete.cancel() }
        incompleteSources = [:]
    }

    deinit { stop() }

    private func watchIncomplete(_ url: URL) {
        guard incompleteSources[url.path] == nil else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let incomplete = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .attrib, .rename, .delete], queue: .main)
        let currentGeneration = generation
        incomplete.setEventHandler { [weak self] in
            guard let self, self.active, self.generation == currentGeneration else { return }
            self.incompleteSources.removeValue(forKey: url.path)?.cancel()
            self.scheduleScan()
        }
        incomplete.setCancelHandler { close(fd) }
        incompleteSources[url.path] = incomplete
        incomplete.resume()
    }

    private func scheduleScan(resetRetries: Bool = true) {
        guard active else { return }
        if resetRetries { retryCounts = [:] }
        pending?.cancel()
        let currentGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active, self.generation == currentGeneration else { return }
            self.pending = nil
            self.scan()
        }
        pending = work
        // macOS writes a hidden temp file and renames it; give it a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func scan() {
        guard active else { return }
        guard source != nil else {
            scheduleRecovery()
            return
        }
        guard let files = listing() else {
            scheduleRecovery()
            return
        }
        recovery?.cancel()
        recovery = nil
        if !initializedBaseline {
            // Preserve the original cutoff across denied access and retries.
            known.formUnion(files.filter { creationDate($0) < launchDate }.map(\.path))
            initializedBaseline = true
        }
        let paths = Set(files.map(\.path))
        known.formIntersection(paths)
        retryCounts = retryCounts.filter { paths.contains($0.key) }
        for path in incompleteSources.keys.filter({ !paths.contains($0) }) {
            incompleteSources.removeValue(forKey: path)?.cancel()
        }
        var needsRetry = false
        for url in files where !known.contains(url.path) {
            guard Self.imageExtensions.contains(url.pathExtension.lowercased()) else { continue }
            if onlyTaggedScreenshots, !isScreenCapture(url) {
                // Screenshot metadata can arrive after the image itself. Poll
                // briefly without keeping a file descriptor for every ordinary
                // image added to the Desktop.
                if retryNeeded(url) { needsRetry = true }
                continue
            }
            if onNew(url) {
                known.insert(url.path)
                retryCounts[url.path] = nil
                incompleteSources.removeValue(forKey: url.path)?.cancel()
            } else {
                // Updating an existing file does not necessarily notify the
                // directory watcher. Watch rejected files themselves as well.
                watchIncomplete(url)
                // A file may exist before it can be decoded. Do not mark it
                // handled until the line actually accepted it. Bound retries
                // for a damaged image; a later file event starts another try.
                if retryNeeded(url) { needsRetry = true }
            }
        }
        onChange()
        if needsRetry { scheduleScan(resetRetries: false) }
    }

    private func listing() -> [URL]? {
        guard let urls = try? listDirectory(folder) else { return nil }
        return urls.sorted { creationDate($0) < creationDate($1) }
    }

    private func scheduleRecovery() {
        guard active, recovery == nil else { return }
        let currentGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active, self.generation == currentGeneration else { return }
            self.recovery = nil
            if self.source == nil { self.attach() }
            else { self.scan() }
        }
        recovery = work
        DispatchQueue.main.asyncAfter(deadline: .now() + recoveryInterval, execute: work)
    }

    private func creationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    private func retryNeeded(_ url: URL) -> Bool {
        let attempts = (retryCounts[url.path] ?? 0) + 1
        retryCounts[url.path] = attempts
        return attempts < 10
    }

    private func isScreenCapture(_ url: URL) -> Bool {
        let tagged = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) >= 0
        }
        if tagged { return true }
        // Current macOS captures may carry this EXIF marker without the
        // Spotlight extended attribute. ImageIO reads metadata without decoding
        // the image, and ordinary images still need an explicit capture marker.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] else { return false }
        return exif[kCGImagePropertyExifUserComment as String] as? String == "Screenshot"
    }
}
