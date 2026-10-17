import AppKit
import XCTest
@testable import Tendedero

final class ClipboardPreparationTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("clipline-preparation-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func defaults() -> UserDefaults {
        let name = "clipline-preparation-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(true, forKey: "soundOff")
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func pasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard.withUniqueName()
        addTeardownBlock { pasteboard.releaseGlobally() }
        return pasteboard
    }

    private func png(red: CGFloat = 0) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<2 {
            for x in 0..<2 {
                bitmap.setColor(NSColor(calibratedRed: red, green: 0, blue: 0, alpha: 1), atX: x, y: y)
            }
        }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func tiff() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try png(red: 1)))
        return try XCTUnwrap(bitmap.representation(using: .tiff, properties: [:]))
    }

    @MainActor
    private func prepare(_ payload: ClipboardPayload, using worker: ClipboardPreparation,
                         candidates: [URL] = []) async -> ClipboardPreparation.Result? {
        await withCheckedContinuation { continuation in
            worker.prepare(payload, candidates: candidates) { result in
                XCTAssertTrue(Thread.isMainThread, "Prepared results must publish on the main actor")
                continuation.resume(returning: result)
            }
        }
    }

    @MainActor
    func testIncomingImageNormalizesOnceOffMainAndUnchangedCandidateReusesDigest() async throws {
        let probe = ClipboardNormalizationProbe()
        let worker = ClipboardPreparation(store: ClipboardStore(folder: try folder()),
                                          normalize: { probe.normalize($0) })
        let data = try png()
        let first = await prepare(.image(data), using: worker)
        guard case .image(let file) = first else { return XCTFail("Expected prepared image") }
        XCTAssertNotNil(file.thumbnail)
        XCTAssertNotNil(file.digest)
        XCTAssertEqual(worker.cachedDigest(file.url), file.digest)
        XCTAssertEqual(probe.snapshot.calls, 1)
        XCTAssertFalse(probe.snapshot.usedMainThread)

        let second = await prepare(.image(data), using: worker, candidates: [file.url])
        guard case .duplicate(let digest) = second else { return XCTFail("Expected unchanged image to deduplicate") }
        XCTAssertEqual(digest, file.digest)
        XCTAssertEqual(probe.snapshot.calls, 2,
                       "Only the new incoming image needs normalization; the candidate must reuse its digest")
        XCTAssertFalse(probe.snapshot.usedMainThread)
        await worker.waitUntilIdle()
    }

    @MainActor
    func testReplacingCandidateInvalidatesDigestAndPreservesEditedImage() async throws {
        let probe = ClipboardNormalizationProbe()
        let worker = ClipboardPreparation(store: ClipboardStore(folder: try folder()),
                                          normalize: { probe.normalize($0) })
        let original = try png()
        let first = await prepare(.image(original), using: worker)
        guard case .image(let file) = first else { return XCTFail("Expected prepared image") }

        let edited = try png(red: 1)
        try edited.write(to: file.url, options: .atomic)
        XCTAssertNil(worker.cachedDigest(file.url), "Replacing a candidate must invalidate its cached digest")

        let result = await prepare(.image(original), using: worker, candidates: [file.url])
        guard case .image(let replacement) = result else {
            return XCTFail("An edited candidate must not suppress a fresh copy of the original image")
        }
        XCTAssertNotEqual(replacement.url, file.url)
        XCTAssertEqual(replacement.digest, file.digest)
        XCTAssertEqual(try Data(contentsOf: file.url), edited, "Preparation must preserve the edited card's backing file")
        XCTAssertEqual(probe.snapshot.calls, 3,
                       "The incoming original and changed candidate each normalize once after the initial preparation")
        XCTAssertFalse(probe.snapshot.usedMainThread)
        await worker.waitUntilIdle()
    }

    @MainActor
    func testMalformedFirstRepresentationFallsThroughToValidImage() async throws {
        let probe = ClipboardNormalizationProbe()
        let worker = ClipboardPreparation(store: ClipboardStore(folder: try folder()),
                                          normalize: { probe.normalize($0) })
        let result = await prepare(.imageRepresentations([
            Data("invalid first image".utf8), try png()
        ], fallbackText: "unused fallback"), using: worker)
        guard case .image(let file) = result else { return XCTFail("Expected the second image representation to be used") }
        XCTAssertNotNil(file.thumbnail)
        XCTAssertEqual(probe.snapshot.calls, 2, "Try each representation once and stop at the first valid image")
        XCTAssertFalse(probe.snapshot.usedMainThread)
        await worker.waitUntilIdle()
    }

    @MainActor
    func testMalformedRepresentationsFallBackToTextOrRejectWithoutFallback() async throws {
        let worker = ClipboardPreparation(store: ClipboardStore(folder: try folder()))
        let malformed = [Data("invalid png".utf8), Data("invalid tiff".utf8)]
        let fallback = await prepare(.imageRepresentations(malformed, fallbackText: "Copied fallback"), using: worker)
        guard case .passthrough(.text(let text)) = fallback else { return XCTFail("Expected the copied text fallback") }
        XCTAssertEqual(text, "Copied fallback")

        let rejected = await prepare(.imageRepresentations(malformed, fallbackText: nil), using: worker)
        XCTAssertNil(rejected)
        await worker.waitUntilIdle()
    }

    @MainActor
    func testBackgroundLinePublishesAfterCompletionAndRejectsInvalidImage() async throws {
        let line = Line(defaults: defaults(), clipboardFolder: try folder(), copyPasteboard: pasteboard())
        var captures = 0
        line.onCapture = { captures += 1 }

        XCTAssertTrue(line.ingestClipboardInBackground(.image(try png())))
        XCTAssertTrue(line.items.isEmpty, "Submitting an image must yield before publishing a card")
        XCTAssertEqual(captures, 0)
        await line.waitForClipboardPreparation()
        XCTAssertEqual(line.items.map(\.kind), [.image])
        XCTAssertEqual(captures, 1)

        XCTAssertTrue(line.ingestClipboardInBackground(.image(Data("invalid image".utf8))))
        await line.waitForClipboardPreparation()
        XCTAssertEqual(line.items.map(\.kind), [.image])
        XCTAssertEqual(captures, 1, "Invalid image data must not publish a capture")
    }

    @MainActor
    func testBackgroundLinePreservesImageThenTextCaptureOrder() async throws {
        let line = Line(defaults: defaults(), clipboardFolder: try folder(), copyPasteboard: pasteboard())
        XCTAssertTrue(line.ingestClipboardInBackground(.image(try png())))
        XCTAssertTrue(line.ingestClipboardInBackground(.text("Copied after image")))
        XCTAssertTrue(line.items.isEmpty, "The later text must wait for the earlier image preparation")

        await line.waitForClipboardPreparation()
        XCTAssertEqual(line.items.map(\.kind), [.image, .text])
        XCTAssertEqual(line.items.last?.previewText, "Copied after image")
    }

    @MainActor
    func testCancellationBeforePublicationDiscardsPendingCardAndAllowsNextCapture() async throws {
        let line = Line(defaults: defaults(), clipboardFolder: try folder(), copyPasteboard: pasteboard())
        var captures = 0
        line.onCapture = { captures += 1 }
        XCTAssertTrue(line.ingestClipboardInBackground(.image(try png())))
        // Do not yield the main actor before cancellation: even if preparation
        // has finished on its queue, the result cannot have published yet.
        line.cancelClipboardPreparation()
        await line.waitForClipboardPreparation()
        XCTAssertTrue(line.items.isEmpty)
        XCTAssertEqual(captures, 0)

        XCTAssertTrue(line.ingestClipboardInBackground(.text("After cancellation")))
        await line.waitForClipboardPreparation()
        XCTAssertEqual(line.items.map(\.kind), [.text])
        XCTAssertEqual(line.items.first?.previewText, "After cancellation")
        XCTAssertEqual(captures, 1)
    }

    @MainActor
    func testFinderFileIsProtectedBeforeQueuedPreparationCanStart() async throws {
        let root = try folder()
        let store = ClipboardStore(folder: root)
        let normalized = try XCTUnwrap(ClipboardStore.normalizedPNG(try png()))
        let (seedURL, _) = try store.write(normalized, kind: .image, extension: "png")
        let gate = ClipboardNormalizationGate()
        defer { gate.release() }
        let worker = ClipboardPreparation(store: store, normalize: { gate.normalize($0) })
        let line = Line(defaults: defaults(), clipboardFolder: root, copyPasteboard: pasteboard(),
                        clipboardPreparation: worker)
        let seedID = try XCTUnwrap(line.hang(seedURL, quietly: true))

        // Occupy the worker without producing a managed file or a shelf card.
        worker.prepare(.image(Data("occupy worker".utf8)), candidates: []) { _ in }
        await fulfillment(of: [gate.started], timeout: 5)
        line.drop(seedID, quietly: true)
        XCTAssertTrue(line.ingestClipboardInBackground(.files([seedURL])))
        let matchingCards = line.items.filter { $0.url == seedURL }
        XCTAssertFalse(matchingCards.isEmpty)
        XCTAssertTrue(matchingCards.allSatisfy { $0.content.originalFileReference == true },
                      "Existing cards must become original references before yielding to background preparation")

        // Exercise the existing 0.6-second drop cleanup while preparation is
        // deliberately blocked. This is a lifecycle wait, not a speed limit.
        try await Task.sleep(nanoseconds: 750_000_000)
        XCTAssertFalse(line.items.contains(where: { $0.id == seedID }), "The dropped card must finish cleanup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: seedURL.path),
                      "A Finder reference must protect the backing file as soon as it is submitted")

        gate.release()
        await line.waitForClipboardPreparation()
        XCTAssertTrue(line.items.contains(where: { !$0.falling && $0.url == seedURL && $0.content.originalFileReference == true }))
        await worker.waitUntilIdle()
    }

    @MainActor
    func testStaleDuplicateRetriesBeforeLaterTextCapture() async throws {
        let root = try folder()
        let store = ClipboardStore(folder: root)
        let incoming = try png()
        let normalized = try XCTUnwrap(ClipboardStore.normalizedPNG(incoming))
        let (seedURL, _) = try store.write(normalized, kind: .image, extension: "png")
        let gate = ClipboardNormalizationGate()
        defer { gate.release() }
        let worker = ClipboardPreparation(store: store, normalize: { gate.normalize($0) })
        let line = Line(defaults: defaults(), clipboardFolder: root, copyPasteboard: pasteboard(),
                        clipboardPreparation: worker)
        let seedID = try XCTUnwrap(line.hang(seedURL, quietly: true))
        var captureKinds: [ShelfContentKind] = []
        line.onCapture = {
            if let kind = line.items.last?.kind { captureKinds.append(kind) }
        }
        defer { line.onCapture = nil }

        XCTAssertTrue(line.ingestClipboardInBackground(.image(incoming)))
        XCTAssertTrue(line.ingestClipboardInBackground(.text("Copied after duplicate")))
        await fulfillment(of: [gate.started], timeout: 5)
        // The queued worker still knows this seed as a candidate. Removing it
        // from the active shelf makes its forthcoming duplicate result stale.
        line.drop(seedID, quietly: true)
        gate.release() // Release in the same actor turn, before drop cleanup.

        await line.waitForClipboardPreparation()
        XCTAssertEqual(captureKinds, [.image, .text],
                       "Retry the earlier image at the head of the queue before publishing later text")
        let active = line.items.filter { !$0.falling }
        XCTAssertEqual(active.map(\.kind), [.image, .text])
        XCTAssertEqual(active.last?.previewText, "Copied after duplicate")
        await worker.waitUntilIdle()
    }

    @MainActor
    func testFileChangedDuringPreparationDoesNotPublishStaleThumbnail() async throws {
        let root = try folder()
        let candidate = root.appendingPathComponent("mutable-image.png")
        try png().write(to: candidate, options: .atomic)
        let replacement = try png(red: 1)
        let worker = ClipboardPreparation(store: ClipboardStore(folder: root), normalize: { data in
            // .files creates its thumbnail before hashing. Replace the file
            // during hashing so those two results cannot belong to one version.
            try? replacement.write(to: candidate, options: .atomic)
            return ClipboardStore.normalizedPNG(data)
        })

        let result = await prepare(.files([candidate]), using: worker)
        XCTAssertEqual(try Data(contentsOf: candidate), replacement, "The mutation hook must have run")
        switch result {
        case nil: break
        case .files(let files)?:
            XCTAssertTrue(files.isEmpty, "A file replaced during preparation must be excluded from publication")
        default:
            XCTFail("A changed file must not produce a prepared image or unrelated payload")
        }
        XCTAssertNil(worker.cachedDigest(candidate), "A changed file must not acquire a digest from its previous version")
        await worker.waitUntilIdle()
    }

    @MainActor
    func testBackgroundFinderReferencesRetainDirectoriesAndFilesAboveImageLimit() async throws {
        let root = try folder()
        let directory = root.appendingPathComponent("Finder Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let largeFile = root.appendingPathComponent("large-reference.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: largeFile.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: largeFile)
        defer { try? handle.close() }
        // A sparse file exercises metadata acceptance without allocating or
        // reading an image-sized buffer in the test.
        try handle.truncate(atOffset: UInt64(ClipboardStore.imageDataLimit) + 1)
        let line = Line(defaults: defaults(), clipboardFolder: root, copyPasteboard: pasteboard())

        XCTAssertTrue(line.ingestClipboardInBackground(.files([directory, largeFile])))
        await line.waitForClipboardPreparation()

        XCTAssertEqual(line.items.map(\.url), [directory, largeFile])
        XCTAssertEqual(line.items.map(\.kind), [.file, .file])
        XCTAssertTrue(line.items.allSatisfy { $0.content.originalFileReference == true })
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(try largeFile.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                       ClipboardStore.imageDataLimit + 1)
    }

    @MainActor
    func testCaptureCallbackCancellationDiscardsPendingText() async throws {
        let line = Line(defaults: defaults(), clipboardFolder: try folder(), copyPasteboard: pasteboard())
        var captures = 0
        var handledFirstCapture = false
        line.onCapture = {
            captures += 1
            guard !handledFirstCapture else { return }
            handledFirstCapture = true
            line.cancelClipboardPreparation()
        }
        defer { line.onCapture = nil }

        XCTAssertTrue(line.ingestClipboardInBackground(.text("First capture")))
        XCTAssertTrue(line.ingestClipboardInBackground(.text("Cancelled pending capture")))
        await line.waitForClipboardPreparation()

        XCTAssertEqual(line.items.compactMap(\.previewText), ["First capture"])
        XCTAssertEqual(captures, 1)
    }

    @MainActor
    func testCaptureCallbackCancellationAndEnqueuePreservesNewQueueHead() async throws {
        let line = Line(defaults: defaults(), clipboardFolder: try folder(), copyPasteboard: pasteboard())
        var published: [String] = []
        var handledFirstCapture = false
        line.onCapture = {
            if let text = line.items.last?.previewText { published.append(text) }
            guard !handledFirstCapture else { return }
            handledFirstCapture = true
            line.cancelClipboardPreparation()
            XCTAssertTrue(line.ingestClipboardInBackground(.text("New capture after cancellation")))
        }
        defer { line.onCapture = nil }

        XCTAssertTrue(line.ingestClipboardInBackground(.text("First capture")))
        XCTAssertTrue(line.ingestClipboardInBackground(.text("Cancelled old queue head")))
        await line.waitForClipboardPreparation()

        let expected = ["First capture", "New capture after cancellation"]
        XCTAssertEqual(published, expected, "Completing the old request must not remove the newly enqueued head")
        XCTAssertEqual(line.items.compactMap(\.previewText), expected)
    }

    @MainActor
    func testCaptureCallbackEnqueuePublishesEachCaptureOnceInOrder() async throws {
        let line = Line(defaults: defaults(), clipboardFolder: try folder(), copyPasteboard: pasteboard())
        var published: [String] = []
        var handledFirstCapture = false
        line.onCapture = {
            if let text = line.items.last?.previewText { published.append(text) }
            guard !handledFirstCapture else { return }
            handledFirstCapture = true
            XCTAssertTrue(line.ingestClipboardInBackground(.text("Enqueued inside callback")))
        }
        defer { line.onCapture = nil }

        XCTAssertTrue(line.ingestClipboardInBackground(.text("First capture")))
        XCTAssertTrue(line.ingestClipboardInBackground(.text("Already queued second capture")))
        await line.waitForClipboardPreparation()

        let expected = ["First capture", "Already queued second capture", "Enqueued inside callback"]
        XCTAssertEqual(published, expected, "A reentrant enqueue must not prepare the current request again")
        XCTAssertEqual(line.items.compactMap(\.previewText), expected)
    }

    @MainActor
    func testFileBatchStopsPublishingWhenFirstCaptureCallbackCancels() async throws {
        let root = try folder()
        let files = try (1...3).map { index in
            let url = root.appendingPathComponent("reference-\(index).bin")
            try Data("nonimage reference \(index)".utf8).write(to: url, options: .atomic)
            return url
        }
        let line = Line(defaults: defaults(), clipboardFolder: root, copyPasteboard: pasteboard())
        var captures = 0
        var handledFirstCapture = false
        line.onCapture = {
            captures += 1
            guard !handledFirstCapture else { return }
            handledFirstCapture = true
            line.cancelClipboardPreparation()
        }
        defer { line.onCapture = nil }

        XCTAssertTrue(line.ingestClipboardInBackground(.files(files)))
        await line.waitForClipboardPreparation()

        XCTAssertEqual(line.items.map(\.url), [files[0]],
                       "Cancellation inside the first file callback must stop the rest of the same batch")
        XCTAssertEqual(line.items.map(\.kind), [.file])
        XCTAssertEqual(line.items.first?.content.originalFileReference, true)
        XCTAssertEqual(captures, 1)
        XCTAssertTrue(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @MainActor
    func testWatcherPNGOnlySnapshotContainsOnlyOriginalPNGBytes() throws {
        let board = pasteboard()
        var payloads: [ClipboardPayload] = []
        let watcher = ClipboardWatcher(pasteboard: board) { payload in
            payloads.append(payload)
            return true
        }
        let original = try png()
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setData(original, forType: .png))
        board.clearContents()
        XCTAssertTrue(board.writeObjects([item]))

        watcher.poll()

        XCTAssertEqual(payloads.count, 1)
        guard case .imageRepresentations(let representations, let fallback) = payloads.first else {
            return XCTFail("Expected encoded PNG payload")
        }
        XCTAssertEqual(representations, [original], "The watcher must not ask AppKit to synthesize undeclared TIFF data")
        XCTAssertNil(fallback)
    }

    @MainActor
    func testWatcherTIFFOnlySnapshotContainsOnlyOriginalTIFFBytes() throws {
        let board = pasteboard()
        var payloads: [ClipboardPayload] = []
        let watcher = ClipboardWatcher(pasteboard: board) { payload in
            payloads.append(payload)
            return true
        }
        let original = try tiff()
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setData(original, forType: .tiff))
        board.clearContents()
        XCTAssertTrue(board.writeObjects([item]))

        watcher.poll()

        XCTAssertEqual(payloads.count, 1)
        guard case .imageRepresentations(let representations, let fallback) = payloads.first else {
            return XCTFail("Expected encoded TIFF payload")
        }
        XCTAssertEqual(representations, [original], "The watcher must not ask AppKit to synthesize undeclared PNG data")
        XCTAssertNil(fallback)
    }

    @MainActor
    func testWatcherPreservesMalformedPNGAndValidTIFFForBackgroundImageFallback() async throws {
        let board = pasteboard()
        let line = Line(defaults: defaults(), clipboardFolder: try folder(), copyPasteboard: pasteboard())
        var payloads: [ClipboardPayload] = []
        let watcher = ClipboardWatcher(pasteboard: board) { payload in
            payloads.append(payload)
            return line.ingestClipboardInBackground(payload)
        }
        let malformedPNG = Data("malformed declared PNG".utf8)
        let validTIFF = try tiff()
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setData(malformedPNG, forType: .png))
        XCTAssertTrue(item.setData(validTIFF, forType: .tiff))
        XCTAssertTrue(item.setString("Text fallback must wait for image decoding", forType: .string))
        board.clearContents()
        XCTAssertTrue(board.writeObjects([item]))

        watcher.poll()

        XCTAssertEqual(payloads.count, 1)
        guard case .imageRepresentations(let representations, let fallback) = payloads.first else {
            return XCTFail("Expected both explicitly declared image representations")
        }
        XCTAssertEqual(representations, [malformedPNG, validTIFF])
        XCTAssertEqual(fallback, "Text fallback must wait for image decoding")
        XCTAssertTrue(line.items.isEmpty, "The watcher must hand encoded data to background preparation")

        await line.waitForClipboardPreparation()
        XCTAssertEqual(line.items.map(\.kind), [.image], "A valid TIFF must take precedence over text after PNG decoding fails")
        XCTAssertNil(line.items.first?.previewText)
    }
}

private final class ClipboardNormalizationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var usedMainThread = false

    func normalize(_ data: Data) -> Data? {
        lock.lock()
        calls += 1
        usedMainThread = usedMainThread || Thread.isMainThread
        lock.unlock()
        return ClipboardStore.normalizedPNG(data)
    }

    var snapshot: (calls: Int, usedMainThread: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (calls, usedMainThread)
    }
}

private final class ClipboardNormalizationGate: @unchecked Sendable {
    let started = XCTestExpectation(description: "First normalization reached worker gate")
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var first = true
    private var released = false

    func normalize(_ data: Data) -> Data? {
        lock.lock()
        let shouldBlock = first
        first = false
        lock.unlock()
        if shouldBlock {
            started.fulfill()
            semaphore.wait()
        }
        return ClipboardStore.normalizedPNG(data)
    }

    func release() {
        lock.lock()
        let shouldSignal = !released
        released = true
        lock.unlock()
        if shouldSignal { semaphore.signal() }
    }
}
