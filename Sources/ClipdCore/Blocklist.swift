// clipd 的来源封锁清单:记住「哪些来源复制出来的内容,永远不准离开这台机器」。
//
// ================= 这份清单出厂时是空的,而且必须保持空的 =================
//
// 这不是还没做完,也不是谁忘了填。拥有者在看过完整分析之後亲自拍板:
// 剪贴板里绝大多数是自由文字,而自由文字上真正管用的控制只有两种——
// 一种是尊重来源程式自己贴上的保密标记,另一种就是这份「按来源封锁」的清单。
// 正因为它是仅有的两道防线之一,拥有者决定亲手一条一条决定要挡谁,
// 而不是接受任何人预先替他挑好的名单;别人挑的名单最大的害处,
// 是让人误以为自己已经被保护好了,於是不再去看这份清单到底挡了什么。
//
// 所以请记住:任何人都不准在这里偷偷塞预设值。不准预先加密码管理器,
// 不准预先加银行或医疗网域,不准预先加任何「大家都会挡的」程式或资料夹。
// 要挡什么,一律由拥有者自己在介面上加进来。
// 如果你正想加一条「这个一定要挡吧」的预设规则,请先去问拥有者,不要直接写进来。
//
// 另外两件刻意没做的事,同样是拥有者拍板过的,不要好心「补」回来:
// 一、这份清单只有一层意思,就是「不要上传」。被挡下来的内容照样会被抓取、
//     照样存在本机、照样搜寻得到、照样贴得出来,不存在「连抓都不抓」那一层。
// 二、判断不出来源是哪个程式时,一律当成普通内容照常上传,
//     不会因为「不确定」就自动升级成封锁——不确定不是封锁的理由。
//
// 剪贴板上的保密标记(org.nspasteboard.ConcealedType 那一组)不归这个档案管,
// 那是来源程式自己宣告「我这份内容是机密」,检查写在 PasteboardWatcher.swift 里,
// 这里不重复实作一份,免得两边日後各自演化、行为对不起来。
import Foundation

// MARK: - 错误型别

/// 封锁清单往外丢的错误。每一句都写成完整的句子,因为它们会直接出现在使用者眼前,
/// 而使用者需要知道的是「发生了什么事、我现在能怎么办」,不是一个错误代号。
public enum BlocklistError: Error, CustomStringConvertible {
    case cannotCreateDirectory(path: String, reason: String)
    case cannotRead(path: String, reason: String)
    case cannotWrite(path: String, reason: String)
    case cannotDecode(path: String, reason: String)
    case emptyPattern(kind: BlockRuleKind)
    case duplicateRule(kind: BlockRuleKind, pattern: String)
    case ruleNotFound(id: String)

    public var description: String {
        switch self {
        case let .cannotCreateDirectory(path, reason):
            return "无法建立存放封锁清单的资料夹 \(path),原因是 \(reason)。"
        case let .cannotRead(path, reason):
            return "无法读取封锁清单档 \(path),原因是 \(reason)。"
        case let .cannotWrite(path, reason):
            return "无法写入封锁清单档 \(path),原因是 \(reason),这次的修改没有存下来,清单还是原来的样子。"
        case let .cannotDecode(path, reason):
            return "封锁清单档 \(path) 的内容无法解读,原因是 \(reason);在你把它修好之前,程式不会自作主张把它当成空清单,因为那等於静悄悄地把你设好的封锁全部解除。"
        case let .emptyPattern(kind):
            return "「\(kind.displayName)」这一类的规则不能留空白,因为空白的比对内容会把每一则内容都当成命中,等於让整台机器停止上传。"
        case let .duplicateRule(kind, pattern):
            return "清单里已经有一条同样是「\(kind.displayName)」而且比对内容是「\(pattern)」的规则了,重复加一次不会挡得更严,只会让你之後看不懂哪一条在生效。"
        case let .ruleNotFound(id):
            return "找不到识别码是 \(id) 的封锁规则,它可能已经在别的地方被删掉了,请重新整理一次清单再试。"
        }
    }
}

// MARK: - 资料模型

/// 一条封锁规则要拿什么东西来比对。
///
/// 这四种刻意都属於「来源」而不是「内容」:比对内容(例如看起来像不像信用卡号)
/// 在自由文字上几乎一定会误判,而来源是明确的事实,对就是对、错就是错。
public enum BlockRuleKind: String, Codable, Sendable, CaseIterable {
    case bundleIdentifier    // 来源程式的套件识别码,例如 com.apple.Notes,必须一字不差
    case appNameFragment     // 来源程式名称里的一小段字,不分大小写
    case urlHost             // 来源网址的主机名称,本身与其子网域都算
    case pathPrefix          // 档案路径的开头,支援开头的波浪号

    /// 给介面直接显示用的中文名称。
    public var displayName: String {
        switch self {
        case .bundleIdentifier: return "来源程式的套件识别码"
        case .appNameFragment: return "来源程式名称的片段"
        case .urlHost: return "来源网址的主机名称"
        case .pathPrefix: return "档案路径的开头"
        }
    }

    /// 给介面当输入提示用的一句完整说明,让人知道这一栏该填什么、会挡到多广。
    public var hintSentence: String {
        switch self {
        case .bundleIdentifier:
            return "请填入程式的套件识别码,例如 com.apple.Notes,比对时必须一字不差,所以不会误伤名字相近的其他程式。"
        case .appNameFragment:
            return "请填入程式名称里的一小段字,例如「1Password」,比对时不分大小写,只要程式名称里出现这一段就会被挡下。"
        case .urlHost:
            return "请填入网址的主机名称,例如 example.com,它自己以及它底下的子网域都会被挡下,但名字只是长得像的 notexample.com 不会。"
        case .pathPrefix:
            return "请填入档案路径的开头,例如 ~/Documents/机密,开头的波浪号会自动换成你的家目录,凡是从这个位置底下来的档案都会被挡下。"
        }
    }
}

/// 一条封锁规则。`note` 是给拥有者自己写理由的地方,因为半年後回头看清单时,
/// 「我当初为什么要挡这个」比「我挡了什么」更难想起来。
public struct BlockRule: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: BlockRuleKind
    public var pattern: String
    public var note: String
    public var addedAt: Date
    public var isEnabled: Bool

    /// 预设是启用的,因为拥有者在介面上亲手打完一条规则再按下确定,意思就是「现在开始挡」;
    /// 唯一刻意建成停用的是 `Blocklist.suggestingRule(for:)` 产生的草稿,理由写在那个方法上。
    public init(
        id: String = UUID().uuidString,
        kind: BlockRuleKind,
        pattern: String,
        note: String = "",
        addedAt: Date = Date(),
        isEnabled: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.pattern = pattern
        self.note = note
        self.addedAt = addedAt
        self.isEnabled = isEnabled
    }
}

/// 一次判断的结果。`sentence` 会原封不动地显示在介面上,也会原封不动地写进稽核纪录,
/// 所以它必须是一句人看得懂的完整中文句子,而不是一个只有工程师看得懂的代号。
public struct BlockDecision: Sendable {
    public let isBlocked: Bool
    public let matchedRule: BlockRule?
    public let sentence: String

    public init(isBlocked: Bool, matchedRule: BlockRule?, sentence: String) {
        self.isBlocked = isBlocked
        self.matchedRule = matchedRule
        self.sentence = sentence
    }
}

// MARK: - 封锁清单

/// 拥有者亲手维护的来源封锁清单,持久化成一份排版过、人可以直接开来改的 JSON。
///
/// 执行绪约定:这个型别自己拿一把锁,因为它的两端天生不在同一条执行绪上——
/// 介面在主执行绪增删规则,而 `evaluate` 会在上传前的批次组装路径上被呼叫,
/// 那条路径不保证在主执行绪。锁只保护这个物件自己的规则阵列,不保护档案系统。
public final class Blocklist {

    /// 清单档的位置。公开出来是为了让设定画面可以「在 Finder 中显示」,
    /// 让拥有者自己去看、去改、去备份——这份清单本来就该是他看得见的东西。
    public let fileURL: URL

    private let lock = NSLock()
    private var storage: [BlockRule] = []

    /// 目前的规则,依加入的先後顺序排列。对外唯读,任何修改都必须走下面那几个会落地的方法,
    /// 免得记忆体里改了、档案里没改,重开程式封锁就悄悄失效。
    public private(set) var rules: [BlockRule] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storage = newValue
        }
    }

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        try Blocklist.ensureDirectory(fileURL.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try reload()
        } else {
            // 第一次执行就是一份空清单,而且要真的写到磁碟上。
            // 写出来的用意是让拥有者立刻找得到这个档案、看得出它确实是空的,
            // 而不是怀疑程式偷偷在别处藏了一份预设名单。
            storage = []
            try Blocklist.persist([], to: fileURL)
        }
    }

    // MARK: 读写

    /// 从磁碟重新读一次。拥有者用编辑器直接改完清单之後,靠这个方法让程式跟上。
    public func reload() throws {
        let decoded = try Blocklist.load(from: fileURL)
        rules = decoded
    }

    /// 加一条规则。比对内容留空会被挡下来,重复的规则也会被挡下来,理由写在错误说明里。
    public func add(_ rule: BlockRule) throws {
        var normalized = rule
        normalized.pattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.pattern.isEmpty else { throw BlocklistError.emptyPattern(kind: rule.kind) }
        // 时间刻意砍到整秒。档案里的时间写成人读得懂的 ISO 8601,而那个格式只写到秒;
        // 若记忆体里留着毫秒以下的零头,同一条规则「刚加进去的样子」与「从档案读回来的样子」
        // 就会比不相等,之後任何拿规则做比对的程式码都会莫名其妙地失败。
        normalized.addedAt = Date(timeIntervalSince1970: normalized.addedAt.timeIntervalSince1970.rounded(.down))

        let incoming = Blocklist.comparableValue(normalized.pattern, kind: normalized.kind)
        try mutate { current in
            let clash = current.contains { existing in
                existing.kind == normalized.kind
                    && Blocklist.comparableValue(existing.pattern, kind: existing.kind) == incoming
            }
            if clash {
                throw BlocklistError.duplicateRule(kind: normalized.kind, pattern: normalized.pattern)
            }
            current.append(normalized)
        }
    }

    /// 删掉一条规则。找不到这个识别码时什么都不做也不报错,
    /// 因为呼叫者要的结果是「这一条不要存在」,而它本来就不存在,目的已经达成了。
    public func remove(id: String) throws {
        guard rules.contains(where: { $0.id == id }) else { return }
        try mutate { current in
            current.removeAll { $0.id == id }
        }
    }

    /// 暂时停用或重新启用一条规则。这里找不到识别码就要报错,不能默默不做:
    /// 使用者按下的是一个开关,画面上开关已经动了,若後端其实没动,他会以为已经挡住了。
    public func setEnabled(_ on: Bool, id: String) throws {
        try mutate { current in
            guard let index = current.firstIndex(where: { $0.id == id }) else {
                throw BlocklistError.ruleNotFound(id: id)
            }
            current[index].isEnabled = on
        }
    }

    // MARK: 判断

    /// 判断这一则内容可不可以上传。
    ///
    /// 比对顺序是固定的:先套件识别码、再程式名称片段、再网址主机、最後档案路径。
    /// 顺序固定的用意是让结果可以重现——同一则内容在两台机器上要命中同一条规则,
    /// 否则稽核纪录里写的「因为某某规则被挡下」就没有意义了。
    ///
    /// 判断不出来源(`sourceBundleID` 与 `sourceAppName` 都是空的)时不会命中任何规则,
    /// 也就是照常上传。这是拥有者明确拍板过的:不确定不是封锁的理由。
    public func evaluate(item: ClipItem, sourceURLHost: String?, filePaths: [String]) -> BlockDecision {
        // 停用的规则一律当成不存在,这样拥有者可以先关掉一条看看影响,而不必把它删掉重打。
        // 比对内容是空白的也一律略过:空白片段会命中每一则内容,
        // 那绝对不是有人把栏位留空时想要的结果。`add` 已经挡掉空白,
        // 这道防线是为了「有人直接用编辑器改坏了档案」那种情形。
        let active = rules.filter { $0.isEnabled && !$0.pattern.isEmpty }

        for rule in active where rule.kind == .bundleIdentifier {
            // 套件识别码是机器给的精确身分,所以一字不差地比。
            // 若这里改成模糊比对,com.example.notes 会连带挡到 com.example.notes-helper,
            // 而那是另一个程式,拥有者从来没有说要挡它。
            if let bundleID = item.sourceBundleID, bundleID == rule.pattern {
                return Blocklist.blockedDecision(rule: rule, matchedValue: bundleID)
            }
        }

        for rule in active where rule.kind == .appNameFragment {
            // 程式名称是人取的、还会随语言变,所以这里用「包含且不分大小写」,
            // 让拥有者可以只记一个关键字,而不必抄一串完整名称。
            guard let appName = item.sourceAppName else { continue }
            if appName.lowercased().contains(rule.pattern.lowercased()) {
                return Blocklist.blockedDecision(rule: rule, matchedValue: appName)
            }
        }

        if let rawHost = sourceURLHost {
            let host = Blocklist.normalizeHost(rawHost)
            for rule in active where rule.kind == .urlHost {
                let pattern = Blocklist.normalizeHost(rule.pattern)
                guard !pattern.isEmpty, !host.isEmpty else { continue }
                // 比的是「等於」或「以一个点接在後面」,不是单纯的字尾比对。
                // 单纯比字尾的话,example.com 这条规则会连 notexample.com 一起挡掉,
                // 那是一个完全不相干的网域,挡错了拥有者根本不会发现。
                if host == pattern || host.hasSuffix("." + pattern) {
                    return Blocklist.blockedDecision(rule: rule, matchedValue: host)
                }
            }
        }

        for rule in active where rule.kind == .pathPrefix {
            // 两边都用同一个方法展开波浪号,所以就算这个程式日後被沙盒关起来、
            // 家目录变成容器路径,规则与实际档案路径还是会一起变,不会一边变一边没变。
            let pattern = (rule.pattern as NSString).expandingTildeInPath
            guard !pattern.isEmpty else { continue }
            for path in filePaths {
                let expanded = (path as NSString).expandingTildeInPath
                // 这里是单纯的开头比对。它可能稍微挡宽一点(例如「~/机密」也会挡到「~/机密备份」),
                // 而挡宽的後果是内容留在本机,挡窄的後果是内容外流,所以刻意往宽的那边靠;
                // 想要精确挡到某个资料夹的人,把结尾的斜线一起写进规则即可。
                if expanded.hasPrefix(pattern) {
                    return Blocklist.blockedDecision(rule: rule, matchedValue: expanded)
                }
            }
        }

        return BlockDecision(isBlocked: false, matchedRule: nil, sentence: allowedSentence(activeCount: active.count))
    }

    /// 一句话说明这份清单现在长什么样子,给设定画面的标题列用。
    public var summarySentence: String {
        let all = rules
        guard !all.isEmpty else {
            // 空清单要讲得直白,不能只写「没有规则」。使用者需要立刻知道的是
            // 「所以现在什么都没被挡」,以及「这是刻意留白、要挡谁由你决定」。
            return "来源封锁清单目前是空的,所以现在没有任何来源因为这份清单而被挡下上传;这份清单从一开始就刻意留白,要挡哪些程式、网站或资料夹,由你自己决定并亲手加进来。"
        }
        let enabled = all.filter { $0.isEnabled }.count
        let disabled = all.count - enabled
        return "来源封锁清单里一共有 \(all.count) 条规则,其中 \(enabled) 条正在生效、\(disabled) 条被你暂时停用;凡是命中生效规则的内容,都只会留在这台机器上,不会被上传。"
    }

    // MARK: 给介面的便利方法

    /// 由一则内容产生一张「以後都别上传这个程式的东西」的规则草稿,给面板做一键封锁用。
    ///
    /// 刻意建成停用状态,而且刻意不帮忙存档:这个方法只负责把表单先填好,
    /// 要不要真的变成一条生效的规则,必须由拥有者自己按下确定,再由呼叫端把 `isEnabled`
    /// 改成 true 并交给 `add` 落地。我们绝不代替拥有者往他的清单里加东西,
    /// 因为一份他没有亲手同意过的清单,他就不会再相信清单上的任何一条。
    public static func suggestingRule(for item: ClipItem) -> BlockRule {
        let bundleID = (item.sourceBundleID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let note: String
        if bundleID.isEmpty {
            // 来源判断不出来的情形照样回传一张草稿,只是比对内容是空的。
            // 呼叫端应该看 `pattern.isEmpty` 决定要不要把那个一键封锁的按钮变灰,
            // 因为空白的规则会被 `add` 直接拒绝。
            note = "这一则内容判断不出是从哪一个程式复制来的,所以这张草稿没有可以比对的对象;请你自己填上要封锁的套件识别码,或改用别种类型的规则。"
        } else {
            let appName = item.sourceAppName ?? bundleID
            note = "这张草稿是从「\(appName)」复制的一则内容产生的;启用之後,凡是从这个程式复制的内容都只会留在本机,不会被上传。"
        }
        return BlockRule(kind: .bundleIdentifier, pattern: bundleID, note: note, isEnabled: false)
    }

    // MARK: 句子

    private static func blockedDecision(rule: BlockRule, matchedValue: String) -> BlockDecision {
        var sentence = "这一则内容命中了你亲手加进封锁清单的规则「\(rule.kind.displayName):\(rule.pattern)」"
            + "(实际比对到的是「\(matchedValue)」),所以它不会被上传,只会留在这台机器上,"
            + "而且照样搜寻得到、照样贴得出来。"
        let note = rule.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            sentence += "你当初为这条规则写下的理由是:\(note)"
        }
        return BlockDecision(isBlocked: true, matchedRule: rule, sentence: sentence)
    }

    private func allowedSentence(activeCount: Int) -> String {
        if activeCount == 0 {
            return "封锁清单里目前没有任何生效中的规则,所以没有东西挡着这一则内容,它会照常被上传。"
        }
        return "封锁清单里的 \(activeCount) 条生效规则都没有命中这一则内容,所以它会照常被上传。"
    }

    // MARK: 比对用的正规化

    /// 把主机名称整理成可以互相比较的样子。
    ///
    /// 百分号转义刻意只解一次。解到不能再解会让 %252e 这种双层编码在多解一轮之後变成一个点,
    /// 於是有人可以拿一个看起来不像子网域的字串骗过比对;只解一次,进来什么样就是什么样。
    private static func normalizeHost(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 先解转义再转小写,是为了让 %2E 这种被编码起来的点也能被後面的去尾点处理到。
        if let decoded = host.removingPercentEncoding {
            host = decoded
        }
        host = host.lowercased()
        // 网域的完整写法结尾会有一个代表根网域的点,example.com. 与 example.com 是同一个地方,
        // 不去掉的话两边就永远比不相等。
        while host.hasSuffix(".") {
            host.removeLast()
        }
        return host
    }

    /// 判断两条规则算不算重复时,拿来比较的那个值。每一种规则的「一样」定义不同,
    /// 例如程式名称片段不分大小写,所以 1Password 与 1password 是同一条。
    private static func comparableValue(_ pattern: String, kind: BlockRuleKind) -> String {
        switch kind {
        case .bundleIdentifier:
            return pattern
        case .appNameFragment:
            return pattern.lowercased()
        case .urlHost:
            return normalizeHost(pattern)
        case .pathPrefix:
            return (pattern as NSString).expandingTildeInPath
        }
    }

    // MARK: 落地

    /// 所有会改动规则的动作都走这里:在锁里面改、立刻落地,写档失败就整个退回去。
    /// 不退回去的话,画面上看起来加成功了,重开程式却发现没加到,
    /// 而这份清单的失误方向偏偏是「以为挡住了、其实没挡」,那是最不能接受的一种。
    private func mutate(_ change: (inout [BlockRule]) throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        let previous = storage
        try change(&storage)
        do {
            try Blocklist.persist(storage, to: fileURL)
        } catch {
            storage = previous
            throw error
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // 排版过、栏位顺序固定,是因为这份档案本来就设计成拥有者可以自己开来读、自己改、也丢得进版本控制。
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // 时间写成 ISO 8601 而不是预设的浮点秒数,因为「2026-07-25T09:30:00Z」人读得懂,
        // 「775129800.0」人读不懂,而这份档案的第一读者就是人。
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        // 内建的 iso8601 策略只认得不带小数秒的写法,别的工具或拥有者自己手打的时间
        // 很可能带着小数秒,一旦解不开整份清单都会被判定为坏档、整个封锁功能停摆,
        // 而那个後果远比「多写几行去多试一种格式」严重,所以这里两种写法都收。
        //
        // 两个格式器都在闭包里现做,不放成共用的静态属性:格式器不是执行绪安全的型别,
        // 共用一份等於在多执行绪读档时埋一颗随机崩溃的地雷,而这里一次只解几十个日期,
        // 多配置几次的代价小到量不出来。
        decoder.dateDecodingStrategy = .custom { innerDecoder in
            let container = try innerDecoder.singleValueContainer()
            let text = try container.decode(String.self)

            let plain = ISO8601DateFormatter()
            if let date = plain.date(from: text) { return date }

            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFraction.date(from: text) { return date }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "时间「\(text)」不是可以辨认的 ISO 8601 写法,正确的样子像 2026-07-25T09:30:00Z。"
            )
        }
        return decoder
    }

    private static func load(from fileURL: URL) throws -> [BlockRule] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw BlocklistError.cannotRead(path: fileURL.path, reason: error.localizedDescription)
        }
        do {
            return try makeDecoder().decode([BlockRule].self, from: data)
        } catch {
            // 这里绝对不能默默改用空清单:那等於在拥有者不知情的情况下把他设的封锁全部解除,
            // 而他会以为自己还被挡着。宁可整个功能停下来叫他去修那个多打的逗号。
            throw BlocklistError.cannotDecode(path: fileURL.path, reason: error.localizedDescription)
        }
    }

    private static func persist(_ rules: [BlockRule], to fileURL: URL) throws {
        let data: Data
        do {
            data = try makeEncoder().encode(rules)
        } catch {
            throw BlocklistError.cannotWrite(path: fileURL.path, reason: error.localizedDescription)
        }

        let directory = fileURL.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        let manager = FileManager.default

        // 先用 0600 建立空档再写内容,而不是写完才改权限:若先写後改,中间那一瞬间档案是预设的 0644,
        // 同一台机器上的其他使用者读得到这份清单,而清单本身就透露了拥有者认为哪些程式与网站敏感。
        guard manager.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
        ) else {
            throw BlocklistError.cannotWrite(path: temporary.path, reason: "系统不让我们建立暂存档")
        }

        do {
            try data.write(to: temporary)
            if manager.fileExists(atPath: fileURL.path) {
                // 换名是同一个档案系统上的原子操作,所以同时在读的人只会看到「完整的旧清单」
                // 或「完整的新清单」,不会读到写到一半、少了几条规则的半截 JSON。
                _ = try manager.replaceItemAt(fileURL, withItemAt: temporary)
                // replaceItemAt 有机会沿用旧档的权限,所以换完再确认一次 0600。
                try manager.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o600))],
                    ofItemAtPath: fileURL.path
                )
            } else {
                // 目标还不存在时 replaceItemAt 会失败,第一次写档走搬移,权限直接沿用暂存档的 0600。
                try manager.moveItem(at: temporary, to: fileURL)
            }
        } catch {
            try? manager.removeItem(at: temporary)
            throw BlocklistError.cannotWrite(path: fileURL.path, reason: error.localizedDescription)
        }
    }

    private static func ensureDirectory(_ directory: URL) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw BlocklistError.cannotCreateDirectory(path: directory.path, reason: error.localizedDescription)
        }
    }
}
