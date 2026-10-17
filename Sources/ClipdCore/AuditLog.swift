// clipd 的外送稽核纪录:一份只能往後加、不能回头改的本机流水帐,记下「哪些东西真的离开过这台机器」,
// 以及同样重要的「哪些东西被考虑过、最後没有送出去」。
//
// 为什么是一行一个 JSON 物件的纯文字档,而不是一个自订结构的二进位资料库:
// 这份纪录存在的唯一理由,是有一天有人(合规稽核、诊所主管、或者使用者自己在半夜三点)问
// 「到底有什么东西离开过这台电脑」。那个时候能直接交出去的,是一个用任何文字编辑器打开就看得懂、
// 可以 grep、可以 diff、可以原封不动附在信里寄出去的档案。一个塞着自订 schema 的 SQLite 档不是那个东西:
// 它需要我们提供工具才读得懂,而「你得先信任我写的读取工具」正好是稽核最不该接受的前提。
//
// 这个档案刻意只做纪录,不做判断。要不要挡、要不要送,是别人的职责;这里只负责把发生过的事写下来。
import CryptoKit
import Foundation
import Security

// MARK: - 错误型别

/// 稽核纪录往外丢的错误。每一句都写成完整的句子,因为其中好几句会直接出现在使用者眼前。
public enum AuditError: Error, CustomStringConvertible {
    case emptyInstallKey
    case cannotCreateDirectory(path: String, reason: String)
    case cannotWrite(path: String, reason: String)
    case cannotRead(path: String, reason: String)
    case cannotEncode(reason: String)

    public var description: String {
        switch self {
        case .emptyInstallKey:
            return "稽核纪录需要一把本机安装金钥才能建立,传进来的金钥是空的;没有金钥的话纪录里的内容识别码会退化成明文杂凑,那本身就是一次外泄,所以这里宁可直接失败。"
        case let .cannotCreateDirectory(path, reason):
            return "无法建立存放外送稽核纪录的资料夹 \(path),原因是 \(reason)。"
        case let .cannotWrite(path, reason):
            return "无法写入外送稽核纪录 \(path),原因是 \(reason);这一笔事件没有被记下来。"
        case let .cannotRead(path, reason):
            return "无法读取外送稽核纪录 \(path),原因是 \(reason)。"
        case let .cannotEncode(reason):
            return "无法把这一笔稽核事件转成 JSON,原因是 \(reason);这一笔事件没有被记下来。"
        }
    }
}

// MARK: - 事件与纪录

/// 一笔外送事件的种类。
public enum EgressEvent: String, Codable, Sendable {
    case queued             // 已经排进待送批次,还没真的送出去
    case sent               // 已经送出去而且对方确认收到
    case blocked            // 命中封锁清单,不上传;注意这一则仍然被抓下来、仍然存在本机、仍然搜寻得到
    case cancelled          // 使用者在送出之前取消
    case expired            // 排队排到过期,一直没送成
    case failed             // 送出的尝试失败了
    case killSwitchEnabled  // 使用者按下总开关,全面停止外送
    case killSwitchDisabled // 使用者把总开关关掉,恢复外送
    case historyDestroyed   // 使用者销毁了本机历史
}

/// 侦测器对某一段内容下的判断。
public enum DetectorVerdict: String, Codable, Sendable {
    case matched            // 确定命中
    case suspected          // 疑似命中,信心不足
    case cleared            // 看过了,没有命中
}

/// 侦测器命中的一处位置,写进稽核纪录用的那一份。
///
/// 这里刻意只记「第几个字元开始、长几个字元」,绝对不记命中的那一段字本身。
/// 理由很直接:一份忠实记下「我帮你挡掉了这把 API 金钥」的纪录,自己就是一份 API 金钥清单。
/// 那会把稽核纪录从「安全措施」变成「攻击目标」——攻击者不必再去翻剪贴板,翻这个档案就够了。
/// 需要人工复核时,拿 offset 与 length 回到本机那一则原文去看,原文本来就还在。
///
/// 为什么不直接沿用 Detectors.swift 里那个 `DetectorHit`,而要另外定一个型别:
/// 那一个是侦测器交给判断逻辑用的,身上带着 label 这种给人看的说明栏位,而且日後还会长出别的栏位。
/// 落地进一份长期保存的档案是另一件事,它必须有一道明确的关卡,让「哪些栏位可以写进磁碟」
/// 是一个人得动手做的决定,而不是「侦测器多加一个栏位,那个栏位就自动跟着躺进稽核档」。
/// 呼叫端要自己把侦测结果转成这个型别,而转换的那一行就是拒绝抄进原文的那一行。
public struct AuditDetectorHit: Codable, Sendable, Equatable {
    public let detectorID: String
    public let detectorVersion: String
    public let verdict: DetectorVerdict
    public let offset: Int
    public let length: Int

    public init(detectorID: String, detectorVersion: String, verdict: DetectorVerdict, offset: Int, length: Int) {
        self.detectorID = detectorID
        self.detectorVersion = detectorVersion
        self.verdict = verdict
        self.offset = offset
        self.length = length
    }
}

/// 一笔稽核纪录。
///
/// 每一笔都带 policyVersion。没有它的话,一句「这一则当时判定为乾净」就没有意义:
/// 乾净是相对於当时那一套规则说的,规则改过之後,同一则内容可能就不乾净了。
/// 有了版本号,日後才有办法回头问「用今天的规则重跑一次,当年这些乾净的判定还站得住吗」。
public struct AuditRecord: Codable, Sendable, Equatable {
    public var id: String
    public var at: Date
    public var event: EgressEvent
    public var policyVersion: String

    public var itemID: String?
    public var kind: ItemKind?
    public var byteCount: Int?

    /// 内容识别码,是 HMAC 不是裸杂凑,做法见 `AuditLog.contentTag(for:)` 上面的说明。
    public var contentTag: String?

    public var sourceBundleID: String?
    public var sourceAppName: String?
    public var provenance: Provenance?

    /// 来源网址的主机名称,明文保留。主机本身通常不是秘密,而且它正是稽核时唯一问得出口的东西。
    public var sourceHost: String?
    /// 来源网址的查询字串的 HMAC。查询字串里长年住着 session token、一次性登入连结与病历编号,
    /// 明文抄进一份长期保存的档案等於把那些凭证的寿命从几分钟延长到几年,所以只留一个对得上、读不出的标记。
    public var queryTag: String?
    /// 视窗标题只留字数,不留内容。临床系统的视窗标题几乎必然含有病人姓名与健保号码,
    /// 那是这份纪录最不该顺手收藏的东西;字数足够回答「当时有没有标题」这种结构性问题。
    public var titleCharacterCount: Int?

    public var detectorHits: [AuditDetectorHit]
    public var destination: String?
    public var batchID: String?
    /// 给人看的补充说明。这里只准放代码与理由,绝对不准放任何一段剪贴内容。
    public var note: String?

    /// 前一笔纪录的杂凑。由 `AuditLog.append` 填,呼叫端不需要也不应该自己填。
    public internal(set) var prev: String
    /// 这一笔自己的杂凑。由 `AuditLog.append` 填。
    public internal(set) var recHash: String

    public init(
        id: String = UUID().uuidString,
        at: Date = Date(),
        event: EgressEvent,
        policyVersion: String,
        itemID: String? = nil,
        kind: ItemKind? = nil,
        byteCount: Int? = nil,
        contentTag: String? = nil,
        sourceBundleID: String? = nil,
        sourceAppName: String? = nil,
        provenance: Provenance? = nil,
        sourceHost: String? = nil,
        queryTag: String? = nil,
        titleCharacterCount: Int? = nil,
        detectorHits: [AuditDetectorHit] = [],
        destination: String? = nil,
        batchID: String? = nil,
        note: String? = nil
    ) {
        self.id = id
        // 截到毫秒:时间戳在档案里以 ISO 字串保存,毫秒以下的精度写出去就读不回来。
        // 先截掉,记忆体里的值与档案里的值才会永远一致,不会出现「刚写完再读就差了几微秒」的怪事。
        self.at = Date(timeIntervalSince1970: (at.timeIntervalSince1970 * 1000).rounded() / 1000)
        self.event = event
        self.policyVersion = policyVersion
        self.itemID = itemID
        self.kind = kind
        self.byteCount = byteCount
        self.contentTag = contentTag
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.provenance = provenance
        self.sourceHost = sourceHost
        self.queryTag = queryTag
        self.titleCharacterCount = titleCharacterCount
        self.detectorHits = detectorHits
        self.destination = destination
        self.batchID = batchID
        self.note = note
        self.prev = ""
        self.recHash = ""
    }
}

/// 跨月换档时写在新档第一行的锚点。
///
/// 没有它的话,每个月的档案就是一条各自独立的短链,把整个旧档删掉不会留下任何痕迹。
/// 有了锚点,新档的第一行就写着「上一个档案叫什么、最後一笔的杂凑是什么、一共几笔」,
/// 少一个档案立刻看得出来。它自己也参与杂凑链,所以锚点本身同样改不得。
public struct AuditAnchor: Codable, Sendable, Equatable {
    public var at: Date
    public var anchorOfFile: String
    public var finalHash: String
    public var recordCount: Int
    public internal(set) var prev: String
    public internal(set) var recHash: String
}

// MARK: - 稽核纪录本体

/// 只能往後附加的本机外送流水帐。
///
/// 执行绪:上传是在背景执行的,而面板上的查询发生在主执行绪,两边会同时进来,
/// 所以这里用一把锁把所有会碰到档案的进入点串起来。这不是效能敏感的路径——
/// 写入的频率是「一批一次」而不是「每个按键一次」,一把简单的锁换来的确定性划算得多。
public final class AuditLog: @unchecked Sendable {

    /// 报告的三个标题。公开出来是为了让画面那一层可以直接拿去做分节,不必再猜字串。
    public static let reportHeadingDeparted = "【第一节 确定离开过这台机器的】"
    public static let reportHeadingStayed = "【第二节 确定没有离开这台机器的】"
    public static let reportHeadingUndetermined = "【第三节 无法确定的】"

    /// 整条链的起点。第一笔纪录的 prev 就是它。
    static let genesisHash = String(repeating: "0", count: 64)

    public let directory: URL
    private let installKey: SymmetricKey
    private let lock = NSLock()
    /// 目前这条链最後一笔的杂凑。开档时从磁碟上重新读出来,不是从零开始。
    private var lastHash: String

    public init(directory: URL, installKey: Data) throws {
        guard !installKey.isEmpty else { throw AuditError.emptyInstallKey }
        self.directory = directory
        self.installKey = SymmetricKey(data: installKey)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        } catch {
            throw AuditError.cannotCreateDirectory(path: directory.path, reason: error.localizedDescription)
        }
        // 接续既有的链。若这里偷懒从 genesis 重新开始,每次程式重开都会产生一个断点,
        // 而断点跟「有人动过手脚」在链上长得一模一样,那样验证就永远验不出真正的问题。
        self.lastHash = try AuditLog.readLastHash(in: directory) ?? AuditLog.genesisHash
    }

    // MARK: 金钥与标记

    /// 产生一把本机安装金钥。呼叫端负责把它存进 Keychain,而且永远不要把它写进这份纪录里。
    public static func makeInstallKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // 系统乱数拿不到时用 UUID 补上。这不是等价的强度,但一把弱一点的金钥仍然远好过
            // 一个可预测的常数,更好过让整个稽核纪录因为拿不到乱数而完全不启动。
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        }
        return Data(bytes)
    }

    /// 把一段内容换成可比对、但读不回原文的识别码。
    ///
    /// 这里用 HMAC-SHA256 而不是直接 SHA256,理由是纯杂凑对短内容毫无保护力:
    /// 一组六位数验证码只有一百万种可能,一个健保号码、一个四位数 PIN、一句常见的短密码也差不多,
    /// 攻击者拿到档案之後在笔电上跑几秒钟就能把明文全部还原出来。
    /// 那会让这份为了「证明我们没有外泄」而存在的档案,自己变成一次外泄。
    /// 加上一把只存在这台机器上的安装金钥之後,没有金钥就连暴力枚举都无从开始;
    /// 同一台机器上同样的内容仍然算出同一个标记,所以「这一则是不是我上次挡掉的那一则」照样答得出来。
    public func contentTag(for data: Data) -> String {
        AuditLog.hex(HMAC<SHA256>.authenticationCode(for: data, using: installKey))
    }

    /// 文字内容的标记。先做 Unicode 正规化再去掉头尾空白,
    /// 这样同一段字被复制两次却差一个换行时,仍然认得出是同一件事。
    public func contentTag(forText text: String) -> String {
        let normalised = text.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return contentTag(for: Data(normalised.utf8))
    }

    /// 网址查询字串的标记。查询字串一律不留明文,理由写在 `AuditRecord.queryTag` 上面。
    public func queryTag(forQueryString query: String) -> String {
        contentTag(for: Data(query.precomposedStringWithCanonicalMapping.utf8))
    }

    /// 视窗标题只换成字数。传 nil 就回 nil,因为「没有标题」与「标题长度为零」是两件不同的事。
    public static func titleCharacterCount(_ title: String?) -> Int? {
        guard let title else { return nil }
        return title.count
    }

    // MARK: 附加

    /// 把一笔事件写进纪录。prev 与 recHash 由这里填,呼叫端填了也会被覆盖。
    public func append(_ record: AuditRecord) throws {
        lock.lock()
        defer { lock.unlock() }

        let fileName = AuditLog.fileName(for: record.at)
        let fileURL = directory.appendingPathComponent(fileName)

        // 换月:新档的第一行先写锚点,把旧档的最後杂凑与笔数钉在这里。
        if !FileManager.default.fileExists(atPath: fileURL.path), lastHash != AuditLog.genesisHash,
           let previous = try AuditLog.logFilesInOrder(in: directory).last {
            let previousCount = try AuditLog.lineCount(of: previous)
            var anchor = AuditAnchor(
                at: record.at,
                anchorOfFile: previous.lastPathComponent,
                finalHash: lastHash,
                recordCount: previousCount,
                prev: lastHash,
                recHash: ""
            )
            anchor.recHash = try chainHash(of: anchor, previous: lastHash)
            try AuditLog.appendLine(try AuditLog.encode(anchor), to: fileURL)
            lastHash = anchor.recHash
        }

        var stamped = record
        stamped.prev = lastHash
        stamped.recHash = try chainHash(of: stamped, previous: lastHash)
        try AuditLog.appendLine(try AuditLog.encode(stamped), to: fileURL)
        lastHash = stamped.recHash
    }

    // MARK: 验证

    /// 从头到尾重算整条杂凑链。
    ///
    /// 老实话必须讲在前面:这条链侦测得出竄改,防不住竄改。任何以这个使用者身分执行的程式
    /// 都可以把整个资料夹删掉、可以把最後十行砍掉再重算一条自洽的新链。
    /// 它挡得住的是「偷偷改掉其中一行、指望没人发现」,挡不住「有决心而且有权限的人」。
    /// 要防住後者需要把杂凑往外送到一个使用者动不了的地方,那是另一个决定,不是这个档案能给的。
    public func verifyChain() throws -> (recordCount: Int, isIntact: Bool, sentence: String) {
        lock.lock()
        defer { lock.unlock() }

        var running = AuditLog.genesisHash
        var recordCount = 0
        var anchorCount = 0

        for fileURL in try AuditLog.logFilesInOrder(in: directory) {
            let name = fileURL.lastPathComponent
            var lineNumber = 0
            for rawLine in try AuditLog.readLines(at: fileURL) {
                lineNumber += 1
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty { continue }

                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let storedHash = object["recHash"] as? String,
                      let storedPrev = object["prev"] as? String else {
                    return (recordCount, false, "外送稽核纪录在档案 \(name) 的第 \(lineNumber) 行读不出来:那一行不是一个带着 prev 与 recHash 的合法 JSON 物件,代表它在写进去之後被改坏或被别的东西覆盖过。这一行之後的每一笔都无法再验证,因为链已经从这里断掉了。")
                }
                if storedPrev != running {
                    return (recordCount, false, "外送稽核纪录在档案 \(name) 的第 \(lineNumber) 行接不上:那一行写着的前一笔杂凑,与实际上前一笔算出来的杂凑不一样,代表中间有纪录被抽掉、被插入或被重排过。这一行之後的每一笔都无法再验证。")
                }
                let computed = try chainHash(ofCanonical: AuditLog.canonicalBytes(of: object), previous: running)
                if computed != storedHash {
                    return (recordCount, false, "外送稽核纪录在档案 \(name) 的第 \(lineNumber) 行对不上:重新算出来的杂凑与那一行自己写着的杂凑不一样,代表这一行的内容在写进去之後被改动过。这一行之後的每一笔都无法再验证,因为链已经从这里断掉了。")
                }
                running = storedHash
                if object["event"] != nil { recordCount += 1 } else { anchorCount += 1 }
            }
        }

        if recordCount == 0 && anchorCount == 0 {
            return (0, true, "外送稽核纪录目前还是空的,没有任何一笔可以验证,所以也没有任何东西离开过这台机器的纪录。")
        }
        return (recordCount, true, "外送稽核纪录一共 \(recordCount) 笔事件与 \(anchorCount) 个跨月锚点,从第一笔到最後一笔的杂凑链完整接得上,没有任何一行被改过或被抽掉。必须同时讲清楚的是,这条链只查得出有人动过,挡不住有人动:任何以这个使用者身分执行的程式都可以把整个资料夹删掉,那时候连要比对的东西都不剩了。")
    }

    // MARK: 查询

    /// 依事件种类、起始时间与来源程式筛出纪录。三个条件都传 nil 就是全部。
    public func query(event: EgressEvent?, since: Date?, sourceBundleID: String?) throws -> [AuditRecord] {
        lock.lock()
        defer { lock.unlock() }
        return try allRecordsUnlocked().filter { record in
            if let event, record.event != event { return false }
            if let since, record.at < since { return false }
            if let sourceBundleID, record.sourceBundleID != sourceBundleID { return false }
            return true
        }
    }

    /// 一句可以直接贴到画面上的本月摘要。
    public func summarySentence() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        let records = try allRecordsUnlocked()
        guard let first = records.first else {
            return "这份外送稽核纪录目前还是空的,到目前为止没有任何一则内容离开过这台机器。"
        }
        let monthStart = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date.distantPast
        let thisMonth = records.filter { $0.at >= monthStart }
        let sent = thisMonth.filter { $0.event == .sent }
        let blocked = thisMonth.filter { $0.event == .blocked }.count
        return "这份外送稽核纪录从 \(AuditLog.dayText(first.at)) 开始记录,本月到目前为止有 \(sent.count) 则内容真的离开过这台机器、\(AuditLog.sizeText(sent)),另外有 \(blocked) 则命中封锁清单没有送出去但仍然留在本机,连同更早之前的纪录一共 \(records.count) 笔事件。"
    }

    // MARK: 老实的报告

    /// 回答「某个程式或某个网站的东西,到底有没有离开过这台机器」。
    ///
    /// 报告分成三节,而第三节才是这个功能真正的价值所在。
    /// 一份只会回答「没有」而不肯交代自己看不见什么的纪录,是在制造信心,
    /// 而且刚好制造在信心最昂贵的地方:一句没有根据的「没有外流」会让人停止追查、停止通报、停止补救。
    /// 所以这里宁可把每一个盲点都摊开来讲,让读的人自己决定这个「没有」值多少钱。
    public func report(sourceBundleID: String?, sourceHost: String?) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        let all = try allRecordsUnlocked()

        func matchesNarrow(_ record: AuditRecord) -> Bool {
            if let sourceBundleID, record.sourceBundleID != sourceBundleID { return false }
            if let sourceHost, record.sourceHost != sourceHost { return false }
            return true
        }
        // 第三节刻意只套程式的条件、不套网址的条件:用网址来问的时候,
        // 「根本没有记录到网址」的那几则正是最需要被看见的,拿网址去筛就等於把盲点筛掉藏起来。
        func matchesWide(_ record: AuditRecord) -> Bool {
            if let sourceBundleID, record.sourceBundleID != sourceBundleID { return false }
            return true
        }

        let subject: String
        switch (sourceBundleID, sourceHost) {
        case let (bundle?, host?): subject = "来源程式是 \(bundle) 而且来源网站是 \(host) 的内容"
        case let (bundle?, nil): subject = "来源程式是 \(bundle) 的内容"
        case let (nil, host?): subject = "来源网站是 \(host) 的内容"
        case (nil, nil): subject = "所有被记录过的内容"
        }

        var out = "以下是针对\(subject)所做的外送查询报告。请连着第三节一起读,只看前两节会得到一个比事实更肯定的结论。\n"

        // 第一节:确定离开过。
        let departed = all.filter { $0.event == .sent && matchesNarrow($0) }
        out += "\n\(AuditLog.reportHeadingDeparted)\n"
        if departed.isEmpty {
            out += "在这份纪录涵盖的范围内,没有任何一则符合条件的内容被确认送出去过。\n"
        } else {
            out += "一共有 \(departed.count) 则内容被确认送出而且对方回覆收到了,\(AuditLog.sizeText(departed)),最早的一则在 \(AuditLog.dayText(departed[0].at)),最晚的一则在 \(AuditLog.dayText(departed[departed.count - 1].at))。\n"
            out += AuditLog.itemLines(departed)
        }

        // 第二节:确定没有离开。failed 刻意不放在这里,理由见第三节。
        let stayed = all.filter { [.blocked, .cancelled, .expired].contains($0.event) && matchesNarrow($0) }
        out += "\n\(AuditLog.reportHeadingStayed)\n"
        if stayed.isEmpty {
            out += "在这份纪录涵盖的范围内,没有任何一则符合条件的内容被挡下、取消或放到过期。\n"
        } else {
            let blocked = stayed.filter { $0.event == .blocked }.count
            out += "一共有 \(stayed.count) 则内容没有送出去,其中 \(blocked) 则是命中封锁清单被挡下来的。要提醒的是,被挡下来只代表没有上传,这些内容仍然被抓下来了、仍然存在这台机器的本机历史里、仍然搜寻得到也仍然贴得出来。\n"
            out += AuditLog.itemLines(stayed)
        }

        // 第三节:无法确定的。
        let failed = all.filter { $0.event == .failed && matchesNarrow($0) }
        let noHost = all.filter { $0.event == .sent && $0.sourceHost == nil && matchesWide($0) }
        let weakProvenance = all.filter {
            matchesWide($0) && ($0.provenance == .low || $0.provenance == .unknown || $0.provenance == nil)
        }
        out += "\n\(AuditLog.reportHeadingUndetermined)\n"
        out += "一、送出失败的 \(failed.count) 则:失败只代表我们没有收到对方的确认,不代表位元组没有离开网路卡。连线在送出之後、回覆之前断掉的话,内容可能已经完整抵达对方,只是收据丢了,这两种情况在这一端看起来一模一样。\n"
        if !failed.isEmpty { out += AuditLog.itemLines(failed) }
        out += "二、送出去但没有记录到来源网址的 \(noHost.count) 则:这些是在这份纪录还不会抓网址的版本下送出的,或是当下就抓不到网址。用网站名称来问的时候,它们既不能算进「有」,也不能算进「没有」。\n"
        if !noHost.isEmpty { out += AuditLog.itemLines(noHost) }
        out += "三、来源可信度被记成 low 或 unknown 的 \(weakProvenance.count) 则:macOS 不会在剪贴板变动时通知我们是谁写的,来源永远是事後推断的。可信度低的那几则,写在纪录上的来源程式有可能根本就是错的,所以用程式名称做的筛选会连带算错。\n"
        if !weakProvenance.isEmpty { out += AuditLog.itemLines(weakProvenance) }
        out += "四、同一份内容被人从另一个程式重新复制一次再送出,这件事在结构上就不在这份纪录的视野里:那一次复制会被老实地记在另一个程式名下,你拿原本那个程式或那个网站来问,永远看不到它。内容识别码只在两次复制的位元组完全一样时才对得起来,而人重新选取一次的范围几乎不会完全一样。要回答这一类问题,得去看内容本身,不能只看来源。\n"
        return out
    }

    // MARK: - 内部:杂凑

    private func chainHash<T: Encodable>(of value: T, previous: String) throws -> String {
        let encoded = try AuditLog.encode(value)
        guard let object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw AuditError.cannotEncode(reason: "编出来的 JSON 不是一个物件")
        }
        return try chainHash(ofCanonical: AuditLog.canonicalBytes(of: object), previous: previous)
    }

    private func chainHash(ofCanonical canonical: Data, previous: String) throws -> String {
        var input = Data(previous.utf8)
        input.append(canonical)
        return AuditLog.hex(SHA256.hash(data: input))
    }

    /// 去掉 recHash 之後排好键、压成一行的正规化 JSON。
    ///
    /// 写入与验证两条路都收敛到这一个函式,而且都是拿「JSON 物件」当输入而不是拿 Swift 结构当输入。
    /// 这样一来验证时根本不必把那一行还原成结构再重新编码,也就不会因为日期格式、
    /// 栏位顺序或某个可选值的编码习惯改变,让一份原本好好的纪录突然被判成竄改。
    private static func canonicalBytes(of object: [String: Any]) throws -> Data {
        var copy = object
        copy.removeValue(forKey: "recHash")
        do {
            return try JSONSerialization.data(withJSONObject: copy, options: [.sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw AuditError.cannotEncode(reason: error.localizedDescription)
        }
    }

    private static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 内部:档案

    /// 一行一个 JSON 物件,档名 egress-YYYY-MM.jsonl,按本地月份换档。
    /// 用本地时区而不是 UTC,是因为「这个月送出了几则」这句话里的月份,指的是使用者日历上的月份。
    static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM"
        return "egress-\(formatter.string(from: date)).jsonl"
    }

    private static func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy 年 M 月 d 日 HH:mm"
        return formatter.string(from: date)
    }

    /// 讲清楚这一批一共多大。刻意不把没有记到大小的那几则当成零:
    /// 「合计 0 个位元组」跟「有几则连大小都没记到」是两个完全不同的事实,
    /// 把後者说成前者,就是在一份专门用来讲实话的报告里讲了一句假话。
    private static func sizeText(_ records: [AuditRecord]) -> String {
        let sized = records.filter { $0.byteCount != nil }
        let bytes = sized.reduce(0) { $0 + ($1.byteCount ?? 0) }
        if sized.count == records.count {
            return "合计 \(bytes) 个位元组"
        }
        return "其中 \(sized.count) 则有记下大小、合计 \(bytes) 个位元组,另外 \(records.count - sized.count) 则连大小都没有记到"
    }

    private static func itemLines(_ records: [AuditRecord]) -> String {
        let shown = records.prefix(20)
        var text = shown.map { record -> String in
            let item = record.itemID ?? record.id
            let app = record.sourceAppName ?? record.sourceBundleID ?? "来源不明"
            return "    · \(AuditLog.dayText(record.at))|\(item)|\(app)|规则版本 \(record.policyVersion)"
        }.joined(separator: "\n") + "\n"
        if records.count > shown.count {
            text += "    · 另外还有 \(records.count - shown.count) 则没有列出来,完整清单请直接看 \(records.count) 笔原始纪录档。\n"
        }
        return text
    }

    private static func logFilesInOrder(in directory: URL) throws -> [URL] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            throw AuditError.cannotRead(path: directory.path, reason: error.localizedDescription)
        }
        // 档名里的年月是零填补的,所以字典序就等於时间序,不必再解析日期。
        return names
            .filter { $0.hasPrefix("egress-") && $0.hasSuffix(".jsonl") }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }

    private static func readLines(at url: URL) throws -> [String] {
        // 一次读整个档案。稽核纪录是「一批一行」而不是「一个按键一行」,即使跑上好几年也就几百 KB,
        // 为了这个规模去写串流读取只会换来更多可能出错的地方。
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw AuditError.cannotRead(path: url.path, reason: error.localizedDescription)
        }
        return text.components(separatedBy: "\n")
    }

    private static func lineCount(of url: URL) throws -> Int {
        try readLines(at: url).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    private static func readLastHash(in directory: URL) throws -> String? {
        guard let last = try logFilesInOrder(in: directory).last else { return nil }
        for line in try readLines(at: last).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any],
                  let hash = object["recHash"] as? String else { return nil }
            return hash
        }
        return nil
    }

    private static func appendLine(_ line: Data, to url: URL) throws {
        var payload = line
        payload.append(0x0A)
        // O_APPEND 让核心保证每一次写入都接在档案尾端,这个描述子在语意上写不到已经写过的位置。
        // 「只能往後加」因此是作业系统在挡,不是靠我们自己记得先 seek 到尾巴。
        let descriptor = url.path.withCString { open($0, O_WRONLY | O_APPEND | O_CREAT, 0o600) }
        guard descriptor >= 0 else {
            throw AuditError.cannotWrite(path: url.path, reason: String(cString: strerror(errno)))
        }
        defer { close(descriptor) }
        // 档案若是先前就存在,O_CREAT 的权限参数不会生效,所以每次都再确认一次 0600:
        // 这份纪录里有来源程式与时间轴,同一台机器上的其他使用者不该读得到。
        _ = fchmod(descriptor, 0o600)

        var remaining = payload
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { buffer in
                write(descriptor, buffer.baseAddress, buffer.count)
            }
            guard written > 0 else {
                throw AuditError.cannotWrite(path: url.path, reason: String(cString: strerror(errno)))
            }
            remaining = remaining.dropFirst(written)
        }
    }

    /// 读出所有事件纪录,依时间排好。锚点不是事件,所以不会出现在结果里。
    private func allRecordsUnlocked() throws -> [AuditRecord] {
        var records: [AuditRecord] = []
        let decoder = AuditLog.decoder()
        for url in try AuditLog.logFilesInOrder(in: directory) {
            for line in try AuditLog.readLines(at: url) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                // 解不开的行在这里安静跳过:锚点本来就不是事件,而真正被改坏的行是 verifyChain 的职责。
                // 若查询遇到一行坏资料就整个丢例外,使用者会因为一行读不懂而看不到另外九百九十九行好资料。
                if let record = try? decoder.decode(AuditRecord.self, from: Data(trimmed.utf8)) {
                    records.append(record)
                }
            }
        }
        return records.sorted { $0.at < $1.at }
    }

    // MARK: - 内部:编解码

    /// 时间在档案里一律写成带毫秒的 UTC ISO 8601 字串。人看得懂,机器也不会因为时区而读错。
    private static let timeFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try encoder().encode(value)
        } catch {
            throw AuditError.cannotEncode(reason: error.localizedDescription)
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // 排序键值让同一笔纪录永远编成同一串位元组,这是杂凑链能成立的前提;
        // 不转义斜线则是为了让网址在档案里维持人看得懂的样子。绝对不能加 prettyPrinted,一行一笔是这个格式的定义。
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(AuditLog.timeFormatter.string(from: date))
        }
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = AuditLog.timeFormatter.date(from: text) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "时间栏位「\(text)」不是带毫秒的 ISO 8601 字串,这一行的时间读不回来。"
                )
            }
            return date
        }
        return decoder
    }
}
