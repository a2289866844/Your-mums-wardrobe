import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 委派介面

/// 抓到一则新内容时的回呼。
public protocol PasteboardWatcherDelegate: AnyObject {
    /// `blobs` 的键就是 `ItemRepresentation.blobPath` 里的那个相对路径,值是要落地成档案的原始位元组。
    /// 图片故意不放进 `ClipItem` 本体,因为一张全萤幕截图动辄好几 MB,直接塞进资料库会让每一次查询都拖着它跑。
    func pasteboardWatcher(_ w: PasteboardWatcher, didCapture item: ClipItem, blobs: [String: Data])
}

// MARK: - 监看器

/// 轮询 `NSPasteboard.general`,把每一次内容变动转成一则 `ClipItem`。
///
/// 为什么是轮询而不是通知:macOS 至今没有提供剪贴板变动的系统通知,唯一的办法就是自己盯着 `changeCount` 看。
/// M0 实测过成本,单次读取 `changeCount` 的中位数是 10.2 微秒、第 95 百分位 22.8 微秒、最差 280.9 微秒,
/// 所以「读取本身」几乎不花钱;选多长的间隔要考虑的是唤醒 CPU 的耗电,而不是运算量。
public final class PasteboardWatcher {

    // MARK: 对外状态

    public weak var delegate: PasteboardWatcherDelegate?

    /// 当本程式自己把内容写回剪贴板(例如使用者从面板选一则来贴上)时,应用层要把写入後的
    /// `NSPasteboard.general.changeCount` 填进这个栏位。轮询看到的变动如果正好等于这个值,
    /// 就知道这是自己造成的,直接跳过;否则每贴上一次就会多记一笔一模一样的纪录,历史会被自己灌爆。
    /// 预设 `-1` 代表「还没有任何一次自我写入」,而 `changeCount` 永远不会是负数,所以不会误伤。
    public var selfWriteChangeCount: Int = -1

    /// 使用者可以随时暂停抓取。暂停时计时器仍然在跑、仍然追踪 `changeCount`,但完全不去读内容,
    /// 所以恢复之後不会把暂停期间复制的东西补抓进来。这是刻意的设计:使用者按下暂停,
    /// 通常正是因为接下来要复制不想被记录的东西。
    public var isPaused: Bool = false

    // MARK: 内部状态

    private let pasteboard = NSPasteboard.general
    private let ring: ActivationRing
    private let interval: TimeInterval
    private var timer: Timer?
    private var activityToken: NSObjectProtocol?
    private var lastChangeCount: Int

    public init(ring: ActivationRing, interval: TimeInterval = 0.2) {
        self.ring = ring
        // 间隔若被传成 0 或负数,计时器会变成忙碌回圈把一颗核心烧满,所以在这里挡下来。
        self.interval = max(0.05, interval)
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    deinit {
        // 计时器只弱参考 self,所以本物件可以正常释放;但计时器本身是被 RunLoop 抓着的,
        // 不在这里作废掉就会留下一个永远空转的计时器。
        timer?.invalidate()
        if let token = activityToken { ProcessInfo.processInfo.endActivity(token) }
    }

    // MARK: 生命周期

    public func start() {
        guard timer == nil else { return }   // 重复呼叫 start() 不应该叠出第二个计时器。
        beginActivity()

        // 起点对齐现况:启动前就躺在剪贴板上的旧内容不算「刚刚发生的一次复制」,
        // 若不对齐,程式一开机就会莫名其妙抓一笔进来。
        lastChangeCount = pasteboard.changeCount

        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // 容忍度设成间隔的一成,让系统可以把我们的唤醒跟其他工作合并,省电而不影响体感。
        t.tolerance = interval * 0.1
        // 一定要挂 .common 模式:预设的 .default 模式在使用者拉动选单或捲动视窗时会被暂停,
        // 那正好是复制动作最密集的时候,漏掉就再也补不回来。
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        endActivity()
    }

    /// 立刻读一次剪贴板并组出 `ClipItem`,不理会 `changeCount` 有没有变。
    ///
    /// 这个方法是纯读取:不会通知 delegate、不会更新内部状态、不会写进任何地方,
    /// 所以人工测试时随便呼叫都不会污染资料库。板上带着「不要记录我」标记时回传 `nil`。
    public func captureNow() -> ClipItem? {
        capture()?.item
    }

    // MARK: App Nap

    private func beginActivity() {
        guard activityToken == nil else { return }
        // 一个常驻选单列、没有视窗、使用者绝大多数时间都在别的程式里的 App,是 App Nap 的头号目标。
        // App Nap 一旦介入就会把计时器节流到好几秒才跳一次 —— 而「使用者正在别的程式里」这个前提,
        // 对这个产品来说是永远成立的,等于监看功能会在最需要它的时候悄悄失灵,而且不会有任何错误讯息。
        // 所以整个监看期间都要握着这个 activity token,明确告诉系统我们不能被休眠。
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "剪贴板监看"
        )
    }

    private func endActivity() {
        guard let token = activityToken else { return }
        ProcessInfo.processInfo.endActivity(token)
        activityToken = nil
    }

    // MARK: 轮询

    private func tick() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        // 先记下新的计数再决定要不要抓。就算这一则最後被规则挡掉,也不该在下一次轮询时重试,
        // 否则被挡掉的内容会让程式每 0.2 秒重跑一次判断直到使用者换掉剪贴板。
        lastChangeCount = current

        // 暂停期间仍然要更新上面那个计数,但绝对不读内容。这样使用者恢复抓取之後,
        // 暂停当下复制的东西不会被追溯抓进来——「暂停」的意思是那段时间我们没有看,
        // 而不是「延後再看」。这个差别在使用者是为了复制密码才按暂停时特别重要。
        guard !isPaused else { return }

        guard current != selfWriteChangeCount else { return }
        guard let result = capture() else { return }
        delegate?.pasteboardWatcher(self, didCapture: result.item, blobs: result.blobs)
    }

    // MARK: 抓取主流程

    private struct Capture {
        let item: ClipItem
        let blobs: [String: Data]
    }

    private func capture() -> Capture? {
        let now = Date()
        guard let rawTypes = pasteboard.types?.map(\.rawValue), !rawTypes.isEmpty else { return nil }
        guard !isNeverCapture(Set(rawTypes)) else { return nil }

        let board = readBoard(types: rawTypes)
        let kind = classify(board)
        let canonical = canonicalBytes(kind: kind, board: board)
        // 一个位元组都读不到,代表这是我们认不得的纯私有型别。宁可什麽都不记,也不要留一笔空壳纪录。
        guard !canonical.isEmpty else { return nil }

        var blobs: [String: Data] = [:]
        let reps = makeRepresentations(board, blobs: &blobs)
        let source = resolveSource(at: now)

        let item = ClipItem(
            id: makeItemID(at: now),
            kind: kind,
            capturedAt: now,
            contentHash: sha256Hex(canonical),
            preview: makePreview(kind: kind, board: board),
            searchText: makeSearchText(kind: kind, board: board),
            sourceBundleID: source.bundleID,
            sourceAppName: source.appName,
            provenance: source.provenance,
            isPinned: false,
            representations: reps
        )
        return Capture(item: item, blobs: blobs)
    }

    // MARK: 排除规则

    /// 比对的对象一定要是整块板的型别联集(`NSPasteboard.general.types`),不能是逐个 `NSPasteboardItem` 的型别。
    /// 有些密码管理器把「不要记录我」标记写成独立的一个 pasteboard item,逐项检查会完全看不到它,
    /// 结果就是密码被静静地记进历史 —— 这是这支程式最不能犯的错。
    private func isNeverCapture(_ boardTypes: Set<String>) -> Bool {
        if !boardTypes.isDisjoint(with: PasteboardMarker.neverCapture) { return true }
        // 通用剪贴板(隔空同步过来的内容)一律不记:它是从另一台装置飘过来的,
        // 本机的前景程式跟它毫无关系,任何来源推断规则套上去都只会产生一个看起来很确定的错误答案。
        if boardTypes.contains(PasteboardMarker.remoteClipboard) { return true }
        return false
    }

    // MARK: 读取整块板

    private struct BoardSnapshot {
        let types: [String]
        let text: String?
        let fileURLs: [URL]
        let pngData: Data?
        let pixelWidth: Int
        let pixelHeight: Int
        let rawByType: [String: Data]
    }

    private func readBoard(types: [String]) -> BoardSnapshot {
        let text = pasteboard.string(forType: .string)
        let fileURLs = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []

        let pngUTI = UTType.png.identifier
        let tiffUTI = UTType.tiff.identifier

        // 图片一律优先拿 public.png。实测一张全萤幕 Retina 截图,PNG 大约 2.6 MB,
        // 而剪贴板同时提供的未压缩 public.tiff 大约 29.5 MB —— 相差十一倍多。
        // 两者的画素完全一样,拿 TIFF 只是让每张截图多吃掉近 27 MB 的记忆体与磁碟。
        var png = types.contains(pngUTI) ? pasteboard.data(forType: .png) : nil
        if png == nil, types.contains(tiffUTI), let tiff = pasteboard.data(forType: .tiff) {
            // 只有在板上根本没给 PNG 的时候才走这条路:此时不得不吞下那 29.5 MB,
            // 但转档後留在磁碟上的仍然是压缩过的 PNG。
            // 这里刻意不用 NSImage(pasteboard:),因为它会自行挑选型别、丢掉原始画素资讯,
            // 而且对多帧或含 alpha 的资料行为不透明。NSBitmapImageRep 是直接对位元组做事,可预期。
            png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        }
        let size = png.flatMap(pixelSize(of:))

        // 读齐板上每一种表示法,不要只挑一种。使用者贴到不同程式时期待的可能是任何一种,
        // 而剪贴板一旦被换掉,没读到的那几种就永远回不来了。
        var raw: [String: Data] = [:]
        for t in types {
            if t == pngUTI { continue }                       // PNG 走 blob,不重复放一份在这里。
            if t == tiffUTI, png != nil { continue }          // 理由同上:29.5 MB 的重复资料不留。
            if t == PasteboardMarker.source { continue }      // 这是後设资料不是内容,另外处理。
            if let d = pasteboard.data(forType: NSPasteboard.PasteboardType(t)) { raw[t] = d }
        }

        return BoardSnapshot(
            types: types, text: text, fileURLs: fileURLs, pngData: png,
            pixelWidth: size?.width ?? 0, pixelHeight: size?.height ?? 0, rawByType: raw
        )
    }

    /// 只读 PNG 的标头拿尺寸,不把整张图解码成点阵,省下一次没必要的记忆体尖峰。
    private func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }

    // MARK: 分类

    private func classify(_ b: BoardSnapshot) -> ItemKind {
        if let t = b.text, isSingleLink(t) { return .link }
        if b.pngData != nil { return .image }
        if !b.fileURLs.isEmpty { return .file }
        if let t = b.text, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .text }
        return .other
    }

    /// 判断一段文字是不是「单独一个网址」。
    /// 刻意只认 http 与 https:mailto、file 这类虽然也解析得过,但面板上的 .link 代表「点了会开浏览器」,
    /// 让它们留在 .text 比较诚实。从 Finder 复制档案时板上的字串是 file:// 开头,也因此不会被误判成网址。
    private func isSingleLink(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 2048 else { return false }
        guard !t.contains(where: { $0.isWhitespace }) else { return false }
        guard let url = URL(string: t),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return false }
        return true
    }

    // MARK: 摘要与搜寻文字

    /// 面板上显示的那一行。任何情况下都不会是空字串 —— 空白的一列会让使用者以为程式坏了。
    private func makePreview(kind: ItemKind, board b: BoardSnapshot) -> String {
        let body = previewBody(kind: kind, board: b)

        // 最後一道防线。实测遇过一则内容只有换行字元:它通过了「字串不是空的」这个检查,
        // 却在整理成单行时被修掉,结果面板上出现一列完全空白、点不出所以然的项目。
        // 面板上每一列都必须能告诉使用者「这是什麽」,哪怕答案是「这个东西显示不出来」。
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }

        let shown = b.types.prefix(3).joined(separator: "、")
        return shown.isEmpty
            ? "這一則的內容沒有辦法顯示成文字,而且剪貼板也沒有回報任何型別。"
            : "這一則的內容沒有辦法顯示成文字,剪貼板上的型別是 \(shown)。"
    }

    private func previewBody(kind: ItemKind, board b: BoardSnapshot) -> String {
        switch kind {
        case .text, .link:
            return singleLine(b.text ?? "", limit: 120)
        case .image:
            let bytes = humanBytes(b.pngData?.count ?? 0)
            if b.pixelWidth > 0 && b.pixelHeight > 0 {
                return "這是一張 \(b.pixelWidth) × \(b.pixelHeight) 像素的圖片,存起來的大小是 \(bytes)。"
            }
            return "這是一張圖片,存起來的大小是 \(bytes),但是讀不出它的像素尺寸。"
        case .file:
            let names = b.fileURLs.map(\.lastPathComponent).filter { !$0.isEmpty }
            if names.isEmpty { return "這是一組檔案,但是取不到任何檔名。" }
            return singleLine(names.joined(separator: "、"), limit: 120)
        case .other:
            if let t = b.text, !t.isEmpty { return singleLine(t, limit: 120) }
            let shown = b.types.prefix(3).joined(separator: "、")
            return "這一則沒有可以顯示的文字,剪貼板上的型別是 \(shown)。"
        }
    }

    private func makeSearchText(kind: ItemKind, board b: BoardSnapshot) -> String {
        switch kind {
        case .text, .link, .other:
            return b.text ?? ""
        case .file:
            // 用空白隔开,让分词器可以把每个档名切成独立的词,不然整串会黏成一个搜不到的长词。
            return b.fileURLs.map(\.lastPathComponent).joined(separator: " ")
        case .image:
            // 图片现在没有任何可搜寻的文字。M3 会把 Vision 做出来的 OCR 结果写回这个栏位,
            // 届时截图里的字就能被搜到,而资料结构不需要跟着改。
            return ""
        }
    }

    /// 把多行文字压成一行:换行与定位字元换成空白,连续空白收成一个,再截到指定长度。
    private func singleLine(_ s: String, limit: Int) -> String {
        let flattened = s.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        if flattened.count <= limit { return flattened }
        return String(flattened.prefix(limit)) + "…"
    }

    private func humanBytes(_ n: Int) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB]
        return f.string(fromByteCount: Int64(n))
    }

    // MARK: 内容杂凑

    /// 只把「这则内容真正是什麽」的那份位元组拿去算杂凑,不要把整块剪贴板算进去。
    ///
    /// 原因很实际:同一句话从 Safari 复制跟从 Word 复制,板上的型别组合完全不同,
    /// 而 RTF 里面还夹着产生器名称与时间戳,连同一个程式复制两次都不会得到相同的位元组。
    /// 若拿整块板去算,去重永远不会命中,使用者复制同一段话三次就会看到三笔一模一样的纪录。
    private func canonicalBytes(kind: ItemKind, board b: BoardSnapshot) -> Data {
        switch kind {
        case .text, .link:
            return Data((b.text ?? "").utf8)
        case .image:
            return b.pngData ?? Data()
        case .file:
            // 排序过再接起来,因为多选档案时系统给的顺序不保证稳定,不排序会让同一组档案算出不同杂凑。
            let paths = b.fileURLs.map(\.path).sorted()
            return Data(paths.joined(separator: "\n").utf8)
        case .other:
            if let t = b.text, !t.isEmpty { return Data(t.utf8) }
            // 认不出内容时退而求其次:按型别名排序後把「型别名 + 该型别的位元组」串起来,
            // 至少保证同样的一块板会算出同样的杂凑。
            var acc = Data()
            for uti in b.rawByType.keys.sorted() {
                acc.append(Data(uti.utf8))
                if let d = b.rawByType[uti] { acc.append(d) }
            }
            return acc
        }
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: 表示法与外部档案

    private func makeRepresentations(_ b: BoardSnapshot, blobs: inout [String: Data]) -> [ItemRepresentation] {
        var reps: [ItemRepresentation] = []

        if let png = b.pngData {
            // 用图片自己的杂凑当路径,而不是用整则纪录的杂凑:同一张图被复制十次只会占一份磁碟空间。
            let path = blobRelativePath(hash: sha256Hex(png), ext: "png")
            blobs[path] = png
            reps.append(ItemRepresentation(uti: UTType.png.identifier, byteCount: png.count, blobPath: path))
        }

        for uti in b.rawByType.keys.sorted() {
            guard let data = b.rawByType[uti] else { continue }
            let inline = isTextUTI(uti) ? String(data: data, encoding: .utf8) : nil
            reps.append(ItemRepresentation(uti: uti, byteCount: data.count, blobPath: nil, inlineText: inline))
        }
        return reps
    }

    /// 内容定址的相对路径。前两码切一层子目录,免得几万个档案全挤在同一个目录里拖慢档案系统。
    private func blobRelativePath(hash: String, ext: String) -> String {
        "blobs/\(hash.prefix(2))/\(hash).\(ext)"
    }

    /// 认不出来的型别(例如各家程式私有的 dyn.xxxx)一律当二进位,不要硬解成字串,
    /// 硬解出来的乱码进了搜寻索引只会製造杂讯。
    private func isTextUTI(_ uti: String) -> Bool {
        guard let t = UTType(uti) else { return false }
        return t.conforms(to: .text) || t == .url || t == .fileURL
    }

    // MARK: 来源推断

    /// 这是整个档案唯一碰到 `ActivationRing` 的地方,假设集中在这里。
    /// 假设的介面是 `ring.candidates(at: Date) -> (candidates: [ActivationCandidate], provenance: Provenance)`,
    /// 其中候选者至少要有 `bundleID: String` 与 `appName: String?`。若实际形状不同,只要改这一个函式。
    private func resolveSource(at date: Date) -> (bundleID: String?, appName: String?, provenance: Provenance) {
        let guess = ring.candidates(at: date)
        // 回传的栏位叫 records 而不是 candidates:这里取的是「排在最前面的那一个可能来源」,
        // 但整份清单会一起交给日後的黑名单判断,因为只要其中任何一个来源被挡下就该挡下整则。
        let first = guess.records.first
        var bundleID = first?.bundleID
        var appName = first?.appName
        var provenance = guess.provenance

        let markerType = NSPasteboard.PasteboardType(PasteboardMarker.source)
        if let marker = pasteboard.string(forType: markerType) {
            let value = marker.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                // 按照 nspasteboard.org 的约定,空字串的 source 标记表示「来源刻意不揭露」,
                // 也就是「不知道是谁」。这里绝对不能因为「标记存在」就升成 .high ——
                // 那会把一个明确的「不知道」变成一个看起来很可信的错误答案,
                // 而使用者日後是靠 provenance 来决定要不要相信 sourceBundleID 的。
                // 所以什麽都不做,让上面那个环形缓冲区的推断与它自己的可信度原封不动地留着。
            } else {
                bundleID = value
                appName = NSRunningApplication.runningApplications(withBundleIdentifier: value)
                    .first?.localizedName ?? appName
                provenance = .high   // 来源是内容产生者自己写上去的,这是我们能拿到最硬的证据。
            }
        }
        return (bundleID, appName, provenance)
    }
}

// MARK: - 人工验证步骤
//
// 这个档案需要一块活的剪贴板才能验,所以不写自动化测试,请依下面的步骤人工确认。
// 每一步都写了「应该看到什麽」,看到别的结果就是有问题。
//
// 一、基本抓取。启动 App 之後,在「文字编辑」里打一段中文再按 Command-C。
//     应该看到:面板多一笔纪录,摘要是那段中文的前 120 个字压成一行,种类是文字,
//     来源显示为「文字编辑」。
//
// 二、网址判定。在浏览器网址列复制一个 https 开头的网址。
//     应该看到:该笔的种类是连结而不是文字。接着复制一段「中间有空白的句子加一个网址」,
//     应该看到:那一笔回到文字,因为它不是单独一个网址。
//
// 三、图片与体积。按 Command-Shift-4 截一张全萤幕的图(截图预设会进剪贴板)。
//     应该看到:摘要是一句完整中文,写着像素尺寸与档案大小,大小在数 MB 而不是数十 MB;
//     磁碟上 blobs/ 底下多出一个以杂凑命名的 .png 档,ClipItem 本身没有内嵌图片位元组。
//
// 四、档案。在 Finder 里选三个档案按 Command-C。
//     应该看到:种类是档案,摘要是三个档名用顿号串起来,搜寻文字是同样三个档名用空白隔开。
//
// 五、密码不可被记录(最重要的一项)。在 1Password 或钥匙圈里复制一组密码。
//     应该看到:面板完全没有新增任何纪录,资料库里也查不到那串密码。
//     若这一项没过,请立刻停用整个功能,这是产品的底线。
//
// 六、去重。把同一段文字连续复制三次(中间去点一下别的地方让 changeCount 变动)。
//     应该看到:三次算出来的 contentHash 完全相同,面板上只留一笔。
//
// 七、自我写入。从面板选一则贴回剪贴板。
//     应该看到:历史「没有」因此多一笔重复纪录。若有,代表应用层忘了在写入後设定
//     selfWriteChangeCount。
//
// 八、App Nap。启动後切到别的程式并让机器闲置十分钟以上,再回来复制一段文字。
//     应该看到:那一笔仍然在两秒内出现在面板上;如果要等好几秒甚至完全没出现,
//     代表 beginActivity 的 token 没有被握住。
//
// 九、通用剪贴板。在 iPhone 上复制一段文字,等 Mac 收到後观察。
//     应该看到:Mac 这边完全不新增纪录。
//
// 十、手动读取。在除错主控台呼叫 watcher.captureNow()。
//     应该看到:回传一个 ClipItem,而且面板上「不会」因此多一笔 —— 这个方法只读不写。
