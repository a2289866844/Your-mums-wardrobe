import Foundation
import Testing
import ClipdCore   // 这里刻意不用 @testable:侦测器是公开 API,测试也应该只透过公开 API 验证。

// 这一组测试锁住的是「什麽东西不可以在使用者不知情的情况下离开这台机器」。
//
// 侦测器坏掉的样子跟一般功能坏掉不一样:它不会当机,也不会报错,只会安静地少回报一笔,
// 而少回报的那一笔就是一把外流的金钥或一个外流的健康号码。使用者不会察觉,日志也不会有痕迹
// (而且日志本来就不该有痕迹 —— 记录被挡下来的金钥等於再建一个金钥仓库)。
// 所以底下每一条测试都是一个已知样本:样本还在,就代表那条规则还活着。

@Suite("内容侦测器")
struct DetectorsTests {

    // MARK: - 小工具

    private func detectorIDs(_ text: String) -> [String] {
        Detectors.scan(text).map(\.detectorID)
    }

    private func hits(_ text: String, from detectorID: String) -> [DetectorHit] {
        Detectors.scan(text).filter { $0.detectorID == detectorID }
    }

    // MARK: - 卑诗省个人健康号码

    @Test("卑诗省健康号码:官方公布的示范号码 9012372173 必须通过模数十一验算")
    func publishedBritishColumbiaExampleIsAccepted() {
        // 官方的算式:加权总和是 151,151 除以 11 的整数部分是 13,13 乘 11 是 143,
        // 151 减 143 是 8,11 减 8 是 3,而号码的第十位正是 3。
        #expect(detectorIDs("健康号码是 9012372173").contains("bc.phn"))
    }

    @Test(
        "卑诗省健康号码:任何一位数字被改掉都必须验不过",
        arguments: [
            "9012372174",   // 只改末位。第十位的权重是 0,所以总和不变,但检查码 3 对不上 4。
            "9012372163",   // 改倒数第二位,总和变成 148,检查码变成 6,对不上末位的 3。
            "8012372173",   // 开头不是 9,连算都不必算。
        ]
    )
    func oneDigitMutationsAreRejected(number: String) {
        #expect(!detectorIDs("健康号码是 \(number)").contains("bc.phn"), "「\(number)」不该被当成有效的健康号码。")
    }

    // MARK: - 加拿大社会保险号码

    @Test("加拿大社会保险号码:检查码正确的号码要被抓到")
    func validCanadianSINIsDetected() {
        #expect(detectorIDs("社会保险号码 130 692 544").contains("ca.sin"))
    }

    @Test("加拿大社会保险号码:检查码不对的号码不可以被抓到")
    func invalidCanadianSINIsIgnored() {
        #expect(!detectorIDs("社会保险号码 130 692 545").contains("ca.sin"))
    }

    // MARK: - 信用卡号

    @Test("信用卡号:通过 Luhn 又符合发卡号段的号码要被抓到")
    func luhnValidCardIsDetected() {
        #expect(detectorIDs("卡号 4111 1111 1111 1111").contains("pan.luhn"))
    }

    @Test("信用卡号:只改一位、让 Luhn 验不过的号码不可以被抓到")
    func luhnInvalidCardIsIgnored() {
        #expect(!detectorIDs("卡号 4111 1111 1111 1112").contains("pan.luhn"))
    }

    // MARK: - 厂商金钥字首

    @Test(
        "厂商金钥字首:清单上的每一个字首都必须被抓到",
        arguments: [
            "AKIA", "ASIA",
            "ghp_", "gho_", "ghs_", "ghu_", "ghr_", "github_pat_",
            "sk-ant-api03-", "sk-proj-",
            "xoxb-", "xoxp-", "xapp-",
            "sk_live_", "rk_live_",
            "AIza", "glpat-", "npm_", "dop_v1_",
        ]
    )
    func everyVendorPrefixIsDetected(prefix: String) {
        let text = prefix + String(repeating: "a", count: 32)
        let found = hits(text, from: "vendor.key-prefix")
        #expect(found.count == 1, "「\(prefix)」没有被厂商字首侦测器抓到,或是被重复回报了。")
        #expect(found.first?.offset == 0)
        #expect(found.first?.length == text.utf16.count)
    }

    @Test("厂商金钥字首:字首後面没有接够长的本体就不算数")
    func bareVendorPrefixWithoutBodyIsIgnored() {
        #expect(!detectorIDs("这份文件提到 AKIA 这四个字母").contains("vendor.key-prefix"))
    }

    // MARK: - JSON Web Token

    @Test("JSON Web Token:标头解得开而且带有 alg 栏位的权杖要被抓到")
    func jsonWebTokenWithRealHeaderIsDetected() {
        // 标头解开後是 {"alg":"HS256","typ":"JWT"},这是真的解得开的样本,不是随便凑的字串。
        let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
            + ".eyJzdWIiOiIxMjM0NTY3ODkwIn0"
            + ".dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(detectorIDs(token).contains("jwt.decodable-header"))
    }

    @Test("JSON Web Token:形状像但标头解不出 JSON 物件的字串不算权杖")
    func threeSegmentsWithoutJSONHeaderIsNotAToken() {
        #expect(!detectorIDs("aaaaaaaaaaaaaaaaaaaa.bbbbbbbbbb.cccccccccc").contains("jwt.decodable-header"))
    }

    // MARK: - 私钥开头标记

    @Test(
        "私钥:只看得到开头那一行、完全没有结尾也必须挡下来",
        arguments: [
            "-----BEGIN OPENSSH PRIVATE KEY-----",
            "-----BEGIN RSA PRIVATE KEY-----",
            "-----BEGIN PRIVATE KEY-----",
            "-----BEGIN ENCRYPTED PRIVATE KEY-----",
            "-----BEGIN PGP PRIVATE KEY BLOCK-----",
        ]
    )
    func privateKeyArmourAloneIsEnough(armour: String) {
        // 复制到一半、或视窗只截到上半部,都是很常见的情况;等结尾那一行等於对这些情况全部放行。
        #expect(detectorIDs(armour).contains("pem.private-key-armour"), "「\(armour)」没有被挡下来。")
    }

    @Test("私钥:公钥的开头标记不可以被误判成私钥")
    func publicKeyArmourIsNotAPrivateKey() {
        #expect(!detectorIDs("-----BEGIN PUBLIC KEY-----").contains("pem.private-key-armour"))
    }

    // MARK: - 网址内嵌帐号密码

    @Test("网址:帐号密码直接写在网址里要被抓到")
    func uriWithInlineCredentialsIsDetected() {
        #expect(detectorIDs("postgres://admin:hunter2secret@db.internal:5432/main").contains("uri.inline-credentials"))
    }

    @Test("网址:一般没有帐密的网址不可以被抓到")
    func ordinaryURIIsIgnored() {
        #expect(!detectorIDs("https://example.com/docs/getting-started").contains("uri.inline-credentials"))
    }

    // MARK: - 设定档里的秘密指派

    @Test("设定档:变数名称带有秘密字眼、值也够长的指派要被抓到")
    func environmentSecretAssignmentIsDetected() {
        let line = "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
        #expect(detectorIDs(line).contains("env.secret-assignment"))
    }

    @Test("设定档:值是空的或短到没有意义的指派不算数", arguments: ["API_KEY=", "API_KEY=abc"])
    func trivialAssignmentIsIgnored(line: String) {
        #expect(!detectorIDs(line).contains("env.secret-assignment"))
    }

    // MARK: - 乱度

    @Test("乱度:四十个字元的随机 base64 字串要被抓到")
    func entropyCatchesRandomBase64Run() {
        // 这一串没有任何厂商字首、没有检查码、也不在任何清单上,能接住它的只有乱度。
        #expect(detectorIDs("kQ7vZm2XpL9dRw4TgY6bN1sHc8FjA3eU5oI0zVxB").contains("entropy.high-variance"))
    }

    @Test("乱度:格式完整的 UUID 不可以被当成金钥")
    func entropyIgnoresWellFormedUUID() {
        #expect(Detectors.scan("550e8400-e29b-41d4-a716-446655440000").isEmpty)
    }

    @Test("乱度:档案路径不可以被当成金钥")
    func entropyIgnoresFilePath() {
        #expect(Detectors.scan("/Users/kakitwan/dev/clipd/Sources/ClipdCore/Detectors.swift").isEmpty)
    }

    @Test("乱度:附近有 git 词汇的四十位十六进位杂凑不可以被当成金钥")
    func entropyIgnoresGitObjectHashInContext() {
        let hash = "9f2c8b1e4d7a6f3b0c5e8a1d4f7b2e9c6a3d0f5b"
        #expect(!detectorIDs("commit \(hash) 动到了迁移档").contains("entropy.high-variance"))
        // 同一串杂凑,附近没有任何 git 词汇时就必须回到「像金钥」的判断 ——
        // 抑制的依据是上下文,不是长度本身,否则任何四十位十六进位的金钥都会被放行。
        #expect(detectorIDs(hash).contains("entropy.high-variance"))
    }

    @Test("乱度:一整句中文不可以被当成金钥")
    func entropyIgnoresChineseSentence() {
        // 中文没有词间空白,整句话是一个连续字串,而 CJK 字元集大到每个字几乎都只出现一次。
        // 若没有把非 ASCII 字元当成断点,这一句的乱度会超过门槛,结果是所有中文内容都上不了云端。
        #expect(Detectors.scan("病人今天回诊,血压一百五十,已经把降压药的剂量调高了一级。").isEmpty)
    }

    // MARK: - 光学损伤那一趟

    @Test("光学损伤:大写 O 被读成数字零的权杖,要靠折叠那一趟救回来")
    func opticalDamagePassRecoversTokenWhereLetterOBecameZero() {
        // 这个样本模拟的是从截图辨识出来的文字:gho_ 的小写 o 被读成了数字零。
        // 原文那一趟对 gh0_ 完全没有反应(字首对不上,而这一串刻意压得乱度极低,乱度也接不住),
        // 所以命中只可能来自折叠那一趟。前面那段中文同时验证了位置有正确换算回原文座标。
        let prefix = "金钥是 "
        let damaged = "gh0_" + String(repeating: "a", count: 32)
        let text = prefix + damaged
        let all = Detectors.scan(text)

        #expect(all.count == 1, "除了字首那一笔之外不该有别的命中,实际拿到:\(all.map(\.detectorID))")
        #expect(all.first?.detectorID == "vendor.key-prefix")
        #expect(all.first?.offset == (prefix as NSString).length)
        #expect(all.first?.length == (damaged as NSString).length)
    }

    @Test("光学损伤:整串被读成全形的金钥要被还原回来")
    func opticalDamagePassRecoversFullwidthToken() {
        // 实测的另一种损伤:整段字被辨识成全形。折叠那一趟会先做相容性正规化,把全形变回 ASCII。
        let leading = "金钥:"
        let fullwidth = "ｓｋ－ｐｒｏｊ－Ａ９ｆ２Ｘｑａｂｃｄｅｆｇｈｉｊｋｌｍｎｏｐ"
        let found = hits(leading + fullwidth, from: "vendor.key-prefix")
        #expect(found.count == 1)
        #expect(found.first?.offset == (leading as NSString).length)
        #expect(found.first?.length == (fullwidth as NSString).length)
    }

    @Test("光学损伤:金钥中间被插进一个空白也要被接住")
    func opticalDamagePassToleratesOneInjectedSpace() {
        // 实测样本 `sk-proj-A9f_2Xq!` 被辨识时,中间凭空多了一个空白,金钥因此断成两截。
        // 折叠那一趟允许跨过最多一个空白;原文那一趟不允许,免得把金钥後面那句英文也算进来。
        #expect(hits("sk-proj- A9f2Xqabcdefghijklmnop", from: "vendor.key-prefix").count == 1)
        #expect(hits("npm_ 这一行只是在讲安装说明而已", from: "vendor.key-prefix").isEmpty)
    }

    @Test("光学损伤:同一把金钥的完好版本与受损版本都要被抓到,而且各只回报一笔")
    func bothIntactAndDamagedFormsAreDetectedOnce() {
        let body = String(repeating: "a", count: 32)
        #expect(hits("gho_" + body, from: "vendor.key-prefix").count == 1)
        #expect(hits("gh0_" + body, from: "vendor.key-prefix").count == 1)
    }

    // MARK: - 只回报位置,不回报内容

    @Test("命中只带位置与长度,而且那个范围要正好盖住那段秘密")
    func hitsCarryPositionOnlyAndTheRangeIsCorrect() {
        let secret = "AKIA" + String(repeating: "B", count: 16)
        let leading = "前面这段中文说明,金钥是 "
        let text = leading + secret + " 後面还有别的字。"
        let found = hits(text, from: "vendor.key-prefix")

        #expect(found.count == 1)
        guard let hit = found.first else { return }
        #expect(hit.offset == (leading as NSString).length)
        #expect(hit.length == (secret as NSString).length)
        // 用回报的范围去原文里取,取出来必须正好是那段秘密 —— 这是位置正确的唯一硬证据。
        let recovered = (text as NSString).substring(with: NSRange(location: hit.offset, length: hit.length))
        #expect(recovered == secret)
        // 而且回报本身不可以夹带任何一段原文,标签只能是一句固定的说明。
        #expect(!hit.label.contains(secret))
        #expect(!hit.detectorID.contains(secret))
    }

    // MARK: - 版本号

    @Test("版本号:整包政策与每一笔命中都必须带得出版本,否则快取的乾净结论会失去意义")
    func versionsArePresent() {
        #expect(!Detectors.policyVersion.isEmpty)
        let found = Detectors.scan("-----BEGIN OPENSSH PRIVATE KEY-----")
        #expect(!found.isEmpty)
        for hit in found {
            #expect(!hit.detectorVersion.isEmpty)
            #expect(!hit.detectorID.isEmpty)
            #expect(!hit.label.isEmpty)
        }
    }

    // MARK: - 已知缺口:这几条测试钉住的是「现在抓不到」,不是「应该抓不到」

    @Test(
        "已知缺口:没有形状的秘密现在完全穿得过去",
        arguments: [
            "陈大文今天回诊,主诉胸闷三天。",          // 临床叙述里的病人姓名
            "correct-horse-battery-staple",          // 密码短语式的密码,乱度比乱码还低
            "验证码 483920",                          // 六位数一次性验证码,太短也没有检查码
            "internal-token-9f3a2b",                 // 公司内部自订格式、没有厂商字首的权杖
        ]
    )
    func shapelessSecretsCurrentlyPassThrough(sample: String) {
        // 这几条不是在庆祝,是在把缺口钉在明处。哪一天有人补上了对应的规则,这条测试会转红,
        // 那时候请改测试、并且把 policyVersion 往前跳 —— 而不是把测试删掉。
        #expect(Detectors.scan(sample).isEmpty, "「\(sample)」现在被抓到了,请一并更新 policyVersion 与档案结尾的缺口说明。")
    }
}
