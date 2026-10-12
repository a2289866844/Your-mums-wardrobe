import XCTest
@testable import Tendedero

final class CaptureGeometryTests: XCTestCase {
    private let source = CGRect(x: 100, y: 100, width: 800, height: 600)
    private let destination = CGRect(x: 600, y: 700, width: 220, height: 182)

    func testFixedFlightKeepsOriginalDeadlineAndExactEndpoint() {
        let path = CaptureFlightPath(from: source, to: destination, duration: 0.65)
        XCTAssertEqual(path.frame(at: 0), source)
        XCTAssertEqual(path.deadline, 0.65)
        XCTAssertEqual(path.frame(at: 0.65).minX, destination.minX, accuracy: 0.0001)
        XCTAssertEqual(path.frame(at: 0.65).minY, destination.minY, accuracy: 0.0001)
        XCTAssertEqual(path.frame(at: 0.65).size, destination.size)
    }

    func testShelfShiftRetargetsWithoutPositionJump() {
        var path = CaptureFlightPath(from: source, to: destination, duration: 0.65)
        let elapsed = 0.3
        let before = path.frame(at: elapsed)
        let shifted = destination.offsetBy(dx: -122, dy: 0)
        path.retarget(to: shifted, at: elapsed)
        XCTAssertEqual(path.frame(at: elapsed), before)
        XCTAssertEqual(path.frame(at: path.deadline), shifted)
        XCTAssertLessThan(abs(path.frame(at: elapsed + 1.0 / 60).midX - before.midX), 10)
    }

    func testLateShiftSettlesInsteadOfSnappingOnOriginalDeadline() {
        var path = CaptureFlightPath(from: source, to: destination, duration: 0.65)
        let before = path.frame(at: 0.64)
        let shifted = destination.offsetBy(dx: 122, dy: -20)
        path.retarget(to: shifted, at: 0.64)
        XCTAssertEqual(path.frame(at: 0.64), before)
        XCTAssertEqual(path.deadline, 0.82, accuracy: 0.0001)
        XCTAssertLessThan(abs(path.frame(at: 0.65).midX - before.midX), 1)
        XCTAssertEqual(path.frame(at: path.deadline), shifted)
    }

    func testRepeatedShelfChangesStayContinuousAndMissingTargetKeepsFallback() {
        var path = CaptureFlightPath(from: source, to: destination, duration: 0.65)
        for elapsed in [0.2, 0.4, 0.6] {
            let before = path.frame(at: elapsed)
            let shifted = destination.offsetBy(dx: elapsed * 200, dy: 0)
            path.retarget(to: shifted, at: elapsed)
            XCTAssertEqual(path.frame(at: elapsed), before)
        }
        let before = path.frame(at: 0.7)
        let deadline = path.deadline
        path.retarget(to: nil, at: 0.7)
        path.retarget(to: CGRect(x: CGFloat.infinity, y: 0, width: 220, height: 182), at: 0.7)
        XCTAssertEqual(path.frame(at: 0.7), before)
        XCTAssertEqual(path.deadline, deadline)
        XCTAssertEqual(path.frame(at: deadline), destination.offsetBy(dx: 120, dy: 0))
    }

    func testCaptureCoordinatesConvertUsingMainDisplayTop() {
        XCTAssertEqual(captureRect(globalRect: [-100, 200, 300, 100], mainDisplayTop: 900),
                       CGRect(x: -100, y: 600, width: 300, height: 100))
        // A display above the main one uses a negative capture Y coordinate.
        XCTAssertEqual(captureRect(globalRect: [100, -500, 200, 100], mainDisplayTop: 900),
                       CGRect(x: 100, y: 1300, width: 200, height: 100))
    }

    func testInvalidMetadataCannotReachAnimationGeometry() {
        XCTAssertNil(captureRect(globalRect: [0, 0, 1, 100], mainDisplayTop: 900))
        XCTAssertNil(captureRect(globalRect: [0, 0, 100, -100], mainDisplayTop: 900))
        XCTAssertNil(captureRect(globalRect: [0, 0, 100], mainDisplayTop: 900))
        for index in 0..<4 {
            for value in [Double.nan, Double.infinity, -Double.infinity] {
                var values = [NSNumber(value: 0), NSNumber(value: 0), NSNumber(value: 100), NSNumber(value: 100)]
                values[index] = NSNumber(value: value)
                XCTAssertNil(captureRect(globalRect: values, mainDisplayTop: 900))
            }
        }
    }
}
