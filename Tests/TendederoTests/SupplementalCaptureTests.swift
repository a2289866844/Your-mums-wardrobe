import AppKit
import ClipdCore
import XCTest
@testable import Tendedero

private final class ReplacingRichTextProvider: NSObject, NSPasteboardItemDataProvider {
    let replace: (NSPasteboard) -> Void
    init(_ replace: @escaping (NSPasteboard) -> Void) { self.replace = replace }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        if let pasteboard { replace(pasteboard) }
        item.setData(Data("{\\rtf1 stale}".utf8), forType: type)
    }
}

@MainActor
final class SupplementalCaptureTests: XCTestCase {
    func testRichTextRoundTripThroughArchiveAndCopy() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("clipline-rich-\(UUID())")
        let suite = "clipline-rich-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "soundOff")
        let board = NSPasteboard.withUniqueName()
        let store = try Store(directory: root.appendingPathComponent("Archive"))
        defer {
            store.close(); board.releaseGlobally(); defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let cache = root.appendingPathComponent("Cache")
        let library = try ClipdLibrary(directory: root.appendingPathComponent("Archive"), store: store, cacheDirectory: cache)
        let line = Line(defaults: defaults, clipboardFolder: cache, copyPasteboard: board)
        try library.connect(to: line, trackApplications: false)
        let watcher = ClipboardWatcher(pasteboard: board, onTextFormats: { line.capturedTextFormats = $0 }) { line.ingestClipboard($0) }
        let rtf = Data("{\\rtf1\\ansi Rich text}".utf8)
        let entry = NSPasteboardItem()
        entry.setString("Rich text", forType: .string)
        entry.setData(rtf, forType: .rtf)
        board.clearContents(); board.writeObjects([entry])
        watcher.poll()
        await library.waitForWrites()
        XCTAssertTrue(line.capturedTextFormats.isEmpty)
        let card = try XCTUnwrap(line.items.first)
        line.copy(card.id)
        XCTAssertEqual(board.data(forType: .rtf), rtf)
        XCTAssertEqual(board.string(forType: .string), "Rich text")
        XCTAssertEqual(try store.count(), 1)
    }

    func testReplacingClipboardWhileReadingRichFormatDoesNotDeliverMixedContent() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var delivered = 0
        var formatsDelivered = 0
        let watcher = ClipboardWatcher(pasteboard: board, onTextFormats: { _ in formatsDelivered += 1 }) { _ in delivered += 1; return true }
        let provider = ReplacingRichTextProvider { board in
            let replacement = NSPasteboardItem()
            replacement.setString("private replacement", forType: .string)
            replacement.setString("1", forType: .init("org.nspasteboard.ConcealedType"))
            board.clearContents(); board.writeObjects([replacement])
        }
        let entry = NSPasteboardItem()
        entry.setString("original", forType: .string)
        entry.setDataProvider(provider, forTypes: [.rtf])
        board.clearContents(); board.writeObjects([entry])
        watcher.poll()
        XCTAssertEqual(delivered, 0)
        XCTAssertEqual(formatsDelivered, 0)
        watcher.poll()
        XCTAssertEqual(delivered, 0)
        withExtendedLifetime(provider) {}
    }
}
