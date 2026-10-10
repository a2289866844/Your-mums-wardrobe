import Foundation
import XCTest
@testable import Tendedero

final class ScreenshotLocationTests: XCTestCase {
    private func environment() throws -> (UserDefaults, URL) {
        let suite = "clipline-location-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let desktop = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(suite).appendingPathComponent("Desktop")
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: desktop.deletingLastPathComponent())
        }
        return (defaults, desktop)
    }

    private func prepare(_ defaults: UserDefaults, _ desktop: URL, _ values: inout [String: String],
                         language: String = "en") throws {
        let original = values
        try ScreenshotLocation.prepare(defaults: defaults, desktop: desktop, preferredLanguage: language,
                                       readLocation: { original[$0] }, writeLocation: { values[$0] = $1 })
    }

    func testAbsentAndDesktopDestinationsAdoptFolderWithoutChangingThumbnail() throws {
        for initial in [nil, "desktop"] as [String?] {
            let (defaults, desktop) = try environment()
            let existing = desktop.appendingPathComponent("existing-capture.png")
            try Data("existing capture".utf8).write(to: existing)
            var values = ["show-thumbnail": "true"]
            if initial != nil { values["location"] = desktop.path }
            try prepare(defaults, desktop, &values)
            let folder = desktop.appendingPathComponent("Screenshots")
            XCTAssertEqual(values["location"], folder.path)
            XCTAssertEqual(values["location-screenshot"], folder.path)
            XCTAssertEqual(values["show-thumbnail"], "true")
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
            XCTAssertTrue(defaults.bool(forKey: "desktopScreenshotFolderConfigured"))
            XCTAssertEqual(defaults.string(forKey: "managedDesktopScreenshotFolder"), folder.path)
            XCTAssertEqual(try Data(contentsOf: existing), Data("existing capture".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(existing.lastPathComponent).path))
        }
    }

    func testChineseFolderAlreadySelectedIsAdoptedAndRecreated() throws {
        let (defaults, desktop) = try environment()
        let folder = desktop.appendingPathComponent("截圖")
        var values = ["location-screenshot": folder.path]
        try prepare(defaults, desktop, &values, language: "zh-Hant-HK")
        XCTAssertEqual(defaults.string(forKey: "managedDesktopScreenshotFolder"), folder.path)
        try FileManager.default.removeItem(at: folder)
        // Retain the adopted name even if the user's language changes.
        try prepare(defaults, desktop, &values)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    func testCustomDestinationsIncludingMissingArePreserved() throws {
        for exists in [true, false] {
            let (defaults, desktop) = try environment()
            let custom = desktop.deletingLastPathComponent().appendingPathComponent("Custom")
            if exists { try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true) }
            var values = ["location-screenshot": custom.path, "location": desktop.path]
            let original = values
            try prepare(defaults, desktop, &values)
            XCTAssertEqual(values, original, "The modern key's custom destination takes precedence")
            XCTAssertEqual(FileManager.default.fileExists(atPath: custom.path), exists)
            XCTAssertFalse(FileManager.default.fileExists(atPath: desktop.appendingPathComponent("Screenshots").path))
            XCTAssertTrue(defaults.bool(forKey: "desktopScreenshotFolderConfigured"))
        }
    }

    func testCreationFailureChangesNeitherPreferencesNorAdoptionState() throws {
        let (defaults, desktop) = try environment()
        let blocked = desktop.appendingPathComponent("Screenshots")
        try Data("existing file".utf8).write(to: blocked)
        var writes: [String: String] = [:]
        XCTAssertThrowsError(try ScreenshotLocation.prepare(
            defaults: defaults, desktop: desktop, preferredLanguage: "en",
            readLocation: { _ in nil }, writeLocation: { writes[$0] = $1 }))
        XCTAssertTrue(writes.isEmpty)
        XCTAssertFalse(defaults.bool(forKey: "desktopScreenshotFolderConfigured"))
        XCTAssertNil(defaults.string(forKey: "managedDesktopScreenshotFolder"))
        XCTAssertEqual(try String(contentsOf: blocked), "existing file")
    }

    func testLaterUserSelectedDesktopOrCustomDestinationIsRespected() throws {
        for target in ["Desktop", "Custom"] {
            let (defaults, desktop) = try environment()
            var values: [String: String] = [:]
            try prepare(defaults, desktop, &values)
            let selected = target == "Desktop" ? desktop : desktop.appendingPathComponent("Custom")
            values["location"] = selected.path
            values["location-screenshot"] = selected.path
            let original = values
            try prepare(defaults, desktop, &values)
            XCTAssertEqual(values, original)
        }
    }
}
