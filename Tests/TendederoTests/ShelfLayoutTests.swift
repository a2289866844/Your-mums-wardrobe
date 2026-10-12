import XCTest
@testable import Tendedero

final class ShelfLayoutTests: XCTestCase {
    func testNarrowDisplayCapacityFitsCards() {
        for width in [320.0, 480, 600, 700, 800, 1024, 1440, 1728] {
            let count = Layout.capacity(width: width)
            let span = Double(count - 1) * Layout.spacing + Layout.cardWidth
            XCTAssertLessThanOrEqual(span, width)
            let first = Layout.x(index: 0, count: count, width: width)
            let last = Layout.x(index: count - 1, count: count, width: width)
            XCTAssertGreaterThanOrEqual(first - Layout.cardWidth / 2, 0)
            XCTAssertLessThanOrEqual(last + Layout.cardWidth / 2, width)
        }
    }

    func testCapacityPreservesExistingDesktopDensityAndLimit() {
        XCTAssertEqual(Layout.capacity(width: 1440), 5)
        XCTAssertEqual(Layout.capacity(width: 1728), 6)
        XCTAssertEqual(Layout.capacity(width: 5120), 12)
        XCTAssertEqual(Layout.capacity(width: 0), 1)
    }

    func testTemporaryOverflowDuringInteractionOrFallFitsPanel() {
        for width in [320.0, 480, 1440, 1674, 1728] {
            for extra in 1...3 {
                let count = Layout.capacity(width: width) + extra
                let first = Layout.x(index: 0, count: count, width: width)
                let last = Layout.x(index: count - 1, count: count, width: width)
                XCTAssertGreaterThanOrEqual(first - Layout.cardWidth / 2, 20)
                XCTAssertLessThanOrEqual(last + Layout.cardWidth / 2, width - 20)
            }
        }
    }
}
