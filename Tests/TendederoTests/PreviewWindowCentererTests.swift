import XCTest
@testable import Tendedero

@MainActor
final class PreviewWindowCentererTests: XCTestCase {
    func testCentersInsideUsableDisplayWithoutChangingSize() {
        let size = CGSize(width: 1000, height: 700)
        let visible = CGRect(x: 60, y: 0, width: 1668, height: 1079)
        let point = PreviewWindowCenterer.centeredPosition(size: size, visible: visible, primaryTop: 1117)!
        XCTAssertEqual(point.x, 394)
        XCTAssertEqual(point.y, 227.5)
        XCTAssertEqual(point.x + size.width / 2, visible.midX)
        XCTAssertEqual(1117 - point.y - size.height / 2, visible.midY)
    }

    func testCentersOnLeftAndAboveDisplaysInGlobalAXCoordinates() {
        let size = CGSize(width: 800, height: 600)
        XCTAssertEqual(PreviewWindowCenterer.centeredPosition(size: size,
            visible: CGRect(x: -1920, y: 0, width: 1920, height: 1055), primaryTop: 1080),
            CGPoint(x: -1360, y: 252.5))
        XCTAssertEqual(PreviewWindowCenterer.centeredPosition(size: size,
            visible: CGRect(x: 0, y: 1080, width: 1920, height: 1055), primaryTop: 1080),
            CGPoint(x: 560, y: -827.5))
    }

    func testInvalidGeometryIsRejected() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        for size in [CGSize.zero, CGSize(width: -1, height: 100), CGSize(width: CGFloat.infinity, height: 100)] {
            XCTAssertNil(PreviewWindowCenterer.centeredPosition(size: size, visible: visible, primaryTop: 900))
        }
        XCTAssertNil(PreviewWindowCenterer.centeredPosition(size: CGSize(width: 800, height: 600),
            visible: visible, primaryTop: .nan))
    }

    func testExactDocumentWinsOverOtherSameNamedDocument() {
        let url = URL(fileURLWithPath: "/tmp/target/截圖 1.png")
        let windows = [
            PreviewWindowCenterer.Identity(document: "file:///tmp/other/%E6%88%AA%E5%9C%96%201.png", focused: true),
            PreviewWindowCenterer.Identity(document: url.absoluteString, focused: false)
        ]
        XCTAssertEqual(PreviewWindowCenterer.matchingIndex(windows, for: url), 1)
        XCTAssertNil(PreviewWindowCenterer.matchingIndex([windows[0]], for: url))
    }

    func testMissingDocumentNeverSelectsAWindow() {
        let url = URL(fileURLWithPath: "/tmp/photo.png")
        let candidate = PreviewWindowCenterer.Identity(document: nil, focused: true)
        XCTAssertNil(PreviewWindowCenterer.matchingIndex([candidate], for: url))
        XCTAssertNil(PreviewWindowCenterer.matchingIndex([candidate, candidate], for: url))
        XCTAssertNil(PreviewWindowCenterer.matchingIndex([
            .init(document: "", focused: true)
        ], for: url))
    }

    func testDuplicateDocumentWindowsSelectOnlyFocusedWindow() {
        let url = URL(fileURLWithPath: "/tmp/photo.png")
        let windows = [
            PreviewWindowCenterer.Identity(document: url.absoluteString, focused: false),
            PreviewWindowCenterer.Identity(document: url.path, focused: true)
        ]
        XCTAssertEqual(PreviewWindowCenterer.matchingIndex(windows, for: url), 1)
        XCTAssertNil(PreviewWindowCenterer.matchingIndex([windows[0], windows[0]], for: url))
    }
}
