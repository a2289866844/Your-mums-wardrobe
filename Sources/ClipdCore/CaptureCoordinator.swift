// clipd 的抓取协调器 —— 把一张刚落到磁碟上的截图,一路带到「存好了、也送进知识库了」。
//
// 这个档案存在的理由有两个。第一,这条线上的顺序(先去重、再判来源、再辨识、再落地、最後才送出去)
// 彼此有先後相依,写在 AppDelegate 里就没有人测得动它。第二,每一步失败时该怎麽办并不一样 ——
// 有的该整笔放弃,有的该照存不误 —— 集中在同一个档案里,审查的人才有办法一眼看完整条决策链。
//
// 整合约定:本档只在 `public init` 里包起来的那个闭包碰 `OCRService`,假设它提供
// `recognize(imageAt: URL) async throws -> R`,而 R 带有 `text` 与 `isLowConfidence` 两个栏位;
// 名字若与实作对不上,只需要改那三行。`blobDirectory` 是「相对路径的根」,
// `ItemRepresentation.blobPath` 存的一律是相对於它的路径,资料夹整个搬家之後纪录依然指得到档案。

import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 委派介面

/// 协调器把结果与所有意外都往外送的唯一出口。
///
/// 两个方法都保证在主执行绪(主 actor)上被呼叫,因为唯一的实作者是介面层,
/// 而介面层碰任何东西都必须在主执行绪。
public protocol CaptureCoordinatorDelegate: AnyObject {
    /// 一笔内容已经确实写进本机资料库了。走到这里代表存档成功,不是「打算存」。
    func coordinator(_ c: CaptureCoordinator, didStore item: ClipItem)
    /// 一句写给人看的完整中文句子:略过的理由、失败的原因、或是知识库回报的进度。
    /// 刻意不传 Error 而传句子,是因为这些讯息最後会原样出现在使用者眼前。
    func coordinator(_ c: CaptureCoordinator, didEncounter sentence: String)
}

// MARK: - 协调器本体

/// 标 `@unchecked Sendable` 的理由:本类别自己的可变状态只有 `storedDelegate` 与
/// `storedOCRSummary` 两个,两者的读写全部走同一把 `lock`;其馀栏位都是 `let`。
/// `store` 与 `ring` 自己就保证可以跨执行绪呼叫;`bridge` 的每一次呼叫都被收进同一条背景佇列。
public final class CaptureCoordinator: @unchecked Sendable {

    /// 去重的时间窗。一张截图会同时落在磁碟上、也可能被系统放上剪贴板,两条路径会在几秒内
    /// 先後把同一份位元组送进来;三十秒足够涵盖这段落差,又短到不会把使用者「刻意再截一次
    /// 同一个画面」误判成重复。
    public static let duplicateWindow: TimeInterval = 30

    /// 文字辨识回来的东西里,协调器真正用得到的就只有这两个栏位。特地收敛成自己的型别,是为了让
    /// 「呼叫 OCRService」只发生在建构子那一行:测试因此可以直接注入一段假的辨识结果,
    /// 既不必真的跑 Vision(会慢、会随系统版本浮动),也不必知道 `OCRService` 是怎麽建出来的。
    struct OCRText {
        let text: String
        let isLowConfidence: Bool
    }

    private let store: Store
    private let ring: ActivationRing
    private let recognizeText: (URL) async throws -> OCRText
    private let bridge: KnowledgeBridge?
    private let blobDirectory: URL

    /// 资料库工作专用的序列佇列,理由写在 `onStoreQueue` 上。
    private let storeQueue = DispatchQueue(label: "dev.clipd.capture")
    private let lock = NSLock()
    private weak var storedDelegate: CaptureCoordinatorDelegate?
    private var storedOCRSummary: String?

    public convenience init(store: Store, ring: ActivationRing, ocr: OCRService, bridge: KnowledgeBridge?, blobDirectory: URL) {
        // 整个档案唯一碰 OCRService 的地方,就是底下这三行。
        self.init(store: store, ring: ring, bridge: bridge, blobDirectory: blobDirectory, recognizeText: { url in
            let result = try await ocr.recognize(imageAt: url)
            return OCRText(text: result.text, isLowConfidence: result.isLowConfidence)
        })
    }

    /// 测试用的建构子:辨识那一步换成一段可以自己写死的闭包,其馀每一步都跟正式路径同一份程式码。
    init(
        store: Store,
        ring: ActivationRing,
        bridge: KnowledgeBridge?,
        blobDirectory: URL,
        recognizeText: @escaping (URL) async throws -> OCRText
    ) {
        self.store = store
        self.ring = ring
        self.bridge = bridge
        self.blobDirectory = blobDirectory
        self.recognizeText = recognizeText
    }

    /// 弱参考,避免介面层与协调器互相抓着对方不放。
    /// 写成计算属性是为了让读写都经过锁 —— 设定它的是主执行绪,读它的是背景流程,两边一定会并发。
    public var delegate: CaptureCoordinatorDelegate? {
        get { lock.withLock { storedDelegate } }
        set { lock.withLock { storedDelegate = newValue } }
    }

    /// 最近一次文字辨识的完整中文结论,包含「信心偏低」这件事。
    ///
    /// 信心偏低刻意不写进 `searchText`。把「辨识信心偏低」当成一行标记附在搜寻文字後面,会让这几个字
    /// 自己被索引进去:使用者之後搜「信心」或「偏低」会莫名其妙搜到一堆截图,排序也会被这段与画面
    /// 无关的字干扰。搜寻文字里只能有画面上真的存在的字,品质讯息属於另一个频道,所以走这里送出去。
    public var lastOCRSummary: String? { lock.withLock { storedOCRSummary } }

    // MARK: - 截图进来的那条路

    /// 处理一张刚落到磁碟上的截图。
    ///
    /// `takenAt` 是「按下截图快捷键的那一刻」,不是发现档案的那一刻;来源判断整个建立在它上面。
    /// 这个方法不丢错误:每一种失败都会翻成一句中文送给委派,让呼叫端永远不必写 catch。
    public func ingestScreenshot(at url: URL, takenAt: Date) async {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            await report("读不到刚拍下的截图档「\(url.lastPathComponent)」,原因是 \(error.localizedDescription),所以这一张不会进入历史。")
            return
        }
        guard !data.isEmpty else {
            await report("截图档「\(url.lastPathComponent)」的内容是空的,可能是系统还没写完就被我们读到了,所以这一张先跳过。")
            return
        }

        let hash = Self.sha256Hex(data)

        // 去重一定要摆在最前面,而且要在做任何昂贵的事(文字辨识、写档)之前。
        // 同一张截图很常同时落在磁碟上、又被放上剪贴板,两条抓取路径会各送一次进来;
        // 只要位元组一样、时间又靠得够近,就该判定是同一次动作,历史清单里只能留一笔。
        guard await passesDuplicateCheck(contentHash: hash, subject: "这张截图") else { return }

        let source = resolveSource(at: takenAt)
        let outcome = await runOCR(at: url)
        lock.withLock { storedOCRSummary = outcome.summary }

        let size = Self.pixelSize(of: data)
        let relativePath = Self.blobRelativePath(hash: hash)
        do {
            try writeBlob(data, relativePath: relativePath)
        } catch {
            // 图片写不进去就整笔放弃。存一笔指向不存在档案的纪录,只会让使用者点开一片空白,
            // 那比「这张没抓到」更难理解。
            await report("这张截图的图档写不进储存资料夹,原因是 \(error.localizedDescription),所以整笔放弃,不留半套纪录。")
            return
        }

        let item = ClipItem(
            id: makeItemID(at: takenAt),
            kind: .image,
            capturedAt: takenAt,
            contentHash: hash,
            preview: Self.makeScreenshotPreview(size: size, outcome: outcome),
            // 辨识不到文字时这里就是空字串,而不是拿档名或程式名去凑。
            // 搜寻结果必须对应画面上真的看得到的字,凑出来的字会让使用者搜到自己没见过的东西。
            searchText: outcome.text,
            sourceBundleID: source.bundleID,
            sourceAppName: source.appName,
            provenance: source.provenance,
            isPinned: false,
            representations: [
                // 图片位元组永远只留在磁碟上:一张全萤幕截图动辄好几 MB,内嵌进资料库会让每次查询都拖着它跑。
                ItemRepresentation(uti: UTType.png.identifier, byteCount: data.count, blobPath: relativePath),
            ]
        )

        // 辨识不到字时给知识库传 nil 而不是空字串,nil 才诚实表达「这张图没有可用的文字」。
        await insertAndAnnounce(item, ocr: outcome, ocrText: outcome.text.isEmpty ? nil : outcome.text,
                                failureContext: "这张截图")
    }

    /// Persist once, with a durable OCR job, before doing any recognition.
    public func storeScreenshot(at url: URL, takenAt: Date, duplicateWindow: TimeInterval = CaptureCoordinator.duplicateWindow) async throws -> ClipItem {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let hash = Self.sha256Hex(data)
        if let id = try store.existingID(contentHash: hash, within: duplicateWindow), let existing = try store.item(id: id) { return existing }
        let source = resolveSource(at: takenAt)
        let size = Self.pixelSize(of: data)
        let path = Self.blobRelativePath(hash: hash)
        try writeBlob(data, relativePath: path)
        let preview = size.map { "截圖 \($0.width) × \($0.height)" } ?? "截圖"
        let item = ClipItem(id: makeItemID(at: takenAt), kind: .image, capturedAt: takenAt,
            contentHash: hash, preview: preview, searchText: "", sourceBundleID: source.bundleID,
            sourceAppName: source.appName, provenance: source.provenance,
            representations: [ItemRepresentation(uti: UTType.png.identifier, byteCount: data.count, blobPath: path)])
        try store.insert(item, pendingImageOCR: true)
        return item
    }

    /// Recognition runs separately from capture writes. The transaction updates
    /// text/index/job together and cannot resurrect a row removed by retention.
    public func recognizeStoredScreenshot(_ id: String) async -> ClipItem? {
        do {
            guard let item = try store.item(id: id), item.kind == .image,
                  let path = item.representations.first(where: { $0.blobPath != nil })?.blobPath else { return nil }
            let url = blobDirectory.appendingPathComponent(path).standardizedFileURL
            let root = blobDirectory.appendingPathComponent("blobs").standardizedFileURL
            guard url.path.hasPrefix(root.path + "/"), url == url.resolvingSymlinksInPath().standardizedFileURL else { throw CocoaError(.fileReadNoPermission) }
            let outcome = await runOCR(at: url)
            lock.withLock { storedOCRSummary = outcome.summary }
            guard outcome.failureReason == nil else { try store.noteImageOCRFailure(id); return nil }
            guard try store.updateImageOCR(id, text: outcome.text) else { return nil }
            return try store.item(id: id)
        } catch {
            try? store.noteImageOCRFailure(id)
            return nil
        }
    }

    // MARK: - 剪贴板进来的那条路

    /// 处理监看器抓到的一则内容:先把附带的外部档案落地,再写进资料库。
    /// `blobs` 的键就是对应表示法里的 `blobPath`,与 `PasteboardWatcher` 的约定一致。
    public func ingestPasteboardCapture(_ item: ClipItem, blobs: [String: Data]) async {
        // 去重的规则对两条抓取路径必须是同一套,所以这里呼叫的是跟截图那条路完全相同的检查。
        guard await passesDuplicateCheck(contentHash: item.contentHash, subject: "这则内容") else { return }

        // 先落地再写资料库:顺序反过来的话,只要写档失败,资料库里就会留下一笔指不到档案的纪录。
        for path in blobs.keys.sorted() {
            guard let data = blobs[path] else { continue }
            do {
                try writeBlob(data, relativePath: path)
            } catch {
                await report("这则内容的附带档案写不进储存资料夹,原因是 \(error.localizedDescription),所以整笔放弃,不留半套纪录。")
                return
            }
        }

        // 这条路径没有经过文字辨识,所以两个辨识参数都刻意传 nil:若在这里顺手读 `lastOCRSummary`,
        // 送出去的会是上一张截图留下的旧结论,等於对使用者说了一句与这一笔无关的话。
        await insertAndAnnounce(item, ocr: nil, ocrText: nil, failureContext: "这则内容")
    }

    // MARK: - 共用的收尾:写库、通知、送知识库

    private func insertAndAnnounce(_ item: ClipItem, ocr outcome: OCROutcome?, ocrText: String?, failureContext: String) async {
        do {
            try await onStoreQueue { [store] in try store.insert(item) }
        } catch {
            await report("\(failureContext)存不进资料库,原因是 \(error);这一笔没有留下来。")
            return
        }

        await deliverStored(item)

        // 辨识品质有疑虑时才多讲一句:正常辨识完还要报一次会让通知沦为杂讯,连真正该被看见的
        // 「这些字可能不准」也会一起被忽略掉。
        if let outcome, outcome.needsAttention {
            await report(outcome.summary)
        }

        await handOffToKnowledgeBridge(item, ocrText: ocrText)
    }

    /// 把已经存好的一笔交给知识库。这里所有的失败都只回报、不回滚:本机抓取才是这支程式的主线工作,
    /// 知识库是下游。让下游的失败反过来吃掉一笔已经抓到的内容,等於用「同步失败」这种小事换掉
    /// 使用者的资料,那个交换在任何情况下都不划算。
    private func handOffToKnowledgeBridge(_ item: ClipItem, ocrText: String?) async {
        guard bridge != nil else { return }   // 没有接知识库是完全合法的设定,不是错误。
        do {
            // 写档与呼叫外部索引指令都会把执行绪整条挡住,所以跟资料库共用同一条背景佇列。
            // 写入回报的那句「已经写进知识库」刻意不转给使用者:每抓一则就说一次会变成杂讯。
            try await onStoreQueue { [self] in
                guard let bridge = self.bridge else { return }
                _ = try bridge.write(item, ocrText: ocrText)
            }
        } catch {
            await report("这一笔已经存进本机资料库了,但送去知识库时失败,原因是 \(error);本机纪录不受影响。")
            return
        }
        do {
            let sentence = try await onStoreQueue { [self] () -> String? in
                guard let bridge = self.bridge else { return nil }
                return try bridge.reindexIfBatchReady()
            }
            if let sentence, !sentence.isEmpty {
                await report(sentence)
            }
        } catch {
            await report("知识库这一批的重建索引失败了,原因是 \(error);本机纪录不受影响,下一批会再试一次。")
        }
    }

    // MARK: - 文字辨识

    /// 辨识的结果,把「这次没成功」也一起表达掉,所以刻意不用 throws 往外丢 —— 辨识失败不该连带让一张已经抓到的图片消失。
    struct OCROutcome {
        let text: String
        let summary: String
        let failureReason: String?
        /// 值得多讲一句给使用者听:不是失败就是信心偏低。
        let needsAttention: Bool
    }

    private func runOCR(at url: URL) async -> OCROutcome {
        let result: OCRText
        do {
            result = try await recognizeText(url)
        } catch {
            // 辨识失败不影响存档:图片本身已经抓到了,少了可搜寻的文字仍然比整张丢掉好。
            let reason = "\(error)"
            return OCROutcome(text: "", summary: "上一次文字辨识失败了,原因是 \(reason)。",
                              failureReason: reason, needsAttention: true)
        }
        let text = result.text
        guard !text.isEmpty else {
            return OCROutcome(text: "", summary: "上一次文字辨识跑完了,但这张图里没有读到任何文字。",
                              failureReason: nil, needsAttention: false)
        }
        guard result.isLowConfidence else {
            return OCROutcome(text: text, summary: "上一次文字辨识读到了 \(text.count) 个字,信心水准正常。",
                              failureReason: nil, needsAttention: false)
        }
        return OCROutcome(
            text: text,
            summary: "上一次文字辨识读到了 \(text.count) 个字,但辨识信心偏低,这些字可能与画面上的原文有出入,请当成线索而不是原文。",
            failureReason: nil, needsAttention: true
        )
    }

    // MARK: - 来源判断

    private func resolveSource(at t: Date) -> (bundleID: String?, appName: String?, provenance: Provenance) {
        // 一定要用「拍照的那一刻」去问,不能用「现在」—— 这正是启动历史那个环形缓冲区存在的全部理由。
        // 截图从按下快捷键到档案真的落到磁碟上会有明显的延迟,那段时间里使用者早就切走了,
        // 拿此刻的前景程式当来源,答案几乎保证是错的,而且错得很有说服力。
        let candidates = ring.candidates(at: t)
        guard let best = candidates.records.first else {
            return (nil, nil, candidates.provenance)
        }
        return (best.bundleID, best.appName, candidates.provenance)
    }

    // MARK: - 去重

    /// 问资料库「这份内容刚刚是不是已经收过了」。回传 true 代表该继续处理这一笔。
    /// `subject` 是要写进句子里的主词,例如「这张截图」,让讯息读起来是一句完整的话。
    private func passesDuplicateCheck(contentHash: String, subject: String) async -> Bool {
        let existing: String?
        do {
            let window = Self.duplicateWindow
            existing = try await onStoreQueue { [store] in
                try store.existingID(contentHash: contentHash, within: window)
            }
        } catch {
            // 查不动去重就照存。少一次去重最多多出一笔重复纪录,漏抓一张截图却是真的救不回来,
            // 所以这里刻意选择「宁可重复也不要遗失」,但一定要把查询失败讲出来。
            await report("这次没能确认\(subject)是不是重复的,原因是 \(error);为了不漏抓,还是照样存一笔。")
            return true
        }
        guard let existing else { return true }
        await report("\(subject)在 \(Int(Self.duplicateWindow)) 秒内已经收过一次(纪录 \(existing)),所以这次略过,不再重复存一笔。")
        return false
    }

    // MARK: - 外部档案

    /// 内容定址的相对路径:前两码切一层子目录,免得几万个档案全挤在同一层拖慢档案系统。
    /// 同一张图不论被抓到几次都落在同一个路径上,所以磁碟上只会有一份。
    static func blobRelativePath(hash: String) -> String {
        "blobs/\(hash.prefix(2))/\(hash).png"
    }

    private func writeBlob(_ data: Data, relativePath: String) throws {
        let destination = blobDirectory.appendingPathComponent(relativePath)
        // 权限收成 0o700:这些档案是使用者截过的画面与复制过的内容,同帐号以外的人没有理由看得到。
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // 用 atomic 写:若上一次写到一半断电,磁碟上会留下一个长度不对的档案,
        // 而内容定址察觉不到这种半截档,所以每次都整个重写一遍最保险。
        try data.write(to: destination, options: .atomic)
    }

    // MARK: - 预览句子

    private static func makeScreenshotPreview(size: (width: Int, height: Int)?, outcome: OCROutcome) -> String {
        // 读不出尺寸时要说实话。随便填 0 × 0 会让使用者以为图片坏了。
        let dimension = size.map { "一张 \($0.width) × \($0.height) 像素的截图" } ?? "一张读不出尺寸的截图"
        if let reason = outcome.failureReason {
            return "这是\(dimension),文字辨识这一步失败了,原因是 \(reason),所以这一张暂时没有可以搜寻的文字。"
        }
        let fragment = firstFragment(of: outcome.text)
        guard !fragment.isEmpty else {
            // 没读到文字一定要明讲。预览栏留白会让使用者以为程式坏掉了,
            // 而「这张图里本来就没有字」是一个正常且常见的结果。
            return "这是\(dimension),里面没有辨识到任何文字。"
        }
        return "这是\(dimension),辨识出来的文字开头是「\(fragment)」。"
    }

    /// 取开头一小段当预览。换行与连续空白先压成单一空白,否则预览会带着排版留下的空洞。
    private static func firstFragment(of text: String, limit: Int = 30) -> String {
        let flattened = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)) + "…"
    }

    // MARK: - 图片与杂凑

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 只读中继资料就能拿到尺寸,不必把整张图解码成点阵,省下来的记忆体在连拍截图时很有感。
    private static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
    }

    // MARK: - 执行绪纪律

    /// 纪律有两条,两条都必须成立。一、所有碰资料库(与知识库)的呼叫都在这条专属的序列佇列上跑,
    /// 绝不在主执行绪 —— `Store` 的每个方法内部都是 `queue.sync`,在主执行绪上呼叫会直接把介面卡住;
    /// 丢给 Swift 并行的合作执行绪池同样不行,那个池子只有几条执行绪,拿 `sync` 去挡它会拖垮其他工作。
    /// 二、委派一律回到主 actor 上呼叫(见 `report` 与 `deliverStored`),介面层才不必自己再跳一次。
    private func onStoreQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            storeQueue.async {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func report(_ sentence: String) async {
        await MainActor.run {
            self.delegate?.coordinator(self, didEncounter: sentence)
        }
    }

    private func deliverStored(_ item: ClipItem) async {
        await MainActor.run {
            self.delegate?.coordinator(self, didStore: item)
        }
    }
}
