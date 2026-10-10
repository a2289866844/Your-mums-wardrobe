import AppKit
import XCTest
@testable import Tendedero

final class ScreenshotWatcherRecoveryTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("clipline-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func writeImage(to url: URL, createdAt: Date? = nil) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        if let createdAt {
            try FileManager.default.setAttributes([.creationDate: createdAt], ofItemAtPath: url.path)
        }
    }

    @MainActor
    func testMissingUnicodeFolderRecoversAndDeliversCaptureOnce() async throws {
        let folder = try temporaryRoot().appendingPathComponent("截圖")
        let accepted = expectation(description: "Capture arriving while folder unavailable")
        var deliveries = 0
        let watcher = ScreenshotWatcher(folder: folder, recoveryInterval: 0.05, onNew: { _ in
            deliveries += 1
            accepted.fulfill()
            return true
        }, onChange: {})
        defer { watcher.stop() }
        watcher.start()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeImage(to: folder.appendingPathComponent("new.png"))
        await fulfillment(of: [accepted], timeout: 3)
        try Data().write(to: folder.appendingPathComponent("rescan.txt"))
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(deliveries, 1)
    }

    @MainActor
    func testDeniedOpenRetainsStartupCutoffAndRecovers() async throws {
        let folder = try temporaryRoot()
        let cutoff = Date()
        try writeImage(to: folder.appendingPathComponent("old.png"), createdAt: cutoff.addingTimeInterval(-60))
        let accepted = expectation(description: "Capture during denied access accepted")
        var attempts = 0
        var delivered: [String] = []
        let watcher = ScreenshotWatcher(folder: folder, startedAt: cutoff, recoveryInterval: 0.05,
            openDirectory: { path in
                attempts += 1
                guard attempts > 2 else { errno = EACCES; return -1 }
                return open(path, O_EVTONLY)
            }, onNew: { url in
                delivered.append(url.lastPathComponent)
                accepted.fulfill()
                return true
            }, onChange: {})
        defer { watcher.stop() }
        watcher.start()
        try writeImage(to: folder.appendingPathComponent("new.png"))
        await fulfillment(of: [accepted], timeout: 3)
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(delivered, ["new.png"])
    }

    @MainActor
    func testDeniedListingAppliesBaselineOnFirstSuccessfulListing() async throws {
        let folder = try temporaryRoot()
        let cutoff = Date()
        try writeImage(to: folder.appendingPathComponent("old.png"), createdAt: cutoff.addingTimeInterval(-60))
        let accepted = expectation(description: "Listing recovers without delivering historical images")
        var attempts = 0
        var delivered: [String] = []
        let watcher = ScreenshotWatcher(folder: folder, startedAt: cutoff, recoveryInterval: 0.05,
            listDirectory: { url in
                attempts += 1
                guard attempts > 2 else { throw CocoaError(.fileReadNoPermission) }
                return try FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])
            }, onNew: { url in
                delivered.append(url.lastPathComponent)
                accepted.fulfill()
                return true
            }, onChange: {})
        defer { watcher.stop() }
        watcher.start()
        try writeImage(to: folder.appendingPathComponent("new.png"))
        await fulfillment(of: [accepted], timeout: 3)
        XCTAssertGreaterThanOrEqual(attempts, 3)
        XCTAssertEqual(delivered, ["new.png"])
    }

    @MainActor
    func testRenamedFolderIsReattachedAtOriginalPath() async throws {
        let root = try temporaryRoot()
        let folder = root.appendingPathComponent("Screenshots")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = expectation(description: "Capture before folder replacement")
        let second = expectation(description: "Capture after folder replacement")
        var delivered: [String] = []
        let watcher = ScreenshotWatcher(folder: folder, recoveryInterval: 0.05, onNew: { url in
            delivered.append(url.lastPathComponent)
            if url.lastPathComponent == "first.png" { first.fulfill() }
            else { second.fulfill() }
            return true
        }, onChange: {})
        defer { watcher.stop() }
        watcher.start()
        try writeImage(to: folder.appendingPathComponent("first.png"))
        await fulfillment(of: [first], timeout: 3)
        try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent("Previous"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeImage(to: folder.appendingPathComponent("second.png"))
        await fulfillment(of: [second], timeout: 3)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(delivered, ["first.png", "second.png"])
    }

    @MainActor
    func testStopCancelsRecoveryAndCannotResurrectWatcher() async throws {
        let folder = try temporaryRoot().appendingPathComponent("Missing")
        var attempts = 0
        var deliveries = 0
        let watcher = ScreenshotWatcher(folder: folder, recoveryInterval: 0.05,
            openDirectory: { path in attempts += 1; return open(path, O_EVTONLY) },
            onNew: { _ in deliveries += 1; return true }, onChange: {})
        watcher.start()
        watcher.stop()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeImage(to: folder.appendingPathComponent("new.png"))
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(deliveries, 0)
    }

    @MainActor
    func testSuccessfulRecoveryStopsPollingAndPreservesAcceptedFiles() async throws {
        let folder = try temporaryRoot()
        var allowed = false
        var attempts = 0
        var listings = 0
        var deliveries = 0
        let accepted = expectation(description: "Capture accepted after recovery")
        let watcher = ScreenshotWatcher(folder: folder, recoveryInterval: 0.05,
            openDirectory: { path in
                attempts += 1
                return allowed ? open(path, O_EVTONLY) : -1
            }, listDirectory: { url in
                listings += 1
                return try FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])
            }, onNew: { _ in deliveries += 1; accepted.fulfill(); return true }, onChange: {})
        defer { watcher.stop() }
        watcher.start()
        try writeImage(to: folder.appendingPathComponent("new.png"))
        allowed = true
        await fulfillment(of: [accepted], timeout: 3)
        try await Task.sleep(nanoseconds: 350_000_000)
        let settledListings = listings
        let settledAttempts = attempts
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(listings, settledListings, "Healthy folders must not be polled")
        XCTAssertEqual(attempts, settledAttempts)
        try Data().write(to: folder.appendingPathComponent("rescan.txt"))
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(deliveries, 1)
    }

    func testConfiguredMissingPathIsPreservedAndEmptyLocationUsesDesktop() throws {
        let folder = try temporaryRoot().appendingPathComponent("Missing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(ScreenshotWatcher.screenshotFolder(configuredPath: folder.path).path, folder.path)
        XCTAssertEqual(ScreenshotWatcher.screenshotFolder(configuredPath: nil), ScreenshotWatcher.desktop)
        XCTAssertEqual(ScreenshotWatcher.screenshotFolder(configuredPath: ""), ScreenshotWatcher.desktop)
        XCTAssertEqual(ScreenshotWatcher.screenshotFolder(configuredPath: "~/Desktop/截圖").path,
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/截圖").path)
    }
}
