import AppKit
import XCTest
@testable import Tendedero

@MainActor
final class GrabInteractionTests: XCTestCase {
    private func event(_ type: NSEvent.EventType, clicks: Int = 1, point: NSPoint = NSPoint(x: 80, y: 40)) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    private func view(_ kind: ShelfContentKind = .image) -> GrabView {
        let view = GrabView(frame: NSRect(x: 0, y: 0, width: 180, height: 120))
        view.kind = kind
        return view
    }

    func testSingleClickOpensOnceAndDoubleClickDoesNotReopen() {
        let view = view()
        var opened = 0
        view.onClick = { opened += 1 }
        view.mouseDown(with: event(.leftMouseDown))
        view.mouseUp(with: event(.leftMouseUp))
        view.mouseDown(with: event(.leftMouseDown, clicks: 2))
        view.mouseUp(with: event(.leftMouseUp, clicks: 2))
        XCTAssertEqual(opened, 1)
    }

    func testDiscardCornerNeverOpens() {
        let view = view()
        var discarded = 0
        var opened = 0
        view.onDiscard = { discarded += 1 }
        view.onClick = { opened += 1 }
        view.mouseDown(with: event(.leftMouseDown, point: NSPoint(x: 10, y: 110)))
        view.mouseUp(with: event(.leftMouseUp, point: NSPoint(x: 10, y: 110)))
        XCTAssertEqual(discarded, 1)
        XCTAssertEqual(opened, 0)
    }

    func testTextAndLinkWritersExposeContentWithoutBackingFile() {
        let text = view(.text)
        text.previewText = "A useful thought"
        let textWriter = text.dragPasteboardWriter() as? NSPasteboardItem
        XCTAssertEqual(textWriter?.string(forType: .string), "A useful thought")
        XCTAssertNil(textWriter?.string(forType: .fileURL))
        let link = view(.link)
        link.linkURL = URL(string: "https://example.com/route")!
        let linkWriter = link.dragPasteboardWriter() as? NSPasteboardItem
        XCTAssertEqual(linkWriter?.string(forType: .URL), "https://example.com/route")
        XCTAssertEqual(linkWriter?.string(forType: .string), "https://example.com/route")
        XCTAssertNil(linkWriter?.string(forType: .fileURL))
    }

    func testTextDragRetainsFullStoredTextBeyondPreview() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: file) }
        let content = String(repeating: "A full thought. ", count: 100)
        try content.write(to: file, atomically: true, encoding: .utf8)
        let view = view(.text)
        view.url = file
        view.previewText = String(content.prefix(800))
        let writer = view.dragPasteboardWriter() as? NSPasteboardItem
        XCTAssertEqual(writer?.string(forType: .string), content)
    }

    func testFileWriterUsesOriginalFileURL() {
        for kind in [ShelfContentKind.image, .file] {
            let view = view(kind)
            let file = URL(fileURLWithPath: "/tmp/demo.png")
            view.url = file
            XCTAssertEqual(view.dragPasteboardWriter() as? NSURL, file as NSURL)
            XCTAssertEqual(view.sourceOperations(for: .outsideApplication), [.copy, .move, .delete])
        }
        for kind in [ShelfContentKind.text, .link] {
            XCTAssertEqual(view(kind).sourceOperations(for: .outsideApplication), .copy)
            XCTAssertEqual(view(kind).sourceOperations(for: .withinApplication), [])
        }
    }

    func testLongHoldOnTextOrLinkRemainsOrdinaryClick() {
        for kind in [ShelfContentKind.text, .link, .file] {
            let view = view(kind)
            var markedUp = 0
            var opened = 0
            view.onLongPress = { markedUp += 1 }
            view.onClick = { opened += 1 }
            view.mouseDown(with: event(.leftMouseDown))
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            view.mouseUp(with: event(.leftMouseUp))
            XCTAssertEqual(markedUp, 0)
            XCTAssertEqual(opened, 1)
        }
    }

    func testImageHoldOpensMarkupAndSuppressesClick() {
        let view = view()
        var markedUp = 0
        var opened = 0
        view.onLongPress = { markedUp += 1 }
        view.onClick = { opened += 1 }
        view.mouseDown(with: event(.leftMouseDown))
        RunLoop.main.run(until: Date().addingTimeInterval(0.55))
        view.mouseUp(with: event(.leftMouseUp))
        XCTAssertEqual(markedUp, 1)
        XCTAssertEqual(opened, 0)
    }

    func testAccessibilityPressOpens() {
        let view = view(.text)
        var opened = 0
        view.onClick = { opened += 1 }
        XCTAssertTrue(view.accessibilityPerformPress())
        XCTAssertEqual(opened, 1)
    }
}
