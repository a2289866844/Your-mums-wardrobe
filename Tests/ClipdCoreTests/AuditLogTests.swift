import Foundation
import Testing
import ClipdCore   // 这里刻意不用 @testable:稽核纪录的每一项承诺都是公开行为,测试也只该透过公开 API 验证。

// 这一组测试盯的是稽核纪录的四个承诺:写进去的读得回来、被改过看得出来、
// 内容不会以可还原的形式留在档案里、以及那份报告永远肯把自己的盲点讲出来。
//
// 换月锚点刻意不测:那需要把系统时钟拨到下个月,而在 swift test 底下能做到的只有「传一个未来的时间给它」,
// 那验到的是参数传递,不是真的跨月行为。锚点的验证留给真人在真实机器上跨月时看一眼。

/// 每一个测试都拿一个全新的暂存资料夹,测完整个删掉。
/// 共用同一个资料夹会让上一个测试留下的杂凑链变成下一个测试的隐形前提,那种失败最难查。
private func withTemporaryAuditDirectory(_ body: (URL) throws -> Void) throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("clipd-audit-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

/// 把资料夹里所有纪录档的原始位元组接成一整串,用来断言「某段字从来没有被写进去过」。
private func rawBytesOfEveryLogFile(in directory: URL) throws -> String {
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    return try names
        .map { try String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8) }
        .joined(separator: "\n")
}

/// 资料夹里唯一那个纪录档的完整路径。
private func onlyLogFile(in directory: URL) throws -> URL {
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        .filter { $0.hasPrefix("egress-") }
    #expect(names.count == 1)
    return directory.appendingPathComponent(names[0])
}

@Suite("外送稽核纪录")
struct AuditLogTests {

    // MARK: 写进去读得回来

    @Test("附加进去的事件可以照原样查回来,而且事件种类、时间与来源程式三个条件都筛得动")
    func 附加之後查得回来() throws {
        try withTemporaryAuditDirectory { directory in
            let log = try AuditLog(directory: directory, installKey: AuditLog.makeInstallKey())
            let base = Date(timeIntervalSince1970: 1_770_000_000)

            try log.append(AuditRecord(at: base, event: .sent, policyVersion: "2026.07.1",
                                       itemID: "item-1", kind: .text, byteCount: 120,
                                       sourceBundleID: "com.example.a", sourceAppName: "程式甲",
                                       provenance: .high))
            try log.append(AuditRecord(at: base.addingTimeInterval(60), event: .blocked, policyVersion: "2026.07.1",
                                       itemID: "item-2", kind: .text, byteCount: 40,
                                       sourceBundleID: "com.example.b", sourceAppName: "程式乙",
                                       provenance: .medium))
            try log.append(AuditRecord(at: base.addingTimeInterval(120), event: .sent, policyVersion: "2026.07.1",
                                       itemID: "item-3", kind: .link, byteCount: 88,
                                       sourceBundleID: "com.example.a", sourceAppName: "程式甲",
                                       provenance: .high, sourceHost: "example.org"))

            let everything = try log.query(event: nil, since: nil, sourceBundleID: nil)
            #expect(everything.count == 3)
            #expect(everything.map({ $0.itemID }) == ["item-1", "item-2", "item-3"])
            // 时间要一路原封不动地走完「编码、写档、读档、解码」这一圈,差一毫秒都算错。
            #expect(everything[0].at == base)
            #expect(everything[2].sourceHost == "example.org")
            #expect(everything[0].policyVersion == "2026.07.1")

            #expect(try log.query(event: .sent, since: nil, sourceBundleID: nil).count == 2)
            #expect(try log.query(event: nil, since: base.addingTimeInterval(90), sourceBundleID: nil).count == 1)
            #expect(try log.query(event: nil, since: nil, sourceBundleID: "com.example.a").count == 2)
            #expect(try log.query(event: .blocked, since: nil, sourceBundleID: "com.example.a").isEmpty)

            // 换一个全新的物件读同一个资料夹,确认资料是真的在磁碟上,不是只活在记忆体里。
            let reopened = try AuditLog(directory: directory, installKey: AuditLog.makeInstallKey())
            #expect(try reopened.query(event: nil, since: nil, sourceBundleID: nil).count == 3)
        }
    }

    // MARK: 杂凑链

    @Test("刚写完的纪录整条杂凑链验得过,关掉再开继续写也一样接得上")
    func 杂凑链完整时验得过() throws {
        try withTemporaryAuditDirectory { directory in
            let key = AuditLog.makeInstallKey()
            let log = try AuditLog(directory: directory, installKey: key)
            for index in 0..<5 {
                try log.append(AuditRecord(event: .sent, policyVersion: "2026.07.1", itemID: "item-\(index)"))
            }

            let first = try log.verifyChain()
            #expect(first.recordCount == 5)
            #expect(first.isIntact)
            // 这份纪录必须主动承认自己只查得出竄改、挡不住竄改,不能让人读完以为它是防线。
            #expect(first.sentence.contains("挡不住"))

            // 重开一次再继续写。若开档时没有把前一笔的杂凑读回来,这里就会多出一个断点,
            // 而断点在链上跟「有人动过手脚」长得一模一样。
            let reopened = try AuditLog(directory: directory, installKey: key)
            try reopened.append(AuditRecord(event: .killSwitchEnabled, policyVersion: "2026.07.1"))
            let second = try reopened.verifyChain()
            #expect(second.recordCount == 6)
            #expect(second.isIntact)
        }
    }

    @Test("把中间某一行改掉之後,验证会说链断了,而且用完整的中文讲清楚断在哪一行")
    func 改掉中间一行就验不过() throws {
        try withTemporaryAuditDirectory { directory in
            let key = AuditLog.makeInstallKey()
            let log = try AuditLog(directory: directory, installKey: key)
            try log.append(AuditRecord(event: .sent, policyVersion: "2026.07.1",
                                       itemID: "item-1", sourceAppName: "程式甲"))
            try log.append(AuditRecord(event: .sent, policyVersion: "2026.07.1",
                                       itemID: "item-2", sourceAppName: "程式乙"))
            try log.append(AuditRecord(event: .sent, policyVersion: "2026.07.1",
                                       itemID: "item-3", sourceAppName: "程式丙"))
            #expect(try log.verifyChain().isIntact)

            // 只改中间那一行的一个栏位值,长度一样、JSON 依然合法。
            // 这正是最难发现、也最值得被发现的那一种竄改:有人把某一则的来源改成别人。
            let fileURL = try onlyLogFile(in: directory)
            let original = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(original.contains("程式乙"))
            let tampered = original.replacingOccurrences(of: "程式乙", with: "程式丁")
            try tampered.write(to: fileURL, atomically: true, encoding: .utf8)

            let result = try AuditLog(directory: directory, installKey: key).verifyChain()
            #expect(!result.isIntact)
            #expect(result.sentence.contains("第 2 行"))
            #expect(result.sentence.contains("被改动过"))
            #expect(result.sentence.contains(fileURL.lastPathComponent))
            // 断掉之前那一笔仍然算得数,所以笔数是 1 而不是 0;报告要说得出「从哪里开始不能信」。
            #expect(result.recordCount == 1)
        }
    }

    // MARK: 内容识别码

    @Test("同一段内容在两把不同的安装金钥底下会得到完全不同的识别码,同一把金钥则永远一致")
    func 不同安装金钥的识别码不一样() throws {
        try withTemporaryAuditDirectory { directoryA in
            try withTemporaryAuditDirectory { directoryB in
                let keyA = AuditLog.makeInstallKey()
                let keyB = AuditLog.makeInstallKey()
                #expect(keyA != keyB)

                let logA = try AuditLog(directory: directoryA, installKey: keyA)
                let logB = try AuditLog(directory: directoryB, installKey: keyB)

                // 六位数验证码正是纯杂凑最挡不住的那一种内容:只有一百万种可能,枚举几秒钟就还原了。
                // 换成 HMAC 之後,没有那台机器上的安装金钥就连枚举都无从开始。
                let secret = "482913"
                #expect(logA.contentTag(forText: secret) != logB.contentTag(forText: secret))

                // 同一把金钥、同一段内容,必须永远算出同一个识别码,否则「这是不是我上次挡掉的那一则」就问不了。
                #expect(logA.contentTag(forText: secret) == logA.contentTag(forText: secret))
                let sameKeyAgain = try AuditLog(directory: directoryA, installKey: keyA)
                #expect(sameKeyAgain.contentTag(forText: secret) == logA.contentTag(forText: secret))

                // 头尾空白与换行不该让同一段内容变成两件事。
                #expect(logA.contentTag(forText: "  \(secret)\n") == logA.contentTag(forText: secret))
                // 不同内容当然要不一样。
                #expect(logA.contentTag(forText: "482914") != logA.contentTag(forText: secret))

                // 空金钥要当场拒绝,不能默默退化成没有金钥的裸杂凑。
                #expect(throws: AuditError.self) {
                    _ = try AuditLog(directory: directoryB, installKey: Data())
                }
            }
        }
    }

    // MARK: 绝对不落地的东西

    @Test("被侦测器命中的那一段字、网址的查询字串与视窗标题,一个字都不会出现在纪录档的位元组里")
    func 命中的字串永远不会写进档案() throws {
        try withTemporaryAuditDirectory { directory in
            let log = try AuditLog(directory: directory, installKey: AuditLog.makeInstallKey())

            // 这三样东西是这份纪录最不该顺手收藏的:一份忠实记下「我帮你挡掉了这把金钥」的档案,
            // 自己就是一份金钥清单;查询字串里住着 session token;临床视窗标题里住着病人姓名与健保号码。
            let apiKey = "sk-live-9f2b7c14aa5d4e0192837465bcaf0011"
            let queryString = "session=abc123def456&patient=0912345678"
            let windowTitle = "王小明 病历 9012345678 - 诊所系统"

            let text = "请用这把金钥 \(apiKey) 呼叫服务"
            guard let range = text.range(of: apiKey) else {
                Issue.record("测试资料本身就找不到那把金钥,後面的断言全部不成立。")
                return
            }
            let offset = text.distance(from: text.startIndex, to: range.lowerBound)

            try log.append(AuditRecord(
                event: .blocked,
                policyVersion: "2026.07.1",
                itemID: "item-1",
                kind: .text,
                byteCount: text.utf8.count,
                contentTag: log.contentTag(forText: text),
                sourceBundleID: "com.example.a",
                sourceAppName: "程式甲",
                provenance: .high,
                sourceHost: "portal.example.org",
                queryTag: log.queryTag(forQueryString: queryString),
                titleCharacterCount: AuditLog.titleCharacterCount(windowTitle),
                detectorHits: [AuditDetectorHit(detectorID: "api-key", detectorVersion: "3",
                                           verdict: .matched, offset: offset, length: apiKey.count)],
                note: "命中 api-key 侦测器,不上传"
            ))

            let bytes = try rawBytesOfEveryLogFile(in: directory)
            #expect(!bytes.contains(apiKey))
            #expect(!bytes.contains(queryString))
            #expect(!bytes.contains("session=abc123def456"))
            #expect(!bytes.contains(windowTitle))
            #expect(!bytes.contains("王小明"))
            #expect(!bytes.contains("9012345678"))
            // 原文本身当然也不该在里面,纪录只留得住「有多长、在第几个字」。
            #expect(!bytes.contains("请用这把金钥"))

            // 该留的还是要留得住,否则这份纪录就没有稽核价值了。
            #expect(bytes.contains("api-key"))
            #expect(bytes.contains("portal.example.org"))
            let stored = try log.query(event: .blocked, since: nil, sourceBundleID: nil)
            #expect(stored.count == 1)
            #expect(stored[0].detectorHits.count == 1)
            #expect(stored[0].detectorHits[0].offset == offset)
            #expect(stored[0].detectorHits[0].length == apiKey.count)
            #expect(stored[0].detectorHits[0].verdict == .matched)
            #expect(stored[0].titleCharacterCount == windowTitle.count)
            #expect(stored[0].queryTag != nil)
        }
    }

    // MARK: 老实的报告

    @Test("三节报告在完全没有资料时,三个标题一个都不会少,盲点那一节照样把话讲完")
    func 空纪录的报告仍然有三节() throws {
        try withTemporaryAuditDirectory { directory in
            let log = try AuditLog(directory: directory, installKey: AuditLog.makeInstallKey())

            // 一份完全空的纪录。这正是最危险的时刻:前两节都是「没有」,
            // 若第三节此时消失,读的人会得到一个比事实更肯定的结论。
            let empty = try log.report(sourceBundleID: nil, sourceHost: nil)
            #expect(empty.contains(AuditLog.reportHeadingDeparted))
            #expect(empty.contains(AuditLog.reportHeadingStayed))
            #expect(empty.contains(AuditLog.reportHeadingUndetermined))
            // 第三节必须点名那个结构性盲点:同一份内容从别的程式重新复制一次,这份纪录看不见。
            #expect(empty.contains("重新复制一次"))

            // 问一个从来没出现过的程式,同样要三节齐全。
            let unknownApp = try log.report(sourceBundleID: "com.example.never", sourceHost: nil)
            #expect(unknownApp.contains(AuditLog.reportHeadingDeparted))
            #expect(unknownApp.contains(AuditLog.reportHeadingStayed))
            #expect(unknownApp.contains(AuditLog.reportHeadingUndetermined))
        }
    }

    @Test("有资料时,送出、挡下与说不准三类各自落在正确的一节,送失败的那些算在说不准里")
    func 三节报告把事件分对了() throws {
        try withTemporaryAuditDirectory { directory in
            let log = try AuditLog(directory: directory, installKey: AuditLog.makeInstallKey())
            let bundle = "com.example.a"

            try log.append(AuditRecord(event: .sent, policyVersion: "2026.07.1", itemID: "sent-1",
                                       byteCount: 100, sourceBundleID: bundle, sourceAppName: "程式甲",
                                       provenance: .high, sourceHost: "example.org"))
            try log.append(AuditRecord(event: .blocked, policyVersion: "2026.07.1", itemID: "blocked-1",
                                       byteCount: 20, sourceBundleID: bundle, sourceAppName: "程式甲",
                                       provenance: .high, sourceHost: "example.org"))
            try log.append(AuditRecord(event: .failed, policyVersion: "2026.07.1", itemID: "failed-1",
                                       byteCount: 30, sourceBundleID: bundle, sourceAppName: "程式甲",
                                       provenance: .high, sourceHost: "example.org"))
            // 来源判断不可靠的一则:它写着的来源程式有可能根本就是错的,所以只能进第三节。
            try log.append(AuditRecord(event: .sent, policyVersion: "2026.07.1", itemID: "murky-1",
                                       byteCount: 10, sourceBundleID: bundle, sourceAppName: "程式甲",
                                       provenance: .low))

            let report = try log.report(sourceBundleID: bundle, sourceHost: "example.org")
            #expect(report.contains(AuditLog.reportHeadingDeparted))
            #expect(report.contains(AuditLog.reportHeadingStayed))
            #expect(report.contains(AuditLog.reportHeadingUndetermined))
            #expect(report.contains("sent-1"))
            #expect(report.contains("blocked-1"))
            #expect(report.contains("failed-1"))
            // 用网址来问的时候,没有记录到网址的那一则正是最该被看见的,不可以被网址条件筛掉。
            #expect(report.contains("murky-1"))
            // 被挡下来不等於没被抓下来,报告必须把这件事讲明白,否则使用者会以为本机也没有了。
            #expect(report.contains("仍然存在这台机器的本机历史里"))
            // 送失败绝对不能被算成「确定没有离开」。
            let stayedSection = report.components(separatedBy: AuditLog.reportHeadingStayed)
            #expect(stayedSection.count == 2)
            let stayedBody = stayedSection[1].components(separatedBy: AuditLog.reportHeadingUndetermined)[0]
            #expect(!stayedBody.contains("failed-1"))

            let summary = try log.summarySentence()
            #expect(summary.contains("离开过这台机器"))
            #expect(!summary.isEmpty)
        }
    }
}
