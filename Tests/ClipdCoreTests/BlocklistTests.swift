import Foundation
import Testing
@testable import ClipdCore

// 这一组测试守着来源封锁清单的四件事:
// 一、它出厂时是空的,而且会明白讲出「现在什么都没被挡」——这是拥有者亲自拍板的设计,
//     哪天有人偷偷塞了一条预设规则进去,第一个测试就会红,那正是这个测试存在的理由。
// 二、每一种规则的比对边界(一字不差、不分大小写、子网域、波浪号)都照说好的走。
// 三、停用的规则真的不会命中,不然「先关掉看看影响」这个用法就是骗人的。
// 四、改动会真的落地,而且档案权限是 0600。

/// 每一个测试都拿一个全新的暂存资料夹与档名,测完就整个删掉。
/// 共用同一个档案会让「上一个测试留下的规则」变成下一个测试的隐形前提,那种失败最难查。
/// 另外这里刻意让资料夹「还不存在」,顺便验证 Blocklist 会自己把资料夹建出来。
private func withTemporaryBlocklistFile(_ body: (URL) throws -> Void) throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("clipd-blocklist-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory.appendingPathComponent("blocklist.json"))
}

/// 读出档案目前的 POSIX 权限位元。
private func blocklistPosixPermissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let number = attributes[.posixPermissions] as? NSNumber
    return number?.intValue ?? -1
}

/// 做一则内容出来当测试素材。只有来源那两个栏位会影响封锁判断,其余栏位填得像样就够了。
private func makeItem(bundleID: String? = nil, appName: String? = nil) -> ClipItem {
    ClipItem(
        id: makeItemID(),
        kind: .text,
        capturedAt: Date(),
        contentHash: "测试用的杂凑值",
        preview: "一段测试用的内容",
        searchText: "一段测试用的内容",
        sourceBundleID: bundleID,
        sourceAppName: appName,
        provenance: bundleID == nil ? .unknown : .high
    )
}

@Suite("来源封锁清单")
struct BlocklistTests {

    // MARK: 出厂状态

    @Test("全新的清单是空的,摘要句子会直说现在没有任何来源被挡下")
    func 全新的清单是空的() throws {
        try withTemporaryBlocklistFile { url in
            let list = try Blocklist(fileURL: url)

            // 出厂空清单是拥有者亲自拍板的决定,谁想加预设规则都要先过这一关。
            #expect(list.rules.isEmpty)
            #expect(FileManager.default.fileExists(atPath: url.path))

            // 摘要必须讲人话,而且要讲出「所以现在什么都没挡」这个结论,不能只说「有 0 条规则」。
            #expect(list.summarySentence.contains("空的"))
            #expect(list.summarySentence.contains("没有任何来源"))
            #expect(list.summarySentence.hasSuffix("。"))

            // 空清单底下,任何内容都应该被放行,而且理由要写成一句完整的句子。
            let decision = list.evaluate(item: makeItem(bundleID: "com.example.任何程式"), sourceURLHost: nil, filePaths: [])
            #expect(decision.isBlocked == false)
            #expect(decision.matchedRule == nil)
            #expect(decision.sentence.hasSuffix("。"))

            // 档案里也必须真的是一个空阵列,而不是藏了几条规则却假装没有。
            // 这里把所有空白字元都拿掉再比,因为排版过的 JSON 会在中括号之间留换行。
            let raw = try String(contentsOf: url, encoding: .utf8)
            #expect(raw.filter({ !$0.isWhitespace }) == "[]")
        }
    }

    @Test("来源判断不出来的内容照常放行,不会因为不确定就升级成封锁")
    func 来源不明照常放行() throws {
        try withTemporaryBlocklistFile { url in
            let list = try Blocklist(fileURL: url)
            try list.add(BlockRule(kind: .bundleIdentifier, pattern: "com.apple.Notes"))

            // 这一则连是谁复制的都不知道。拥有者明确决定过:不确定不是封锁的理由。
            let decision = list.evaluate(item: makeItem(), sourceURLHost: nil, filePaths: [])
            #expect(decision.isBlocked == false)
        }
    }

    // MARK: 套件识别码

    @Test("套件识别码要一字不差才算命中,长得像的另一个程式不会被误伤")
    func 套件识别码要一字不差() throws {
        try withTemporaryBlocklistFile { url in
            let list = try Blocklist(fileURL: url)
            try list.add(BlockRule(kind: .bundleIdentifier, pattern: "com.apple.Notes", note: "私人笔记不外传。"))

            let hit = list.evaluate(item: makeItem(bundleID: "com.apple.Notes", appName: "备忘录"), sourceURLHost: nil, filePaths: [])
            #expect(hit.isBlocked)
            #expect(hit.matchedRule?.pattern == "com.apple.Notes")
            // 判断结果会原封不动显示给人看,所以必须是完整句子,而且要交代「被挡下来会怎样」。
            #expect(hit.sentence.contains("不会被上传"))
            #expect(hit.sentence.contains("私人笔记不外传。"))

            // 前缀相同但其实是另一个程式,绝对不能被顺手挡掉。
            let helper = list.evaluate(item: makeItem(bundleID: "com.apple.Notes-helper"), sourceURLHost: nil, filePaths: [])
            #expect(helper.isBlocked == false)

            // 完全不相干的程式当然放行。
            let other = list.evaluate(item: makeItem(bundleID: "com.apple.Safari"), sourceURLHost: nil, filePaths: [])
            #expect(other.isBlocked == false)
            #expect(other.sentence.hasSuffix("。"))
        }
    }

    // MARK: 程式名称片段

    @Test("程式名称片段不分大小写,只要名称里出现那一段就算命中")
    func 程式名称片段不分大小写() throws {
        try withTemporaryBlocklistFile { url in
            let list = try Blocklist(fileURL: url)
            try list.add(BlockRule(kind: .appNameFragment, pattern: "PassWord"))

            // 规则与实际名称的大小写都跟对方对不上,但人的意思显然是同一个程式。
            #expect(list.evaluate(item: makeItem(appName: "1password 8"), sourceURLHost: nil, filePaths: []).isBlocked)
            #expect(list.evaluate(item: makeItem(appName: "MY PASSWORD VAULT"), sourceURLHost: nil, filePaths: []).isBlocked)
            // 片段出现在名称中间也算,因为拥有者只要记一个关键字就好。
            #expect(list.evaluate(item: makeItem(appName: "Enpassword Helper"), sourceURLHost: nil, filePaths: []).isBlocked)
            // 名称里没有这一段就不该命中。
            #expect(list.evaluate(item: makeItem(appName: "Safari"), sourceURLHost: nil, filePaths: []).isBlocked == false)
            // 连名称都没有的内容不会命中名称类的规则。
            #expect(list.evaluate(item: makeItem(bundleID: "com.example.app"), sourceURLHost: nil, filePaths: []).isBlocked == false)
        }
    }

    // MARK: 网址主机

    @Test("网址主机命中自己与子网域,但不会误伤名字长得像的另一个网域")
    func 网址主机只吃真正的子网域() throws {
        try withTemporaryBlocklistFile { url in
            let list = try Blocklist(fileURL: url)
            try list.add(BlockRule(kind: .urlHost, pattern: "example.com"))

            let item = makeItem(bundleID: "com.apple.Safari", appName: "Safari")
            func decide(_ host: String) -> BlockDecision {
                list.evaluate(item: item, sourceURLHost: host, filePaths: [])
            }

            // 自己、子网域、大小写不同、结尾多一个根网域的点、以及被百分号编码起来的点,都是同一个地方。
            #expect(decide("example.com").isBlocked)
            #expect(decide("mail.example.com").isBlocked)
            #expect(decide("a.b.example.com").isBlocked)
            #expect(decide("EXAMPLE.COM").isBlocked)
            #expect(decide("example.com.").isBlocked)
            #expect(decide("mail%2Eexample.com").isBlocked)

            // 这三个是完全不相干的网域,只是字面上看起来像。若这里红了,
            // 代表比对退化成了单纯的字尾比对,那会在拥有者毫不知情的情况下挡错东西。
            #expect(decide("notexample.com").isBlocked == false)
            #expect(decide("myexample.com").isBlocked == false)
            #expect(decide("example.com.evil.net").isBlocked == false)
            // 根本没有网址的内容当然不会命中网址类的规则。
            #expect(list.evaluate(item: item, sourceURLHost: nil, filePaths: []).isBlocked == false)
        }
    }

    // MARK: 档案路径

    @Test("档案路径的规则会先把开头的波浪号换成家目录再比对")
    func 档案路径会展开波浪号() throws {
        try withTemporaryBlocklistFile { url in
            let list = try Blocklist(fileURL: url)
            try list.add(BlockRule(kind: .pathPrefix, pattern: "~/机密资料"))

            let item = makeItem(bundleID: "com.apple.finder", appName: "访达")
            let home = NSHomeDirectory()

            // 规则写波浪号、实际路径是展开後的绝对路径,两边必须对得上,
            // 否则拥有者会照着介面提示打了波浪号,却什么都没挡到。
            let hit = list.evaluate(item: item, sourceURLHost: nil, filePaths: ["\(home)/机密资料/病历.pdf"])
            #expect(hit.isBlocked)
            #expect(hit.matchedRule?.kind == .pathPrefix)

            // 反过来,实际路径带波浪号、规则是展开後的写法,也要对得上。
            let list2 = try Blocklist(fileURL: url.deletingLastPathComponent().appendingPathComponent("另一份.json"))
            try list2.add(BlockRule(kind: .pathPrefix, pattern: "\(home)/机密资料"))
            #expect(list2.evaluate(item: item, sourceURLHost: nil, filePaths: ["~/机密资料/病历.pdf"]).isBlocked)

            // 不在那个位置底下的档案要放行,而且一整批档案里只要有一个命中就算命中。
            #expect(list.evaluate(item: item, sourceURLHost: nil, filePaths: ["\(home)/下载/照片.png"]).isBlocked == false)
            #expect(list.evaluate(item: item, sourceURLHost: nil, filePaths: []).isBlocked == false)
            #expect(list.evaluate(
                item: item,
                sourceURLHost: nil,
                filePaths: ["\(home)/下载/照片.png", "\(home)/机密资料/病历.pdf"]
            ).isBlocked)
        }
    }

    // MARK: 停用

    @Test("停用的规则永远不会命中,重新启用之後又会命中")
    func 停用的规则不会命中() throws {
        try withTemporaryBlocklistFile { url in
            let list = try Blocklist(fileURL: url)
            let rule = BlockRule(kind: .bundleIdentifier, pattern: "com.apple.Notes", isEnabled: false)
            try list.add(rule)

            let item = makeItem(bundleID: "com.apple.Notes", appName: "备忘录")
            #expect(list.evaluate(item: item, sourceURLHost: nil, filePaths: []).isBlocked == false)

            try list.setEnabled(true, id: rule.id)
            #expect(list.evaluate(item: item, sourceURLHost: nil, filePaths: []).isBlocked)

            // 关掉之後要立刻失效,「先关掉看看影响」这个用法才是真的。
            try list.setEnabled(false, id: rule.id)
            #expect(list.evaluate(item: item, sourceURLHost: nil, filePaths: []).isBlocked == false)

            // 开关状态也要落地,不然重开程式又变回原样。
            let reopened = try Blocklist(fileURL: url)
            #expect(reopened.rules.first?.isEnabled == false)

            // 对着一个不存在的识别码按开关要报错,因为画面上的开关已经动了,
            // 若後端默默不做,使用者会以为自己已经挡住了。
            #expect(throws: BlocklistError.self) {
                try list.setEnabled(true, id: "这个-id-不存在")
            }
        }
    }

    // MARK: 落地

    @Test("加进去、删掉、改过的规则都会写进档案,换一个程序读也一样")
    func 改动会落地并且读得回来() throws {
        try withTemporaryBlocklistFile { url in
            let list = try Blocklist(fileURL: url)
            let appRule = BlockRule(kind: .bundleIdentifier, pattern: "com.apple.Notes", note: "私人笔记。")
            let hostRule = BlockRule(kind: .urlHost, pattern: "example.com", note: "内部网站。")
            try list.add(appRule)
            try list.add(hostRule)

            // 换一个全新的物件读同一个档案,内容必须一模一样,包含时间与备注。
            let reopened = try Blocklist(fileURL: url)
            #expect(reopened.rules == list.rules)
            #expect(reopened.rules.count == 2)
            #expect(reopened.rules.map({ $0.pattern }) == ["com.apple.Notes", "example.com"])
            #expect(reopened.rules.first?.note == "私人笔记。")
            // 读回来的规则照样要能挡住东西,否则等於重开程式後封锁就失效了。
            #expect(reopened.evaluate(item: makeItem(bundleID: "com.apple.Notes"), sourceURLHost: nil, filePaths: []).isBlocked)

            // 清单有内容之後,摘要要报出正确的条数,而且不能再说自己是空的。
            #expect(list.summarySentence.contains("2 条规则"))
            #expect(!list.summarySentence.contains("空的"))

            // 同一条规则重复加会被挡下,免得清单里出现两条一样的东西让人看不懂。
            #expect(throws: BlocklistError.self) {
                try list.add(BlockRule(kind: .urlHost, pattern: "example.com"))
            }
            // 比对内容留空也会被挡下,因为空白会把每一则内容都当成命中。
            #expect(throws: BlocklistError.self) {
                try list.add(BlockRule(kind: .appNameFragment, pattern: "   "))
            }
            #expect(list.rules.count == 2)

            // 删掉一条之後,重新读档也要真的少一条;删一个本来就不存在的识别码不该报错。
            try list.remove(id: appRule.id)
            try list.remove(id: "这个-id-不存在")
            let afterRemoval = try Blocklist(fileURL: url)
            #expect(afterRemoval.rules.count == 1)
            #expect(afterRemoval.rules.first?.pattern == "example.com")

            // 用编辑器改完档案之後,reload 要让程式跟上。
            try list.reload()
            #expect(list.rules.count == 1)
        }
    }

    @Test("清单档的权限是 0600,第一次建立与之後每一次改写都一样")
    func 清单档权限是0600() throws {
        try withTemporaryBlocklistFile { url in
            let list = try Blocklist(fileURL: url)
            // 第一次建档走的是「建立暂存档再搬过来」这条路。
            #expect(try blocklistPosixPermissions(of: url) == 0o600)

            // 之後每一次改写走的是「换名取代」那条路,那条路有机会把权限换掉,所以要另外确认一次。
            let rule = BlockRule(kind: .bundleIdentifier, pattern: "com.apple.Notes")
            try list.add(rule)
            #expect(try blocklistPosixPermissions(of: url) == 0o600)

            try list.setEnabled(false, id: rule.id)
            #expect(try blocklistPosixPermissions(of: url) == 0o600)

            try list.remove(id: rule.id)
            #expect(try blocklistPosixPermissions(of: url) == 0o600)

            // 写完之後资料夹里不该留下任何暂存档,否则这份清单会以另一个名字继续躺在硬碟上。
            let leftovers = try FileManager.default
                .contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
                .filter { $0.hasSuffix(".tmp") }
            #expect(leftovers.isEmpty)
        }
    }

    // MARK: 一键封锁的草稿

    @Test("由一则内容产生的封锁草稿一律是停用的,不会自动变成一条生效规则")
    func 一键封锁只产生停用的草稿() throws {
        try withTemporaryBlocklistFile { url in
            let item = makeItem(bundleID: "com.apple.Notes", appName: "备忘录")
            let draft = Blocklist.suggestingRule(for: item)

            // 停用是重点:我们绝不代替拥有者往他的清单里加东西。
            #expect(draft.isEnabled == false)
            #expect(draft.kind == .bundleIdentifier)
            #expect(draft.pattern == "com.apple.Notes")
            #expect(draft.note.contains("备忘录"))

            // 产生草稿这件事本身不会动到清单,要等呼叫端真的呼叫 add 才算数。
            let list = try Blocklist(fileURL: url)
            #expect(list.rules.isEmpty)

            // 来源判断不出来时照样给一张草稿,只是比对内容是空的,让介面知道该把按钮变灰。
            let blankDraft = Blocklist.suggestingRule(for: makeItem())
            #expect(blankDraft.pattern.isEmpty)
            #expect(blankDraft.isEnabled == false)
            #expect(throws: BlocklistError.self) {
                try list.add(blankDraft)
            }
        }
    }
}
