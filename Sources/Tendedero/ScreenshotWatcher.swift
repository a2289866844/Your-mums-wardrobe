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
    private struct FileIdentity: Equatable {
        let resourceID: AnyHashable?
        let createdAt: Date
    }
    private struct FileRevision: Equatable {
        let identity: FileIdentity
        let modifiedAt: Date?
        let size: Int?
    }
    private struct ImageFile {
        let url: URL
        let revision: FileRevision
        var identity: FileIdentity { revision.identity }
    }
    private struct RetryState {
        let revision: FileRevision
        let attempts: Int
        let needsFileWatch: Bool
    }
    private var known: [String: FileIdentity] = [:]
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var recovery: DispatchWorkItem?
    private var overflowRecovery: DispatchWorkItem?
    private var active = false
    private var generation = 0
    private var attachment = 0
    private var initializedBaseline = false
    private var reportedOpenFailure = false
    private var retries: [String: RetryState] = [:]
    private struct IncompleteWatch {
        let source: DispatchSourceFileSystemObject
        let token: Int
    }
    private var incompleteSources: [String: IncompleteWatch] = [:]
    private var nextIncompleteToken = 0
    private let onNew: (URL) -> Bool
    private let onChange: () -> Void
    private let launchDate: Date
    private let recoveryInterval: TimeInterval
    private let openDirectory: (String) -> Int32
    private let listDirectory: (URL) throws -> [URL]

    private static let maximumIncompleteWatches = 64
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp"]

    static let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")

    /// Watches the folder macOS saves screenshots to, or a given folder.
    init(folder: URL? = nil, onlyTaggedScreenshots: Bool? = nil, startedAt: Date = Date(),
         recoveryInterval: TimeInterval = 1,
         openDirectory: @escaping (String) -> Int32 = { open($0, O_EVTONLY) },
         listDirectory: @escaping (URL) throws -> [URL] = {
             try FileManager.default.contentsOfDirectory(
                 at: $0, includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey, .fileResourceIdentifierKey,
                                              .contentModificationDateKey, .fileSizeKey],
                 options: [.skipsHiddenFiles])
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
            ?? (self.folder.resolvingSymlinksInPath().standardizedFileURL.path
                == Self.desktop.resolvingSymlinksInPath().standardizedFileURL.path)
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
        known = [:]
        retries = [:]
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
                self.cancelIncompleteWatches()
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
        overflowRecovery?.cancel()
        overflowRecovery = nil
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
        cancelIncompleteWatches()
    }

    deinit { stop() }

    private func cancelIncompleteWatches() {
        for watch in incompleteSources.values { watch.source.cancel() }
        incompleteSources = [:]
    }

    private func watchIncomplete(_ url: URL) -> Bool {
        if incompleteSources[url.path] != nil { return true }
        guard incompleteSources.count < Self.maximumIncompleteWatches else { return false }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return false }
        let incomplete = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .attrib, .rename, .delete], queue: .main)
        let currentGeneration = generation
        nextIncompleteToken += 1
        let currentToken = nextIncompleteToken
        incomplete.setEventHandler { [weak self] in
            guard let self, self.active, self.generation == currentGeneration,
                  self.incompleteSources[url.path]?.token == currentToken else { return }
            self.incompleteSources.removeValue(forKey: url.path)?.source.cancel()
            self.retries[url.path] = nil
            self.scheduleScan()
        }
        incomplete.setCancelHandler { close(fd) }
        incompleteSources[url.path] = IncompleteWatch(source: incomplete, token: currentToken)
        incomplete.resume()
        return true
    }

    private func scheduleScan() {
        guard active else { return }
        // Coalesce from the first event. Repeated writes must not push the
        // deadline back indefinitely while the screenshot folder is busy.
        guard pending == nil else { return }
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
        let currentGeneration = generation
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
            for file in files where file.identity.createdAt < launchDate {
                known[file.url.path] = file.identity
            }
            initializedBaseline = true
        }
        let paths = Set(files.map { $0.url.path })
        known = known.filter { paths.contains($0.key) }
        retries = retries.filter { paths.contains($0.key) }
        for path in incompleteSources.keys.filter({ !paths.contains($0) }) {
            incompleteSources.removeValue(forKey: path)?.source.cancel()
        }
        var needsRetry = false
        var hasOverflow = false
        for file in files where known[file.url.path] != file.identity {
            let url = file.url
            if let previous = retries[url.path], previous.revision != file.revision {
                retries[url.path] = nil
                if previous.revision.identity != file.identity {
                    incompleteSources.removeValue(forKey: url.path)?.source.cancel()
                }
            }
            if let state = retries[url.path], state.attempts >= 10 {
                // Overflow checks read only metadata. Decode an exhausted file
                // again only after its revision changes or its own watch fires.
                if state.needsFileWatch {
                    let wasWatching = incompleteSources[url.path] != nil
                    if watchIncomplete(url) {
                        // A newly available descriptor can also mean access
                        // recovered. Retry once as we leave overflow polling.
                        if !wasWatching {
                            retries[url.path] = nil
                            needsRetry = true
                        }
                    } else { hasOverflow = true }
                }
                continue
            }
            if onlyTaggedScreenshots, !isScreenCapture(url) {
                // Screenshot metadata can arrive after the image itself. Poll
                // briefly without keeping a file descriptor for every ordinary
                // image added to the Desktop.
                if retryNeeded(file, needsFileWatch: false) { needsRetry = true }
                continue
            }
            let accepted = onNew(url)
            // A callback may stop or restart the watcher. The old scan must
            // not deliver more captures or change the new run's baseline.
            guard active, generation == currentGeneration else { return }
            if accepted {
                known[url.path] = file.identity
                retries[url.path] = nil
                incompleteSources.removeValue(forKey: url.path)?.source.cancel()
            } else {
                // Updating an existing file does not necessarily notify the
                // directory watcher. Watch rejected files themselves as well.
                if !watchIncomplete(url) { hasOverflow = true }
                // A file may exist before it can be decoded. Do not mark it
                // handled until the line actually accepted it. Bound retries
                // for a damaged image; a later file event starts another try.
                if retryNeeded(file, needsFileWatch: true) { needsRetry = true }
            }
        }
        guard active, generation == currentGeneration else { return }
        onChange()
        guard active, generation == currentGeneration else { return }
        if hasOverflow { scheduleOverflowRecovery() }
        else {
            overflowRecovery?.cancel()
            overflowRecovery = nil
        }
        if needsRetry { scheduleScan() }
    }

    private func listing() -> [ImageFile]? {
        guard let urls = try? listDirectory(folder) else { return nil }
        // Fetch metadata once per candidate rather than during every sort
        // comparison, and never pass image-named directories to ingestion.
        return urls.compactMap { url -> ImageFile? in
            guard Self.imageExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: [
                    .creationDateKey, .isRegularFileKey, .fileResourceIdentifierKey,
                    .contentModificationDateKey, .fileSizeKey]),
                  values.isRegularFile == true else { return nil }
            return ImageFile(url: url, revision: FileRevision(identity: FileIdentity(
                resourceID: values.fileResourceIdentifier as? AnyHashable,
                createdAt: values.creationDate ?? .distantPast),
                modifiedAt: values.contentModificationDate, size: values.fileSize))
        }.sorted {
            if $0.identity.createdAt == $1.identity.createdAt {
                return $0.url.path < $1.url.path
            }
            return $0.identity.createdAt < $1.identity.createdAt
        }
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

    private func scheduleOverflowRecovery() {
        guard active, overflowRecovery == nil else { return }
        let currentGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active, self.generation == currentGeneration else { return }
            self.overflowRecovery = nil
            self.scan()
        }
        overflowRecovery = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func retryNeeded(_ file: ImageFile, needsFileWatch: Bool) -> Bool {
        let attempts = (retries[file.url.path]?.attempts ?? 0) + 1
        retries[file.url.path] = RetryState(revision: file.revision, attempts: attempts,
                                          needsFileWatch: needsFileWatch)
        return attempts < 10
    }

    private func isScreenCapture(_ url: URL) -> Bool {
        let tagged = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            let name = "com.apple.metadata:kMDItemIsScreenCapture"
            let size = getxattr(path, name, nil, 0, 0, 0)
            guard size > 0, size <= 4096 else { return false }
            var data = Data(count: size)
            let count = data.withUnsafeMutableBytes { bytes in
                getxattr(path, name, bytes.baseAddress, bytes.count, 0, 0)
            }
            guard count == size,
                  let value = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return false }
            // Accept Boolean true and the string "1" screenshot markers.
            // Attribute presence alone also accepts explicit false or garbage.
            if let value = value as? Bool { return value }
            return (value as? String) == "1"
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
