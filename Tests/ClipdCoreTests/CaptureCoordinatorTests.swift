// 抓取协调器的测试。
//
// 这里的图片是真的用 CoreGraphics 画出来、再编码成 PNG 的,不是随手凑几个位元组:
// 协调器会去读它的像素尺寸、算它的内容杂凑、把它写进内容定址的路径,
// 用假资料测这几件事等於什麽都没测到。
//
// 文字辨识那一步则刻意换成写死的假结果。理由是这几个测试要验的是「辨识回来之後怎麽处理」——
// 有没有进搜寻索引、预览句子长什麽样、信心偏低有没有被挡在搜寻文字之外 ——
// 而不是 Vision 的辨识率;真的去跑辨识会让测试变慢,而且答案会随着系统版本浮动。

import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ClipdCore

// MARK: - 测试用的小工具

private enum 测试素材错误: Error {
    case 画不出图
    case 编不出PNG
}

/// 画一张真的写着中文的图,再编成 PNG。
/// 文字用 CoreText 直接画在点阵上,不经过 AppKit,测试因此不必开视窗环境也跑得起来。
private func makeChineseScreenshotPNG(text: String, width: Int = 480, height: Int = 160) throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw 测试素材错误.画不出图
    }

    // 白底黑字:真实截图几乎都是深色字画在浅色底上,素材愈接近真实愈有意义。
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let font = CTFontCreateWithName("PingFang SC" as CFString, 40, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    context.textPosition = CGPoint(x: 20, y: 60)
    CTLineDraw(line, context)

    guard let image = context.makeImage() else { throw 测试素材错误.画不出图 }
    let buffer = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil) else {
        throw 测试素材错误.编不出PNG
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw 测试素材错误.编不出PNG }
    return buffer as Data
}

/// 每个测试都拿一个全新的暂存资料夹,资料库与图档都放在里面,测完整个删掉。
/// 共用资料夹会让上一个测试留下的资料变成下一个测试的隐形前提,那种失败最难查。
private func withCaptureEnvironment(
    _ body: (Store, ActivationRing, URL) async throws -> Void
) async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("clipd-capture-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = try Store(directory: directory, passphrase: "測試用的通行碼")
    defer { store.close() }   // defer 後进先出,所以会先关档再删资料夹,顺序正确。

    // ownBundleID 给一个固定值,避免测试执行档的 bundle 识别码在 swift test 底下不稳定。
    let ring = ActivationRing(capacity: 16, ownBundleID: "dev.clipd.tests")
    try await body(store, ring, directory)
}

/// 收集委派讯息。协调器保证在主执行绪呼叫,但读的人是测试执行绪,所以还是上锁。
private final class DelegateRecorder: CaptureCoordinatorDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var storedItems: [ClipItem] = []
    private var storedSentences: [String] = []

    var items: [ClipItem] { lock.withLock { storedItems } }
    var sentences: [String] { lock.withLock { storedSentences } }

    func coordinator(_ c: CaptureCoordinator, didStore item: ClipItem) {
        lock.withLock { storedItems.append(item) }
    }

    func coordinator(_ c: CaptureCoordinator, didEncounter sentence: String) {
        lock.withLock { storedSentences.append(sentence) }
    }
}

/// 组一台把辨识结果写死的协调器。`bridge` 给 nil 就是「没有接知识库」这个正式设定。
private func makeCoordinator(
    store: Store,
    ring: ActivationRing,
    directory: URL,
    recognized: String,
    isLowConfidence: Bool = false
) -> CaptureCoordinator {
    CaptureCoordinator(
        store: store, ring: ring, bridge: nil, blobDirectory: directory,
        recognizeText: { _ in CaptureCoordinator.OCRText(text: recognized, isLowConfidence: isLowConfidence) }
    )
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// MARK: - 截图进历史

@Test("截图存进历史之後,可以用画面上的文字把它搜出来")
func 截图存进历史之後可以用画面上的文字搜到() async throws {
    try await withCaptureEnvironment { store, ring, directory in
        let png = try makeChineseScreenshotPNG(text: "病人血壓正常")
        let url = directory.appendingPathComponent("截圖.png")
        try png.write(to: url)

        let recorder = DelegateRecorder()
        let coordinator = makeCoordinator(store: store, ring: ring, directory: directory,
                                          recognized: "病人血壓正常,收縮壓 128 毫米汞柱")
        coordinator.delegate = recorder

        await coordinator.ingestScreenshot(at: url, takenAt: Date())

        #expect(try store.count() == 1)
        let stored = try #require(try store.recent(limit: 10).first)
        #expect(stored.kind == .image)
        // 搜寻文字必须是辨识出来的原文,截图才有办法被当成「有内容的东西」找回来。
        #expect(stored.searchText.contains("收縮壓"))
        #expect(!stored.searchText.isEmpty)
        // 预览要是一句完整的话,同时讲出尺寸与读到的开头文字。
        #expect(stored.preview.contains("480 × 160"))
        #expect(stored.preview.contains("病人血壓正常"))

        let hits = try store.search("血壓", limit: 10)
        #expect(hits.count == 1)
        #expect(hits.first?.id == stored.id)

        // 存好了一定要通知介面层,而且只通知一次。
        #expect(recorder.items.count == 1)
        #expect(recorder.items.first?.id == stored.id)
    }
}

@Test("同一张截图在时间窗内送进来两次,历史里只会留下一笔")
func 同一张截图送两次只会留下一笔() async throws {
    try await withCaptureEnvironment { store, ring, directory in
        let png = try makeChineseScreenshotPNG(text: "重複的畫面")
        let url = directory.appendingPathComponent("重複.png")
        try png.write(to: url)

        let recorder = DelegateRecorder()
        let coordinator = makeCoordinator(store: store, ring: ring, directory: directory, recognized: "重複的畫面")
        coordinator.delegate = recorder

        let takenAt = Date()
        await coordinator.ingestScreenshot(at: url, takenAt: takenAt)
        // 第二次模拟的是同一张图又从剪贴板那条路进来:位元组一样、时间也只差一点点。
        await coordinator.ingestScreenshot(at: url, takenAt: takenAt.addingTimeInterval(1))

        #expect(try store.count() == 1)
        #expect(recorder.items.count == 1)
        // 略过这件事必须讲出来,不能默默吞掉,否则使用者会以为第二次截图失败了。
        #expect(recorder.sentences.contains { $0.contains("略过") })
    }
}

@Test("图档会落在以内容杂凑切两层的路径上,而且纪录里存的是相对路径")
func 图档会落在内容定址的路径上() async throws {
    try await withCaptureEnvironment { store, ring, directory in
        let png = try makeChineseScreenshotPNG(text: "存檔位置")
        let url = directory.appendingPathComponent("來源.png")
        try png.write(to: url)

        let coordinator = makeCoordinator(store: store, ring: ring, directory: directory, recognized: "存檔位置")
        await coordinator.ingestScreenshot(at: url, takenAt: Date())

        // 期望路径在测试里自己算一遍,不引用实作的组字函式,否则实作改错时测试会跟着一起错。
        let hash = sha256Hex(png)
        let expected = "blobs/\(hash.prefix(2))/\(hash).png"

        let stored = try #require(try store.recent(limit: 1).first)
        let representation = try #require(stored.representations.first)
        #expect(representation.blobPath == expected)
        #expect(representation.uti == UTType.png.identifier)
        // 图片位元组绝对不能内嵌进纪录,那会让每一次列表查询都拖着好几 MB 跑。
        #expect(representation.inlineText == nil)
        #expect(representation.byteCount == png.count)

        let onDisk = directory.appendingPathComponent(expected)
        #expect(FileManager.default.fileExists(atPath: onDisk.path))
        #expect(try Data(contentsOf: onDisk) == png)
    }
}

@Test("没有接知识库的时候,截图照样存得进本机资料库")
func 没有接知识库时照样存得进去() async throws {
    try await withCaptureEnvironment { store, ring, directory in
        let png = try makeChineseScreenshotPNG(text: "沒有知識庫")
        let url = directory.appendingPathComponent("單機.png")
        try png.write(to: url)

        let recorder = DelegateRecorder()
        // bridge 传 nil:本机抓取是主线工作,知识库是下游,下游没接上不该影响主线。
        let coordinator = CaptureCoordinator(
            store: store, ring: ring, bridge: nil, blobDirectory: directory,
            recognizeText: { _ in CaptureCoordinator.OCRText(text: "沒有知識庫", isLowConfidence: false) }
        )
        coordinator.delegate = recorder

        await coordinator.ingestScreenshot(at: url, takenAt: Date())

        #expect(try store.count() == 1)
        #expect(recorder.items.count == 1)
    }
}

// MARK: - 来源与辨识品质

@Test("来源取的是按下截图那一刻的前景程式,不是档案落地那一刻的")
func 来源取的是按下截图那一刻的前景程式() async throws {
    try await withCaptureEnvironment { store, ring, directory in
        let png = try makeChineseScreenshotPNG(text: "來源判斷")
        let url = directory.appendingPathComponent("來源判斷.png")
        try png.write(to: url)

        let takenAt = Date().addingTimeInterval(-8)
        // 截图当下在预览程式;等档案落地时使用者已经切到终端机了。
        ring.record(ActivationRecord(bundleID: "com.apple.Preview", appName: "预览",
                                     at: takenAt.addingTimeInterval(-5)))
        ring.record(ActivationRecord(bundleID: "com.apple.Terminal", appName: "终端机",
                                     at: Date().addingTimeInterval(-1)))

        let coordinator = makeCoordinator(store: store, ring: ring, directory: directory, recognized: "來源判斷")
        await coordinator.ingestScreenshot(at: url, takenAt: takenAt)

        let stored = try #require(try store.recent(limit: 1).first)
        #expect(stored.sourceBundleID == "com.apple.Preview")
        #expect(stored.sourceAppName == "预览")
        #expect(stored.provenance == .medium)
    }
}

@Test("辨识信心偏低要讲出来,但绝对不能混进搜寻文字里")
func 辨识信心偏低不会污染搜寻文字() async throws {
    try await withCaptureEnvironment { store, ring, directory in
        let png = try makeChineseScreenshotPNG(text: "模糊的畫面")
        let url = directory.appendingPathComponent("模糊.png")
        try png.write(to: url)

        let recorder = DelegateRecorder()
        let coordinator = makeCoordinator(store: store, ring: ring, directory: directory,
                                          recognized: "模糊的畫面", isLowConfidence: true)
        coordinator.delegate = recorder

        await coordinator.ingestScreenshot(at: url, takenAt: Date())

        let stored = try #require(try store.recent(limit: 1).first)
        // 搜寻文字里只能有画面上真的存在的字。多一行「信心偏低」会让这几个字自己被索引进去,
        // 使用者之後搜「信心」就会莫名其妙搜到一堆截图。
        #expect(stored.searchText == "模糊的畫面")
        #expect(!stored.searchText.contains("信心"))
        // 品质讯息走另外两个频道:一个给後续的安全层读,一个直接说给使用者听。
        let summary = try #require(coordinator.lastOCRSummary)
        #expect(summary.contains("信心偏低"))
        #expect(recorder.sentences.contains { $0.contains("信心偏低") })
    }
}

// MARK: - 剪贴板那条路

@Test("剪贴板抓到的内容会连附带档案一起落地,重复的那一次则会被挡掉")
func 剪贴板内容会连附带档案一起落地() async throws {
    try await withCaptureEnvironment { store, ring, directory in
        let png = try makeChineseScreenshotPNG(text: "剪貼板圖片")
        let hash = sha256Hex(png)
        let path = "blobs/\(hash.prefix(2))/\(hash).png"
        let item = ClipItem(
            id: makeItemID(),
            kind: .image,
            capturedAt: Date(),
            contentHash: hash,
            preview: "这是一张从剪贴板抓到的图片。",
            searchText: "剪貼板圖片",
            provenance: .medium,
            representations: [ItemRepresentation(uti: UTType.png.identifier, byteCount: png.count, blobPath: path)]
        )

        let recorder = DelegateRecorder()
        let coordinator = makeCoordinator(store: store, ring: ring, directory: directory, recognized: "")
        coordinator.delegate = recorder

        await coordinator.ingestPasteboardCapture(item, blobs: [path: png])
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path))
        #expect(try store.count() == 1)

        // 同一份位元组再来一次:去重的规则对两条抓取路径是同一套。
        await coordinator.ingestPasteboardCapture(item, blobs: [path: png])
        #expect(try store.count() == 1)
        #expect(recorder.items.count == 1)
    }
}

@Test("Deferred screenshot storage and OCR update preserve pin, representations and row identity")
func deferredScreenshotPreservesMetadataAndSurvivesReopen() async throws {
    try await withCaptureEnvironment { store, ring, directory in
        let png = try makeChineseScreenshotPNG(text: "延後辨識")
        let file = directory.appendingPathComponent("deferred.png")
        try png.write(to: file)
        let coordinator = makeCoordinator(store: store, ring: ring, directory: directory, recognized: "延後辨識完成")
        let initial = try await coordinator.storeScreenshot(at: file, takenAt: Date())
        #expect(initial.searchText.isEmpty)
        #expect(try store.pendingImageOCRIDs() == [initial.id])
        let duplicate = try await coordinator.storeScreenshot(at: file, takenAt: Date())
        #expect(duplicate.id == initial.id)
        #expect(try store.count() == 1)
        let reopened = try Store(directory: directory, passphrase: "測試用的通行碼")
        defer { reopened.close() }
        #expect(try reopened.pendingImageOCRIDs() == [initial.id])
        try store.setPinned(true, id: initial.id)
        let persisted = try #require(try store.item(id: initial.id))
        let recognized = try #require(await coordinator.recognizeStoredScreenshot(initial.id))
        #expect(recognized.isPinned)
        #expect(recognized.representations == initial.representations)
        #expect(recognized.capturedAt == persisted.capturedAt)
        #expect(recognized.contentHash == initial.contentHash)
        #expect(try store.search("辨識完成", limit: 10).first?.id == initial.id)
        #expect(try reopened.pendingImageOCRIDs().isEmpty)
    }
}

@Test("Deferred OCR cannot resurrect a deleted image")
func deferredOCRDoesNotResurrectDeletedImage() async throws {
    try await withCaptureEnvironment { store, ring, directory in
        let png = try makeChineseScreenshotPNG(text: "稍後刪除")
        let file = directory.appendingPathComponent("deleted.png")
        try png.write(to: file)
        let coordinator = makeCoordinator(store: store, ring: ring, directory: directory, recognized: "不應復活")
        let initial = try await coordinator.storeScreenshot(at: file, takenAt: Date())
        try store.delete(id: initial.id)
        #expect(try store.pendingImageOCRIDs().isEmpty)
        #expect(try store.updateImageOCR(initial.id, text: "不應復活") == false)
        #expect(await coordinator.recognizeStoredScreenshot(initial.id) == nil)
        #expect(try store.count() == 0)
        #expect(try store.search("不應復活", limit: 10).isEmpty)
    }
}

@Test("OCR failures retain durable work and stop after three attempts")
func deferredOCRFailuresAreBounded() async throws {
    try await withCaptureEnvironment { store, ring, directory in
        let png = try makeChineseScreenshotPNG(text: "失敗可重試")
        let file = directory.appendingPathComponent("retry.png")
        try png.write(to: file)
        let coordinator = CaptureCoordinator(store: store, ring: ring, bridge: nil, blobDirectory: directory,
            recognizeText: { _ in throw CocoaError(.fileReadCorruptFile) })
        let initial = try await coordinator.storeScreenshot(at: file, takenAt: Date())
        let persisted = try #require(try store.item(id: initial.id))
        for _ in 0..<2 {
            #expect(await coordinator.recognizeStoredScreenshot(initial.id) == nil)
            #expect(try store.pendingImageOCRIDs() == [initial.id])
        }
        #expect(await coordinator.recognizeStoredScreenshot(initial.id) == nil)
        #expect(try store.pendingImageOCRIDs().isEmpty)
        #expect(try store.item(id: initial.id) == persisted)
    }
}

private actor DeferredOCRGate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var entered = false
    func block() async { entered = true; await withCheckedContinuation { waiting = $0 } }
    func hasEntered() -> Bool { entered }
    func release() { waiting?.resume(); waiting = nil }
}

@Test("A blocked OCR request cannot block later capture writes")
func deferredOCRDoesNotBlockCaptureWrites() async throws {
    try await withCaptureEnvironment { store, ring, directory in
        let png = try makeChineseScreenshotPNG(text: "背景辨識")
        let file = directory.appendingPathComponent("background.png")
        try png.write(to: file)
        let gate = DeferredOCRGate()
        let coordinator = CaptureCoordinator(store: store, ring: ring, bridge: nil, blobDirectory: directory,
            recognizeText: { _ in await gate.block(); return CaptureCoordinator.OCRText(text: "背景完成", isLowConfidence: false) })
        let initial = try await coordinator.storeScreenshot(at: file, takenAt: Date())
        let recognition = Task { await coordinator.recognizeStoredScreenshot(initial.id) }
        for _ in 0..<100 {
            if await gate.hasEntered() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await gate.hasEntered())
        let next = ClipItem(id: makeItemID(), kind: .text, capturedAt: Date(timeIntervalSince1970: 1_700_000_000), contentHash: "following-text",
            preview: "文字不等待", searchText: "文字不等待", representations: [])
        try store.insert(next)
        #expect(try store.item(id: next.id) == next)
        await gate.release()
        #expect(await recognition.value?.searchText == "背景完成")
    }
}
