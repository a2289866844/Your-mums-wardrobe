import AppKit
import ClipdCore
import XCTest
@testable import Tendedero

@MainActor
final class ClipdLibraryTests: XCTestCase {
    private func fixture(preparationQueue: DispatchQueue? = nil) throws -> (Line, ClipdLibrary, NSPasteboard, URL) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("clipline-library-\(UUID())")
        let suite = "clipline-library-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "soundOff")
        let board = NSPasteboard.withUniqueName()
        let store = try Store(directory: root.appendingPathComponent("Archive"))
        let cache = root.appendingPathComponent("Cache")
        let library = try ClipdLibrary(directory: root.appendingPathComponent("Archive"), store: store, cacheDirectory: cache, preparationQueue: preparationQueue)
        let line = Line(defaults: defaults, clipboardFolder: cache, copyPasteboard: board)
        line.maxItems = Line.historyLimit
        addTeardownBlock {
            store.close()
            board.releaseGlobally()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        return (line, library, board, root)
    }

    private func text(_ body: String, id: String = makeItemID(), pinned: Bool = false) -> ClipItem {
        ClipItem(id: id, kind: .text, capturedAt: Date(), contentHash: ClipboardStore.digest(Data(body.utf8)),
            preview: String(body.prefix(80)), searchText: body, sourceBundleID: "test.source", sourceAppName: "Original App",
            isPinned: pinned, representations: [ItemRepresentation(uti: "public.utf8-plain-text", byteCount: body.utf8.count, inlineText: body)])
    }

    func testExistingArchiveUsesSameRowsAndPreservesFullCopyAndRichFormats() throws {
        let (line, library, board, _) = try fixture()
        let body = String(repeating: "舊版 Clipd 完整內容\n", count: 180)
        var record = text(body, pinned: true)
        record.representations.append(ItemRepresentation(uti: "public.html", byteCount: 12, inlineText: "<b>hello</b>"))
        try library.store.insert(record)
        try library.connect(to: line, trackApplications: false)
        XCTAssertEqual(try library.store.count(), 1)
        let card = try XCTUnwrap(line.visibleItems.first)
        XCTAssertEqual(card.content.sourceAppName, "Original App")
        XCTAssertEqual(card.content.isPinned, true)
        line.copy(card.id)
        XCTAssertEqual(board.string(forType: .string), body)
        XCTAssertEqual(board.string(forType: .html), "<b>hello</b>")
    }

    func testNewCapturesAreArchivedAndEditedContentIsIndexed() async throws {
        let (line, library, board, _) = try fixture()
        try library.connect(to: line, trackApplications: false)
        XCTAssertTrue(line.ingestClipboard(.text("待搜尋的原文")))
        await library.waitForWrites()
        let card = try XCTUnwrap(line.items.first)
        let id = try XCTUnwrap(card.content.historyID)
        XCTAssertEqual(try library.store.count(), 1)
        XCTAssertTrue(line.archivingIDs.isEmpty)
        try line.updateText(card.id, text: "修改後的搜尋內容")
        XCTAssertTrue(try library.store.search("原文", limit: 10).isEmpty)
        XCTAssertEqual(try library.store.search("修改後", limit: 10).first?.id, id)
        line.copy(card.id)
        XCTAssertEqual(board.string(forType: .string), "修改後的搜尋內容")
    }

    func testHistoricalSearchCanCopyAnItemBeyondTheShelfLimit() async throws {
        let (line, library, board, _) = try fixture()
        let old = text("遙遠的歷史烏龍茶")
        try library.store.insert(old)
        for index in 0..<125 { try library.store.insert(text("New item \(index)")) }
        try library.connect(to: line, trackApplications: false)
        XCTAssertFalse(line.items.contains { $0.content.historyID == old.id })
        line.libraryQuery = "烏龍茶"
        try await waitUntil { !line.libraryResults.isEmpty }
        let found = try XCTUnwrap(line.visibleItems.first)
        line.copy(found.id)
        XCTAssertEqual(board.string(forType: .string), "遙遠的歷史烏龍茶")
        line.editingURL = found.url
        line.libraryQuery = "does-not-exist"
        try await waitUntil { line.libraryResults.isEmpty }
        try line.updateText(found.id, text: "跨篩選仍能儲存")
        XCTAssertEqual(try library.store.item(id: old.id)?.searchText, "跨篩選仍能儲存")
        line.editingURL = nil
    }

    func testPinnedFilterAndMissingImageCopyPreservesClipboard() async throws {
        let (line, library, board, root) = try fixture()
        let first = text("Pinned text"), second = text("Other text")
        try library.store.insert(first)
        try library.store.insert(second)
        try library.connect(to: line, trackApplications: false)
        try library.togglePin(first.id)
        line.libraryScope = .pinned
        try await waitUntil { line.libraryResults.count == 1 }
        XCTAssertEqual(line.visibleItems.first?.content.historyID, first.id)
        line.copy(try XCTUnwrap(line.visibleItems.first).id)
        XCTAssertEqual(board.string(forType: .string), "Pinned text")
        let missing = ClipItem(id: makeItemID(), kind: .image, capturedAt: Date(), contentHash: "missing",
            preview: "missing", searchText: "", representations: [ItemRepresentation(uti: "public.png", byteCount: 5, blobPath: "blobs/missing.png")])
        try library.store.insert(missing)
        XCTAssertFalse(try line.copyArchived(missing.id))
        XCTAssertEqual(board.string(forType: .string), "Pinned text")
        XCTAssertNil(library.safeBlobURL("../outside.png"))
        XCTAssertNil(library.safeBlobURL(root.appendingPathComponent("outside.png").path))
    }

    func testRepeatedTextCardsHaveDistinctIDsAndDoNotLoseRows() throws {
        let (line, library, _, _) = try fixture()
        for _ in 0..<3 { try library.store.insert(text("Repeated body")) }
        try library.connect(to: line, trackApplications: false)
        XCTAssertEqual(Set(line.items.map(\.id)).count, 3)
        XCTAssertEqual(Set(line.items.compactMap { $0.content.historyID }).count, 3)
    }

    func testOpeningAndWritingArchiveLeavesLegacySnippetFileUntouched() async throws {
        let (line, library, _, root) = try fixture()
        let file = library.directory.appendingPathComponent("snippets.json")
        let legacy = Data("Legacy snippet contents are retained verbatim.".utf8)
        try legacy.write(to: file)
        let reopened = try ClipdLibrary(directory: library.directory, store: library.store,
                                        cacheDirectory: root.appendingPathComponent("Cache"))
        try reopened.connect(to: line, trackApplications: false)
        XCTAssertTrue(line.ingestClipboard(.text("New ordinary history item")))
        await reopened.waitForWrites()
        XCTAssertEqual(try Data(contentsOf: file), legacy)
        XCTAssertEqual(try reopened.store.count(), 1)
    }

    func testClearingSearchRestoresHistoryWithoutStaleResultCount() async throws {
        let (line, library, _, _) = try fixture()
        try library.store.insert(text("Find this archive text"))
        try library.connect(to: line, trackApplications: false)
        XCTAssertTrue(line.libraryStatus.isEmpty)
        line.libraryQuery = "Find this"
        try await waitUntil { line.libraryResults.count == 1 }
        XCTAssertFalse(line.libraryStatus.isEmpty)
        line.libraryQuery = ""
        XCTAssertTrue(line.libraryResults.isEmpty)
        XCTAssertTrue(line.libraryStatus.isEmpty)
    }

    func testEndingSearchSessionShowsNextCaptureInsteadOfOldFilter() async throws {
        let (line, library, _, _) = try fixture()
        try library.store.insert(text("Old searchable note", pinned: true))
        try library.connect(to: line, trackApplications: false)
        line.libraryScope = .pinned
        line.libraryQuery = "Old searchable"
        try await waitUntil { line.libraryResults.count == 1 }
        line.resetLibraryView()
        XCTAssertFalse(line.showingLibraryResults)
        XCTAssertTrue(line.libraryQuery.isEmpty)
        XCTAssertTrue(line.ingestClipboard(.text("New capture after the shelf closed")))
        await library.waitForWrites()
        XCTAssertEqual(line.visibleItems.last?.previewText, "New capture after the shelf closed")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(line.showingLibraryResults, "An old query must not reappear after capture")
    }

    func testPlaintextArchiveOpensWithoutCreatingAKey() throws {
        let (_, library, _, root) = try fixture()
        let key = root.appendingPathComponent("Archive/db.key")
        XCTAssertFalse(FileManager.default.fileExists(atPath: key.path))
        let reopened = try ClipdLibrary(directory: library.directory, cacheDirectory: root.appendingPathComponent("Cache"))
        XCTAssertEqual(try reopened.store.count(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: key.path))
    }

    func testLegacyEncryptedArchiveIsNotOverwrittenWithoutConversion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipline-encrypted-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var original = text("Existing encrypted record")
        original.capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let encrypted = try Store(directory: root, passphrase: "fixture")
        try encrypted.insert(original)
        encrypted.close()
        XCTAssertThrowsError(try ClipdLibrary(directory: root))
        let reopened = try Store(directory: root, passphrase: "fixture")
        defer { reopened.close() }
        XCTAssertEqual(try reopened.item(id: original.id), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("db.key").path))
    }

    func testSearchPaginationHasNoSkippedOrRepeatedItemsAtPartialEnd() async throws {
        let (line, library, _, _) = try fixture()
        for index in 1...14 { try library.store.insert(text("pagination number \(index)")) }
        try library.connect(to: line, trackApplications: false)
        line.libraryQuery = "pagination"
        try await waitUntil { line.libraryResults.count == 14 }
        let first = line.visibleItems.map(\.id)
        XCTAssertEqual(first.count, 6)
        XCTAssertFalse(line.hasOlderPage)
        line.showNewerPage()
        let second = line.visibleItems.map(\.id)
        XCTAssertEqual(second.count, 6)
        line.showNewerPage()
        let last = line.visibleItems.map(\.id)
        XCTAssertEqual(last.count, 2)
        XCTAssertFalse(line.hasNewerPage)
        XCTAssertEqual(Set(first + second + last).count, 14)
        line.showOlderPage()
        XCTAssertEqual(line.visibleItems.map(\.id), second)
    }

    func testArchiveTextDoesNotCreateDuplicateCardFilesOrPreferencesAndStillDragsInFull() async throws {
        let (_, library, board, root) = try fixture()
        let suite = "clipline-no-plaintext-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "soundOff")
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = root.appendingPathComponent("PrivateCache")
        let line = Line(defaults: defaults, clipboardFolder: cache, copyPasteboard: board)
        line.maxItems = Line.historyLimit
        let body = "Historical body\n" + String(repeating: "完整文字保持在資料庫。\n", count: 150)
        try library.store.insert(text(body))
        try library.connect(to: line, trackApplications: false)
        let card = try XCTUnwrap(line.visibleItems.first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: card.url.path))
        XCTAssertEqual(defaults.stringArray(forKey: "pegged"), [])
        XCTAssertEqual(defaults.dictionary(forKey: "peggedContent")?.count, 0)
        let grab = GrabView()
        grab.kind = .text
        grab.url = card.url
        grab.fullText = { line.textForCard(card.id) }
        let writer = try XCTUnwrap(grab.dragPasteboardWriter() as? NSPasteboardItem)
        XCTAssertEqual(writer.string(forType: .string), body)
        XCTAssertTrue(line.ingestClipboard(.text("New capture")))
        await library.waitForWrites()
        XCTAssertTrue(line.items.allSatisfy { !FileManager.default.fileExists(atPath: $0.url.path) })
        XCTAssertEqual(defaults.stringArray(forKey: "pegged"), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }

    func testLegacyCliplineCopyAlreadyInClipdDoesNotBecomeDuplicateCards() async throws {
        let (line, library, _, _) = try fixture()
        let body = "Already collected by both apps"
        XCTAssertTrue(line.ingestClipboard(.text(body)))
        let record = text(body)
        try library.store.insert(record)
        try library.connect(to: line, trackApplications: false)
        await library.waitForWrites()
        XCTAssertEqual(try library.store.count(), 1)
        XCTAssertEqual(line.items.filter { !$0.falling && $0.content.historyID == record.id }.count, 1)
    }

    func testBackgroundConnectionYieldsAndPreservesCaptureDuringHistoryLoad() async throws {
        let queue = DispatchQueue(label: "test.archive-preparation")
        queue.suspend()
        var resumed = false
        defer { if !resumed { queue.resume() } }
        let (line, library, board, _) = try fixture(preparationQueue: queue)
        let original = text("Existing archived body")
        try library.store.insert(original)
        let connection = Task { try await library.connectInBackground(to: line, trackApplications: false) }
        try await waitUntil { line.library === library }
        XCTAssertTrue(line.items.isEmpty, "The main actor must run while archive preparation is blocked")
        XCTAssertTrue(line.ingestClipboard(.text("Capture during startup")))
        await library.waitForWrites()
        let capturedID = try XCTUnwrap(line.items.first?.content.historyID)
        queue.resume()
        resumed = true
        try await connection.value
        await library.waitForWrites()
        XCTAssertEqual(try library.store.count(), 2, "Startup must not import the in-flight capture twice")
        XCTAssertEqual(Set(line.items.compactMap { $0.content.historyID }), Set([original.id, capturedID]))
        let card = try XCTUnwrap(line.items.first { $0.content.historyID == original.id })
        line.copy(card.id)
        XCTAssertEqual(board.string(forType: .string), "Existing archived body")
    }

    func testStopCancelsQueuedBackgroundConnectionWithoutPublishingHistory() async throws {
        let queue = DispatchQueue(label: "test.stopped-archive-preparation")
        queue.suspend()
        var resumed = false
        defer { if !resumed { queue.resume() } }
        let (line, library, _, _) = try fixture(preparationQueue: queue)
        try library.store.insert(text("Keep existing archive"))
        let connection = Task { try await library.connectInBackground(to: line, trackApplications: false) }
        try await waitUntil { line.library === library }
        library.stop()
        queue.resume()
        resumed = true
        do {
            try await connection.value
            XCTFail("Stopped startup should be cancelled")
        } catch is CancellationError {} catch { throw error }
        XCTAssertTrue(line.items.isEmpty)
        XCTAssertEqual(try library.store.count(), 1)
    }

    func testBackgroundImagePreparationPreservesMetadataAndCopy() async throws {
        let (line, library, board, _) = try fixture()
        let data = try imageData()
        let path = "blobs/fixture.png"
        let url = library.directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        let record = ClipItem(id: makeItemID(), kind: .image, capturedAt: Date(),
            contentHash: ClipboardStore.digest(data), preview: "Fixture image", searchText: "Visible OCR text",
            sourceAppName: "Fixture Source", isPinned: true,
            representations: [ItemRepresentation(uti: "public.png", byteCount: data.count, blobPath: path)])
        try library.store.insert(record)
        try await library.connectInBackground(to: line, trackApplications: false)
        let card = try XCTUnwrap(line.items.first)
        XCTAssertEqual(card.url, url)
        XCTAssertEqual(card.thumb.size, NSSize(width: 32, height: 24))
        XCTAssertEqual(card.content.ocrText, "Visible OCR text")
        XCTAssertEqual(card.content.sourceAppName, "Fixture Source")
        XCTAssertEqual(card.content.isPinned, true)
        line.copy(card.id)
        XCTAssertEqual(board.data(forType: .png), data)
        line.libraryQuery = "Visible OCR"
        try await waitUntil { line.libraryResults.count == 1 }
        XCTAssertEqual(line.libraryResults.first?.id, card.id, "Preparation must keep stable card identities")
    }

    func testSupersededQueuedSearchDoesNotReplaceCurrentResults() async throws {
        let queue = DispatchQueue(label: "test.coalesced-archive-preparation")
        let (line, library, _, _) = try fixture(preparationQueue: queue)
        try library.store.insert(text("First search body"))
        let current = text("Second current body")
        try library.store.insert(current)
        try library.connect(to: line, trackApplications: false)
        queue.suspend()
        var resumed = false
        defer { if !resumed { queue.resume() } }
        line.libraryQuery = "First"
        try await Task.sleep(for: .milliseconds(100))
        line.libraryQuery = "Second"
        try await Task.sleep(for: .milliseconds(100))
        queue.resume()
        resumed = true
        try await waitUntil { line.libraryResults.first?.content.historyID == current.id }
        XCTAssertEqual(line.libraryResults.count, 1)
        XCTAssertEqual(line.libraryStatus, "1 筆結果")
    }

    func testBackgroundConnectionKeepsLiveScreenshotIdentityWithoutDuplicateCards() async throws {
        let queue = DispatchQueue(label: "test.live-screenshot-startup")
        queue.suspend()
        var resumed = false
        defer { if !resumed { queue.resume() } }
        let (line, library, board, root) = try fixture(preparationQueue: queue)
        let older = text("Existing archive text")
        try library.store.insert(older)
        let connection = Task { try await library.connectInBackground(to: line, trackApplications: false) }
        try await waitUntil { line.library === library }

        let data = try imageData()
        let screenshotURL = root.appendingPathComponent("Live Screenshot.png")
        try data.write(to: screenshotURL)
        let captureID = try XCTUnwrap(line.hang(screenshotURL, quietly: true, flying: true))
        await library.waitForWrites()
        let before = try XCTUnwrap(line.items.first { $0.id == captureID })
        let historyID = try XCTUnwrap(before.content.historyID)
        XCTAssertEqual(before.url, screenshotURL)
        XCTAssertEqual(try library.store.count(), 2)

        queue.resume()
        resumed = true
        try await connection.value
        await library.waitForWrites()

        XCTAssertEqual(line.items.count, 2)
        XCTAssertEqual(line.items.filter { $0.content.historyID == historyID }.count, 1)
        XCTAssertEqual(Set(line.items.map(\.id)).count, line.items.count, "Every visible card needs a distinct identity")
        let restored = try XCTUnwrap(line.items.first { $0.content.historyID == historyID })
        XCTAssertEqual(restored.id, captureID, "Loading the archive must preserve the live screenshot identity")
        XCTAssertEqual(restored.url, screenshotURL)
        XCTAssertEqual(restored.flying, before.flying)
        line.copy(restored.id)
        XCTAssertEqual(board.data(forType: .png), data)
        XCTAssertEqual(try library.store.count(), 2, "Merging the live screenshot must not create another archive row")
    }


    func testThumbnailPreparationIsCappedAtTwentyAcrossHistoryPagesAndSearch() async throws {
        let (line, library, _, _) = try fixture()
        defer { library.stop() }
        let data = try imageData()
        for index in 0..<45 {
            let path = "blobs/window-\(index).png"
            let file = library.directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
            try library.store.insert(ClipItem(id: makeItemID(), kind: .image, capturedAt: Date(timeIntervalSince1970: Double(index)),
                contentHash: "window-\(index)", preview: "Window image", searchText: "window fixture",
                representations: [ItemRepresentation(uti: "public.png", byteCount: data.count, blobPath: path)]))
        }
        try await library.connectInBackground(to: line, trackApplications: false)
        XCTAssertEqual(line.items.count, 45, "Only thumbnails are bounded; historical metadata remains available")
        for _ in 0..<8 {
            await library.waitForThumbnails()
            XCTAssertLessThanOrEqual(line.items.filter(\.thumbnailPrepared).count, 20)
            XCTAssertTrue(line.visibleItems.allSatisfy(\.thumbnailPrepared))
            line.showOlderPage()
        }
        line.resetLibraryView()
        line.libraryQuery = "window"
        try await waitUntil { line.libraryResults.count == 45 }
        await library.waitForThumbnails()
        XCTAssertLessThanOrEqual((line.items + line.libraryResults).filter(\.thumbnailPrepared).map(\.id).reduce(into: Set<UUID>()) { $0.insert($1) }.count, 20)
        XCTAssertTrue(line.visibleItems.allSatisfy(\.thumbnailPrepared))
        library.refreshResults()
        try await Task.sleep(for: .milliseconds(150))
        await library.waitForThumbnails()
        XCTAssertTrue(line.visibleItems.allSatisfy(\.thumbnailPrepared), "Refreshing unchanged results must restore their thumbnails")
        line.showNewerPage()
        await library.waitForThumbnails()
        XCTAssertTrue(line.visibleItems.allSatisfy(\.thumbnailPrepared))
    }

    func testImageArchivesBeforeOCRAndCannotDelayFollowingText() async throws {
        let (line, library, _, _) = try fixture()
        defer { library.stop() }
        try library.connect(to: line, trackApplications: false)
        library.setOCRPaused(true)
        XCTAssertTrue(line.ingestClipboardInBackground(.image(try imageData())))
        await line.waitForClipboardPreparation()
        await library.waitForWrites()
        let image = try XCTUnwrap(try library.store.recent(limit: 10).first)
        XCTAssertEqual(image.kind, .image)
        XCTAssertEqual(try library.store.pendingImageOCRIDs(), [image.id])
        XCTAssertTrue(image.searchText.isEmpty)
        XCTAssertTrue(line.ingestClipboard(.text("Text following a queued image")))
        await library.waitForWrites()
        XCTAssertEqual(try library.store.count(), 2)
        XCTAssertEqual(try library.store.search("following", limit: 10).count, 1)
        XCTAssertEqual(try library.store.pendingImageOCRIDs(), [image.id], "Visible shelf pauses OCR, while text storage remains independent")
    }

    func testQueuedWatcherCopiesPreserveOrderAndEachCopiesOwnRichFormats() async throws {
        let (line, library, output, _) = try fixture()
        defer { library.stop() }
        try library.connect(to: line, trackApplications: false)
        library.setOCRPaused(true)
        let input = NSPasteboard.withUniqueName()
        defer { input.releaseGlobally() }
        let watcher = ClipboardWatcher(pasteboard: input,
            onTextFormats: { line.capturedTextFormats = $0 },
            onNew: { line.ingestClipboardInBackground($0) })
        func submit(_ text: String, html: Data? = nil, rtf: Data? = nil, image: Data? = nil) {
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            if let html { item.setData(html, forType: .html) }
            if let rtf { item.setData(rtf, forType: .rtf) }
            if let image { item.setData(image, forType: .png) }
            input.clearContents()
            input.writeObjects([item])
            watcher.poll()
        }
        XCTAssertTrue(line.ingestClipboardInBackground(.image(try imageData())))
        let firstHTML = Data("<b>First rich copy</b>".utf8)
        let firstRTF = Data(#"{\rtf1\ansi First rich copy}"#.utf8)
        let secondHTML = Data("<i>Second rich copy</i>".utf8)
        let secondRTF = Data(#"{\rtf1\ansi Second rich copy}"#.utf8)
        submit("First rich copy", html: firstHTML, rtf: firstRTF)
        // Malformed image representations must keep the rich text fallback.
        submit("Second rich copy", html: secondHTML, rtf: secondRTF, image: Data("not a PNG".utf8))
        submit("https://example.com/queued-link", html: Data("<a>Link</a>".utf8))
        submit("Final plain copy")
        XCTAssertTrue(line.items.isEmpty, "Later text must wait for the first image")
        XCTAssertTrue(line.capturedTextFormats.isEmpty, "Watcher callback state is ephemeral")
        await line.waitForClipboardPreparation()
        await library.waitForWrites()
        XCTAssertEqual(line.items.map(\.kind), [.image, .text, .text, .link, .text])
        XCTAssertEqual(try library.store.count(), 5)
        for (index, text, html, rtf) in [(1, "First rich copy", firstHTML, firstRTF),
                                       (2, "Second rich copy", secondHTML, secondRTF)] {
            line.copy(line.items[index].id)
            XCTAssertEqual(output.string(forType: .string), text)
            XCTAssertEqual(output.data(forType: .html), html)
            XCTAssertEqual(output.data(forType: .rtf), rtf)
            XCTAssertTrue((output.types ?? []).contains(ClipboardWatcher.ownCopyType))
        }
        line.copy(line.items[3].id)
        XCTAssertEqual(output.string(forType: .URL), "https://example.com/queued-link")
        XCTAssertEqual(output.data(forType: .html), Data("<a>Link</a>".utf8))
        line.copy(line.items[4].id)
        XCTAssertEqual(output.string(forType: .string), "Final plain copy")
        XCTAssertFalse((output.types ?? []).contains(.html))
        XCTAssertFalse((output.types ?? []).contains(.rtf))
    }

    func testCancellationDropsQueuedRichArchiveAndFreshCopyDoesNotInheritFormats() async throws {
        let (line, library, output, _) = try fixture()
        defer { library.stop() }
        try library.connect(to: line, trackApplications: false)
        library.setOCRPaused(true)
        XCTAssertTrue(line.ingestClipboardInBackground(.image(try imageData())))
        line.capturedTextFormats = [CapturedTextFormat(uti: "public.html", data: Data("<b>Cancelled</b>".utf8))]
        XCTAssertTrue(line.ingestClipboardInBackground(.text("Cancelled rich copy")))
        line.capturedTextFormats = []
        line.cancelClipboardPreparation()
        XCTAssertTrue(line.ingestClipboardInBackground(.text("Fresh plain copy")))
        await line.waitForClipboardPreparation()
        await library.waitForWrites()
        XCTAssertEqual(try library.store.count(), 1)
        XCTAssertEqual(line.items.map(\.kind), [.text])
        let card = try XCTUnwrap(line.items.first)
        line.copy(card.id)
        XCTAssertEqual(output.string(forType: .string), "Fresh plain copy")
        XCTAssertFalse((output.types ?? []).contains(.html))
        XCTAssertTrue(try library.store.search("Cancelled", limit: 10).isEmpty)
    }

    func testQueuedTextArchivesCaptureTimeAndSourceInsteadOfPublicationContext() async throws {
        let (line, library, _, _) = try fixture()
        defer { library.stop() }
        try library.connect(to: line, trackApplications: false)
        library.setOCRPaused(true)
        XCTAssertTrue(line.ingestClipboardInBackground(.image(try imageData())))
        let capturedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let context = ClipboardCaptureContext(capturedAt: capturedAt,
            sourceBundleID: "test.copied-from", sourceAppName: "Copied From App")
        XCTAssertTrue(line.ingestClipboardInBackground(.text("Context belongs to the copy"), captureContext: context))
        await line.waitForClipboardPreparation()
        await library.waitForWrites()
        let record = try XCTUnwrap(try library.store.search("Context", limit: 10).first)
        XCTAssertEqual(record.capturedAt.timeIntervalSince1970, capturedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(record.sourceBundleID, context.sourceBundleID)
        XCTAssertEqual(record.sourceAppName, context.sourceAppName)
        XCTAssertEqual(line.items.last?.content.sourceAppName, context.sourceAppName)
    }

    private func imageData() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 24,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        if let bytes = bitmap.bitmapData { memset(bytes, 128, bitmap.bytesPerRow * bitmap.pixelsHigh) }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for archive results")
    }
}
