import XCTest
@testable import Tendedero

final class InboxSettingsTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/tmp/clipline-inbox-fixture", isDirectory: true)

    private func defaults() -> UserDefaults {
        let suite = "clipline-inbox-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testRestorePreservesNewModernDestinationAndThumbnailChoice() throws {
        let defaults = defaults()
        var values: [String: Any] = ["location": "/old", "location-screenshot": "/old-modern", "show-thumbnail": true]
        try Inbox.apply(defaults: defaults, folder: folder, read: { values[$0] },
                        write: { values[$0] = $1 }, createDirectory: { _ in })
        values["location-screenshot"] = "/user-selected"
        values["show-thumbnail"] = true
        Inbox.restore(defaults: defaults, folder: folder, read: { values[$0] }, write: { values[$0] = $1 })
        XCTAssertEqual(values["location"] as? String, "/old")
        XCTAssertEqual(values["location-screenshot"] as? String, "/user-selected")
        XCTAssertEqual(values["show-thumbnail"] as? Bool, true)
    }

    func testLegacyDestinationChangeStillRestoresOwnedModernKey() throws {
        let defaults = defaults()
        var values: [String: Any] = ["location": "/old", "location-screenshot": "/old-modern", "show-thumbnail": true]
        try Inbox.apply(defaults: defaults, folder: folder, read: { values[$0] },
                        write: { values[$0] = $1 }, createDirectory: { _ in })
        values["location"] = "/user-selected"
        Inbox.restore(defaults: defaults, folder: folder, read: { values[$0] }, write: { values[$0] = $1 })
        XCTAssertEqual(values["location"] as? String, "/user-selected")
        XCTAssertEqual(values["location-screenshot"] as? String, "/old-modern")
        XCTAssertEqual(values["show-thumbnail"] as? Bool, true)
    }

    func testCrashRelaunchRetainsOriginalBackupAndRebasesOnlyUserChanges() throws {
        let defaults = defaults()
        var values: [String: Any] = ["location": "/old", "location-screenshot": "/old-modern"]
        for _ in 0..<2 {
            try Inbox.apply(defaults: defaults, folder: folder, read: { values[$0] },
                            write: { values[$0] = $1 }, createDirectory: { _ in })
        }
        values["location-screenshot"] = "/new-modern"
        try Inbox.apply(defaults: defaults, folder: folder, read: { values[$0] },
                        write: { values[$0] = $1 }, createDirectory: { _ in })
        Inbox.restore(defaults: defaults, folder: folder, read: { values[$0] }, write: { values[$0] = $1 })
        XCTAssertEqual(values["location"] as? String, "/old")
        XCTAssertEqual(values["location-screenshot"] as? String, "/new-modern")
        XCTAssertNil(values["show-thumbnail"])
    }

    func testFailedDirectoryCreationDoesNotChangePreferencesOrBackup() {
        let defaults = defaults()
        var values: [String: Any] = ["location": "/old"]
        XCTAssertThrowsError(try Inbox.apply(defaults: defaults, folder: folder,
                                            read: { values[$0] }, write: { values[$0] = $1 },
                                            createDirectory: { _ in throw CocoaError(.fileWriteNoPermission) }))
        XCTAssertEqual(values["location"] as? String, "/old")
        XCTAssertNil(values["location-screenshot"])
        XCTAssertNil(defaults.dictionary(forKey: "inboxSavedSettings"))
    }

    func testRestoreWithoutBackupDoesNotDeleteSettings() {
        var writes = 0
        Inbox.restore(defaults: defaults(), folder: folder, read: { _ in self.folder.path },
                      write: { _, _ in writes += 1 })
        XCTAssertEqual(writes, 0)
    }

    func testPreviouslyAbsentKeysAreRemovedOnRestore() throws {
        let defaults = defaults()
        var values: [String: Any] = [:]
        try Inbox.apply(defaults: defaults, folder: folder, read: { values[$0] },
                        write: { values[$0] = $1 }, createDirectory: { _ in })
        XCTAssertEqual(values.count, 3)
        Inbox.restore(defaults: defaults, folder: folder, read: { values[$0] }, write: { values[$0] = $1 })
        XCTAssertTrue(values.isEmpty)
    }

    func testBackupIsPersistedBeforeApplyingAndRetainedUntilRestoreCommits() throws {
        let defaults = defaults()
        var values: [String: Any] = ["location": "/old"]
        var backupPersisted = false
        try Inbox.apply(defaults: defaults, folder: folder, read: { values[$0] }, write: {
            XCTAssertTrue(backupPersisted)
            values[$0] = $1
        }, createDirectory: { _ in }, persistBackup: { _ in backupPersisted = true; return true })
        Inbox.restore(defaults: defaults, folder: folder, read: { values[$0] }, write: { values[$0] = $1 }, commit: {
            XCTAssertNotNil(defaults.dictionary(forKey: "inboxSavedSettings"))
            return false
        })
        XCTAssertNotNil(defaults.dictionary(forKey: "inboxSavedSettings"))
        Inbox.restore(defaults: defaults, folder: folder, read: { values[$0] }, write: { values[$0] = $1 })
        XCTAssertNil(defaults.dictionary(forKey: "inboxSavedSettings"))
        XCTAssertEqual(values["location"] as? String, "/old")
    }

    func testFailedBackupPersistenceMakesNoSystemWrites() {
        var writes = 0
        XCTAssertThrowsError(try Inbox.apply(defaults: defaults(), folder: folder, read: { _ in "/old" },
                                            write: { _, _ in writes += 1 }, createDirectory: { _ in },
                                            persistBackup: { _ in false }))
        XCTAssertEqual(writes, 0)
    }

    func testUnavailableInboxAfterCrashCanStillRestorePreviousDestination() throws {
        let defaults = defaults()
        var values: [String: Any] = ["location": "/old", "show-thumbnail": true]
        try Inbox.apply(defaults: defaults, folder: folder, read: { values[$0] }, write: { values[$0] = $1 },
                        createDirectory: { _ in })
        XCTAssertThrowsError(try Inbox.apply(defaults: defaults, folder: folder, read: { values[$0] },
                                            write: { values[$0] = $1 },
                                            createDirectory: { _ in throw CocoaError(.fileWriteNoPermission) }))
        Inbox.restore(defaults: defaults, folder: folder, read: { values[$0] }, write: { values[$0] = $1 })
        XCTAssertEqual(values["location"] as? String, "/old")
        XCTAssertNil(values["location-screenshot"])
        XCTAssertEqual(values["show-thumbnail"] as? Bool, true)
    }
}
