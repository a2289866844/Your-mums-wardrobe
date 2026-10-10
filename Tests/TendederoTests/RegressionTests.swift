import AppKit
import XCTest
@testable import Tendedero

final class RegressionTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("tendedero-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "tendedero-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(true, forKey: "soundOff")
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func writeImage(to url: URL) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    @MainActor
    func testRestoringTwelvePhotosDoesNotTruncateOrRewriteSavedList() throws {
        let folder = try temporaryFolder()
        let paths = try (0..<12).map { index in
            let url = folder.appendingPathComponent("capture-\(index).png")
            try writeImage(to: url)
            return url.path
        }
        let defaults = isolatedDefaults()
        defaults.set(paths, forKey: "pegged")
        let line = Line(defaults: defaults, clipboardFolder: folder.appendingPathComponent("Clipboard"))
        XCTAssertEqual(line.liveCount, 12)
        XCTAssertEqual(line.items.map(\.url.path), paths)
        XCTAssertEqual(defaults.stringArray(forKey: "pegged"), paths)
    }

    @MainActor
    func testFullLineStillSignalsEveryNewCapture() throws {
        let folder = try temporaryFolder()
        let line = Line(defaults: isolatedDefaults(), clipboardFolder: try temporaryFolder().appendingPathComponent("Clipboard"))
        line.maxItems = 2
        var notifications = 0
        line.onCapture = { notifications += 1 }
        var lastID: UUID?
        for index in 0..<3 {
            let url = folder.appendingPathComponent("capture-\(index).png")
            try writeImage(to: url)
            lastID = line.hang(url)
        }
        XCTAssertEqual(line.liveCount, 2)
        XCTAssertEqual(notifications, 3)
        XCTAssertTrue(line.items.contains { $0.id == lastID && !$0.falling })
        XCTAssertNil(line.hang(folder.appendingPathComponent("capture-2.png")))
        XCTAssertEqual(notifications, 3, "Duplicate reports must not reopen the line")
    }

    @MainActor
    func testUnreadableCaptureDoesNotSignalSuccess() throws {
        let url = try temporaryFolder().appendingPathComponent("unfinished.png")
        try Data().write(to: url)
        let line = Line(defaults: isolatedDefaults(), clipboardFolder: try temporaryFolder().appendingPathComponent("Clipboard"))
        var notifications = 0
        line.onCapture = { notifications += 1 }
        XCTAssertNil(line.hang(url))
        XCTAssertEqual(notifications, 0)
        try writeImage(to: url)
        XCTAssertNotNil(line.hang(url))
        XCTAssertEqual(notifications, 1)
    }

    @MainActor
    func testWatcherRetriesRejectedCaptureWithoutAnotherFileEvent() async throws {
        let folder = try temporaryFolder()
        let accepted = expectation(description: "Accepted on retry")
        var attempts = 0
        let watcher = ScreenshotWatcher(folder: folder, onNew: { _ in
            attempts += 1
            if attempts == 1 { return false }
            accepted.fulfill()
            return true
        }, onChange: {})
        defer { watcher.stop() }
        try writeImage(to: folder.appendingPathComponent("capture.png"))
        watcher.start()
        await fulfillment(of: [accepted], timeout: 3)
        XCTAssertEqual(attempts, 2)
    }

    @MainActor
    func testWatcherAcceptsImageThatFinishesWritingLater() async throws {
        let folder = try temporaryFolder()
        let url = folder.appendingPathComponent("slow.png")
        let accepted = expectation(description: "Image decoded after writing completed")
        var rejected = 0
        var acceptedCount = 0
        let watcher = ScreenshotWatcher(folder: folder, onNew: { candidate in
            guard makeThumbnail(candidate) != nil else { rejected += 1; return false }
            acceptedCount += 1
            accepted.fulfill()
            return true
        }, onChange: {})
        defer { watcher.stop() }
        watcher.start()
        try Data().write(to: url)
        try await Task.sleep(nanoseconds: 650_000_000)
        XCTAssertGreaterThan(rejected, 0)
        try writeImage(to: url)
        await fulfillment(of: [accepted], timeout: 3)
        XCTAssertEqual(acceptedCount, 1)
    }

    @MainActor
    func testDamagedImageRetriesAreBoundedAndLaterWriteRecovers() async throws {
        let folder = try temporaryFolder()
        let url = folder.appendingPathComponent("damaged.png")
        let accepted = expectation(description: "File recovered after retries were exhausted")
        var attempts = 0
        let watcher = ScreenshotWatcher(folder: folder, onNew: { candidate in
            attempts += 1
            guard makeThumbnail(candidate) != nil else { return false }
            accepted.fulfill()
            return true
        }, onChange: {})
        defer { watcher.stop() }
        try Data().write(to: url)
        watcher.start()
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertGreaterThan(attempts, 0)
        let stoppedAt = attempts
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(attempts, stoppedAt, "Damaged files must not trigger an endless polling loop")
        try writeImage(to: url)
        await fulfillment(of: [accepted], timeout: 3)
        XCTAssertGreaterThan(attempts, stoppedAt)
    }
}
