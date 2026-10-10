import XCTest
@testable import Tendedero

final class HoverTriggerTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    private func notchRegion() -> CGRect {
        HoverTrigger.region(on: screen, menuBarHeight: 33,
                            topLeftArea: CGRect(x: 0, y: 1085, width: 771, height: 32),
                            topRightArea: CGRect(x: 956, y: 1085, width: 772, height: 32))
    }

    func testHardwareNotchTriggersButBothMenuBarSidesDoNot() {
        let region = notchRegion()
        XCTAssertEqual(region.width, 185)
        XCTAssertTrue(HoverTrigger.contains(CGPoint(x: 864, y: 1100), in: region))
        for x in [50.0, 770.9, 956.0, 1650.0] {
            XCTAssertFalse(HoverTrigger.contains(CGPoint(x: x, y: 1100), in: region))
        }
    }

    func testExactTopEdgeAndSmallLowerLipAreReachable() {
        let region = notchRegion()
        XCTAssertTrue(HoverTrigger.contains(CGPoint(x: 864, y: screen.maxY), in: region))
        XCTAssertTrue(HoverTrigger.contains(CGPoint(x: 864, y: 1078), in: region))
        XCTAssertFalse(HoverTrigger.contains(CGPoint(x: 864, y: 1077.9), in: region))
        XCTAssertFalse(HoverTrigger.contains(CGPoint(x: 864, y: screen.maxY + 0.1), in: region))
    }

    func testDisplayWithoutNotchUsesOnlySmallCenteredArea() {
        let region = HoverTrigger.region(on: screen, menuBarHeight: 24)
        XCTAssertEqual(region.width, 180)
        XCTAssertEqual(region.midX, screen.midX)
        XCTAssertTrue(HoverTrigger.contains(CGPoint(x: 864, y: 1117), in: region))
        XCTAssertFalse(HoverTrigger.contains(CGPoint(x: 600, y: 1117), in: region))
    }

    func testSecondaryDisplayUsesItsOwnOriginAndCenter() {
        let display = CGRect(x: -1920, y: 1117, width: 1920, height: 1080)
        let region = HoverTrigger.region(on: display, menuBarHeight: 24)
        XCTAssertTrue(HoverTrigger.contains(CGPoint(x: -960, y: 2197), in: region))
        XCTAssertFalse(HoverTrigger.contains(CGPoint(x: 864, y: 1117), in: region))
    }

    func testInvalidAuxiliaryAreasCannotMakeWholeBarHot() {
        let region = HoverTrigger.region(on: screen, menuBarHeight: 33,
                                         topLeftArea: CGRect(x: 0, y: 1085, width: 100, height: 32),
                                         topRightArea: CGRect(x: 1600, y: 1085, width: 128, height: 32))
        XCTAssertEqual(region.width, 180)
        XCTAssertEqual(region.midX, screen.midX)
    }

    func testNarrowEntranceKeepsExistingUpperThirdExitRule() {
        var reveal = HoverReveal()
        reveal.start(on: screen)
        let outsideNotchButInsideUpperThird = CGPoint(x: 50, y: 1000)
        XCTAssertFalse(HoverTrigger.contains(outsideNotchButInsideUpperThird, in: notchRegion()))
        XCTAssertFalse(reveal.shouldRetract(pointer: outsideNotchButInsideUpperThird))
        XCTAssertTrue(reveal.shouldRetract(pointer: CGPoint(x: 864, y: 700)))
    }
}
