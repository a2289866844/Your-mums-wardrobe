import XCTest
@testable import Tendedero

final class CapturePreviewTests: XCTestCase {
    func testNewCaptureRetractsAtThreeSecondsWithoutExtraFiveSecondGrace() {
        let start = Date(timeIntervalSinceReferenceDate: 100)
        var preview = CapturePreview()
        preview.start(at: start)
        XCTAssertFalse(preview.shouldRetract(at: start.addingTimeInterval(2.99)))
        XCTAssertTrue(preview.shouldRetract(at: start.addingTimeInterval(3)))
        XCTAssertFalse(preview.shouldRetract(at: start.addingTimeInterval(8)))
    }

    func testAnotherScreenshotStartsItsOwnThreeSecondPreview() {
        let start = Date(timeIntervalSinceReferenceDate: 100)
        var preview = CapturePreview()
        preview.start(at: start)
        preview.start(at: start.addingTimeInterval(2))
        XCTAssertFalse(preview.shouldRetract(at: start.addingTimeInterval(3)))
        XCTAssertTrue(preview.shouldRetract(at: start.addingTimeInterval(5)))
    }

    func testManualOrHotZoneRevealCancelsCapturePreviewTimer() {
        let start = Date(timeIntervalSinceReferenceDate: 100)
        var preview = CapturePreview()
        preview.start(at: start)
        preview.cancel()
        XCTAssertFalse(preview.shouldRetract(at: start.addingTimeInterval(30)))
    }
}
