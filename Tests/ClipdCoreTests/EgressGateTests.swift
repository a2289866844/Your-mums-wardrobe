import Foundation
import Testing
@testable import ClipdCore

// 这一组测试守的是 clipd 里唯一一个错了就收不回来的判断:一则内容可不可以离开这台机器。
//
// 每一个测试都把封锁清单与内容侦测器换成假的。这样做不是为了偷懒,而是为了让失败的原因只剩一个:
// 如果这里红了,那就是出境判断本身写错了,不会是清单档案改了格式、
// 也不会是某个侦测器多认或少认了一种样式。清单自己的比对规则由 BlocklistTests 负责,
// 侦测器自己认得准不准由它自己的测试负责,这里只管「拿到这些结果之後,该怎麽决定」。

// MARK: - 假的封锁清单

/// 什麽都不挡的清单。拥有者决定清单出厂时完全是空的,所以这才是绝大多数使用者的真实状态。
private final class EmptyBlocklist: BlockRuleMatching {
    func evaluate(item: ClipItem, sourceURLHost: String?, filePaths: [String]) -> BlockDecision {
        BlockDecision(isBlocked: false, matchedRule: nil, sentence: "这一则没有命中任何封锁规则。")
    }
}

/// 一律命中同一条规则的清单,用来验证清单那一关的行为。
private final class AlwaysMatchingBlocklist: BlockRuleMatching {
    let rule: BlockRule
    let sentence: String

    init(rule: BlockRule, sentence: String) {
        self.rule = rule
        self.sentence = sentence
    }

    func evaluate(item: ClipItem, sourceURLHost: String?, filePaths: [String]) -> BlockDecision {
        BlockDecision(isBlocked: true, matchedRule: rule, sentence: sentence)
    }
}

// MARK: - 测试用的零件

/// 造一笔侦测命中。`detectorID` 与 `label` 是这几个测试真正在意的东西,位置随便给一个合理的值就好。
private func makeHit(_ detectorID: String, _ label: String) -> DetectorHit {
    DetectorHit(detectorID: detectorID, detectorVersion: "1", label: label, offset: 0, length: 8)
}

/// 造一则测试用的内容。预设的文字刻意平淡无奇,不含任何看起来像号码的东西。
private func makeItem(
    kind: ItemKind = .text,
    searchText: String = "今天的会议改到下午三点,地点在二楼那间会议室。",
    provenance: Provenance = .medium,
    bundleID: String? = "com.example.Notes"
) -> ClipItem {
    ClipItem(
        id: makeItemID(),
        kind: kind,
        capturedAt: Date(),
        contentHash: "测试用的杂凑值",
        preview: String(searchText.prefix(20)),
        searchText: searchText,
        sourceBundleID: bundleID,
        sourceAppName: "测试程式",
        provenance: provenance
    )
}

/// 造一个清单全空、侦测器也什麽都不认的闸门。
/// 这样任何一个非放行的结果,都一定是出境判断自己下的,不是被别人挡掉的。
private func makeGate(
    policy: EgressPolicy = .default,
    scan: @escaping (String) -> [DetectorHit] = { _ in [] }
) -> EgressGate {
    EgressGate(matcher: EmptyBlocklist(), policy: policy, scan: scan)
}

@Suite("出境闸门")
struct EgressGateTests {

    // MARK: 使用者按下的紧急停止

    @Test("上云总开关一关掉,不管是哪一种内容都不会离开这台机器", arguments: ItemKind.allCases)
    func 总开关关掉时全部挡下(kind: ItemKind) {
        var policy = EgressPolicy.default
        policy.isKillSwitchOn = true
        let decision = makeGate(policy: policy).evaluate(item: makeItem(kind: kind))

        #expect(decision.verdict == .block)
        // 被挡下来的东西根本不会送,所以扣住多久这件事对它没有意义,一律是 0。
        #expect(decision.holdSeconds == 0)
        // 使用者要看得出来是哪一个开关挡的,否则他会去翻清单找一条根本不存在的规则。
        #expect(decision.reasonSentence.contains("总开关"))
        #expect(decision.blockedByRule == nil)
    }

    @Test("诊间模式一打开,不管是哪一种内容都不会离开这台机器", arguments: ItemKind.allCases)
    func 诊间模式打开时全部挡下(kind: ItemKind) {
        var policy = EgressPolicy.default
        policy.isClinicModeOn = true
        let decision = makeGate(policy: policy).evaluate(item: makeItem(kind: kind))

        #expect(decision.verdict == .block)
        #expect(decision.holdSeconds == 0)
        #expect(decision.reasonSentence.contains("诊间模式"))
    }

    @Test("图片碰上总开关时,挡下来这个结论要赢过扣住三十分钟")
    func 总开关的结论赢过图片的扣住() {
        var policy = EgressPolicy.default
        policy.isKillSwitchOn = true
        let decision = makeGate(policy: policy).evaluate(item: makeItem(kind: .image))

        // 这个测试守的是判断链的顺序。如果哪天有人把图片那一关往前搬,
        // 图片就会变成「扣住三十分钟之後照样上传」,而使用者以为自己已经全部关掉了。
        #expect(decision.verdict == .block)
    }

    @Test("总开关关着的时候,连内容侦测器都不会被叫起来跑")
    func 总开关关着时不必再扫一次文字() {
        var policy = EgressPolicy.default
        policy.isKillSwitchOn = true
        var 扫过几次 = 0
        let gate = makeGate(policy: policy, scan: { _ in
            扫过几次 += 1
            return []
        })
        _ = gate.evaluate(item: makeItem())

        // 结论已经确定是不上传了,再扫一遍文字不会改变任何事,只是白花时间。
        #expect(扫过几次 == 0)
    }

    // MARK: 使用者自己写下的封锁清单

    @Test("命中封锁清单时会挡下来,而且说得出是哪一条规则")
    func 命中清单时挡下并且指名规则() {
        let rule = BlockRule(kind: .bundleIdentifier, pattern: "com.example.PatientChart", note: "这是病历系统。")
        let 清单说法 = "这一则内容命中了你亲手加进封锁清单的规则「来源程式的套件识别码:com.example.PatientChart」,所以它不会被上传,只会留在这台机器上。"
        let gate = EgressGate(
            matcher: AlwaysMatchingBlocklist(rule: rule, sentence: 清单说法),
            policy: .default,
            scan: { _ in [] }
        )
        let decision = gate.evaluate(item: makeItem(bundleID: "com.example.PatientChart"))

        #expect(decision.verdict == .block)
        #expect(decision.holdSeconds == 0)
        // 规则本身要一起带回去,面板才有办法给使用者一个「就是这一条,点这里去改」的入口。
        #expect(decision.blockedByRule == rule)
        // 清单那边已经把话讲完整了,闸门要原封不动地传出去,不可以自己再改写一遍。
        // 同一件事有两份说法,日後一定会各自漂移然後开始互相矛盾。
        #expect(decision.reasonSentence == 清单说法)
    }

    @Test("命中封锁清单时就不必再扫一次文字了")
    func 命中清单时不再扫文字() {
        let rule = BlockRule(kind: .bundleIdentifier, pattern: "com.example.PatientChart")
        var 扫过几次 = 0
        let gate = EgressGate(
            matcher: AlwaysMatchingBlocklist(rule: rule, sentence: "命中了封锁规则。"),
            policy: .default,
            scan: { _ in
                扫过几次 += 1
                return []
            }
        )
        _ = gate.evaluate(item: makeItem())

        // 清单比对只是字串比对,侦测器要扫过整段文字,所以便宜的那一关排前面;
        // 既然已经确定挡下来了,贵的那一关就该整个省掉。
        #expect(扫过几次 == 0)
    }

    // MARK: 内容侦测器

    @Test("侦测器命中时会挡下来,而且理由句子只转述侦测器的说法,不抄原文")
    func 侦测命中时挡下() {
        let 敏感文字 = "病人的个人健康号码是 9876543217。"
        let 说法 = "这段文字里出现了一组看起来像个人健康号码的数字。"
        let gate = makeGate(scan: { _ in [makeHit("canadian-phn", 说法)] })
        let decision = gate.evaluate(item: makeItem(searchText: 敏感文字))

        #expect(decision.verdict == .block)
        #expect(decision.holdSeconds == 0)
        #expect(decision.detectorHits.count == 1)
        // 侦测器自己写好的说法要原样转述,使用者才知道自己复制到了什麽。
        #expect(decision.reasonSentence.contains(说法))
        // 这一段才是重点:说明句子如果把号码抄回去,它就变成散布得更广的第二份外泄。
        // Detectors 那边的第一条铁则就是命中结果里不放原文,闸门必须跟着守。
        #expect(!decision.reasonSentence.contains("9876543217"))
    }

    @Test("挡下来的时候要把每一笔命中都带走,人工复核才找得到位置")
    func 挡下时带着每一笔命中() {
        let gate = makeGate(scan: { _ in
            [makeHit("private-key", "这段文字里出现了私密金钥档案的开头标记。"),
             makeHit("jwt", "这段文字里出现了一个 JSON Web Token。")]
        })
        let decision = gate.evaluate(item: makeItem())

        #expect(decision.verdict == .block)
        // 命中的位置(offset 与 length)只活在这个阵列里,少一笔就少一个可以回去看的地方。
        #expect(decision.detectorHits.count == 2)
        // 两个不同的侦测器都命中时,两边的说法都要讲出来,只讲一个会让使用者以为只有一个问题。
        #expect(decision.reasonSentence.contains("私密金钥"))
        #expect(decision.reasonSentence.contains("JSON Web Token"))
    }

    @Test("同一个侦测器命中很多次时,句子里只会说一次")
    func 同一个侦测器只说一次() {
        let 说法 = "这一段不含空白的长字串乱度偏高,形状像是机器产生的金钥。"
        let gate = makeGate(scan: { _ in
            [makeHit("entropy", 说法), makeHit("entropy", 说法), makeHit("entropy", 说法)]
        })
        let decision = gate.evaluate(item: makeItem())

        // 一份设定档里有二十把金钥时,照实念二十遍会让这句话长到没有人看,
        // 而使用者需要知道的其实只有「里面有金钥」这一件事。
        let 出现次数 = decision.reasonSentence.components(separatedBy: 说法).count - 1
        #expect(出现次数 == 1)
        // 但是带回去的命中笔数不可以跟着被去重,因为每一笔的位置都不一样。
        #expect(decision.detectorHits.count == 3)
    }

    @Test("侦测器什麽都没找到时,不会因为文字很长就自己紧张起来")
    func 侦测器没命中就不挡() {
        let 长文 = String(repeating: "这是一段没有任何敏感资讯的普通笔记内容。", count: 50)
        let decision = makeGate().evaluate(item: makeItem(searchText: 长文))

        #expect(decision.verdict == .allow)
        #expect(decision.detectorHits.isEmpty)
    }

    // MARK: 图片

    @Test("图片就算一个侦测结果都没有,照样扣住最久的那一段时间")
    func 图片没命中也扣住最久() {
        let decision = makeGate().evaluate(item: makeItem(kind: .image))

        // 侦测器在图片上几乎没有战斗力,所以「什麽都没找到」在这里不构成放行的理由。
        #expect(decision.verdict == .hold(EgressPolicy.default.screenshotHoldSeconds))
        #expect(decision.holdSeconds == 30 * 60)
        #expect(decision.detectorHits.isEmpty)
        #expect(decision.reasonSentence.contains("30 分钟"))
    }

    @Test("图片扣住的时间比一般内容长很多,这个差距本身就是这一关存在的意义")
    func 图片扣得比一般内容久() {
        let gate = makeGate()
        let 图片 = gate.evaluate(item: makeItem(kind: .image))
        let 文字 = gate.evaluate(item: makeItem())

        #expect(图片.holdSeconds > 文字.holdSeconds)
    }

    @Test("图片里真的侦测到敏感资讯时,挡下来要赢过扣住三十分钟")
    func 图片命中侦测器时直接挡下() {
        let gate = makeGate(scan: { _ in
            [makeHit("canadian-phn", "这段文字里出现了一组看起来像个人健康号码的数字。")]
        })
        let decision = gate.evaluate(item: makeItem(kind: .image))

        // 扣住三十分钟是「读不出东西时的保底手段」,不是「读得出东西时的上限」。
        #expect(decision.verdict == .block)
    }

    // MARK: 文字辨识不可靠

    @Test("文字辨识不可靠时,扣住的时间会从常规窗口拉长到可疑窗口")
    func 辨识不可靠时拉长扣住时间() {
        // 用档案而不是图片,因为图片在上一关就已经被接走了;
        // 真正会走到这一关的是扫描件 PDF 这一类「不是图片、但文字来自辨识」的内容。
        let decision = makeGate().evaluate(item: makeItem(kind: .file), ocrWasLowConfidence: true)

        #expect(decision.verdict == .hold(EgressPolicy.default.suspiciousHoldSeconds))
        #expect(decision.holdSeconds == 10 * 60)
        #expect(decision.holdSeconds > EgressPolicy.default.normalHoldSeconds)
        // 使用者要知道为什麽这一则比别人等得久,否则他只会觉得程式坏了。
        #expect(decision.reasonSentence.contains("辨识"))
    }

    @Test("辨识可靠时不会平白无故被拉长")
    func 辨识可靠时维持常规窗口() {
        let decision = makeGate().evaluate(item: makeItem(kind: .file), ocrWasLowConfidence: false)

        #expect(decision.verdict == .allow)
        #expect(decision.holdSeconds == EgressPolicy.default.normalHoldSeconds)
    }

    // MARK: 一般放行

    @Test("一般文字什麽都没命中时会放行,但仍然给一段来得及反悔的窗口")
    func 一般文字以常规窗口放行() {
        let decision = makeGate().evaluate(item: makeItem())

        #expect(decision.verdict == .allow)
        #expect(decision.holdSeconds == 60)
        #expect(decision.blockedByRule == nil)
        #expect(decision.detectorHits.isEmpty)
        // 60 秒讲给人听的时候会说成「1 分钟」,不会说成「60 秒」;
        // 窗口的长度由上面那一行断言守着,这一行守的是那句话真的把长度讲出来了。
        #expect(decision.reasonSentence.contains("1 分钟"))
    }

    @Test("政策里的秒数改了,放行的窗口就跟着改,不会有第二份写死的数字")
    func 窗口长度跟着政策走() {
        var policy = EgressPolicy.default
        policy.normalHoldSeconds = 5
        let decision = makeGate(policy: policy).evaluate(item: makeItem())

        #expect(decision.holdSeconds == 5)
        #expect(decision.reasonSentence.contains("5 秒"))
    }

    // MARK: 守住拥有者的决定

    @Test("来源判断不出来的项目不会被特别对待,跟来源清楚的项目走完全一样的路")
    func 来源不明不会被特别对待() {
        // 这是一则回归测试,守的是拥有者明确做过的一个决定。
        //
        // macOS 没有剪贴板变动通知,来源永远是推断出来的,所以 .unknown 只代表取样那一刻刚好没问到,
        // 不代表这一则内容比较敏感。如果让来源不明自动升级成可疑,结果会是一大批完全无害的内容
        // 被长时间扣住,使用者很快就学会忽略「扣住」这件事——一个天天误报的警报等於没有警报。
        // 若哪天有人「顺手把安全性补强」而让这个测试红了,该被退回去的是那个改动,不是这个测试。
        let gate = makeGate()
        let 来源不明 = gate.evaluate(item: makeItem(provenance: .unknown, bundleID: nil))
        let 来源清楚 = gate.evaluate(item: makeItem(provenance: .high))

        #expect(来源不明.verdict == 来源清楚.verdict)
        #expect(来源不明.verdict == .allow)
        #expect(来源不明.holdSeconds == 来源清楚.holdSeconds)
        #expect(来源不明.holdSeconds == EgressPolicy.default.normalHoldSeconds)
    }

    @Test("四种来源可信度走出来的结果完全一样,可信度不参与出境判断", arguments: [Provenance.high, .medium, .low, .unknown])
    func 来源可信度不影响判断(provenance: Provenance) {
        let decision = makeGate().evaluate(item: makeItem(provenance: provenance))

        #expect(decision.verdict == .allow)
        #expect(decision.holdSeconds == EgressPolicy.default.normalHoldSeconds)
    }

    @Test("来源判断不出来的图片,也只是照图片的规则扣住,不会再被额外加重")
    func 来源不明的图片只走图片那一关() {
        let gate = makeGate()
        let 来源不明 = gate.evaluate(item: makeItem(kind: .image, provenance: .unknown, bundleID: nil))
        let 来源清楚 = gate.evaluate(item: makeItem(kind: .image, provenance: .high))

        #expect(来源不明.holdSeconds == 来源清楚.holdSeconds)
        #expect(来源不明.verdict == .hold(EgressPolicy.default.screenshotHoldSeconds))
    }

    // MARK: 预设值

    @Test("预设的三段窗口是 60 秒、10 分钟、30 分钟,而且一段比一段长")
    func 预设窗口的长度与顺序() {
        let policy = EgressPolicy.default

        #expect(policy.normalHoldSeconds == 60)
        #expect(policy.suspiciousHoldSeconds == 600)
        #expect(policy.screenshotHoldSeconds == 1800)
        // 顺序错了整个设计就垮了:越可疑的东西反而越快送出去,那比没有窗口更糟。
        #expect(policy.normalHoldSeconds < policy.suspiciousHoldSeconds)
        #expect(policy.suspiciousHoldSeconds < policy.screenshotHoldSeconds)
        // 出厂时两个紧急停止都是关的,否则程式一装好就什麽都不上传,使用者会以为功能坏了。
        #expect(!policy.isKillSwitchOn)
        #expect(!policy.isClinicModeOn)
    }
}
