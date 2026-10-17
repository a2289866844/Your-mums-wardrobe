// clipd 的内容侦测器 —— 在一则剪贴板内容离开这台机器之前,先看看它像不像一把金钥、一个身分号码,
// 或者别的「送出去就收不回来」的东西。
//
// 这个档案只做一件事:读一段文字,回报「在第几个字元开始、长几个字元的地方,像有某种秘密」。
// 它不决定要不要上传,也不知道封锁清单长什麽样子 —— 那是呼叫端的政策问题。把「辨识」跟「决策」
// 分开写,是为了让这里的每一条规则都可以被单独测试,也让日後有人想调整政策时不必动到侦测逻辑。
//
// 三条贯穿整个档案的铁则,後面的人请不要绕过:
//
// 一、只回报位置,绝不回报内容。DetectorHit 里没有任何栏位放得下被比对到的那段字,这是刻意的。
//    一份「我挡下了哪些金钥」的日志,本身就是一个金钥仓库 —— 而且是一个没人在保护、没人在轮替、
//    却集中了全公司秘密的仓库。真正安全的作法是让那段字从来没有被复制到第二个地方去。
//    档案里唯一会短暂持有原文的地方是 JWT 的标头解码,那个字串只活在那个函式的堆叠上。
//
// 二、每个侦测器带自己的版本号,而 policyVersion 只要任何一条规则改动就要跟着往前跳。
//    六个月後,一句「这则内容在版本 X 时被判定为乾净」如果 X 早於某条规则的诞生日,那句话什麽都
//    不代表 —— 它只说明当时没有人去看那个面向,不代表当时那个面向是安全的。呼叫端若要快取判定
//    结果,必须连同这两个版本号一起存,版本一对不上就重扫。
//
// 三、诚实写下每个侦测器抓不到什麽。档案最後有一整段「这里抓不到的东西」,那不是免责声明,
//    是给未来的人看的地图:知道哪里没有围栏,才不会把没围栏的地方当成安全区。
//
// 座标系统:offset 与 length 的单位一律是 UTF-16 码元,也就是 NSRange 与 AppKit 文字元件用的单位。
// 选这个单位是为了呼叫端可以直接拿去在 NSTextView 上画底线,不必再做一次转换。

import Foundation

// MARK: - 对外的结果型别

/// 一次命中。刻意不带被比对到的原文,理由见档案开头的铁则一。
public struct DetectorHit: Sendable, Equatable {
    public let detectorID: String       // 稳定的侦测器识别码,快取与统计都靠它对齐
    public let detectorVersion: String  // 这条规则自己的版本,规则一改就要跟着改
    public let label: String            // 一句写给人看的完整中文句子,说明这里被认为藏了什麽
    public let offset: Int              // 起点,单位是原始文字的 UTF-16 码元
    public let length: Int              // 长度,单位同上

    public init(detectorID: String, detectorVersion: String, label: String, offset: Int, length: Int) {
        self.detectorID = detectorID
        self.detectorVersion = detectorVersion
        self.label = label
        self.offset = offset
        self.length = length
    }
}

// MARK: - 对外的入口

public enum Detectors {

    /// 整包规则的版本。任何一个侦测器的规则、门槛、字首清单有改动,这里就要往前跳,
    /// 否则旧的快取判定会被误认为仍然有效,而那正是「乾净」这两个字最危险的用法。
    public static let policyVersion = "2026-07-25.1"

    /// 扫描一段文字,回报所有命中。结果依起点排序,同一个侦测器不会回报互相重叠的两笔。
    public static func scan(_ text: String) -> [DetectorHit] {
        guard !text.isEmpty else { return [] }
        let subject = clippedIfOversize(text)

        // 第一趟:照着原文扫。绝大多数命中来自这一趟,因为原文没有被任何东西破坏过。
        var hits = runAllDetectors(on: ScanTarget(text: subject, foldedIndexMap: nil), patterns: rawPatterns)

        // 第二趟:光学损伤修正趟。理由写在 foldForOpticalDamage 上面那段量测纪录里。
        let folded = foldWithIndexMap(subject)
        hits += runAllDetectors(
            on: ScanTarget(text: folded.text, foldedIndexMap: folded.map),
            patterns: foldedPatterns
        )

        return merge(hits)
    }

    // MARK: - 扫描规模的上限

    /// 单次扫描最多看这麽多 UTF-16 码元。
    ///
    /// 这是一个诚实的漏洞:超过上限的部分完全不会被扫,秘密若躺在一份三百万字的贴上内容的末尾,
    /// 这里会漏掉它。之所以还是留了上限,是因为抓取流程跑在使用者按下复制的那一瞬间,
    /// 一份几十 MB 的贴上内容如果在这里跑满所有侦测器,使用者感觉到的是整台机器卡住。
    /// 呼叫端若在意这个缺口,正确作法是对超长内容采取更保守的政策,而不是把上限调大。
    private static let maximumScannedUTF16Length = 1_048_576

    private static func clippedIfOversize(_ text: String) -> String {
        guard text.utf16.count > maximumScannedUTF16Length else { return text }
        // 用 Character 数量截断而不是 UTF-16 数量,是为了不切断代理对(切断会产生无效字串)。
        // 字元数一定不大於码元数,所以这样截出来的长度必然在上限之内。
        return String(text.prefix(maximumScannedUTF16Length))
    }
}

// MARK: - 扫描目标:同一份文字的两种座标

private struct ScanTarget {
    let text: String
    let nsText: NSString
    let characters: [Character]
    let utf16Starts: [Int]          // 第 i 个字元在这份文字里的 UTF-16 起点,最後一格是总长度
    let foldedIndexMap: [Int]?      // 折叠後的 UTF-16 位置 → 原文的 UTF-16 位置;nil 表示这趟就是原文

    init(text: String, foldedIndexMap: [Int]?) {
        self.text = text
        self.nsText = text as NSString
        var characters: [Character] = []
        var starts: [Int] = []
        characters.reserveCapacity(text.count)
        starts.reserveCapacity(text.count + 1)
        var cursor = 0
        for character in text {
            characters.append(character)
            starts.append(cursor)
            for scalar in character.unicodeScalars { cursor += UTF16.width(scalar) }
        }
        starts.append(cursor)
        self.characters = characters
        self.utf16Starts = starts
        self.foldedIndexMap = foldedIndexMap
    }

    /// 把这一趟的座标换算回原文座标。原文趟是恒等对应,折叠趟走索引对照表。
    func originalRange(utf16Offset: Int, utf16Length: Int) -> (offset: Int, length: Int) {
        guard let map = foldedIndexMap, !map.isEmpty else { return (utf16Offset, utf16Length) }
        let start = map[min(max(utf16Offset, 0), map.count - 1)]
        let end = map[min(max(utf16Offset + utf16Length, 0), map.count - 1)]
        return (start, max(0, end - start))
    }

    func hit(_ id: String, _ version: String, _ label: String, utf16Offset: Int, utf16Length: Int) -> DetectorHit {
        let mapped = originalRange(utf16Offset: utf16Offset, utf16Length: utf16Length)
        return DetectorHit(
            detectorID: id, detectorVersion: version, label: label,
            offset: mapped.offset, length: mapped.length
        )
    }

    func hit(_ id: String, _ version: String, _ label: String, characterRange: Range<Int>) -> DetectorHit {
        let start = utf16Starts[characterRange.lowerBound]
        let end = utf16Starts[characterRange.upperBound]
        return hit(id, version, label, utf16Offset: start, utf16Length: end - start)
    }
}

// MARK: - 光学损伤折叠

extension Detectors {

    /// 把一段文字折叠成「光学辨识过後长什麽样都一样」的形式,同时产出位置对照表。
    ///
    /// 为什麽需要这一趟:同一把金钥经过截图与文字辨识之後,字面上就不是同一串字了。在这台机器上
    /// 用一张真实的测试图量到的三件事 ——
    ///   一、JWT 标头的 `eyJhbGciOi` 被读成 `eyJhbGci0i`,大写 O 变成数字零,於是「解开标头看看有没有
    ///       alg 栏位」这条规则整个落空,因为解出来的已经不是合法的 base64。
    ///   二、`I10` 被读成 `110`,大写 I 变成数字一。
    ///   三、`sk-proj-A9f_2Xq!` 中间被插进一个空白,而结尾的惊叹号变成了全形的「!」。
    /// 结论很清楚:精确的字首比对最禁不起光学损伤,而「形状」跟「乱度」几乎不受影响。所以这里把
    /// 最常被认错的几组字元折叠到同一个代表字,然後拿折叠後的字首清单去比对折叠後的文字 ——
    /// 两边都折叠,原文与受损文字就会落在同一个形状上。
    ///
    /// 折叠方向一律是「字母折向数字」(O→0、I 与 l→1、S→5、B→8),挑这个方向没有特别的道理,
    /// 重点是两边用同一个方向,不是方向本身。
    ///
    /// 位置对照表:折叠是逐字元做的,每个原字元产生的替代字串里的每一个码元,都记住它来自原文的
    /// 哪个位置。这样折叠趟找到的命中才能换算回原文座标,而不是回报一组指向不存在文字的座标。
    ///
    /// 已知限制:这里的 NFKC 是逐字元做的,不是整串做的,所以跨字元的相容性合并不会发生。
    /// 选逐字元是因为整串正规化之後就再也拼不回位置对照表了,而回报错误的位置比少折叠一点更糟。
    fileprivate static func foldWithIndexMap(_ text: String) -> (text: String, map: [Int]) {
        var output = ""
        var map: [Int] = []
        output.reserveCapacity(text.utf16.count)
        map.reserveCapacity(text.utf16.count + 1)
        var cursor = 0
        for character in text {
            let replacement = foldCharacter(character)
            for scalar in replacement.unicodeScalars {
                for _ in 0..<UTF16.width(scalar) { map.append(cursor) }
            }
            output += replacement
            for scalar in character.unicodeScalars { cursor += UTF16.width(scalar) }
        }
        map.append(cursor)
        return (output, map)
    }

    /// 折叠单一字元。先做相容性正规化(全形标点、全形英数、连字等都会变回 ASCII),再折叠易混字元。
    fileprivate static func foldCharacter(_ character: Character) -> String {
        let normalized = String(character).precomposedStringWithCompatibilityMapping
        var output = ""
        output.reserveCapacity(normalized.unicodeScalars.count)
        for scalar in normalized.unicodeScalars {
            switch scalar {
            case "O", "o": output.append("0")   // 大小写 O 都会被读成零,gho_ 这种字首就是栽在小写 o 上
            case "I", "l": output.append("1")   // 大写 I 与小写 l 在多数字体里跟数字一几乎无法分辨
            case "S", "s": output.append("5")
            case "B": output.append("8")        // 小写 b 有明显的下半圆,实测没有被读错过,所以不折
            default: output.unicodeScalars.append(scalar)
            }
        }
        return output
    }

    fileprivate static func foldForOpticalDamage(_ text: String) -> String {
        text.map(foldCharacter).joined()
    }
}

// MARK: - 样式的组装与编译

extension Detectors {

    /// 样式由三种零件拼成,目的是让「字面值」这一种零件可以在折叠趟自动被折叠,
    /// 而不必手写两份正规表示式 —— 手写两份迟早会漏改一份,而漏改的那一份不会报错,只会静静地失效。
    fileprivate enum PatternPiece {
        case literal(String)     // 字面值,折叠趟会先折叠再跳脱
        case anyOf([String])     // 一组字面值择一,处理方式同上
        case raw(String)         // 原封不动的正规表示式片段,不折叠
    }

    fileprivate static func buildPattern(_ pieces: [PatternPiece], folded: Bool) -> String {
        var output = ""
        for piece in pieces {
            switch piece {
            case .literal(let value):
                output += NSRegularExpression.escapedPattern(for: folded ? foldForOpticalDamage(value) : value)
            case .anyOf(let values):
                let alternatives = values.map {
                    NSRegularExpression.escapedPattern(for: folded ? foldForOpticalDamage($0) : $0)
                }
                output += "(?:" + alternatives.joined(separator: "|") + ")"
            case .raw(let value):
                output += value
            }
        }
        return output
    }

    /// 编译一个样式。样式全都是这个档案里的常数,执行期编译失败只可能是有人改坏了字面值,
    /// 所以开发期直接断言炸掉;正式版则让该侦测器安静失效 —— 但那是一个静悄悄的安全退化,
    /// 唯一能挡住它的是测试档里「每个侦测器都要在已知样本上命中」那几条测试,请不要删掉它们。
    fileprivate static func compile(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            assertionFailure("侦测器的正规表示式编译失败,样式是「\(pattern)」,错误是「\(error)」。")
            return nil
        }
    }

    fileprivate struct Patterns {
        let isOpticalDamagePass: Bool
        let privateKeyArmour: NSRegularExpression?
        let puttyPrivateKey: NSRegularExpression?
        let jwtCandidate: NSRegularExpression?
        let credentialURI: NSRegularExpression?
        let environmentAssignment: NSRegularExpression?
        let uuid: NSRegularExpression?
        let hexColourRun: NSRegularExpression?
        let gitVocabulary: NSRegularExpression?
        let vendorPrefixes: [(prefix: [Character], minimumSuffix: Int)]

        init(folded: Bool) {
            isOpticalDamagePass = folded
            privateKeyArmour = compile(buildPattern([
                .literal("-----BEGIN "),
                .raw("[A-Z0-9 ]{0,40}"),
                .literal("PRIVATE KEY"),
                .raw("(?:"), .literal(" BLOCK"), .raw(")?"),
                .literal("-----"),
            ], folded: folded))

            puttyPrivateKey = compile(buildPattern([
                .literal("PuTTY-User-Key-File-"), .raw("[0-9]"),
            ], folded: folded))

            // 三段 base64url。第一段要求至少 16 个字元,是因为任何真实的 JWT 标头解开之後至少是
            // {"alg":"..."},编码回去必定超过这个长度;门槛太低会让一堆用点号分隔的档名进来。
            jwtCandidate = compile(
                "(?<![A-Za-z0-9_.-])([A-Za-z0-9_-]{16,1024})\\.([A-Za-z0-9_-]{8,4096})\\.([A-Za-z0-9_-]{0,2048})(?![A-Za-z0-9_.-])"
            )

            credentialURI = compile(
                "[A-Za-z][A-Za-z0-9+.\\-]{1,20}://[^\\s:/@]{1,64}:[^\\s:/@]{1,128}@[^\\s/?#]{1,255}"
            )

            environmentAssignment = compile(buildPattern([
                .raw("^[ \\t]*(?:"), .literal("export"), .raw("[ \\t]+)?[A-Za-z0-9_]{0,63}"),
                .anyOf(["KEY", "SECRET", "TOKEN", "PASSWORD", "PASSWD", "CREDENTIAL", "PRIVATE"]),
                .raw("[A-Za-z0-9_]{0,63}[ \\t]*[:=][ \\t]*"),
                .raw("(?:\"[^\"\\n]{6,256}\"|'[^'\\n]{6,256}'|[^\\s#\\n]{6,512})"),
            ], folded: folded), options: [.caseInsensitive, .anchorsMatchLines])

            uuid = compile(
                "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
            )

            hexColourRun = compile("^(?:#[0-9a-fA-F]{3,8}[,;]?)+$")

            gitVocabulary = compile(buildPattern([
                .raw("(?:"),
                .anyOf(["git", "commit", "sha", "blob", "tree", "HEAD", "rebase", "merge",
                        "checkout", "revision", "parent", "diff", "branch", "cherry-pick"]),
                .raw(")"),
            ], folded: folded), options: [.caseInsensitive])

            // 每个字首後面至少要再接多少个 token 字元才算数。门槛来自各家金钥的实际长度:
            // 太短会把文章里刚好出现的四个字母当成 AWS 金钥,太长则会漏掉被截断的金钥。
            let table: [(String, Int)] = [
                ("AKIA", 12), ("ASIA", 12),
                ("ghp_", 20), ("gho_", 20), ("ghs_", 20), ("ghu_", 20), ("ghr_", 20), ("github_pat_", 20),
                ("sk-ant-api03-", 20), ("sk-proj-", 20),
                ("xoxb-", 10), ("xoxp-", 10), ("xapp-", 10),
                ("sk_live_", 10), ("rk_live_", 10),
                ("AIza", 30), ("glpat-", 12), ("npm_", 20), ("dop_v1_", 20),
            ]
            vendorPrefixes = table.map {
                (Array(folded ? foldForOpticalDamage($0.0) : $0.0), $0.1)
            }
        }
    }

    // NSRegularExpression 的文件明确说明它在编译完成後是执行绪安全的,所以这两组样式各编译一次、
    // 之後被任意多条执行绪共用都没有问题,不必每次扫描都重新编译一遍。
    fileprivate static let rawPatterns = Patterns(folded: false)
    fileprivate static let foldedPatterns = Patterns(folded: true)
}

// MARK: - 各个侦测器

extension Detectors {

    fileprivate static func runAllDetectors(on target: ScanTarget, patterns: Patterns) -> [DetectorHit] {
        var hits: [DetectorHit] = []
        hits += detectPrivateKeyArmour(target, patterns)
        hits += detectJSONWebToken(target, patterns)
        hits += detectVendorKeyPrefix(target, patterns)
        hits += detectNumericIdentifiers(target)
        hits += detectCredentialURI(target, patterns)
        hits += detectEnvironmentAssignment(target, patterns)
        hits += detectHighEntropyRun(target, patterns)
        return hits
    }

    private static func allMatches(_ regex: NSRegularExpression?, _ target: ScanTarget) -> [NSTextCheckingResult] {
        guard let regex else { return [] }
        return regex.matches(in: target.text, options: [], range: NSRange(location: 0, length: target.nsText.length))
    }

    // MARK: 一、私钥档案的开头标记

    /// 只看开头那一行就判定,不等结尾那一行。半份金钥仍然是外流的金钥,而且使用者复制到一半、
    /// 或视窗只截到上半部,都是很常见的情况 —— 等结尾等於对这些情况全部放行。
    ///
    /// 抓不到:已经被 base64 再包一层的金钥、放在 JSON 字串里被跳脱成 `\n` 的金钥
    /// (那种情况下 `-----BEGIN` 还在,所以其实抓得到)、以及完全没有标头的裸金钥资料。
    private static func detectPrivateKeyArmour(_ target: ScanTarget, _ patterns: Patterns) -> [DetectorHit] {
        let id = "pem.private-key-armour"
        let version = "1.0"
        let label = "这段文字里出现了私密金钥档案的开头标记,内容极可能是一把可以直接拿去用的私钥。"
        var hits: [DetectorHit] = []
        for match in allMatches(patterns.privateKeyArmour, target) + allMatches(patterns.puttyPrivateKey, target) {
            hits.append(target.hit(id, version, label,
                                   utf16Offset: match.range.location, utf16Length: match.range.length))
        }
        return hits
    }

    // MARK: 二、JSON Web Token

    /// 三段 base64url,而且第一段解得开、解出来是一个带有 alg 栏位的 JSON 物件。
    ///
    /// 全部都挡,包括那些「本来就是公开的」匿名金钥。理由是:要区分公开与私密就得去读 role 栏位,
    /// 而一旦走上白名单这条路,某天一把真正的 service_role 金钥就会因为某个栏位长得像白名单而被放行。
    /// 反过来看,误挡一个公开权杖的代价是零 —— 那则内容仍然会被完整抓取、仍然搜寻得到、仍然贴得出来,
    /// 只是不会被送上云端而已。两边的代价差了不知道几个数量级,所以这里不做区分。
    ///
    /// 只解第一段,而且解出来的东西只用来看有没有 alg 这个键,看完就让它离开作用域。第二段(payload)
    /// 一个字都不碰:那里面照惯例躺着使用者编号与电子邮件,把它读出来放进任何变数都是在制造新的外泄面。
    ///
    /// 抓不到:标头被光学损伤破坏过的权杖(解不开就没有 alg 可看),那种情况要靠乱度侦测器接住。
    private static func detectJSONWebToken(_ target: ScanTarget, _ patterns: Patterns) -> [DetectorHit] {
        let id = "jwt.decodable-header"
        let version = "1.0"
        let label = "这段文字里出现了一个 JSON Web Token,它的标头解得开而且带有演算法栏位。"
        var hits: [DetectorHit] = []
        for match in allMatches(patterns.jwtCandidate, target) {
            guard match.numberOfRanges >= 2 else { continue }
            let headerRange = match.range(at: 1)
            guard headerRange.location != NSNotFound else { continue }
            // 这个字串只存在於这一圈回圈之内,不会被回传、写档或印出来。
            let header = target.nsText.substring(with: headerRange)
            guard let data = base64URLDecoded(header),
                  let json = try? JSONSerialization.jsonObject(with: data),
                  let object = json as? [String: Any],
                  object["alg"] != nil
            else { continue }
            hits.append(target.hit(id, version, label,
                                   utf16Offset: match.range.location, utf16Length: match.range.length))
        }
        return hits
    }

    private static func base64URLDecoded(_ text: String) -> Data? {
        var normalized = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while normalized.count % 4 != 0 { normalized.append("=") }
        return Data(base64Encoded: normalized)
    }

    // MARK: 三、各家服务的金钥字首

    /// 字首比对是所有侦测器里最准的一个:命中几乎不会是误判。代价是它只认得清单上那几家,
    /// 而清单永远落後於世界 —— 今天新出的服务用什麽字首,这里一无所知。
    ///
    /// 抓不到:任何不在清单上的字首、公司内部自订格式的权杖、以及被改过大小写的金钥。
    private static func detectVendorKeyPrefix(_ target: ScanTarget, _ patterns: Patterns) -> [DetectorHit] {
        let id = "vendor.key-prefix"
        let version = "1.0"
        let label = "这段文字里出现了云端服务惯用的金钥开头,而且後面接着够长的金钥本体。"
        let characters = target.characters
        var hits: [DetectorHit] = []

        for (prefix, minimumSuffix) in patterns.vendorPrefixes where !prefix.isEmpty {
            var index = 0
            while index + prefix.count <= characters.count {
                let precededByToken = index > 0 && isASCIIAlphanumeric(characters[index - 1])
                if !precededByToken, matchesPrefix(prefix, in: characters, at: index) {
                    var end = index + prefix.count
                    var bodyLength = 0
                    var hasSkippedInjectedSpace = false
                    while end < characters.count {
                        if isTokenCharacter(characters[end]) {
                            bodyLength += 1
                            end += 1
                            continue
                        }
                        // 光学辨识会在金钥中间凭空插进一个空白 —— 实测样本 `sk-proj-A9f_2Xq!` 就是这样
                        // 断成两截的。所以折叠那一趟允许跨过最多一个空白,原文那一趟不允许:原文里的空白
                        // 是真的空白,跨过去会把「npm_ 後面那句英文」也当成金钥本体。
                        if patterns.isOpticalDamagePass, !hasSkippedInjectedSpace, characters[end] == " ",
                           end + 1 < characters.count, isTokenCharacter(characters[end + 1]) {
                            hasSkippedInjectedSpace = true
                            end += 1
                            continue
                        }
                        break
                    }
                    if bodyLength >= minimumSuffix {
                        hits.append(target.hit(id, version, label, characterRange: index..<end))
                    }
                    index = max(end, index + 1)
                } else {
                    index += 1
                }
            }
        }
        return hits
    }

    private static func matchesPrefix(_ prefix: [Character], in characters: [Character], at index: Int) -> Bool {
        for offset in 0..<prefix.count where characters[index + offset] != prefix[offset] { return false }
        return true
    }

    private static func isASCIIAlphanumeric(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }

    private static func isTokenCharacter(_ character: Character) -> Bool {
        isASCIIAlphanumeric(character) || character == "_" || character == "-"
    }

    // MARK: 四到六、数字型的号码

    /// 信用卡号、加拿大社会保险号码、卑诗省个人健康号码共用同一个「数字串」的切法,
    /// 所以放在一起扫,但各自是独立的侦测器、各自有版本号。
    private static func detectNumericIdentifiers(_ target: ScanTarget) -> [DetectorHit] {
        var hits: [DetectorHit] = []
        for run in digitRuns(target) {
            if passesLuhn(run.digits), hasPlausibleIssuerPrefix(run.digits) {
                hits.append(target.hit(
                    "pan.luhn", "1.0",
                    "这串数字通过了信用卡号的检查码验算,而且开头符合已知发卡机构的号段。",
                    characterRange: run.characterRange))
            }
            if isCanadianSIN(run.digits) {
                hits.append(target.hit(
                    "ca.sin", "1.0",
                    "这串数字符合加拿大社会保险号码的位数、开头限制与检查码规则。",
                    characterRange: run.characterRange))
            }
            if isBritishColumbiaPHN(run.digits) {
                hits.append(target.hit(
                    "bc.phn", "1.0",
                    "这串数字符合卑诗省个人健康号码的模数十一检查码规则。",
                    characterRange: run.characterRange))
            }
        }
        return hits
    }

    private struct DigitRun {
        let digits: [Int]
        let characterRange: Range<Int>
    }

    /// 切出「数字串」。中间允许空白与连字号当作分隔符,因为卡号与保险号码在现实里几乎都是分组写的。
    ///
    /// 折叠趟有一个已知的副作用:一整句由 S、O、I、B 组成的英文字会被折成数字,理论上可以凑出一串
    /// 通过检查码的假号码。这是刻意接受的 —— 误判的方向是「这则内容不上传」,那是安全的那一边。
    private static func digitRuns(_ target: ScanTarget) -> [DigitRun] {
        let characters = target.characters
        let maximumSeparators = 6
        var runs: [DigitRun] = []
        var index = 0
        while index < characters.count {
            guard let firstDigit = asciiDigitValue(characters[index]) else { index += 1; continue }
            var digits = [firstDigit]
            var separators = 0
            var end = index + 1
            while end < characters.count {
                if let value = asciiDigitValue(characters[end]) {
                    digits.append(value)
                    end += 1
                } else if (characters[end] == " " || characters[end] == "-"),
                          separators < maximumSeparators,
                          end + 1 < characters.count,
                          asciiDigitValue(characters[end + 1]) != nil {
                    separators += 1
                    end += 1
                } else {
                    break
                }
            }
            runs.append(DigitRun(digits: digits, characterRange: index..<end))
            index = end
        }
        return runs
    }

    private static func asciiDigitValue(_ character: Character) -> Int? {
        guard let ascii = character.asciiValue, ascii >= 48, ascii <= 57 else { return nil }
        return Int(ascii - 48)
    }

    /// Luhn 检查码。信用卡号与加拿大社会保险号码共用同一套算法。
    private static func passesLuhn(_ digits: [Int]) -> Bool {
        guard digits.count >= 2 else { return false }
        var sum = 0
        var shouldDouble = false
        for digit in digits.reversed() {
            var value = digit
            if shouldDouble {
                value *= 2
                if value > 9 { value -= 9 }
            }
            sum += value
            shouldDouble.toggle()
        }
        return sum % 10 == 0
    }

    /// 发卡机构号段。Luhn 只有十分之一的鉴别力,单靠它会把每十个长数字串误判一个,
    /// 所以一定要再加号段判断。清单不完整,少数区域性卡别会被漏掉。
    private static func hasPlausibleIssuerPrefix(_ digits: [Int]) -> Bool {
        let count = digits.count
        guard (13...19).contains(count) else { return false }
        func leading(_ n: Int) -> Int {
            digits.prefix(n).reduce(0) { $0 * 10 + $1 }
        }
        let two = leading(2), three = leading(3), four = leading(4)
        if digits[0] == 4, [13, 16, 19].contains(count) { return true }                       // Visa
        if (51...55).contains(two), count == 16 { return true }                               // Mastercard 旧号段
        if (2221...2720).contains(four), count == 16 { return true }                          // Mastercard 新号段
        if two == 34 || two == 37, count == 15 { return true }                                // American Express
        if four == 6011 || two == 65 || (644...649).contains(three), [16, 19].contains(count) { return true } // Discover
        if (3528...3589).contains(four), (16...19).contains(count) { return true }            // JCB
        if (300...305).contains(three) || four == 3095 || two == 36 || two == 38 || two == 39,
           count == 14 { return true }                                                        // Diners Club
        if two == 62, (16...19).contains(count) { return true }                               // UnionPay
        return false
    }

    /// 加拿大社会保险号码:九位数,首位在 1 到 7 或 9,而且通过 Luhn。
    /// 首位 0 与 8 目前未发放,所以拿来当作额外的过滤条件。
    ///
    /// 抓不到:任何刚好通过 Luhn 的九位数流水号都会被误判成社会保险号码,这个误判率不低。
    private static func isCanadianSIN(_ digits: [Int]) -> Bool {
        guard digits.count == 9 else { return false }
        let first = digits[0]
        guard (1...7).contains(first) || first == 9 else { return false }
        return passesLuhn(digits)
    }

    /// 卑诗省个人健康号码,模数十一。
    ///
    /// 完全照卑诗省卫生厅公布的算法写:十位数、开头是 9,把第一到第十位分别乘上
    /// 0、2、4、8、5、10、9、7、3、0,加总得到 sum;q 取 sum 除以 11 的整数部分,r 等於 sum 减去 11q,
    /// 检查码等於 11 减 r,检查码要等於第十位数字才算有效。
    ///
    /// 官方的示范号码 9012372173 走一遍:总和是 151,151 除以 11 的整数部分是 13,13 乘 11 是 143,
    /// 151 减 143 是 8,11 减 8 是 3,而第十位正是 3,所以有效。这个例子被钉在测试档里。
    ///
    /// 关於 r 等於 0 或 1:官方文件没有说这两种情况该怎麽办。这里判定为无效,因为算出来的检查码会是
    /// 11 或 10,都是两位数,而检查码只有一位可以放。**这一条是推论,不是文件写的**,如果哪天拿到
    /// 官方对这两种情况的说明,请以文件为准并同时把 policyVersion 往前跳。
    private static func isBritishColumbiaPHN(_ digits: [Int]) -> Bool {
        let weights = [0, 2, 4, 8, 5, 10, 9, 7, 3, 0]
        guard digits.count == 10, digits[0] == 9 else { return false }
        var sum = 0
        for position in 0..<10 { sum += digits[position] * weights[position] }
        let quotient = sum / 11
        let remainder = sum - 11 * quotient
        guard remainder != 0, remainder != 1 else { return false }
        return (11 - remainder) == digits[9]
    }

    // MARK: 七、网址里直接写着帐号密码

    /// 抓不到:密码里含有 `@` 或 `/` 的网址(那种写法本来就该做百分号编码,但现实里有人不做)。
    private static func detectCredentialURI(_ target: ScanTarget, _ patterns: Patterns) -> [DetectorHit] {
        let id = "uri.inline-credentials"
        let version = "1.0"
        let label = "这个网址把帐号与密码直接写在网址里面,任何看得到这段文字的人都拿得到那组密码。"
        return allMatches(patterns.credentialURI, target).map {
            target.hit(id, version, label, utf16Offset: $0.range.location, utf16Length: $0.range.length)
        }
    }

    // MARK: 八、环境变数档里的秘密指派

    /// 键名带有秘密字眼、而且值不是空的也不是敷衍的短字串,才算数。
    ///
    /// 抓不到:键名没有那几个字眼的秘密(例如 `DB_DSN`、`AUTH`、`SIGNING`)、值短於六个字元的真金钥。
    /// 会误判:键名刚好包含那几个字眼的无害设定,例如 `MONKEY_NAME=bananas` 里面就藏着 KEY。
    /// 误判的方向仍然是「不上传」,所以这里选择宁可宽一点。
    private static func detectEnvironmentAssignment(_ target: ScanTarget, _ patterns: Patterns) -> [DetectorHit] {
        let id = "env.secret-assignment"
        let version = "1.0"
        let label = "这一行看起来是设定档里的指派,变数名称带有秘密的字眼,而且右边的值不是空的或占位字串。"
        return allMatches(patterns.environmentAssignment, target).map {
            target.hit(id, version, label, utf16Offset: $0.range.location, utf16Length: $0.range.length)
        }
    }

    // MARK: 九、乱度

    /// 对每一段不含空白的 ASCII 字串算 Shannon 乱度,长度二十以上、超过门槛就当成机器产生的秘密。
    /// 门槛依字元集分开设,因为字元集本身就限制了乱度的上限:十六进位最多 4 位元,base64 最多 6 位元。
    ///
    /// 这是唯一一个不依赖任何字面清单的侦测器,所以也是唯一有机会接住「没听过的服务的金钥」的一个。
    /// 代价是它同时会对一堆无害的东西起反应,所以下面那串抑制规则不是可有可无的修补,是它能不能用的关键。
    ///
    /// 为什麽非 ASCII 字元会把一段字切断:中文没有词间空白,一整句中文病历就是一个几十字的连续字串,
    /// 而 CJK 的字元集大到一句话里几乎每个字都只出现一次 —— 那种情况算出来的乱度天生就超过任何门槛。
    /// 如果不切断,这个侦测器会对每一句中文病历都叫一次,结果就是没有任何中文内容上得了云端,
    /// 而使用者只会得到「这东西坏了」的结论,然後把整个防线关掉。
    /// 代价是:一把紧贴着中文、中间连一个空白都没有的金钥,乱度这一关看不到它 ——
    /// 那种情况要靠字首与形状那几个侦测器接住,它们不看这里的切法。
    ///
    /// 抓不到:短於二十个字元的金钥、由英文单字组成的密码短语(乱度低得像一般文字)。
    private static func detectHighEntropyRun(_ target: ScanTarget, _ patterns: Patterns) -> [DetectorHit] {
        let id = "entropy.high-variance"
        let version = "1.0"
        let label = "这一段不含空白的长字串乱度偏高,形状像是机器产生的金钥或权杖,不像人写出来的文字。"
        let minimumRunLength = 20
        let characters = target.characters
        func belongsToRun(_ character: Character) -> Bool {
            character.isASCII && !character.isWhitespace
        }
        var hits: [DetectorHit] = []
        var index = 0

        while index < characters.count {
            if !belongsToRun(characters[index]) { index += 1; continue }
            var end = index
            while end < characters.count, belongsToRun(characters[end]) { end += 1 }
            defer { index = end }

            guard end - index >= minimumRunLength else { continue }
            let run = String(characters[index..<end])
            let shape = runShape(run)
            guard shannonEntropy(run) > shape.threshold else { continue }
            guard !isEntropySuppressed(run, target: target, characterRange: index..<end, patterns: patterns)
            else { continue }
            hits.append(target.hit(id, version, label, characterRange: index..<end))
        }
        return hits
    }

    private enum RunShape {
        case hexadecimal, base58, base64Like, other

        var threshold: Double {
            switch self {
            case .hexadecimal: 3.0
            case .base64Like: 4.5
            case .base58: 4.2
            case .other: 4.3
            }
        }
    }

    /// 先判十六进位,再判 base58,最後才判 base64。base58 的字元集是 base64 的子集,先判 base58
    /// 等於对它套用比较低的门槛(4.2),那正是我们要的:base58 少了四个字元,乱度上限本来就比较低。
    private static let hexadecimalCharacters = Set("0123456789abcdefABCDEF")
    // base58 刻意少了 0、O、I、l 这四个人眼分不清的字元,那正是它被发明出来的原因。
    private static let base58Characters = Set("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
    private static let base64LikeCharacters = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=-_")

    private static func runShape(_ run: String) -> RunShape {
        if run.allSatisfy({ hexadecimalCharacters.contains($0) }) { return .hexadecimal }
        if run.allSatisfy({ base58Characters.contains($0) }) { return .base58 }
        if run.allSatisfy({ base64LikeCharacters.contains($0) }) { return .base64Like }
        return .other
    }

    private static func shannonEntropy(_ run: String) -> Double {
        guard !run.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for character in run { counts[character, default: 0] += 1 }
        let total = Double(run.count)
        var entropy = 0.0
        for count in counts.values {
            let probability = Double(count) / total
            entropy -= probability * log2(probability)
        }
        return entropy
    }

    /// 抑制规则。每一条都对应一种「长得很像金钥但其实天天出现」的东西,不抑制的话乱度侦测器会吵到
    /// 没有人愿意开着它,而一个被关掉的侦测器等於不存在的侦测器。
    private static func isEntropySuppressed(
        _ run: String, target: ScanTarget, characterRange: Range<Int>, patterns: Patterns
    ) -> Bool {
        let fullRange = NSRange(location: 0, length: (run as NSString).length)

        // 一、格式完整的 UUID。它天生就是随机的,但它不是秘密。
        if patterns.uuid?.firstMatch(in: run, options: [], range: fullRange) != nil { return true }

        // 二、看起来是 git 物件杂凑,而且附近有 git 词汇。只看长度会连金钥一起抑制,所以要看上下文。
        if (run.count == 40 || run.count == 64), runShape(run) == .hexadecimal,
           hasGitVocabularyNearby(target: target, characterRange: characterRange, patterns: patterns) {
            return true
        }

        // 三、data URI。内嵌的图片是 base64,乱度天生就高,而且长度动辄上万。
        if run.hasPrefix("data:") { return true }

        // 四、一整串十六进位色码,例如设计稿贴过来的色票清单。
        if patterns.hexColourRun?.firstMatch(in: run, options: [], range: fullRange) != nil { return true }

        // 五、档案路径。路径里的目录名拼起来乱度可以很高,但它不是秘密。
        // 刻意排除含有 :// 的字串,因为那是网址 —— 网址的查询字串里可能真的躺着一把金钥。
        if !run.contains("://"),
           run.hasPrefix("/") || run.hasPrefix("~/") || run.hasPrefix("./") || run.hasPrefix("../") {
            return true
        }
        return false
    }

    private static func hasGitVocabularyNearby(
        target: ScanTarget, characterRange: Range<Int>, patterns: Patterns
    ) -> Bool {
        let windowRadius = 40
        let lower = max(0, characterRange.lowerBound - windowRadius)
        let upper = min(target.characters.count, characterRange.upperBound + windowRadius)
        let window = String(target.characters[lower..<upper])
        let range = NSRange(location: 0, length: (window as NSString).length)
        return patterns.gitVocabulary?.firstMatch(in: window, options: [], range: range) != nil
    }

    // MARK: - 合并两趟的结果

    /// 同一个侦测器在原文趟与折叠趟往往会命中同一个位置,这里把重叠的那些收敛成一笔。
    /// 不同侦测器之间的重叠保留,因为「这里同时像卡号也像健康号码」对呼叫端是有意义的资讯。
    private static func merge(_ hits: [DetectorHit]) -> [DetectorHit] {
        let maximumReportedHits = 500
        let sorted = hits.sorted { left, right in
            if left.offset != right.offset { return left.offset < right.offset }
            if left.detectorID != right.detectorID { return left.detectorID < right.detectorID }
            return left.length > right.length
        }
        // 因为已经依起点排序,同一个侦测器「有没有跟先前任何一笔重叠」只需要跟先前的最大终点比一次。
        // 这一步是效能考量:改成两两互比的话,一份贴上内容若产生上万笔候选,光是合并就会让抓取卡住。
        var furthestEndByDetector: [String: Int] = [:]
        var kept: [DetectorHit] = []
        for hit in sorted where hit.length > 0 {
            if kept.count >= maximumReportedHits { break }
            let furthestEnd = furthestEndByDetector[hit.detectorID] ?? Int.min
            guard hit.offset >= furthestEnd else { continue }
            kept.append(hit)
            furthestEndByDetector[hit.detectorID] = max(furthestEnd, hit.offset + hit.length)
        }
        return kept
    }
}

// MARK: - 这里抓不到的东西
//
// 这一段不是免责声明,是给未来的人看的地图。上面九个侦测器加起来能挡住的,是「有固定形状的秘密」;
// 没有形状的秘密,它一个也挡不住。具体来说,下面这几类东西会原封不动地通过整套侦测,
// 请不要因为「扫过了」就以为它们被挡下来了:
//
//   一、一段临床叙述里的病人姓名。「陈大文今天回诊,血压 150/95」在这里的每一条规则底下都是乾净的:
//      它没有字首、没有检查码、乱度跟一般中文一样低。这是这套侦测器最大的一个缺口,而且它刚好就是
//      这个产品最可能遇到的那种内容。
//   二、密码短语式的密码。`correct-horse-battery-staple` 由英文单字组成,乱度低到远在门槛之下,
//      而它的强度其实比一串乱码还高。乱度侦测器天生看不见这种密码。
//   三、六位数的一次性验证码。它太短(远低於二十字元的门槛)、字元集太小、也没有检查码可验。
//   四、公司内部自订格式、没有任何厂商字首的权杖。如果它同时又不够长或不够乱,就完全没有东西接得住它。
//
// 还有一件事要讲清楚:这套侦测器只看得到「文字」。图片里的字要先经过文字辨识才会走到这里,
// 而辨识本身会漏字;二进位内容、压缩档、被 base64 再包一层的东西,在这里全都是隐形的。
