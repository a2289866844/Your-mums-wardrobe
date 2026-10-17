import CryptoKit
import Foundation

// ═══════════════════════════════════════════════════════════════════════════════
// 【禁 令】 本程式对 nlmkb 只准下 index 这一个子指令,别的一律禁止。
//
// 永远不准执行 nlmkb push、nlmkb sync、nlmkb scan、nlmkb distill,
// 也永远不准直接写入那条管线的状态资料库。理由都在它自己的原始码里查证过:
//   一、push 与 sync 一开头就把「待办的远端删除队列」整个排干(nlmkb/pipeline.py:117),而限制笔数的
//      limit 参数要到 :130 才被读到。换句话说,就算我们只想同步一笔,它还是会先把队列里累积的每一笔
//      远端删除全部送出去。那是使用者的资料,不是我们的,我们没有资格代替他按下去。
//   二、scan 会直接 unlink 掉本机页面,没有垃圾桶、没有二次确认,一次误判就是永久遗失。
//   三、直接写它的检索资料库也没有意义:nlmkb/retrieve.py:145 重建索引的第一件事就是 DROP TABLE,
//      我们写进去的列保证会被抹掉。
//
// 我们只做两件事:把剪贴内容写成 markdown 放进它的 sources 资料夹,然後请它重建索引。
// index 之所以是唯一被允许的子指令,是因为它只读档案、只重盖自己的检索表,不动任何原始资料。
// ═══════════════════════════════════════════════════════════════════════════════

/// 知识库桥接的设定。预设值指向这台机器上真实存在的那条管线,测试则改指暂存资料夹。
public struct KnowledgeBridgeConfig: Sendable {
    /// 一定要写进 nlmkb 的 wiki 输出目录底下的 sources。它的检索器只走访 sources 与 notebooks
    /// 两个子目录(nlmkb/retrieve.py:84),写在别处虽然搜得到,却读不回全文。
    public var wikiSourcesDirectory: URL
    /// nlmkb 执行档。nil 代表这台机器上没有那条管线,我们照样写档,只是不重建索引。
    public var indexCommand: URL?
    /// 累积几个档案就重建一次索引。
    public var batchSize: Int
    /// 累积几个位元组就重建一次索引。两个条件谁先到就算数。
    public var batchBytes: Int

    public init(wikiSourcesDirectory: URL, indexCommand: URL?, batchSize: Int, batchBytes: Int) {
        self.wikiSourcesDirectory = wikiSourcesDirectory
        self.indexCommand = indexCommand
        self.batchSize = batchSize
        self.batchBytes = batchBytes
    }

    /// 这台机器上的实际路径,已经对着真实档案确认过。
    public static func detectDefault() -> KnowledgeBridgeConfig {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let executable = home.appendingPathComponent("dev/notebooklm-kb/.venv/bin/nlmkb")
        // 执行档不在就当作没有,让 preflight 去把话讲清楚,而不是在这里假装它存在。
        let hasExecutable = FileManager.default.isExecutableFile(atPath: executable.path)
        // 2026-08-06 预设关掉自动重建索引。nlmkb index 目前是「全量 DROP + 重嵌」(还没有增量索引),
        // 每凑满一批剪贴就触发一次:会重烧 Voyage 额度、长时间锁住检索库,还曾在半途被中断而把索引清空。
        // 档案照常写进 sources(内容一份不丢),只是不再自动重建;要搜得到就手动跑一次 `nlmkb index`。
        // 等 nlmkb 的增量索引落地后,再 `defaults write dev.clipd.app ClipdAutoIndex -bool true` 开回来即可,不必再改码。
        let autoIndex = UserDefaults.standard.object(forKey: "ClipdAutoIndex") as? Bool ?? false
        let sources = home.appendingPathComponent("Desktop/KnowledgeBase/NotebookLM/sources", isDirectory: true)
        return KnowledgeBridgeConfig(wikiSourcesDirectory: sources,
                                     indexCommand: (hasExecutable && autoIndex) ? executable : nil,
                                     batchSize: 20, batchBytes: 64 * 1024)
    }
}

/// 一次写入的结果。sentence 是可以直接放上画面给使用者看的完整句子。
public struct BridgeOutcome: Sendable {
    public let fileURL: URL
    public let bytes: Int
    public let sentence: String
}

public enum BridgeError: Error, CustomStringConvertible {
    case invalidItemID(id: String)
    case cannotWriteFile(path: String, reason: String)
    case indexCommandNotConfigured
    case indexCommandMissing(path: String)
    case cannotLaunchIndexCommand(path: String, reason: String)
    case indexCommandFailed(status: Int32, output: String)
    case indexCommandTimedOut(seconds: Int)
    case blockedBySafetyCheck(reasons: [String])

    /// 这些句子有机会直接出现在使用者眼前,所以一律写成完整的句子。
    public var description: String {
        switch self {
        case let .invalidItemID(id): return "识别码「\(id)」把危险字元拿掉之後就空了,没办法拿它当档名,所以这一则没有写进知识库。"
        case let .cannotWriteFile(path, reason): return "写入 \(path) 失败,原因是 \(reason)。"
        case .indexCommandNotConfigured: return "这台机器上没有设定 nlmkb 执行档,所以没有办法重建索引;档案已经写好了,等有执行档时再建一次索引就找得到。"
        case let .indexCommandMissing(path): return "找不到 nlmkb 执行档 \(path),所以没有办法重建索引。"
        case let .cannotLaunchIndexCommand(path, reason): return "没办法启动 \(path),原因是 \(reason)。"
        case let .indexCommandFailed(status, output): return "重建索引失败,离开码是 \(status),它印出来的讯息是:\(output)"
        case let .indexCommandTimedOut(seconds): return "重建索引超过 \(seconds) 秒还没结束,已经把它中止了,以免整支程式一直卡在那里。"
        case let .blockedBySafetyCheck(reasons): return "为了安全起见拒绝写入知识库,理由是:" + reasons.joined(separator: "")
        }
    }
}

/// 把抓到的剪贴内容写进使用者本来就在用的本机知识库,让同一件事在那边也搜得到。
public final class KnowledgeBridge {
    /// 单一档案的字元上限抓 1100,是因为目标索引器一块(chunk)大约就是这个量级。
    /// 控制在一块之内,搜寻命中时整则内容会一起被读回来,不会被切成前後两半各缺一角。
    private static let maximumCharacters = 1_100
    /// 重建索引最多等这麽久。真的卡住时宁可中止,也不要让选单列上的程式整个停住。
    private static let indexTimeoutSeconds: TimeInterval = 180
    /// 管线设定档最多这麽久重读一次:每写一则就读一次太浪费,但也不能永远不重读,
    /// 因为使用者随时可能改那个档,而那个档一改错就是我们的封锁条件。
    private static let safetyRecheckSeconds: TimeInterval = 60

    private let config: KnowledgeBridgeConfig
    private let lock = NSLock()
    private var pendingFiles = 0
    private var pendingBytes = 0
    private var lastSafetyCheckAt: Date?
    private var cachedExclusionProblems: [String] = []

    public init(config: KnowledgeBridgeConfig) {
        self.config = config
    }

    /// 把一则剪贴内容写成一个 markdown 档。ocrText 是图片辨识出来的文字,没有就传 nil。
    public func write(_ item: ClipItem, ocrText: String?) throws -> BridgeOutcome {
        let blocking = currentSafetyReasons()
        guard blocking.isEmpty else { throw BridgeError.blockedBySafetyCheck(reasons: blocking) }

        // 档名一律是 clip-<识别码>.md。这个前缀让我们的档案不可能跟 nlmkb 自己的汇出撞名:
        // 它的汇出一律叫「<原始档名> (十六位十六进位雜凑).md」,档名结尾必定是那段括号;
        // 我们的档名结尾是识别码本身,两种形状不可能相同。
        let safeID = item.id.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !safeID.isEmpty else { throw BridgeError.invalidItemID(id: item.id) }
        let fileURL = config.wikiSourcesDirectory.appendingPathComponent("clip-\(safeID).md")

        let markdown = renderMarkdown(for: item, ocrText: ocrText, safeID: safeID)
        guard let data = markdown.data(using: .utf8) else { throw BridgeError.cannotWriteFile(path: fileURL.path, reason: "内容没办法编成 UTF-8。") }
        // 用 atomic 写,读的人才永远只会看到写完的档,不会读到写到一半的半截档案。
        do { try data.write(to: fileURL, options: .atomic) } catch {
            throw BridgeError.cannotWriteFile(path: fileURL.path, reason: error.localizedDescription)
        }

        lock.lock()
        pendingFiles += 1
        pendingBytes += data.count
        lock.unlock()

        let appName = item.sourceAppName ?? "不明的程式"
        return BridgeOutcome(fileURL: fileURL, bytes: data.count,
            sentence: "已经把这一则来自「\(appName)」的内容写进知识库,档名是 \(fileURL.lastPathComponent),大小 \(data.count) 个位元组。")
    }

    /// 已经写好、但还没重建索引的档案数。
    public var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingFiles
    }

    // MARK: - 批次重建索引

    /// 累积够了才重建索引。还没累积够就回 nil,真的跑过一次才回一句中文说明。
    public func reindexIfBatchReady() throws -> String? {
        lock.lock()
        let files = pendingFiles
        let bytes = pendingBytes
        let ready = files >= config.batchSize || bytes >= config.batchBytes
        lock.unlock()
        guard ready, files > 0 else { return nil }

        guard let executable = config.indexCommand else {
            // 没有执行档也要归零并照实说明。计数只是「什麽时候该重建」的依据,真正算数的是已经落地的档案;
            // 留着不归零,只会让之後每一次写入都重複报同一件事。
            resetPendingCounters()
            return "已经累积 \(files) 个档案、共 \(bytes) 个位元组,但是这台机器上没有设定 nlmkb 执行档,所以这一批没有重建索引。"
        }
        let output = try runIndexCommand(executable)
        resetPendingCounters()
        return "已经把累积的 \(files) 个档案、共 \(bytes) 个位元组送去重建索引,nlmkb 回报:\(shortened(output))"
    }

    /// 不管累积多少,现在就重建一次索引。使用者按「立刻同步」时走这一条。
    public func forceReindex() throws -> String {
        guard let executable = config.indexCommand else { throw BridgeError.indexCommandNotConfigured }
        lock.lock()
        let files = pendingFiles
        lock.unlock()
        let output = try runIndexCommand(executable)
        resetPendingCounters()
        return "已经立刻重建一次索引,这一批带上去的是 \(files) 个新档案,nlmkb 回报:\(shortened(output))"
    }

    private func resetPendingCounters() {
        lock.lock()
        pendingFiles = 0
        pendingBytes = 0
        lock.unlock()
    }

    private func shortened(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "它没有印出任何讯息,代表这一次没有需要回报的事。" }
        return trimmed.count > 300 ? String(trimmed.prefix(300)) + "…(後面省略)" : trimmed
    }

    /// 实际去跑 nlmkb。参数永远只有 "index" 这一个,理由写在档案最上面的禁令里。
    private func runIndexCommand(_ executable: URL) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw BridgeError.indexCommandMissing(path: executable.path) }
        // 输出导到暂存档而不是接管线:管线缓冲区一旦塞满,子行程会卡在写入永远不结束;写档没有这个上限。
        let logURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipd-nlmkb-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: logURL) }
        guard let sink = try? FileHandle(forWritingTo: logURL) else { throw BridgeError.cannotLaunchIndexCommand(path: executable.path, reason: "开不了暂存档 \(logURL.path) 来接它的输出。") }
        defer { try? sink.close() }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["index"]
        process.standardOutput = sink
        process.standardError = sink
        do {
            try process.run()
        } catch {
            throw BridgeError.cannotLaunchIndexCommand(path: executable.path, reason: error.localizedDescription)
        }

        // 用轮询等待而不是 terminationHandler,是因为轮询没有回呼的时序竞争,读起来也一眼看得懂。
        let deadline = Date().addingTimeInterval(Self.indexTimeoutSeconds)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning {
            process.terminate()
            throw BridgeError.indexCommandTimedOut(seconds: Int(Self.indexTimeoutSeconds))
        }

        let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        guard process.terminationStatus == 0 else {
            throw BridgeError.indexCommandFailed(status: process.terminationStatus, output: shortened(output))
        }
        return output
    }

    // MARK: - 行前检查

    /// 回报每一件会让这条路走不通的事。全部正常时回空阵列。
    public func preflight() -> [String] {
        directoryProblems() + executableProblems() + pipelineExclusionProblems()
    }

    /// 只有真的会挡住写入的那几项才算封锁条件,而且设定档的检查结果会快取一小段时间。
    private func currentSafetyReasons() -> [String] {
        let directory = directoryProblems()
        guard directory.isEmpty else { return directory }

        lock.lock()
        let fresh = lastSafetyCheckAt.map { Date().timeIntervalSince($0) < Self.safetyRecheckSeconds } ?? false
        let cached = cachedExclusionProblems
        lock.unlock()
        if fresh { return cached }
        let problems = pipelineExclusionProblems()
        lock.lock()
        lastSafetyCheckAt = Date()
        cachedExclusionProblems = problems
        lock.unlock()
        return problems
    }

    private func directoryProblems() -> [String] {
        let path = config.wikiSourcesDirectory.path
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) { return ["知识库的 sources 资料夹 \(path) 不存在,所以现在没有地方可以写。"] }
        if !isDirectory.boolValue { return ["路径 \(path) 存在,但它是一个档案而不是资料夹,没办法把内容写进去。"] }
        if !FileManager.default.isWritableFile(atPath: path) { return ["知识库的 sources 资料夹 \(path) 目前不给写入,请检查它的权限。"] }
        return []
    }

    private func executableProblems() -> [String] {
        guard let executable = config.indexCommand else { return ["这台机器上没有设定 nlmkb 执行档,内容写得进去,但是要等有人手动建一次索引才搜得到。"] }
        guard !FileManager.default.isExecutableFile(atPath: executable.path) else { return [] }
        return ["找不到 nlmkb 执行档 \(executable.path),写进去的内容要等它回来才会被索引到。"]
    }

    /// 检查那条管线的 config.toml 有没有把我们要写的地方排除在扫描之外。这是整个设计里最重要的一道闸:
    /// 它现在的 exclude_paths 含有 ~/Desktop/KnowledgeBase,所以我们写进保险库的档案永远不会进它的
    /// 状态资料库,也就永远不会被它上传或删除。万一哪天有人把那一行拿掉,我们的档案就会落进它的扫描
    /// 范围、被送到我们自己的安全闸之外,那时候这支程式必须拒绝再写,并且把这句话直接讲给使用者看。
    private func pipelineExclusionProblems() -> [String] {
        guard let configURL = pipelineConfigURL,
              let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            // 读不到设定档通常代表那条管线根本不在这台机器上,没有人会来扫我们,所以不算问题。
            return []
        }
        let target = config.wikiSourcesDirectory.standardizedFileURL.path
        // 不在它的扫描范围内就没有被它捡走的可能,排不排除都无所谓。
        let scanned = tomlStringArray(named: "scan_roots", in: text).contains { isPath(target, under: $0) }
        let excluded = tomlStringArray(named: "exclude_paths", in: text).contains { isPath(target, under: $0) }
        guard scanned, !excluded else { return [] }
        return ["nlmkb 的设定档 \(configURL.path) 已经不再把 \(target) 排除在扫描之外,"
              + "再写下去这些内容会被那条管线捡走、送到我们自己的安全闸之外,所以现在拒绝写入。"]
    }

    /// 设定档跟执行档在同一个专案里,所以从执行档往上推三层(bin、.venv、专案根)就找得到;
    /// 没有执行档时退回预设位置。
    private var pipelineConfigURL: URL? {
        guard let executable = config.indexCommand else {
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/notebooklm-kb/config.toml")
        }
        return executable.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("config.toml")
    }

    /// 只挑出我们需要的那两个阵列,不为了这件事拉一整个 TOML 函式库进来。
    /// 支援 key = ["a", "b"] 写成一行或跨多行,并且忽略每一行 # 之後的注解。
    private func tomlStringArray(named key: String, in text: String) -> [String] {
        guard let opening = text.range(of: "\(key)\\s*=\\s*\\[", options: .regularExpression),
              let closing = text.range(of: "]", range: opening.upperBound..<text.endIndex) else { return [] }
        let inner = text[opening.upperBound..<closing.lowerBound]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0] }
            .joined(separator: " ")
        return inner.split(separator: ",").compactMap {
            let cleaned = $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
            return cleaned.isEmpty ? nil : (cleaned as NSString).expandingTildeInPath
        }
    }

    /// 判断一条路径是不是落在某个资料夹底下。补上结尾斜线,/a/bc 才不会被误认成在 /a/b 底下。
    private func isPath(_ path: String, under directory: String) -> Bool {
        path == directory || path.hasPrefix(directory.hasSuffix("/") ? directory : directory + "/")
    }

    private func renderMarkdown(for item: ClipItem, ocrText: String?, safeID: String) -> String {
        let appName = item.sourceAppName ?? "不明的程式"
        let localStamp = Self.localFormatter.string(from: item.capturedAt)

        // frontmatter 刻意用跟 nlmkb 一模一样的五个键,让这些档案在它的资料夹里形状一致、不像异物。
        // original_path 用 clipd:// 这个自订协定,一眼就看得出来源是这支程式而不是某个真实档案。
        var head = """
        ---
        original_path: "clipd://item/\(safeID)"
        sha256: \(Self.frontmatterHash(for: item))
        notebook: "clipd 剪貼簿"
        exported_at: \(Self.isoFormatter.string(from: item.capturedAt))
        generated_by: clipd
        ---


        """

        // 正文一定要把中继资料再讲一次。理由是 nlmkb 的切块器在建索引之前就把 frontmatter 整块剥掉,
        // 只写在上面那一段的东西一律搜不到;而使用者日後最可能拿来搜的就是「哪个程式」跟「哪一天」,
        // 所以这两件事必须落在正文里,以本机时间写出来,他才认得。
        head += "# 从「\(appName)」复制的内容,时间是 \(localStamp)\n\n"
        var lines = ["- 来源程式:\(appName)" + (item.sourceBundleID.map { "(\($0))" } ?? ""),
                     "- 复制时间:\(localStamp)",
                     "- 内容种类:\(Self.kindNames[item.kind] ?? "其他型别")",
                     "- 来源判断的可信度:\(Self.provenanceNames[item.provenance] ?? "判断不出来")"]
        // 图片与档案只写存放路径,永远不写内容本身,理由见 sanitized(_:)。
        lines += item.representations.compactMap(\.blobPath).map { "- 原始内容存放在:\($0)" }
        head += lines.joined(separator: "\n") + "\n\n"

        var body = Self.sanitized(bodyText(for: item, ocrText: ocrText))
        let ellipsis = "\n\n(内容太长,这里只留前面这一段。完整内容还在 clipd 里,识别码是 \(safeID)。)"
        let room = Self.maximumCharacters - head.count - ellipsis.count - 1   // 减掉的 1 是结尾那个换行。
        if head.count + body.count >= Self.maximumCharacters { body = room > 0 ? String(body.prefix(room)) + ellipsis : ellipsis }
        return head + body + "\n"
    }

    private func bodyText(for item: ClipItem, ocrText: String?) -> String {
        var text = item.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = item.preview.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let ocr = ocrText?.trimmingCharacters(in: .whitespacesAndNewlines), !ocr.isEmpty else { return text }
        // 辨识结果有可能已经并进 searchText 了,重複写只会白白吃掉那 1100 字的额度。
        if text.contains(ocr) { return text }
        return text.isEmpty ? "图片里辨识出来的文字:\n\(ocr)" : "\(text)\n\n图片里辨识出来的文字:\n\(ocr)"
    }

    /// 把内嵌资料挡掉。绝对不可以把 base64 或图片本体写进 markdown,有两个理由:一是 nlmkb 有一个
    /// 清理指令会去改写任何含有 data URI 的页面,等於我们主动把自己的档案交给另一支程式编辑,那条
    /// 界线一破就再也说不清哪一段字是谁写的;二是一段 base64 就足以吃掉整份 1100 字的额度,把真正
    /// 搜得到的文字挤出这一块之外。
    private static func sanitized(_ text: String) -> String {
        var result = replace(#"data:[^\s)"'\]]{0,}"#, in: text, with: "(这里原本是一段内嵌资料,依规定没有写进来。)")
        result = replace("[A-Za-z0-9+/]{200,}={0,2}", in: result, with: "(这里原本是一长串编码资料,依规定没有写进来。)")
        result = replace("\n{3,}", in: result, with: "\n\n")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: template))
    }

    /// frontmatter 的 sha256 必须是六十四个十六进位字元,形状才跟 nlmkb 的汇出一致;
    /// ClipItem 的 contentHash 不保证长成那样,所以形状不对时就再雜凑一次,而不是硬塞进去。
    private static func frontmatterHash(for item: ClipItem) -> String {
        let hex = item.contentHash.lowercased().filter(\.isHexDigit)
        if hex.count == 64 { return hex }
        return SHA256.hash(data: Data(item.contentHash.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 种类与可信度都要用中文写进正文,因为使用者搜寻时打的是中文。
    private static let kindNames: [ItemKind: String] = [.text: "纯文字", .link: "网址", .image: "图片", .file: "档案", .other: "其他型别"]
    private static let provenanceNames: [Provenance: String] = [.high: "很确定", .medium: "大致可信", .low: "可能抓错,当时刚好在切换程式", .unknown: "判断不出来"]

    /// 用固定格式而不是跟着系统语系变的格式,使用者日後用日期搜寻时才有一致的字串可以命中;
    /// 时区则刻意跟着这台机器走,因为他记得的是自己的当地时间。
    private static let localFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
    /// ISO8601DateFormatter 预设就是 .withInternetDateTime,正好是 nlmkb frontmatter 用的格式。
    private static let isoFormatter = ISO8601DateFormatter()
}
