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
    @MainActor
    func testReplacementCaptureAtSamePathIsDeliveredAgain() async throws {
        let folder = try temporaryRoot()
        let url = folder.appendingPathComponent("capture.png")
        let accepted = expectation(description: "Both distinct captures accepted")
        accepted.expectedFulfillmentCount = 2
        var deliveries = 0
        let watcher = ScreenshotWatcher(folder: folder, onNew: { _ in
            deliveries += 1
            accepted.fulfill()
            return true
        }, onChange: {})
        defer { watcher.stop() }
        try writeImage(to: url)
        watcher.start()
        XCTAssertEqual(deliveries, 1)
        let replacement = folder.appendingPathComponent("replacement.tmp")
        try writeImage(to: replacement)
        XCTAssertEqual(rename(replacement.path, url.path), 0)
        await fulfillment(of: [accepted], timeout: 1)
        XCTAssertEqual(deliveries, 2)
    }

    @MainActor
    func testImageExtensionDirectoryIsNotDelivered() async throws {
        let folder = try temporaryRoot()
        var deliveries = 0
        let watcher = ScreenshotWatcher(folder: folder, onNew: { _ in
            deliveries += 1
            return true
        }, onChange: {})
        defer { watcher.stop() }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("album.png"),
                                               withIntermediateDirectories: true)
        watcher.start()
        XCTAssertEqual(deliveries, 0)
    }

    @MainActor
    func testSustainedDirectoryActivityCannotStarveCaptureDelivery() async throws {
        let folder = try temporaryRoot()
        var deliveries = 0
        let watcher = ScreenshotWatcher(folder: folder, onNew: { _ in deliveries += 1; return true }, onChange: {})
        defer { watcher.stop() }
        watcher.start()
        try writeImage(to: folder.appendingPathComponent("capture.png"))
        for index in 0..<12 {
            try Data().write(to: folder.appendingPathComponent("event-\(index).txt"))
            try await Task.sleep(nanoseconds: 75_000_000)
        }
        XCTAssertEqual(deliveries, 1, "Capture must be delivered while directory activity continues")
    }

    @MainActor
    func testStoppingDuringDeliveryStopsRemainingDeliveries() throws {
        let folder = try temporaryRoot()
        var deliveries = 0
        var watcher: ScreenshotWatcher!
        watcher = ScreenshotWatcher(folder: folder, onNew: { _ in
            deliveries += 1
            watcher.stop()
            return true
        }, onChange: {})
        defer { watcher.stop(); watcher = nil }
        try writeImage(to: folder.appendingPathComponent("first.png"))
        try writeImage(to: folder.appendingPathComponent("second.png"))
        watcher.start()
        XCTAssertEqual(deliveries, 1)
    }

    @MainActor
    func testReplacedFolderReattachesUnfinishedFileWatchAtSamePath() async throws {
        let root = try temporaryRoot()
        let folder = root.appendingPathComponent("Screenshots")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("capture.png")
        let accepted = expectation(description: "Replacement capture completes after retries")
        let watcher = ScreenshotWatcher(folder: folder, recoveryInterval: 0.05, onNew: { candidate in
            guard makeThumbnail(candidate) != nil else { return false }
            accepted.fulfill()
            return true
        }, onChange: {})
        defer { watcher.stop() }
        try Data().write(to: url)
        watcher.start()
        try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent("Previous"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: url)
        try await Task.sleep(nanoseconds: 2_500_000_000)
        try writeImage(to: url)
        await fulfillment(of: [accepted], timeout: 1)
    }

    @MainActor
    func testUnfinishedFileWatchesAreBoundedAndOverflowStillRecovers() async throws {
        let folder = try temporaryRoot()
        let overflow = folder.appendingPathComponent("capture-069.png")
        var attempts: [String: Int] = [:]
        var listings = 0
        let accepted = expectation(description: "Overflow capture finishes after retries")
        let watcher = ScreenshotWatcher(folder: folder, listDirectory: { url in
            listings += 1
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        }, onNew: { url in
            attempts[url.lastPathComponent, default: 0] += 1
            guard makeThumbnail(url) != nil else { return false }
            XCTAssertEqual(url.resolvingSymlinksInPath(), overflow.resolvingSymlinksInPath())
            accepted.fulfill()
            return true
        }, onChange: {})
        defer { watcher.stop() }
        for index in 0..<70 {
            let name = String(format: "capture-%03d.png", index)
            try Data().write(to: folder.appendingPathComponent(name))
        }
        let descriptorsBefore = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        watcher.start()
        let descriptorsAfter = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        XCTAssertLessThanOrEqual(descriptorsAfter - descriptorsBefore, 65,
                                 "Only the directory and at most 64 unfinished captures need descriptors")
        try await Task.sleep(nanoseconds: 2_600_000_000)
        let exhaustedAttempts = attempts
        try await Task.sleep(nanoseconds: 1_600_000_000)
        XCTAssertEqual(attempts, exhaustedAttempts, "Metadata polling must not decode unchanged exhausted files")
        try writeImage(to: overflow)
        await fulfillment(of: [accepted], timeout: 3)
        for index in 64..<69 {
            try FileManager.default.removeItem(at: folder.appendingPathComponent(String(format: "capture-%03d.png", index)))
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        let settledListings = listings
        try await Task.sleep(nanoseconds: 2_300_000_000)
        XCTAssertEqual(listings, settledListings, "Overflow polling stops when overflow files are gone")
    }

}
