import AppKit
import SwiftUI
import XCTest
@testable import Tendedero

@MainActor
final class CopyButtonHostingTests: XCTestCase {
    func testHostedButtonReflectsSuccessfulCopy() throws {
        try withCard { line, button, _ in
            button.performClick(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            XCTAssertEqual(button.title, L("Copied", "Copiado"))
            XCTAssertEqual(line.copiedID, line.items.first?.id)
        }
    }

    func testHostedButtonReflectsFailureAndSuccessfulRetry() throws {
        try withCard { line, button, file in
            try FileManager.default.removeItem(at: file)
            button.performClick(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            XCTAssertEqual(button.title, L("Retry", "Reintentar"))
            XCTAssertEqual(line.copyFailedID, line.items.first?.id)
            try Data("Restored full text".utf8).write(to: file)
            button.performClick(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            XCTAssertEqual(button.title, L("Copied", "Copiado"))
            XCTAssertNil(line.copyFailedID)
        }
    }

    private func withCard(_ verify: (Line, CardCopyButton, URL) throws -> Void) throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipline-copy-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "clipline-copy-host-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "soundOff")
        defer { defaults.removePersistentDomain(forName: suite) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let line = Line(defaults: defaults, clipboardFolder: directory, copyPasteboard: board)
        XCTAssertTrue(line.ingestClipboard(.text("Full text to copy")))
        let item = try XCTUnwrap(line.items.first)
        let host = NSHostingView(rootView: PeggedView(item: item, line: line))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 240),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let grab = try XCTUnwrap(findGrab(in: host))
        try verify(line, grab.copyButton, item.url)
        withExtendedLifetime(window) {}
    }

    private func findGrab(in view: NSView) -> GrabView? {
        if let grab = view as? GrabView { return grab }
        return view.subviews.lazy.compactMap { self.findGrab(in: $0) }.first
    }
}
