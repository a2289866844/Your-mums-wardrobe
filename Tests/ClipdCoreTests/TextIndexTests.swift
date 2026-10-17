import Testing
import ClipdCore   // 这里刻意不用 @testable:所有被测的东西都是公开 API,测试也应该只透过公开 API 验证。

// 这一组测试锁住的是搜寻能不能用。
// 中文断词一旦改坏,症状不是当机也不是报错,而是「明明存了却搜不到」,
// 那种失败非常难在使用时察觉,所以规则的每一条都在这里被钉住。

@Suite("中文搜寻断词")
struct TextIndexTests {

    /// 把展开结果切回一个个 token,方便逐一检查。
    private func tokens(_ s: String) -> [String] {
        s.split(separator: " ").map(String.init)
    }

    // MARK: - 双字元:最常见也最关键的情况

    @Test("文件端遇到「血壓」要同时索引两个单字与一个重叠双字元")
    func documentSideExpandsTwoCharacterWord() {
        #expect(TextIndex.documentTokens("血壓") == "血 壓 血壓")
    }

    @Test("查询端搜「血壓」只吐重叠双字元,不吐任何落单的单字")
    func querySideEmitsOnlyGrams() {
        #expect(TextIndex.queryTokens("血壓") == "血壓")
    }

    @Test("简体的「血压」与繁体走同一套规则")
    func simplifiedChineseUsesTheSameRule() {
        #expect(TextIndex.documentTokens("血压") == "血 压 血压")
        #expect(TextIndex.queryTokens("血压") == "血压")
    }

    // MARK: - 单字:两端的答案必须一样

    @Test("只有一个「血」字时,文件端与查询端都只吐这个字")
    func singleCharacterIsIdenticalOnBothSides() {
        #expect(TextIndex.documentTokens("血") == "血")
        #expect(TextIndex.queryTokens("血") == "血")
    }

    @Test("只有一个「壓」字时,文件端与查询端都只吐这个字")
    func anotherSingleCharacterIsIdenticalOnBothSides() {
        #expect(TextIndex.documentTokens("壓") == "壓")
        #expect(TextIndex.queryTokens("壓") == "壓")
    }

    // MARK: - 回归测试:查询端多吐一个落单字就会漏搜

    @Test("回归:查询端在任何长度的中文词上都不可以吐出落单的单字")
    func querySideNeverEmitsALoneCharacter() {
        // 这一条是整个档案存在的理由。FTS5 把空白读成 AND,
        // 查询字串里只要混进一个落单的单字,任何缺少该单字独立 token 的文件都会被静静筛掉,
        // 使用者看到的是「资料明明在却搜不到」,而且没有任何错误讯息。
        let inputs = ["血壓", "陳大文", "病人血壓正常", "糖尿病", "回診"]
        for input in inputs {
            let produced = tokens(TextIndex.queryTokens(input))
            let loneCharacters = produced.filter { $0.count == 1 }
            #expect(loneCharacters.isEmpty, "查询「\(input)」吐出了落单的单字:\(loneCharacters)")
            #expect(produced.count == input.count - 1, "查询「\(input)」的双字元数量不对:\(produced)")
        }
    }

    @Test("三个字的「陳大文」查询端刚好吐两个重叠双字元")
    func threeCharacterQueryProducesTwoGrams() {
        #expect(TextIndex.queryTokens("陳大文") == "陳大 大文")
    }

    // MARK: - 中英混排

    @Test("中英数字混排时,中文逐字切,英数整段成一个 token")
    func mixedChineseAndEnglish() {
        #expect(TextIndex.documentTokens("高血壓 metformin 500mg")
                == "高 血 壓 高血 血壓 metformin 500mg")
        #expect(TextIndex.queryTokens("高血壓 metformin 500mg")
                == "高血 血壓 metformin 500mg")
    }

    @Test("中文与英文之间没有空白时也要各自成段")
    func chineseAndLatinSplitWithoutWhitespace() {
        #expect(TextIndex.documentTokens("血壓normal") == "血 壓 血壓 normal")
    }

    @Test("标点会把词切开,不可以跨过标点产生双字元")
    func punctuationBreaksRuns() {
        // 若「壓正」出现在结果里,代表标点没有把两段切开,搜寻会搜到不该搜到的东西。
        let produced = tokens(TextIndex.documentTokens("血壓,正常"))
        #expect(produced == ["血", "壓", "血壓", "正", "常", "正常"])
        #expect(!produced.contains("壓正"))
    }

    // MARK: - 纯英文与边界输入

    @Test("纯英文整段转成小写,让搜寻不分大小写")
    func pureASCIIIsLowercased() {
        #expect(TextIndex.documentTokens("Patient Blood Pressure") == "patient blood pressure")
        #expect(TextIndex.queryTokens("Patient Blood Pressure") == "patient blood pressure")
    }

    @Test("空字串两端都回传空字串,不可以当机")
    func emptyStringProducesEmptyOutput() {
        #expect(TextIndex.documentTokens("") == "")
        #expect(TextIndex.queryTokens("") == "")
    }

    @Test("只有标点与空白时回传空字串,呼叫端应视为没有查询条件")
    func punctuationOnlyProducesEmptyOutput() {
        #expect(TextIndex.documentTokens("，。！？「」——…… ") == "")
        #expect(TextIndex.queryTokens("，。！？「」——…… ") == "")
    }

    // MARK: - 基本多文种平面之外的字

    @Test("扩充 B 区的罕用字算一个字,不可以被拆成两半")
    func extensionBCharacterCountsAsOneCharacter() {
        // 这两个字在 UTF-16 里各占两个码元。若程式以码元为单位处理,
        // 切出来的双字元会是半个字接半个字的乱码,索引与查询永远对不起来。
        let rareWord = "\u{20000}\u{20001}"
        #expect(rareWord.count == 2, "前提检查:这个字串应该是两个字元")
        #expect(TextIndex.documentTokens(rareWord) == "\u{20000} \u{20001} \u{20000}\u{20001}")
        #expect(TextIndex.queryTokens(rareWord) == "\u{20000}\u{20001}")
    }

    @Test("单一个扩充 B 区的字要被当成中日韩文字,不可以并进英文段落")
    func extensionBCharacterIsTreatedAsCJK() {
        // 若扩充 B 区没有被认成中日韩文字,它会被当成一般字母而跟後面的英文黏成同一个 token。
        #expect(TextIndex.documentTokens("\u{20000}abc") == "\u{20000} abc")
    }

    @Test("假名与中日韩相容表意文字也要逐字切开")
    func kanaAndCompatibilityIdeographsAreCJK() {
        #expect(TextIndex.documentTokens("ひらがな").hasPrefix("ひ ら が な "))
        #expect(TextIndex.queryTokens("ひらがな") == "ひら らが がな")
    }

    // MARK: - 正规化

    @Test("全形英数会被正规化成半形,否则贴进来的字与打出来的字对不起来")
    func fullwidthIsNormalisedToHalfwidth() {
        #expect(TextIndex.documentTokens("ＮＯＲＭＡＬ") == "normal")
        #expect(TextIndex.queryTokens("５００ｍｇ") == "500mg")
    }

    // MARK: - 病态输入

    @Test("超长内容会被截在两万个 token,前面的部分仍然搜得到")
    func pathologicalInputIsCapped() {
        // 一段一万五千字的中文若不设限会展开成将近三万个 token。
        let huge = String(repeating: "血壓", count: 7_500)
        #expect(huge.count == 15_000, "前提检查:测试资料长度应为一万五千字")
        #expect(tokens(TextIndex.documentTokens(huge)).count == 20_000)
    }
}
