import Foundation

/// Inbox mode: wardrobe takes over where screenshots go.
///
/// It changes two macOS screenshot settings, the same ones in the Options
/// menu of Cmd+Shift+5: the floating thumbnail is turned off, so the file is
/// written at once instead of five seconds later, and the save location
/// becomes wardrobe's own folder, so the Desktop only gets what you keep.
///
/// The previous values are saved first and put back when the mode is turned
/// off or the app quits, so macOS is never left pointing at a folder nobody
/// is watching.
enum Inbox {
    private static let domain = "com.apple.screencapture" as CFString
    private static let enabledKey = "inboxEnabled"
    private static let offeredKey = "inboxOffered"
    private static let savedKey = "inboxSavedSettings"

    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Clipline/Screenshots", isDirectory: true)
    }()

    /// The user's choice, kept across launches.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Whether we already asked, so the offer appears only once.
    static var wasOffered: Bool {
        get { UserDefaults.standard.bool(forKey: offeredKey) }
        set { UserDefaults.standard.set(newValue, forKey: offeredKey) }
    }

    static func apply() throws {
        CFPreferencesAppSynchronize(domain)
        try apply(defaults: .standard, folder: folder,
                  read: { CFPreferencesCopyAppValue($0 as CFString, domain) },
                  write: set)
        guard CFPreferencesAppSynchronize(domain) else {
            restore()
            throw CocoaError(.fileWriteUnknown)
        }
    }

    static func restore() {
        CFPreferencesAppSynchronize(domain)
        restore(defaults: .standard, folder: folder,
                read: { CFPreferencesCopyAppValue($0 as CFString, domain) },
                write: set, commit: { CFPreferencesAppSynchronize(domain) })
    }

    private static let settings = [("location", "location"),
                                   ("location-screenshot", "locationScreenshot"),
                                   ("show-thumbnail", "thumbnail")]

    /// Injected preferences keep tests and fixture hosts away from system settings.
    static func apply(defaults: UserDefaults, folder: URL,
                      read: (String) -> Any?, write: (String, Any?) -> Void,
                      createDirectory: (URL) throws -> Void = {
                          try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
                      }, persistBackup: (UserDefaults) -> Bool = { $0.synchronize() }) throws {
        // A failed destination must not leave screenshots pointing at an unusable folder.
        try createDirectory(folder)
        let previous = defaults.dictionary(forKey: savedKey)
        var saved = previous ?? [:]
        for (key, backupKey) in settings {
            let current = read(key)
            // Preserve the original backup across a crash/relaunch. If a user
            // changed a single setting, that new value becomes its next backup.
            if previous == nil || !isManaged(current, key: key, folder: folder) {
                saved[backupKey] = current
            }
        }
        defaults.set(saved, forKey: savedKey)
        guard persistBackup(defaults) else { throw CocoaError(.fileWriteUnknown) }
        let path: String = folder.path
        for (key, _) in settings { write(key, key == "show-thumbnail" ? false as Any : path as Any) }
    }

    static func restore(defaults: UserDefaults, folder: URL,
                        read: (String) -> Any?, write: (String, Any?) -> Void,
                        commit: () -> Bool = { true }) {
        guard let saved = defaults.dictionary(forKey: savedKey) else { return }
        for (key, backupKey) in settings where isManaged(read(key), key: key, folder: folder) {
            write(key, saved[backupKey])
        }
        guard commit() else { return }
        // Restore only values we still own; later user choices take precedence.
        defaults.removeObject(forKey: savedKey)
        defaults.synchronize()
    }

    private static func isManaged(_ value: Any?, key: String, folder: URL) -> Bool {
        if key == "show-thumbnail" { return (value as? Bool) == false }
        guard let path = value as? String else { return false }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
            == folder.standardizedFileURL.path
    }

    /// Writes through cfprefsd, so the screenshot service sees it at once.
    /// A nil value removes the key and returns it to the macOS default.
    private static func set(_ key: String, _ value: Any?) {
        CFPreferencesSetAppValue(key as CFString, value as CFPropertyList?, domain)
    }
}
