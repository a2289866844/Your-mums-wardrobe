// clipd 的出境闸门(EgressGate):一则内容已经被抓下来、也已经存进本机之後,
// 这个档案回答下一个、而且是唯一一个真正危险的问题——它可不可以离开这台机器。
//
// 为什麽要独立成一个档案:抓取、储存、搜寻、贴回去这几件事全都只发生在本机,做错了顶多是不好用;
// 上云做错一次就是资料已经在别人手上,收不回来。把这个判断集中在一个地方,
// 才有可能一眼看完全部的放行条件,也才有可能替它写出完整的回归测试。
//
// 与邻居档案的契约(如果编译不过,请先看这一段):
//   * Blocklist.evaluate(item:sourceURLHost:filePaths:) -> BlockDecision  (来自 Blocklist.swift)
//   * BlockDecision 的 isBlocked / matchedRule / sentence 三个栏位          (来自 Blocklist.swift)
//   * Detectors.scan(_ text: String) -> [DetectorHit]                     (来自 Detectors.swift)
//   * DetectorHit 的 detectorID / label 两个栏位                           (来自 Detectors.swift)
// 除了这四项以外,本档案不碰那几个档案的任何成员。
//
// 执行绪约定:评估本身是一个纯粹的判断,不改任何状态,所以刻意不加锁;
// 唯一的可变状态是 policy,而它只会在设定画面被改,也就是只会在主执行绪被改。
// 若哪天有人要从背景执行绪改 policy,请自己排回主执行绪,不要在这里偷偷加锁假装安全。
import Foundation

// MARK: - 判决

/// 出境闸门对一则内容的判决。
///
/// 三种判决刻意分开,因为它们对上传队列的意义完全不同:
/// `allow` 是「正常放行,只是先等一段可以反悔的时间」;
/// `hold` 是「也会放行,但因为某个具体理由而被特别延长」;
/// `block` 是「永远不会送出去」。
///
/// 注意 `allow` 底下其实也有等待时间,只是那段时间写在 `EgressDecision.holdSeconds` 里而不是写在这里。
/// 这样上传队列不管拿到哪一种判决,都只要读同一个 `holdSeconds` 栏位就好,不必对判决做 switch。
public enum EgressVerdict: Sendable, Equatable {
    case allow
    case hold(TimeInterval)
    case block
}

// MARK: - 政策

/// 出境闸门的可调参数。这些值会随着使用者在设定画面上的操作而改变,所以做成 struct 而不是常数。
public struct EgressPolicy: Sendable {

    /// 什麽都没命中的一般内容,在上传前先扣住多久。
    public var normalHoldSeconds: TimeInterval

    /// 有理由怀疑、但还不足以直接挡下来的内容,扣住多久。
    public var suspiciousHoldSeconds: TimeInterval

    /// 图片(尤其是截图)扣住多久。
    public var screenshotHoldSeconds: TimeInterval

    /// 上云总开关。使用者把它关掉,就代表「现在什麽都不要送出去」,程式不该替他判断哪些内容其实无所谓。
    public var isKillSwitchOn: Bool

    /// 诊间模式。使用者在看诊,萤幕上出现的东西预设都当成病人资料。
    public var isClinicModeOn: Bool

    public init(
        normalHoldSeconds: TimeInterval,
        suspiciousHoldSeconds: TimeInterval,
        screenshotHoldSeconds: TimeInterval,
        isKillSwitchOn: Bool = false,
        isClinicModeOn: Bool = false
    ) {
        self.normalHoldSeconds = normalHoldSeconds
        self.suspiciousHoldSeconds = suspiciousHoldSeconds
        self.screenshotHoldSeconds = screenshotHoldSeconds
        self.isKillSwitchOn = isKillSwitchOn
        self.isClinicModeOn = isClinicModeOn
    }

    /// 预设政策:一般 60 秒、可疑 10 分钟、图片 30 分钟。
    ///
    /// 这三个数字刻意比信箱的「收回寄出」长很多,理由是两边的情境根本不一样。
    /// 信箱给的是 5 到 10 秒,但那是使用者刚刚盯着萤幕、亲手按下寄出之後的 5 到 10 秒——
    /// 他人就在现场,眼睛还停在那封信上,来得及反悔。
    /// 我们这里的上传不是使用者按的,是他「复制了一段文字」这个动作顺带触发的;
    /// 复制并不是一个「我要上传」的决定,而且这个时候他通常已经切到另一个程式去做别的事了。
    /// 在这种情境下,十秒钟的倒数等於没有任何人会看到它,那个撤回窗口只是写在规格书上好看而已。
    /// 所以一般内容订在 60 秒:久到使用者从别的程式回过神来还追得上,又不至於让上传永远塞着。
    public static let `default` = EgressPolicy(
        normalHoldSeconds: 60,
        suspiciousHoldSeconds: 10 * 60,
        screenshotHoldSeconds: 30 * 60
    )
}

// MARK: - 决定

/// 一次评估的完整结果。除了判决本身,还带着「为什麽」,而且那个为什麽是一句人看得懂的完整句子。
///
/// 这里刻意不只回传一个 enum:出境判断出错的时候,使用者需要的不是一个代号,
/// 而是「这一则为什麽没上去」或「这一则为什麽上去了」的答案,而且他要能自己看懂,不必来问工程师。
public struct EgressDecision: Sendable {

    /// 放行、延长扣住、还是永不送出。
    public let verdict: EgressVerdict

    /// 一句写给人看的完整中文句子,说明这个判决是怎麽来的。这句话会直接出现在使用者眼前。
    public let reasonSentence: String

    /// 内容侦测器这一次命中了哪些东西。没有走到侦测这一步(例如总开关关着)时是空阵列。
    public let detectorHits: [DetectorHit]

    /// 命中的是哪一条不上传规则。只有走名单那一条路才会有值。
    public let blockedByRule: BlockRule?

    /// 这一则在实际送出去之前要等多久。被挡下来的一律是 0,因为它根本不会送。
    ///
    /// 不管判决是哪一种,上传队列都只要读这一个栏位就知道该等多久,不必对 `verdict` 做 switch。
    public let holdSeconds: TimeInterval

    public init(
        verdict: EgressVerdict,
        reasonSentence: String,
        detectorHits: [DetectorHit] = [],
        blockedByRule: BlockRule? = nil,
        holdSeconds: TimeInterval = 0
    ) {
        self.verdict = verdict
        self.reasonSentence = reasonSentence
        self.detectorHits = detectorHits
        self.blockedByRule = blockedByRule
        self.holdSeconds = holdSeconds
    }
}

// MARK: - 名单比对的最小介面

/// 出境闸门真正需要名单做的事,就只有这一件:拿来源资讯去问「有没有命中哪一条规则」。
///
/// 把它抽成一个只有一个方法的介面,是为了让这个档案的测试不必去生出一个真的 Blocklist——
/// 真的 Blocklist 要读写磁碟上的设定档,而磁碟状态一旦渗进测试,失败原因就会变得很难查。
/// 生产程式照样直接传真的 Blocklist 进来,见下面那个 convenience init。
public protocol BlockRuleMatching {
    /// 判断这一则内容有没有命中清单上任何一条生效中的规则。
    func evaluate(item: ClipItem, sourceURLHost: String?, filePaths: [String]) -> BlockDecision
}

/// 让真正的名单满足上面那个介面。这一行是本档案与 Blocklist.swift 之间唯一的型别层耦合。
extension Blocklist: BlockRuleMatching {}

// MARK: - 出境闸门

/// 依序检查一连串条件,第一个能下结论的条件就是答案。
///
/// 顺序是「最便宜的先问」,而不是「最严格的先问」:
/// 总开关是一个布林值,名单是几十次字串比对,侦测器要扫过整段文字,图片判断则只看一个 enum。
/// 既然任何一关挡下来的结果都一样是不上传,那就没有理由为了一个已经确定挡掉的项目再去扫一遍文字。
public final class EgressGate {

    /// 政策是可变的,因为使用者随时会去设定画面把总开关或诊间模式打开。
    public var policy: EgressPolicy

    private let matcher: any BlockRuleMatching
    private let scan: (String) -> [DetectorHit]

    /// 生产用的进入点:直接把真正的名单交进来。
    public convenience init(blocklist: Blocklist, policy: EgressPolicy = .default) {
        self.init(matcher: blocklist, policy: policy)
    }

    /// 测试与替换用的进入点。侦测器预设就是真正的 `Detectors.scan`,
    /// 所以生产路径上没有人需要传这个参数,也就不会有人不小心把侦测器换掉却没人发现。
    public init(
        matcher: any BlockRuleMatching,
        policy: EgressPolicy = .default,
        scan: @escaping (String) -> [DetectorHit] = Detectors.scan
    ) {
        self.matcher = matcher
        self.policy = policy
        self.scan = scan
    }

    // MARK: 判断链

    /// 判断一则内容可不可以离开这台机器。
    ///
    /// - Parameters:
    ///   - item: 已经抓下来、也已经存进本机的那一则内容。
    ///   - ocrWasLowConfidence: 这一则的文字辨识结果可不可靠;没有做过文字辨识时传 false。
    ///   - sourceURLHost: 来源网址的主机名称,判断不出来时传 nil。
    ///   - filePaths: 这一则牵涉到的档案路径,没有就传空阵列。
    public func evaluate(
        item: ClipItem,
        ocrWasLowConfidence: Bool = false,
        sourceURLHost: String? = nil,
        filePaths: [String] = []
    ) -> EgressDecision {

        // 第 0 关:使用者自己按下的紧急停止。
        // 这两个开关是使用者当下的明确意思表示,不需要程式再帮他斟酌哪些内容其实无所谓;
        // 而且它们最便宜,读两个布林值就有答案,所以放在最前面。
        if policy.isKillSwitchOn {
            return EgressDecision(
                verdict: .block,
                reasonSentence: "上云总开关目前是关着的,所以这一则不会离开这台机器;这是你自己按下的紧急停止,程式不会替你判断哪些内容其实无所谓。它照样会留在本机,搜寻得到,也贴得回去。"
            )
        }
        if policy.isClinicModeOn {
            return EgressDecision(
                verdict: .block,
                reasonSentence: "诊间模式目前是开着的,所以这一则不会离开这台机器;在诊间里出现在萤幕上的东西一律先当成病人资料看待,事前挡下来远比事後补救便宜。它照样会留在本机,搜寻得到,也贴得回去。"
            )
        }

        // 第 1 关:使用者自己写下的不上传名单。
        // 这一关只做字串比对,比扫过整段文字便宜得多,所以排在侦测器前面。
        // 注意这里命中之後就直接回传了,不会再去跑侦测器:既然结论已经是不上传,
        // 再扫一次文字并不会改变任何事,只是白花时间。
        let blockDecision = matcher.evaluate(item: item, sourceURLHost: sourceURLHost, filePaths: filePaths)
        if blockDecision.isBlocked {
            return EgressDecision(
                verdict: .block,
                // 这里刻意把清单那边写好的句子原封不动地传出去,不再自己包一层。
                // 那句话已经讲完了命中哪一条规则、实际比对到什麽、以及内容照样留在本机这三件事;
                // 再包一层的结果只会是同一件事讲两遍,而且两份说法日後一定会各自漂移、开始互相矛盾。
                reasonSentence: blockDecision.sentence,
                blockedByRule: blockDecision.matchedRule
            )
        }

        // 第 2 关:内容侦测器。
        // 到这里才真的去扫文字,因为这是整条链上最贵的一步。
        // Detectors 只回报真的命中,没有「看过了但没找到」那种纪录,所以这里不必再筛一次:
        // 阵列不是空的,就代表有东西不该送出去。
        let hits = scan(item.searchText)
        if !hits.isEmpty {
            return EgressDecision(
                verdict: .block,
                // 这句话刻意只说「命中了哪几类」,绝不把被命中的那一段文字重复出来。
                // 理由很实际:这句话会被显示在面板上、也可能被写进纪录,
                // 如果它把病人的身分证号原样抄一遍,那这句本来要保护资料的说明,
                // 自己就变成了第二份外泄,而且是散布得更广的那一份。
                reasonSentence: "内容侦测器在这一则里找到了不该送出去的东西,所以它不会上云。侦测器的说法是:\(Self.describeDetectors(of: hits))为了避免这句说明本身变成第二份外泄,这里只转述侦测器怎麽说,不重复被命中的那一段文字;要人工复核的话,原文本来就还留在本机,照着每一笔命中的位置回去看即可。它仍然搜寻得到,也贴得回去。",
                detectorHits: hits
            )
        }

        // 第 3 关:图片一律扣住最久,就算侦测器什麽都没找到也一样。
        //
        // 这一关看起来最武断,却是整条链上最有用的一关。临床内容绝大多数是以截图的形式进到剪贴板的——
        // 病历画面、检验报告、影像判读,使用者按的是截图键而不是复制文字。
        // 偏偏侦测器在这里最没有战斗力:它读的是文字,而图片要先经过文字辨识才有文字可读,
        // 辨识本身会漏字、会读错、也可能整张读不出来。
        // 换句话说,「侦测器没找到东西」在图片上几乎不构成任何证据。
        // 既然内容判断在这里靠不住,那真正管用的控制手段就只剩下时间:
        // 给使用者一段够长、长到他截完图回过神来还追得上的窗口,让他自己把不该上去的那张拿掉。
        //
        // 这一关刻意排在低信心那一关前面:图片不管辨识结果好不好都要扣住最久,
        // 先问图片可以少问一个条件。也因为如此,下面那一关实际上处理的是「不是图片、
        // 但文字来自辨识」的情况,例如扫描件 PDF 这一类档案。
        if item.kind == .image {
            let seconds = policy.screenshotHoldSeconds
            return EgressDecision(
                verdict: .hold(seconds),
                reasonSentence: "这是一张图片,一律先扣住 \(Self.describeDuration(seconds))再上传;截图正好是临床内容最常出现、而文字侦测器最看不见的地方,所以在图片上真正管用的控制手段是时间,不是侦测。这段期间你随时可以把它拿掉。",
                detectorHits: hits,
                holdSeconds: seconds
            )
        }

        // 第 4 关:文字辨识结果不可靠。
        //
        // 一张读不出字的截图,对每一个侦测器来说都只是杂讯——没有文字可比对,自然什麽都不会命中,
        // 於是它会一路顺顺地走到放行。但同一份内容送到对面之後,人眼或模型读起来清清楚楚。
        // 也就是说,「我们读不懂」跟「它没有敏感资讯」完全是两回事,前者反而是更该小心的讯号。
        // 所以这里不放行,而是把扣住的时间拉长,把判断交还给唯一真的看得懂那张图的人。
        if ocrWasLowConfidence {
            let seconds = policy.suspiciousHoldSeconds
            return EgressDecision(
                verdict: .hold(seconds),
                reasonSentence: "这一则的文字辨识结果不可靠,所以扣住的时间从 \(Self.describeDuration(policy.normalHoldSeconds))拉长到 \(Self.describeDuration(seconds));我们读不懂它并不代表它没有敏感资讯,读不出字的内容对侦测器来说只是杂讯,但送到对面之後对人或模型来说往往清清楚楚,所以宁可多扣一阵子,让你自己看一眼再决定。",
                detectorHits: hits,
                holdSeconds: seconds
            )
        }

        // 第 5 关:什麽都没命中,正常放行,但仍然给一段可以反悔的窗口。
        let seconds = policy.normalHoldSeconds
        return EgressDecision(
            verdict: .allow,
            reasonSentence: "这一则没有命中任何封锁规则,内容侦测器也没有找到敏感资讯,所以它会在 \(Self.describeDuration(seconds))的撤回窗口结束之後上传;在那之前你随时可以把它拿掉。",
            detectorHits: hits,
            holdSeconds: seconds
        )
    }

    // MARK: 句子的零件

    /// 把命中的侦测器说法接成一段话,同一个侦测器命中很多次也只说一次。
    ///
    /// 转述的是侦测器写好的 `label`,不是被命中的那一段字。两者的差别就是这一整段设计的重点:
    /// 「这里出现了私密金钥的开头标记」是安全的,把那把金钥原样抄一遍就已经是外泄了。
    /// Detectors 那边的第一条铁则就是命中结果里不放原文,这里必须跟着守,
    /// 否则它辛苦守住的东西会在这一行漏掉。
    ///
    /// 依 `detectorID` 去重,而不是依 `label` 去重:同一份设定档里出现二十把金钥时,
    /// 照实念二十遍会让这句话长到没有人看,而使用者需要知道的其实只有「里面有金钥」这一件事。
    private static func describeDetectors(of hits: [DetectorHit]) -> String {
        var seen = Set<String>()
        var sentences: [String] = []
        for hit in hits {
            guard seen.insert(hit.detectorID).inserted else { continue }
            let label = hit.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }
            // 每一句 label 本来就是完整的中文句子、自己带句号,所以直接接起来就好,
            // 中间不必再加顿号——加了反而会变成「句号、句号」这种读不通的标点。
            sentences.append(label.hasSuffix("。") ? label : label + "。")
        }
        // 走到这个函式一定至少有一个命中,不过 label 理论上可能是空白的,
        // 所以还是留一句保底的话,免得使用者看到的是一句中间整个断掉的怪句子。
        return sentences.isEmpty ? "有一个侦测器命中了,但它没有留下说明。" : sentences.joined()
    }

    /// 把秒数讲成人话。60 秒以下讲秒,以上讲分钟,刚好整数分就不带小数点。
    private static func describeDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return "\(Int(seconds.rounded())) 秒"
        }
        let minutes = seconds / 60
        if minutes == minutes.rounded() {
            return "\(Int(minutes)) 分钟"
        }
        return String(format: "%.1f 分钟", minutes)
    }
}

// MARK: - 刻意没有做的两件事

// 下面这两件事看起来都像是「还没做完」,其实是拥有者看过取舍之後明确决定不要的。
// 写在这里是为了让下一个读到这个档案的人(很可能是几个月後的我们自己)不要把它们当成漏洞去「补上」。
//
// 一、来源判断不出来时,不会因此变得比较严格。
//    macOS 没有剪贴板变动通知,来源永远是推断出来的,所以 provenance 是 .unknown 的项目并不罕见——
//    它多半只代表取样的那一刻刚好没问到前景程式,不代表这一则内容比较敏感。
//    如果让 .unknown 自动升级成「可疑」,结果会是一大批完全无害的内容被长时间扣住,
//    使用者很快就会学会忽略扣住这件事,那才是真正危险的地方:一个天天误报的警报等於没有警报。
//    所以拥有者决定把来源不明的项目当成一般项目处理,判断依据留给名单与侦测器,不看 provenance。
//    EgressGateTests 里有一个测试专门守住这个决定,请不要顺手把它改掉。
//
// 二、名单只有一层,没有第二层「连抓都不要抓」。
//    被名单挡下来的项目照样会被抓下来、照样加密存在本机、照样进搜寻索引、照样贴得回去,
//    唯一的差别是它不会上云。拥有者要的是一个剪贴板管理器,不是一个会自己挖洞的历史纪录:
//    如果某些程式里复制的东西根本不进历史,使用者按下呼叫面板却找不到三分钟前才复制的那段文字,
//    他会开始不信任这个程式,而不信任的结果是他乾脆不用它,那连本机的价值都一起没了。
//    「不要留下任何痕迹」这个需求已经由另一个机制处理:剪贴板上的保密标记
//    (org.nspasteboard.ConcealedType 那一组)。那是来源程式自己宣告「这段内容是秘密」,
//    跟我们自己整理出来的名单性质完全不同,而且那个检查已经做在 PasteboardWatcher 里,
//    请不要在这个档案里重复实作一份。
