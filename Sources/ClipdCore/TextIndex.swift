import Foundation

// ── 这个档案在解决什么问题 ────────────────────────────────────────────────
//
// SQLite 内建的 unicode61 分词器只会用空白与标点切字,它看不懂中文。
// 「病人血壓正常」在它眼里是一整个 token,使用者搜「血壓」永远搜不到。
// 所以我们在存进索引之前,先自己把字串切成一串用空白隔开的 token,
// 让 unicode61 只负责按空白切,真正的断词规则由这个档案决定。
//
// 文件端(写进索引时)与查询端(使用者打字时)刻意采用不同的规则,这不是疏漏,
// 而是一个真实踩过的坑换来的:
//
//   文件端会同时索引「单字」与「重叠双字元」。索引「血 壓 血壓」的用意是,
//   使用者只打一个「血」字也要立刻有结果,不必打满两个字才看得到东西。
//
//   查询端只吐「重叠双字元」,而且绝对不能多吐一个落单的单字。
//   因为 FTS5 把查询字串里的空白读成 AND(而不是 OR)。
//   如果查询端沿用文件端的规则,搜「血壓」会展开成带落单字的「血壓 壓」,
//   FTS5 会理解成「同时含有『血壓』这个 token 而且含有『壓』这个 token」。
//   任何一篇文件只要没有独立的「壓」token 就会被静静地筛掉,
//   使用者看到的是「明明有这笔资料却搜不到」,而且完全没有错误讯息可循。
//
// 因此两个规则必须分开维护,任何一边改动前请先回头读上面这段。
//
// ─────────────────────────────────────────────────────────────────────────

/// 把要放进搜寻索引的文字,与使用者输入的搜寻字串,分别展开成 FTS5 吃得下的 token 串。
///
/// 这是一个纯函式的命名空间:没有任何状态,可以从任何执行绪呼叫。
public enum TextIndex {

    /// 文件端:把一段要写进索引的文字展开成 token 串。
    ///
    /// 中日韩文字会同时产生单字与重叠双字元,所以使用者打一个字就搜得到。
    /// - Parameter s: 原始文字,允许是空字串。
    /// - Returns: 用单一空白隔开的 token 串;若整段文字里没有任何可索引的内容,回传空字串。
    public static func documentTokens(_ s: String) -> String {
        tokenize(s, forQuery: false)
    }

    /// 查询端:把使用者打的搜寻字串展开成 token 串。
    ///
    /// 中日韩文字「只」产生重叠双字元,绝不额外吐出落单的单字,
    /// 否则那个单字会变成一个多余的 AND 条件,把本来该出现的结果筛掉。
    /// - Parameter s: 使用者输入的搜寻字串,允许是空字串。
    /// - Returns: 用单一空白隔开的 token 串;若使用者只打了标点或空白,回传空字串。
    ///            呼叫端拿到空字串时应该视为「没有查询条件」,不要把空字串丢给 FTS5 MATCH。
    public static func queryTokens(_ s: String) -> String {
        tokenize(s, forQuery: true)
    }
}

// MARK: - 内部实作

extension TextIndex {

    /// 单次展开最多吐出的 token 数量上限。
    ///
    /// 剪贴板什么都可能被贴进来:一整份原始码、一份 base64 附件、一份日志档。
    /// 若不设上限,一段一百万字的中文会展开成两百万个 token,
    /// 索引写入与记忆体都会被这一笔拖垮,使用者感受到的是整个程式卡住。
    /// 超过上限的部分会被直接截掉,不会 throw:
    /// 对使用者而言,那笔内容的「前面一大段」仍然搜得到,只有非常後面的尾巴搜不到,
    /// 这比整笔资料存不进去或程式无回应都要好。
    private static let maximumTokenCount = 20_000

    /// 需要逐字切开的中日韩文字范围。
    ///
    /// 这些范围用 Unicode 纯量的数值表示,涵盖扩充 B 区(0x20000 起),
    /// 那个区段落在基本多文种平面之外,在 UTF-16 里是一对代理项,
    /// 所以底下一律以 Character / Unicode.Scalar 为单位处理,绝不以 UTF-16 码元为单位,
    /// 否则一个扩充 B 区的字会被误当成两个字,切出来的双字元全部是乱的。
    private static let cjkScalarRanges: [ClosedRange<UInt32>] = [
        0x3040...0x30FF,    // 平假名与片假名
        0x3400...0x9FFF,    // 中日韩统一表意文字,含扩充 A 区
        0xF900...0xFAFF,    // 中日韩相容表意文字
        0x20000...0x2A6DF,  // 中日韩统一表意文字扩充 B 区,在基本多文种平面之外
    ]

    /// 判断一个字元该不该逐字切开。
    ///
    /// 只看第一个 Unicode 纯量就够了:中日韩文字本身是单一纯量,
    /// 後面若跟着变体选择符之类的组合符号,那些不改变它是不是汉字这件事。
    private static func isCJK(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value else { return false }
        return cjkScalarRanges.contains { $0.contains(value) }
    }

    /// 把输入正规化成 NFKC。
    ///
    /// 会有这一步是因为文字来源太杂:OCR 认出来的字、从网页贴过来的字、
    /// 从旧系统汇出的字,全形与半形混用(Ａ 与 A、５ 与 5),
    /// 而且同一个带音标的字母有时是预先组合好的、有时是拆成基底字母加组合符号的。
    /// 不先统一,写进索引的字与使用者打出来的字就会长得不一样,搜寻会无声地失败。
    private static func normalize(_ s: String) -> String {
        s.precomposedStringWithCompatibilityMapping
    }

    /// 展开的主流程:扫过每个字元,把连续的同类字元聚成一段(run),遇到分隔符就把那一段结算掉。
    private static func tokenize(_ raw: String, forQuery: Bool) -> String {
        var tokens: [String] = []
        var run: [Character] = []
        var runIsCJK = false

        /// 把手上累积的那一段结算成 token 并清空,让下一段重新开始。
        func flushRun() {
            guard !run.isEmpty else { return }
            let remaining = maximumTokenCount - tokens.count
            let produced = runIsCJK
                ? cjkTokens(from: run, forQuery: forQuery, limit: remaining)
                : latinTokens(from: run, limit: remaining)
            tokens.append(contentsOf: produced)
            run.removeAll(keepingCapacity: true)
        }

        for character in normalize(raw) {
            // 一旦吐满上限就停手,後面的字元连聚段都不必做,免得白白吃记忆体。
            guard tokens.count < maximumTokenCount else { break }

            let characterIsCJK = isCJK(character)
            // 除了中日韩文字之外,只有字母与数字算内容,其余一律当成分隔符。
            // 标点、空白、表情符号都落在这里,它们的作用是把两段内容切开。
            guard characterIsCJK || character.isLetter || character.isNumber else {
                flushRun()
                continue
            }
            // 中日韩与拉丁字母的切法完全不同,交界处一定要先把前一段结算掉。
            if characterIsCJK != runIsCJK {
                flushRun()
                runIsCJK = characterIsCJK
            }
            run.append(character)
        }
        flushRun()

        return tokens.joined(separator: " ")
    }

    /// 把一段连续的中日韩文字展开成 token。
    ///
    /// - Parameters:
    ///   - run: 一段连续的中日韩文字。空阵列会得到空结果,不会当机。
    ///   - forQuery: 是不是查询端。查询端只吐重叠双字元,理由见档案开头的说明。
    ///   - limit: 这一段最多还能吐出几个 token,已经吐满时传 0 或负数。
    private static func cjkTokens(from run: [Character], forQuery: Bool, limit: Int) -> [String] {
        // 用 first 取值而不是 run[0],这样空阵列走的是回传空结果这条路,不会有越界的可能。
        guard limit > 0, let first = run.first else { return [] }

        // 只有一个字的时候,文件端与查询端的答案一样:就是那个字本身。
        // 查询端在这里吐单字是安全的,因为它是整段唯一的 token,不会变成多余的 AND 条件。
        guard run.count >= 2 else { return [String(first)] }

        var out: [String] = []
        out.reserveCapacity(min(limit, run.count * 2))

        // 文件端先吐所有单字,让使用者打一个字就有结果。查询端跳过这一段。
        if !forQuery {
            for character in run {
                guard out.count < limit else { return out }
                out.append(String(character))
            }
        }
        // 两端都要吐重叠双字元:N 个字会产生 N-1 个,例如「高血壓」→「高血」「血壓」。
        for index in 0..<(run.count - 1) {
            guard out.count < limit else { return out }
            out.append(String(run[index...index + 1]))
        }
        return out
    }

    /// 把一段连续的拉丁字母或数字整段当成一个 token,并转成小写让搜寻不分大小写。
    private static func latinTokens(from run: [Character], limit: Int) -> [String] {
        guard limit > 0, !run.isEmpty else { return [] }
        return [String(run).lowercased()]
    }
}
