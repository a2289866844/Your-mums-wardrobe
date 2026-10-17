import AppKit
import XCTest
@testable import Tendedero

@MainActor
final class NativeConfigurationTests: XCTestCase {
    func testRepeatedCopyConfigurationPreservesLayoutAndImage() throws {
        _ = NSApplication.shared
        let view = GrabView(frame: NSRect(x: 0, y: 0, width: 220, height: 182))
        view.configureCopyButton(title: "First card", copied: false, failed: false)
        view.layoutSubtreeIfNeeded()
        view.needsLayout = false
        let image = try XCTUnwrap(view.copyButton.image)

        view.configureCopyButton(title: "First card", copied: false, failed: false)

        XCTAssertFalse(view.needsLayout)
        XCTAssertTrue(view.copyButton.image === image)
        XCTAssertEqual(view.copyButton.accessibilityLabel(), L("Copy First card", "Copiar First card"))

        view.configureCopyButton(title: "Renamed card", copied: false, failed: false)
        XCTAssertTrue(view.copyButton.image === image)
        XCTAssertEqual(view.copyButton.accessibilityLabel(), L("Copy Renamed card", "Copiar Renamed card"))
    }

    func testCopyFeedbackRetainsRetryAndReusesReadyImage() throws {
        _ = NSApplication.shared
        let view = GrabView(frame: .zero)
        view.configureCopyButton(title: "Card", copied: false, failed: false)
        let readyImage = try XCTUnwrap(view.copyButton.image)
        view.configureCopyButton(title: "Card", copied: false, failed: true)
        XCTAssertEqual(view.copyButton.title, L("Retry", "Reintentar"))
        XCTAssertEqual(view.copyButton.accessibilityLabel(), L("Retry copying Card", "Reintentar copiar Card"))
        view.configureCopyButton(title: "Card", copied: true, failed: false)
        XCTAssertEqual(view.copyButton.title, L("Copied", "Copiado"))
        XCTAssertEqual(view.copyButton.contentTintColor, .systemGreen)

        view.configureCopyButton(title: "Card", copied: false, failed: false)
        XCTAssertEqual(view.copyButton.title, L("Copy", "Copiar"))
        XCTAssertTrue(view.copyButton.image === readyImage)
    }

    func testCardAccessibilityRefreshesForTitleAndKind() {
        _ = NSApplication.shared
        let view = GrabView(frame: .zero)
        view.kind = .image
        view.configureAccessibility(title: "Image")
        XCTAssertEqual(view.openElement.accessibilityHelp(),
                       L("Open this image. Drag the card to another app.", "Abre esta imagen. Arrastra la tarjeta a otra app."))

        view.kind = .text
        view.configureAccessibility(title: "Text")
        XCTAssertEqual(view.accessibilityLabel(), "Text")
        XCTAssertEqual(view.openElement.accessibilityLabel(), L("Open Text", "Abrir Text"))
        XCTAssertEqual(view.openElement.accessibilityHelp(),
                       L("Open this item. Drag the card to another app.", "Abre este elemento. Arrastra la tarjeta a otra app."))
    }

    func testRepeatedToolbarConfigurationDoesNotRequestLayout() throws {
        _ = NSApplication.shared
        let suite = "clipline-native-configuration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let line = Line(defaults: defaults, clipboardFolder: directory)
        let toolbar = LibraryToolbarView(frame: NSRect(x: 0, y: 0, width: 1100, height: 32))
        toolbar.configure(line)
        toolbar.layoutSubtreeIfNeeded()
        toolbar.needsLayout = false
        let searchFrame = toolbar.search.frame

        toolbar.configure(line)

        XCTAssertFalse(toolbar.needsLayout)
        XCTAssertEqual(toolbar.search.frame, searchFrame)

        line.libraryStatus = "10 筆結果"
        toolbar.configure(line)
        XCTAssertTrue(toolbar.needsLayout)
        toolbar.layoutSubtreeIfNeeded()
        XCTAssertFalse(toolbar.status.isHidden)
        XCTAssertLessThan(toolbar.search.frame.width, searchFrame.width)

        line.libraryQuery = "updated query"
        line.libraryScope = .pinned
        toolbar.configure(line)
        XCTAssertEqual(toolbar.search.stringValue, "updated query")
        XCTAssertEqual(toolbar.scopes.selectedSegment, 1)
        XCTAssertEqual(toolbar.compactScopes.indexOfSelectedItem, 1)
    }
}
