import XCTest
@testable import Tendedero

final class ScreenshotLocationMonitorTests: XCTestCase {
    @MainActor
    func testChangedDestinationIncludesCapturesSincePreviousCheckOnce() {
        let start = Date(timeIntervalSince1970: 100)
        var destination = URL(fileURLWithPath: "/tmp/old")
        var changes: [(URL, Date)] = []
        let monitor = ScreenshotLocationMonitor(folder: destination, checkedAt: start,
                                                resolve: { destination }, onChange: { changes.append(($0, $1)) })
        monitor.poll(at: start.addingTimeInterval(2))
        destination = URL(fileURLWithPath: "/tmp/new")
        monitor.poll(at: start.addingTimeInterval(4))
        monitor.poll(at: start.addingTimeInterval(6))
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.0, destination)
        XCTAssertEqual(changes.first?.1, start.addingTimeInterval(2))
    }

    @MainActor
    func testEquivalentPathsDoNotRestartMonitoring() {
        var changes = 0
        let monitor = ScreenshotLocationMonitor(folder: URL(fileURLWithPath: "/tmp/screenshots"),
                                                resolve: { URL(fileURLWithPath: "/tmp/screenshots/../screenshots") },
                                                onChange: { _, _ in changes += 1 })
        monitor.poll()
        XCTAssertEqual(changes, 0)
    }

    @MainActor
    func testEveryPollChecksWatcherAfterDestinationChange() {
        var destination = URL(fileURLWithPath: "/tmp/old")
        var events: [String] = []
        let monitor = ScreenshotLocationMonitor(folder: destination, resolve: { destination },
            onCheck: { events.append("check") }, onChange: { _, _ in events.append("change") })
        monitor.poll()
        monitor.poll()
        destination = URL(fileURLWithPath: "/tmp/new")
        monitor.poll()
        monitor.poll()
        XCTAssertEqual(events, ["check", "check", "change", "check", "check"])
    }
}
