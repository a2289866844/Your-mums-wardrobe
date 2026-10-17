import Foundation
import Testing
@testable import ClipdCore

// MARK: - 测试用的小工具

/// 每一个测试都拿一个全新的暂存资料夹当 sources,测完就整个删掉。
/// 绝对不可以让测试指向真正的知识库,否则跑一次测试就会在使用者的保险库里留下垃圾。
private func withTemporaryBridge(
    batchSize: Int = 3,
    batchBytes: Int = 1_000_000,
    _ body: (KnowledgeBridge, URL) throws -> Void
) throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("clipd-bridge-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    // indexCommand 一律传 nil:测试绝对不准去启动真正的 nlmkb。
    let config = KnowledgeBridgeConfig(
        wikiSourcesDirectory: directory,
        indexCommand: nil,
        batchSize: batchSize,
        batchBytes: batchBytes
    )
    try body(KnowledgeBridge(config: config), directory)
}

private func makeClip(
    id: String = makeItemID(),
    kind: ItemKind = .text,
    preview: String = "病人血壓正常",
    searchText: String? = nil,
    capturedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    sourceAppName: String? = "文字编辑",
    representations: [ItemRepresentation] = []
) -> ClipItem {
    ClipItem(
        id: id,
        kind: kind,
        capturedAt: capturedAt,
        contentHash: UUID().uuidString,
        preview: preview,
        searchText: searchText ?? preview,
        sourceBundleID: "com.apple.TextEdit",
        sourceAppName: sourceAppName,
        provenance: .medium,
        isPinned: false,
        representations: representations
    )
}

/// 跟正式程式用同一套格式产生本机时间字串。测试自己算一次,才能真的验到格式,
/// 而不是拿正式程式的输出去比对它自己。
private func localStamp(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
}

/// 把档案切成 frontmatter 与正文两块,方便分别检查。
private func splitDocument(_ text: String) -> (frontmatter: String, body: String) {
    let parts = text.components(separatedBy: "---\n")
    guard parts.count >= 3 else { return ("", text) }
    return (parts[1], parts.dropFirst(2).joined(separator: "---\n"))
}

// MARK: - 档名与 frontmatter

@Test("写出来的档名是 clip- 加识别码,而且五个 frontmatter 键跟 nlmkb 完全一样")
func 档名与五个中继资料键都对() throws {
    try withTemporaryBridge { bridge, directory in
        let item = makeClip(id: "01HZZTESTID0001")
        let outcome = try bridge.write(item, ocrText: nil)

        #expect(outcome.fileURL.lastPathComponent == "clip-01HZZTESTID0001.md")
        #expect(outcome.fileURL.deletingLastPathComponent().path == directory.path)
        #expect(FileManager.default.fileExists(atPath: outcome.fileURL.path))

        let text = try String(contentsOf: outcome.fileURL, encoding: .utf8)
        let (frontmatter, _) = splitDocument(text)
        // 五个键一个都不能少,少一个就跟 nlmkb 自己的汇出长得不一样了。
        for key in ["original_path:", "sha256:", "notebook:", "exported_at:", "generated_by:"] {
            #expect(frontmatter.contains(key), "frontmatter 缺少 \(key) 这个键。")
        }
        #expect(frontmatter.contains("generated_by: clipd"))
        #expect(frontmatter.contains("clipd://item/01HZZTESTID0001"))
        // exported_at 要是 ISO 8601,所以一定看得到日期与时间之间那个 T。
        #expect(frontmatter.contains("exported_at: ") && frontmatter.contains("T"))
        // 位元组数要跟档案实际大小一致,批次门槛是靠这个数字在算的。
        let onDisk = try Data(contentsOf: outcome.fileURL)
        #expect(outcome.bytes == onDisk.count)
    }
}

@Test("frontmatter 里的 sha256 一定是六十四个十六进位字元,形状才跟 nlmkb 一致")
func 中继资料的雜凑长度永远是六十四() throws {
    try withTemporaryBridge { bridge, _ in
        // contentHash 故意给一个完全不像雜凑的字串,看它会不会硬塞进去。
        var item = makeClip()
        item.contentHash = "根本不是一个雜凑"
        let outcome = try bridge.write(item, ocrText: nil)

        let text = try String(contentsOf: outcome.fileURL, encoding: .utf8)
        let (frontmatter, _) = splitDocument(text)
        let line = try #require(frontmatter.split(separator: "\n").first { $0.hasPrefix("sha256:") })
        let value = line.replacingOccurrences(of: "sha256:", with: "").trimmingCharacters(in: .whitespaces)
        #expect(value.count == 64)
        #expect(value.allSatisfy { $0.isHexDigit })
    }
}

// MARK: - 正文必须重複中继资料

@Test("正文要再写一次来源程式与本机时间,因为 frontmatter 在建索引之前就被剥掉了")
func 正文重複写出来源程式与时间() throws {
    try withTemporaryBridge { bridge, _ in
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let item = makeClip(preview: "病人血壓正常,建議三個月後回診",
                            capturedAt: capturedAt,
                            sourceAppName: "文字编辑")
        let outcome = try bridge.write(item, ocrText: nil)

        let text = try String(contentsOf: outcome.fileURL, encoding: .utf8)
        let (_, body) = splitDocument(text)
        // 这两件事只写在 frontmatter 里等於没写,所以一定要出现在正文。
        #expect(body.contains("文字编辑"))
        #expect(body.contains(localStamp(for: capturedAt)))
        // 内容本身当然也要在。
        #expect(body.contains("病人血壓正常"))
    }
}

@Test("图片的辨识文字会写进正文,图片本体只留存放路径")
func 图片写辨识文字与存放路径() throws {
    try withTemporaryBridge { bridge, _ in
        let item = makeClip(
            kind: .image,
            preview: "一张截图",
            representations: [ItemRepresentation(uti: "public.png", byteCount: 90_000, blobPath: "blobs/ab12.png")]
        )
        let outcome = try bridge.write(item, ocrText: "血壓 128/76,心跳 72")

        let text = try String(contentsOf: outcome.fileURL, encoding: .utf8)
        let (_, body) = splitDocument(text)
        #expect(body.contains("blobs/ab12.png"))
        #expect(body.contains("血壓 128/76"))
    }
}

// MARK: - 绝对不准出现 base64

@Test("内嵌资料与长串编码都不会被写进档案")
func 永远不写入编码资料() throws {
    try withTemporaryBridge { bridge, _ in
        let base64Run = String(repeating: "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo", count: 12)
        let item = makeClip(
            preview: "一张贴上来的图",
            searchText: "报告开头 data:image/png;base64,\(base64Run) 报告结尾 \(base64Run)"
        )
        let outcome = try bridge.write(item, ocrText: nil)

        let text = try String(contentsOf: outcome.fileURL, encoding: .utf8)
        #expect(!text.contains("data:"), "档案里出现了 data URI,nlmkb 的清理指令会因此改写我们的档案。")
        #expect(!text.contains(String(base64Run.prefix(200))), "档案里出现了长串 base64 编码资料。")
        // 挡掉之後仍然要留下看得懂的说明,不能安静地把内容吃掉。
        #expect(text.contains("依规定没有写进来"))
    }
}

// MARK: - 批次门槛

@Test("还没累积到门槛不会重建索引,刚好累积到才会")
func 批次没到门槛不会触发() throws {
    try withTemporaryBridge(batchSize: 3) { bridge, _ in
        #expect(bridge.pendingCount == 0)

        _ = try bridge.write(makeClip(preview: "第一笔"), ocrText: nil)
        #expect(try bridge.reindexIfBatchReady() == nil)
        #expect(bridge.pendingCount == 1)

        _ = try bridge.write(makeClip(preview: "第二笔"), ocrText: nil)
        #expect(try bridge.reindexIfBatchReady() == nil)
        #expect(bridge.pendingCount == 2)

        // 第三笔刚好到门槛,这一次必须回一句中文说明,而且计数要归零重新开始累积。
        _ = try bridge.write(makeClip(preview: "第三笔"), ocrText: nil)
        let fired = try bridge.reindexIfBatchReady()
        let sentence = try #require(fired)
        #expect(!sentence.isEmpty)
        #expect(bridge.pendingCount == 0)

        // 归零之後马上再问一次,不该又触发一次。
        #expect(try bridge.reindexIfBatchReady() == nil)
    }
}

@Test("累积的位元组数超过上限也会触发,不必等到档案数到齐")
func 位元组超过上限也会触发() throws {
    // 门槛故意设得很小,一个档案就会超过。
    try withTemporaryBridge(batchSize: 100, batchBytes: 10) { bridge, _ in
        _ = try bridge.write(makeClip(preview: "只有一笔也够重"), ocrText: nil)
        #expect(try bridge.reindexIfBatchReady() != nil)
    }
}

@Test("没有设定 nlmkb 执行档时,强制重建索引要明确地失败")
func 没有执行档时强制重建要失败() throws {
    try withTemporaryBridge { bridge, _ in
        _ = try bridge.write(makeClip(preview: "病人血壓正常"), ocrText: nil)
        do {
            _ = try bridge.forceReindex()
            Issue.record("没有设定执行档,forceReindex 却成功了。")
        } catch let error as BridgeError {
            guard case .indexCommandNotConfigured = error else {
                Issue.record("失败的理由应该是没有设定执行档,实际拿到的是 \(error)。")
                return
            }
        }
    }
}

// MARK: - 行前检查

@Test("资料夹不存在时,行前检查要用完整的句子讲出来,而且写入要被挡下来")
func 行前检查报告资料夹不存在() throws {
    let missing = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("clipd-bridge-tests-\(UUID().uuidString)/根本没建立过", isDirectory: true)
    let config = KnowledgeBridgeConfig(
        wikiSourcesDirectory: missing,
        indexCommand: nil,
        batchSize: 3,
        batchBytes: 1_000_000
    )
    let bridge = KnowledgeBridge(config: config)

    let problems = bridge.preflight()
    #expect(problems.contains(where: { $0.contains(missing.path) && $0.contains("不存在") }))

    // 检查报了问题,写入就必须真的被挡住,而不是只在报告里讲一句然後照写。
    do {
        _ = try bridge.write(makeClip(preview: "病人血壓正常"), ocrText: nil)
        Issue.record("资料夹不存在,write 却成功了。")
    } catch let error as BridgeError {
        guard case .blockedBySafetyCheck = error else {
            Issue.record("失败的理由应该是安全检查挡下来,实际拿到的是 \(error)。")
            return
        }
    }
}

@Test("资料夹正常时,行前检查只会提到没有设定执行档这一件事")
func 资料夹正常时不会乱报问题() throws {
    try withTemporaryBridge { bridge, directory in
        let problems = bridge.preflight()
        #expect(!problems.contains(where: { $0.contains(directory.path) }))
        // 测试刻意不给执行档,所以这一句应该在,而且要讲清楚後果。
        #expect(problems.contains(where: { $0.contains("nlmkb") }))
    }
}
