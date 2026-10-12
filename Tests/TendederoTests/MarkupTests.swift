import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Tendedero

final class MarkupTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("clipline-markup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    @MainActor
    private func service() -> NSSharingService {
        NSSharingService(title: "Fixture editor", image: NSImage(size: NSSize(width: 2, height: 2)), alternateImage: nil) {}
    }

    private func image(_ color: NSColor) -> NSImage {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color.usingColorSpace(.deviceRGB)!.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return NSImage(cgImage: context.makeImage()!, size: NSSize(width: 4, height: 4))
    }

    @MainActor
    func testSecondEditorCannotRedirectFirstEditorsResult() throws {
        let folder = try temporaryFolder()
        let first = folder.appendingPathComponent("first.png")
        let second = folder.appendingPathComponent("second.png")
        try Data("original first".utf8).write(to: first)
        let secondData = Data("original second".utf8)
        try secondData.write(to: second)
        let markup = Markup()
        let firstService = service(), secondService = service()
        var saved: [URL] = []
        var editing: URL?
        markup.onSaved = { saved.append($0) }
        markup.onEditingChanged = { editing = $0 }
        XCTAssertTrue(markup.beginEditing(first, service: firstService))
        XCTAssertFalse(markup.beginEditing(second, service: secondService))
        markup.sharingService(secondService, didShareItems: [image(.blue)])
        XCTAssertTrue(saved.isEmpty)
        XCTAssertEqual(editing, first)
        markup.sharingService(firstService, didShareItems: [image(.red)])
        XCTAssertEqual(saved, [first])
        XCTAssertNil(editing)
        XCTAssertEqual(try Data(contentsOf: second), secondData)
        XCTAssertNotNil(CGImageSourceCreateWithURL(first as CFURL, nil))
    }

    @MainActor
    func testReturnedPNGPreservesJPEGTargetFormat() throws {
        let target = try temporaryFolder().appendingPathComponent("capture.jpg")
        try Data("original".utf8).write(to: target)
        let markup = Markup(), editor = service()
        XCTAssertTrue(markup.beginEditing(target, service: editor))
        markup.sharingService(editor, didShareItems: [image(.red)])
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(target as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
    }

    @MainActor
    func testFailureAndInvalidResultReleaseEditingProtection() throws {
        let target = try temporaryFolder().appendingPathComponent("capture.png")
        let original = Data("unchanged".utf8)
        try original.write(to: target)
        let markup = Markup(), first = service(), second = service()
        var editing: URL?
        markup.onEditingChanged = { editing = $0 }
        XCTAssertTrue(markup.beginEditing(target, service: first))
        markup.sharingService(first, didFailToShareItems: [], error: CocoaError(.userCancelled))
        XCTAssertNil(editing)
        XCTAssertTrue(markup.beginEditing(target, service: second))
        markup.sharingService(first, didShareItems: [image(.blue)])
        XCTAssertEqual(editing, target, "Late callback from an old editor must be ignored")
        markup.sharingService(second, didShareItems: ["unsupported result"])
        XCTAssertNil(editing)
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    @MainActor
    func testDeletedTargetIsNotRecreatedByEditor() throws {
        let target = try temporaryFolder().appendingPathComponent("capture.png")
        let markup = Markup(), editor = service()
        XCTAssertTrue(markup.beginEditing(target, service: editor))
        markup.sharingService(editor, didShareItems: [image(.red)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
}
