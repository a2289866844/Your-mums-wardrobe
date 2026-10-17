import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Tendedero

@MainActor
final class ScreenshotArrivalTests: XCTestCase {
    func testCaptureMetadataUsesPreparedShelfArrivalAndDeduplicates() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "clipline-screenshot-arrival-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "soundOff")
        let board = NSPasteboard.withUniqueName()
        defer {
            board.releaseGlobally()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        let context = try XCTUnwrap(CGContext(data: nil, width: 1600, height: 1200,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1200))
        let image = try XCTUnwrap(context.makeImage())
        let url = root.appendingPathComponent("Screenshot.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let metadata = try PropertyListSerialization.data(fromPropertyList: [100, 150, 800, 600], format: .binary, options: 0)
        let status = metadata.withUnsafeBytes { bytes in
            url.withUnsafeFileSystemRepresentation { path in
                setxattr(path!, "com.apple.metadata:kMDItemScreenCaptureGlobalRect", bytes.baseAddress, bytes.count, 0, 0)
            }
        }
        XCTAssertEqual(status, 0)
        XCTAssertNotNil(captureRect(of: url))

        let line = Line(defaults: defaults, clipboardFolder: root.appendingPathComponent("Clipboard"), copyPasteboard: board)
        let delegate = AppDelegate(line: line, screenshotFolder: root, defaults: defaults, capturePasteboard: board)
        let windows = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))

        XCTAssertFalse(delegate.hangCapture(url))
        XCTAssertFalse(delegate.hangCapture(url), "Repeated watcher scans must share the pending decode")
        XCTAssertTrue(line.items.isEmpty)
        let deadline = Date().addingTimeInterval(3)
        while line.items.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let card = try XCTUnwrap(line.items.first)
        XCTAssertFalse(card.flying, "Screenshots should be immediately available in the shelf")
        XCTAssertLessThanOrEqual(max(card.thumb.size.width, card.thumb.size.height), 480)
        XCTAssertEqual(Set(NSApplication.shared.windows.map(ObjectIdentifier.init)), windows)
        XCTAssertTrue(delegate.hangCapture(url))
        XCTAssertEqual(line.items.count, 1)
    }

    private func loaderFixture() throws -> (URL, CGImage) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let url = root.appendingPathComponent("Screenshot.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return (url, image)
    }

    func testPendingDecodeCoalescesAndLeavesMainActorResponsive() async throws {
        let (url, image) = try loaderFixture()
        let started = expectation(description: "Background decode started")
        let heartbeat = expectation(description: "Main actor remains available")
        let completed = expectation(description: "Prepared image delivered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let loader = ScreenshotThumbnailLoader { _ in
            XCTAssertFalse(Thread.isMainThread)
            started.fulfill()
            _ = release.wait(timeout: .now() + 3)
            return image
        }
        loader.load(url) { value in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNotNil(value)
            completed.fulfill()
        }
        loader.load(url) { _ in XCTFail("Duplicate pending load should be coalesced") }
        DispatchQueue.main.async { heartbeat.fulfill() }
        await fulfillment(of: [started, heartbeat], timeout: 2)
        release.signal()
        await fulfillment(of: [completed], timeout: 2)
    }

    func testCancelledGenerationCannotDeliverOrClearReplacementLoad() async throws {
        let (url, image) = try loaderFixture()
        let queue = DispatchQueue(label: "test.screenshot.cancel")
        queue.suspend()
        let loader = ScreenshotThumbnailLoader(queue: queue, decode: { _ in image })
        var deliveredOld = false
        loader.load(url) { _ in deliveredOld = true }
        loader.cancelAll()
        let completed = expectation(description: "Replacement load delivered")
        loader.load(url) { value in
            XCTAssertNotNil(value)
            XCTAssertFalse(deliveredOld)
            completed.fulfill()
        }
        queue.resume()
        await fulfillment(of: [completed], timeout: 2)
    }

    func testFileChangingDuringDecodeIsRejected() async throws {
        let (url, image) = try loaderFixture()
        let loader = ScreenshotThumbnailLoader { url in
            try? Data("file changed during decode".utf8).write(to: url)
            return image
        }
        let rejected = expectation(description: "Changed revision rejected")
        loader.load(url) { value in
            XCTAssertNil(value)
            rejected.fulfill()
        }
        await fulfillment(of: [rejected], timeout: 2)
    }

    func testIncompleteImageCanBeRetriedAfterTheWriterFinishes() async throws {
        let (url, _) = try loaderFixture()
        let completeData = try Data(contentsOf: url)
        try Data(completeData.prefix(8)).write(to: url)
        let loader = ScreenshotThumbnailLoader()
        let rejected = expectation(description: "Incomplete image rejected")
        loader.load(url) { value in
            XCTAssertNil(value)
            rejected.fulfill()
        }
        await fulfillment(of: [rejected], timeout: 2)
        try completeData.write(to: url)
        let retry = expectation(description: "Stable revision can be retried")
        loader.load(url) { value in
            XCTAssertNotNil(value)
            retry.fulfill()
        }
        await fulfillment(of: [retry], timeout: 2)
    }
}
