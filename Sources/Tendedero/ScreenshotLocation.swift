import Foundation

/// A persistent save destination, separate from Inbox's temporary, disposable storage.
enum ScreenshotLocation {
    private static let configuredKey = "desktopScreenshotFolderConfigured"
    private static let managedFolderKey = "managedDesktopScreenshotFolder"
    private static let domain = "com.apple.screencapture" as CFString

    static func prepare() throws {
        CFPreferencesAppSynchronize(domain)
        try prepare(
            defaults: .standard,
            desktop: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true),
            preferredLanguage: Locale.preferredLanguages.first ?? "en",
            readLocation: { CFPreferencesCopyAppValue($0 as CFString, domain) as? String },
            writeLocation: { key, path in
                CFPreferencesSetAppValue(key as CFString, path as CFString, domain)
                CFPreferencesAppSynchronize(domain)
            })
    }

    /// Reads the raw destination rather than the watcher's existing-directory fallback:
    /// a missing custom destination is still the user's choice.
    static func prepare(
        defaults: UserDefaults,
        desktop: URL,
        preferredLanguage: String,
        readLocation: (String) -> String?,
        writeLocation: (String, String) -> Void,
        createDirectory: (URL) throws -> Void = {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        }
    ) throws {
        let raw = readLocation("location-screenshot") ?? readLocation("location")
        let current = raw.flatMap { value -> URL? in
            guard !value.isEmpty else { return nil }
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        }
        let desktop = desktop.standardizedFileURL
        let folder = desktop.appendingPathComponent(
            preferredLanguage.hasPrefix("zh") ? "截圖" : "Screenshots", isDirectory: true)

        if defaults.bool(forKey: configuredKey) {
            if let current, let managed = defaults.string(forKey: managedFolderKey),
               current == URL(fileURLWithPath: managed, isDirectory: true).standardizedFileURL {
                try createDirectory(current)
            }
            return
        }

        // Adopt a folder already selected externally as well as the default Desktop.
        if current == nil || current == desktop || current == folder {
            try createDirectory(folder)
            writeLocation("location", folder.path)
            writeLocation("location-screenshot", folder.path)
            defaults.set(folder.path, forKey: managedFolderKey)
        }
        defaults.set(true, forKey: configuredKey)
    }
}
