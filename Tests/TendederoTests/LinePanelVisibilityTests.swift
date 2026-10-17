import AppKit
import XCTest
@testable import Tendedero

@MainActor
final class LinePanelVisibilityTests: XCTestCase {
    private func panel() -> LinePanel {
        _ = NSApplication.shared
        let panel = LinePanel(content: NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100)))
        panel.setFrame(NSRect(x: 100, y: 100, width: 300, height: 100), display: false)
        addTeardownBlock { await MainActor.run { panel.orderOut(nil) } }
        return panel
    }

    func testTuckedShelfReleasesItsVisibleWindowSurface() async throws {
        let panel = panel()
        panel.setShelfVisible(true)
        XCTAssertTrue(panel.isVisible)
        panel.setShelfVisible(false, hideDelay: 0)
        let deadline = Date().addingTimeInterval(2)
        while panel.isVisible && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(panel.isVisible)
        panel.setShelfVisible(true)
        XCTAssertTrue(panel.isVisible)
    }

    func testRepeatedWorkspaceRefreshDoesNotReorderVisibleShelf() {
        let shelf = panel(), other = panel()
        shelf.setShelfVisible(true)
        other.setShelfVisible(true)
        let identifiers = Set([shelf.windowNumber, other.windowNumber])
        // NSApplication.orderedWindows excludes these nonactivating panels.
        // Compare just our two window IDs in WindowServer's actual ordering.
        func order() -> [Int] {
            let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
            return windows.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue }
                .filter { identifiers.contains($0) }
        }
        let before = order()
        XCTAssertEqual(before.count, 2)
        for _ in 0..<10 { shelf.setShelfVisible(true) }
        let after = order()
        XCTAssertEqual(after, before)
    }

    func testLateRetractionCannotHideAReopenedShelf() async throws {
        let panel = panel()
        panel.setShelfVisible(true)
        panel.setShelfVisible(false, hideDelay: 0.03)
        panel.setShelfVisible(true)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(panel.isVisible)
    }

    func testOverlaySupportsAllSpacesAndHidesInMissionControl() {
        let panel = panel()
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.transient))
        XCTAssertFalse(panel.collectionBehavior.contains(.stationary))
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllApplications))
    }
}
