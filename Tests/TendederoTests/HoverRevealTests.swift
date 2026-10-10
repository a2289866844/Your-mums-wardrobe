import XCTest
@testable import Tendedero

final class HoverRevealTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testPointerAtExactTopEdgeNeverAlternatesBetweenOpenAndClosed() {
        var hover = HoverReveal()
        hover.start(on: screen)
        let topEdge = CGPoint(x: 720, y: screen.maxY)
        for _ in 0..<20 {
            XCTAssertFalse(hover.shouldRetract(pointer: topEdge), "The trigger edge must also be inside the keep-open region")
            XCTAssertTrue(hover.isActive)
        }
    }

    func testKeepsLineOpenAcrossEntireWidthOfUpperThird() {
        var hover = HoverReveal()
        hover.start(on: screen)
        for point in [CGPoint(x: 0, y: 600), CGPoint(x: 1439, y: 899), CGPoint(x: 720, y: 750)] {
            XCTAssertFalse(hover.shouldRetract(pointer: point))
            XCTAssertTrue(hover.isActive)
        }
    }

    func testRetractsImmediatelyBelowUpperThird() {
        var hover = HoverReveal()
        hover.start(on: screen)
        XCTAssertTrue(hover.shouldRetract(pointer: CGPoint(x: 720, y: 599.9)))
        XCTAssertFalse(hover.isActive)
    }

    func testMovingToAnotherDisplayClosesTheOriginalReveal() {
        for x in [-1.0, 1440.0] {
            var hover = HoverReveal()
            hover.start(on: screen)
            XCTAssertTrue(hover.shouldRetract(pointer: CGPoint(x: x, y: 750)))
        }
    }

    func testUsesDisplayOriginAndHeightRatherThanMainDisplayCoordinates() {
        var hover = HoverReveal()
        hover.start(on: CGRect(x: -1920, y: -300, width: 1920, height: 1200))
        XCTAssertFalse(hover.shouldRetract(pointer: CGPoint(x: -1000, y: 500)))
        XCTAssertTrue(hover.shouldRetract(pointer: CGPoint(x: -1000, y: 499)))
    }

    func testNewScreenshotOrManualRevealDoesNotInheritHoverRegion() {
        var hover = HoverReveal()
        hover.start(on: screen)
        hover.cancel()
        XCTAssertFalse(hover.shouldRetract(pointer: CGPoint(x: 720, y: 0)))
        XCTAssertFalse(hover.isActive)
    }

    func testCanTriggerAgainAfterPointerLeftRegion() {
        var hover = HoverReveal()
        hover.start(on: screen)
        XCTAssertTrue(hover.shouldRetract(pointer: CGPoint(x: 720, y: 0)))
        hover.start(on: screen)
        XCTAssertFalse(hover.shouldRetract(pointer: CGPoint(x: 720, y: 899)))
        XCTAssertTrue(hover.isActive)
    }
}
