import AppKit
import ImageIO
import XCTest
@testable import Tendedero

final class ScreenshotIdentificationTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("clipline-identification-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func writePNG(to url: URL, userComment: String? = nil) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        var properties: [CFString: Any] = [:]
        if let userComment {
            properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifUserComment: userComment]
        }
        CGImageDestinationAddImage(destination, try XCTUnwrap(bitmap.cgImage), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        // In-place writes do not require a new directory entry event.
        try (data as Data).write(to: url)
    }

    private func addScreenshotTag(to url: URL) throws {
        let value = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
        let result = value.withUnsafeBytes { bytes in
            url.withUnsafeFileSystemRepresentation { path in
                setxattr(path!, "com.apple.metadata:kMDItemIsScreenCapture", bytes.baseAddress, bytes.count, 0, 0)
            }
        }
        XCTAssertEqual(result, 0)
    }

    @MainActor
    func testEXIFScreenshotIsAcceptedWithoutExtendedAttribute() async throws {
        let folder = try temporaryFolder()
        let url = folder.appendingPathComponent("capture.png")
        let accepted = expectation(description: "EXIF screenshot accepted")
        let watcher = ScreenshotWatcher(folder: folder, onlyTaggedScreenshots: true, onNew: { candidate in
            XCTAssertEqual(candidate.resolvingSymlinksInPath(), url.resolvingSymlinksInPath())
            accepted.fulfill()
            return true
        }, onChange: {})
        defer { watcher.stop() }
        try writePNG(to: url, userComment: "Screenshot")
        let tagSize = url.withUnsafeFileSystemRepresentation {
            getxattr($0!, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0)
        }
        XCTAssertEqual(tagSize, -1)
        watcher.start()
        await fulfillment(of: [accepted], timeout: 3)
    }

    @MainActor
    func testExtendedAttributeScreenshotIsStillAccepted() async throws {
        let folder = try temporaryFolder()
        let accepted = expectation(description: "Tagged screenshot accepted")
        let watcher = ScreenshotWatcher(folder: folder, onlyTaggedScreenshots: true, onNew: { _ in
            accepted.fulfill()
            return true
        }, onChange: {})
        defer { watcher.stop() }
        let url = folder.appendingPathComponent("capture.png")
        try writePNG(to: url)
        try addScreenshotTag(to: url)
        watcher.start()
        await fulfillment(of: [accepted], timeout: 3)
    }

    @MainActor
    func testOrdinaryImagesAreRejectedAndClassificationRetriesStop() async throws {
        let folder = try temporaryFolder()
        var deliveries = 0
        var scans = 0
        let watcher = ScreenshotWatcher(folder: folder, onlyTaggedScreenshots: true, onNew: { _ in
            deliveries += 1
            return true
        }, onChange: { scans += 1 })
        defer { watcher.stop() }
        // Even a screenshot-like filename must have screenshot metadata.
        try writePNG(to: folder.appendingPathComponent("Screenshot 2026-10-10 at 10.00.00.png"))
        try writePNG(to: folder.appendingPathComponent("photo.png"), userComment: "Family photo")
        watcher.start()
        try await Task.sleep(nanoseconds: 2_500_000_000)
        let stoppedAt = scans
        XCTAssertGreaterThan(stoppedAt, 1, "Classification should retry while metadata may still arrive")
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(deliveries, 0)
        XCTAssertEqual(scans, stoppedAt, "Ordinary Desktop images must not cause endless polling")
    }

    @MainActor
    func testDelayedEXIFMetadataIsAcceptedExactlyOnce() async throws {
        let folder = try temporaryFolder()
        let url = folder.appendingPathComponent("capture.png")
        let accepted = expectation(description: "Late EXIF screenshot accepted")
        var deliveries = 0
        let watcher = ScreenshotWatcher(folder: folder, onlyTaggedScreenshots: true, onNew: { _ in
            deliveries += 1
            accepted.fulfill()
            return true
        }, onChange: {})
        defer { watcher.stop() }
        try writePNG(to: url)
        watcher.start()
        try await Task.sleep(nanoseconds: 650_000_000)
        XCTAssertEqual(deliveries, 0)
        try writePNG(to: url, userComment: "Screenshot")
        await fulfillment(of: [accepted], timeout: 3)
        // An unrelated directory event rescans the accepted file.
        try Data().write(to: folder.appendingPathComponent("rescan.txt"))
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(deliveries, 1)
    }

    @MainActor
    func testDelayedExtendedAttributeIsAcceptedExactlyOnce() async throws {
        let folder = try temporaryFolder()
        let url = folder.appendingPathComponent("capture.png")
        let accepted = expectation(description: "Late screenshot attribute accepted")
        var deliveries = 0
        let watcher = ScreenshotWatcher(folder: folder, onlyTaggedScreenshots: true, onNew: { _ in
            deliveries += 1
            accepted.fulfill()
            return true
        }, onChange: {})
        defer { watcher.stop() }
        try writePNG(to: url)
        watcher.start()
        try await Task.sleep(nanoseconds: 650_000_000)
        XCTAssertEqual(deliveries, 0)
        try addScreenshotTag(to: url)
        await fulfillment(of: [accepted], timeout: 3)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(deliveries, 1)
    }
}
