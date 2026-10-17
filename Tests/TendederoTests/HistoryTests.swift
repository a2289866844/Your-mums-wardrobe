import AppKit
import Combine
import XCTest
@testable import Tendedero

@MainActor
final class HistoryTests: XCTestCase {
    private func fixture(_ count: Int = 14) throws -> (Line, UserDefaults, URL, NSPasteboard) {
        let suite = "clipline-history-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "soundOff")
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(suite)
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
            board.releaseGlobally()
        }
        let line = Line(defaults: defaults, clipboardFolder: folder, copyPasteboard: board)
        line.maxItems = Line.historyLimit
        for i in 1...count { XCTAssertTrue(line.ingestClipboard(.text("Item \(i)"))) }
        return (line, defaults, folder, board)
    }

    func testPagesCoverHistoryAndReturnToNewest() throws {
        let (line, _, _, _) = try fixture()
        XCTAssertEqual(line.visibleItems.map(\.previewText), (9...14).map { "Item \($0)" })
        XCTAssertTrue(line.hasOlderPage)
        XCTAssertFalse(line.hasNewerPage)
        line.showOlderPage()
        XCTAssertEqual(line.visibleItems.map(\.previewText), (3...8).map { "Item \($0)" })
        line.showOlderPage()
        XCTAssertEqual(line.visibleItems.map(\.previewText), ["Item 1", "Item 2"])
        XCTAssertFalse(line.hasOlderPage)
        line.showOlderPage()
        line.showNewerPage()
        XCTAssertEqual(line.visibleItems.map(\.previewText), (3...8).map { "Item \($0)" })
        line.showNewerPage()
        XCTAssertEqual(line.visibleItems.map(\.previewText), (9...14).map { "Item \($0)" })
        XCTAssertFalse(line.hasNewerPage)
    }

    func testResetOnNewestPageDoesNotInvalidateCardViews() throws {
        let (line, _, _, _) = try fixture()
        var publications = 0
        let observation = line.objectWillChange.sink { publications += 1 }
        line.resetLibraryView()
        XCTAssertEqual(publications, 0)

        line.showOlderPage()
        line.resetLibraryView()
        XCTAssertEqual(line.visibleItems.map(\.previewText), (9...14).map { "Item \($0)" })
        let afterReset = publications
        line.resetLibraryView()
        XCTAssertEqual(publications, afterReset)
        withExtendedLifetime(observation) {}
    }

    func testIdenticalSearchResultsDoNotRebuildCardPage() throws {
        let (line, _, _, _) = try fixture(1)
        let results = line.items
        line.setLibraryResults(results)
        let revision = line.pageRevision
        line.setLibraryResults(results)
        XCTAssertEqual(line.pageRevision, revision)
    }

    func testHistoryMergeKeepsLiveScreenshotStateAndIdentity() throws {
        let (line, _, folder, _) = try fixture(1)
        let original = folder.appendingPathComponent("live.png")
        var content = ShelfContent.image(original)
        content.historyID = "same-archived-screenshot"
        content.title = "Current capture"
        var live = Pegged(url: original, thumb: NSImage(size: NSSize(width: 1, height: 1)), content: content)
        live.flying = true
        line.mergeArchivedCards([live])

        var snapshot = content
        snapshot.title = "Older snapshot"
        let archived = Pegged(url: folder.appendingPathComponent("blobs/archive.png"), thumb: live.thumb, content: snapshot)
        line.mergeArchivedCards([archived])

        let retained = try XCTUnwrap(line.items.first { $0.content.historyID == content.historyID })
        XCTAssertEqual(line.items.filter { $0.content.historyID == content.historyID }.count, 1)
        XCTAssertEqual(Set(line.items.map(\.id)).count, line.items.count)
        XCTAssertEqual(retained.id, live.id)
        XCTAssertEqual(retained.url, original)
        XCTAssertEqual(retained.title, "Current capture")
        XCTAssertTrue(retained.flying)
    }

    func testHistoryPersistsAcrossRestartAndDisplayResize() throws {
        let (line, defaults, folder, board) = try fixture()
        line.pageSize = 3
        XCTAssertEqual(line.liveCount, 14)
        XCTAssertEqual(line.visibleItems.count, 3)
        let restored = Line(defaults: defaults, clipboardFolder: folder, copyPasteboard: board)
        restored.maxItems = Line.historyLimit
        XCTAssertEqual(restored.liveCount, 14)
        restored.showOlderPage()
        XCTAssertEqual(restored.visibleItems.map(\.previewText), (3...8).map { "Item \($0)" })
    }

    func testNewCopyDoesNotDisplaceHistoricalPageAndNavigationWaitsForDrag() throws {
        let (line, _, _, _) = try fixture()
        line.showOlderPage()
        let ids = line.visibleItems.map(\.id)
        XCTAssertTrue(line.ingestClipboard(.text("New arrival")))
        XCTAssertEqual(line.visibleItems.map(\.id), ids)
        line.draggingID = ids[0]
        line.showOlderPage()
        XCTAssertEqual(line.visibleItems.map(\.id), ids)
        line.draggingID = nil
        line.showOlderPage()
        XCTAssertEqual(line.visibleItems.count, 2)
    }

    func testHistoricalTextEditCopiesFullTextAndSurvivesRestart() throws {
        let (line, defaults, folder, board) = try fixture()
        line.showOlderPage()
        let item = try XCTUnwrap(line.visibleItems.first)
        let text = "Edited historical item\n" + String(repeating: "完整內容，保留換行。\n", count: 200)
        try line.updateText(item.id, text: text)
        XCTAssertEqual(line.visibleItems.first?.id, item.id)
        XCTAssertEqual(line.visibleItems.first?.previewText, String(text.prefix(800)))
        line.copy(item.id)
        XCTAssertEqual(board.string(forType: .string), text)
        let restored = Line(defaults: defaults, clipboardFolder: folder, copyPasteboard: board)
        restored.maxItems = Line.historyLimit
        let saved = try XCTUnwrap(restored.items.first { $0.url == item.url })
        restored.copy(saved.id)
        XCTAssertEqual(board.string(forType: .string), text)
        XCTAssertEqual(saved.content.digest, ClipboardStore.digest(Data(text.utf8)))
    }

    func testOversizedEditLeavesPreviousTextIntact() throws {
        let (line, _, _, _) = try fixture(1)
        let item = try XCTUnwrap(line.items.first)
        XCTAssertThrowsError(try line.updateText(item.id, text: String(repeating: "x", count: ClipboardStore.textLimit + 1)))
        XCTAssertEqual(ClipboardStore.text(at: item.url), "Item 1")
    }

    func testDeletingPageAnchorStaysInHistory() throws {
        let (line, _, _, _) = try fixture()
        line.showOlderPage()
        let anchor = try XCTUnwrap(line.visibleItems.last)
        line.drop(anchor.id, quietly: true)
        XCTAssertEqual(line.visibleItems.last?.previewText, "Item 7")
        XCTAssertTrue(line.hasNewerPage)
    }

    func testRetentionBoundKeepsNewest120AndAllPagesStayReachable() throws {
        let (line, _, _, _) = try fixture(126)
        XCTAssertEqual(line.liveCount, 120)
        var seen = Set(line.visibleItems.map(\.id))
        while line.hasOlderPage {
            line.showOlderPage()
            seen.formUnion(line.visibleItems.map(\.id))
        }
        XCTAssertEqual(seen.count, 120)
        XCTAssertEqual(line.visibleItems.first?.previewText, "Item 7")
    }

    func testDiscardDoesNotReturnFromHistoryAfterRestart() throws {
        let (line, defaults, folder, board) = try fixture()
        line.showOlderPage()
        let removed = try XCTUnwrap(line.visibleItems.first)
        line.drop(removed.id, quietly: true)
        XCTAssertFalse(line.visibleItems.contains { $0.id == removed.id })
        let restored = Line(defaults: defaults, clipboardFolder: folder, copyPasteboard: board)
        XCTAssertFalse(restored.items.contains { $0.url == removed.url })
        XCTAssertEqual(restored.liveCount, 13)
    }
}
