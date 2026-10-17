import Foundation
import Testing
@testable import ClipdCore

// MARK: - 测试用的小工具

/// 每一个测试都拿一个全新的暂存资料夹,测完就整个删掉。
/// 共用同一个资料夹会让「上一个测试留下的资料」变成下一个测试的隐形前提,
/// 那种失败最难查,所以宁可每次重开一个。
private func withTemporaryStore(
    passphrase: String = "測試用的通行碼",
    _ body: (Store, URL) throws -> Void
) throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("clipd-store-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = try Store(directory: directory, passphrase: passphrase)
    defer { store.close() }   // defer 是後进先出,所以会先关档再删资料夹,顺序正确。
    try body(store, directory)
}

private func makeItem(
    id: String = makeItemID(),
    preview: String,
    searchText: String? = nil,
    contentHash: String = UUID().uuidString,
    capturedAt: Date = Date(),
    representations: [ItemRepresentation] = []
) -> ClipItem {
    ClipItem(
        id: id,
        kind: .text,
        capturedAt: capturedAt,
        contentHash: contentHash,
        preview: preview,
        searchText: searchText ?? preview,
        sourceBundleID: "com.apple.TextEdit",
        sourceAppName: "文字编辑",
        provenance: .medium,
        isPinned: false,
        representations: representations
    )
}

// MARK: - 基本读写

@Test("插入一笔之後,最近清单要看得到它,而且表示法要原样回来")
func 插入之後最近清单看得到这一笔() throws {
    try withTemporaryStore { store, _ in
        let representations = [
            ItemRepresentation(uti: "public.utf8-plain-text", byteCount: 18, inlineText: "病人血壓正常"),
            ItemRepresentation(uti: "public.html", byteCount: 42, blobPath: "blobs/abc.html"),
        ]
        let item = makeItem(preview: "病人血壓正常", representations: representations)
        try store.insert(item)

        let recent = try store.recent(limit: 10)
        #expect(recent.count == 1)
        let loaded = try #require(recent.first)
        #expect(loaded.id == item.id)
        #expect(loaded.preview == "病人血壓正常")
        #expect(loaded.sourceAppName == "文字编辑")
        #expect(loaded.provenance == .medium)
        // 表示法必须照原本的顺序回来,面板要靠第一个来决定预设贴上哪一种格式。
        #expect(loaded.representations == representations)
    }
}

@Test("最近清单要把新的排在前面")
func 最近清单新的在前面() throws {
    try withTemporaryStore { store, _ in
        let old = makeItem(preview: "比较旧的一笔", capturedAt: Date(timeIntervalSince1970: 1_000))
        let new = makeItem(preview: "比较新的一笔", capturedAt: Date(timeIntervalSince1970: 2_000))
        try store.insert(old)
        try store.insert(new)

        let recent = try store.recent(limit: 10)
        #expect(recent.map(\.id) == [new.id, old.id])
    }
}

@Test("用识别码可以取回单独一笔,取不到的时候是 nil 而不是错误")
func 用识别码取回单独一笔() throws {
    try withTemporaryStore { store, _ in
        let item = makeItem(preview: "今天天氣很好")
        try store.insert(item)

        #expect(try store.item(id: item.id)?.preview == "今天天氣很好")
        #expect(try store.item(id: "根本不存在的识别码") == nil)
    }
}

// MARK: - 中文搜寻

@Test("中文双字词搜得到")
func 中文双字词搜得到() throws {
    try withTemporaryStore { store, _ in
        let item = makeItem(preview: "病人血壓正常,無特殊不適,建議三個月後回診")
        try store.insert(item)

        let hits = try store.search("血壓", limit: 20)
        #expect(hits.map(\.id) == [item.id])
    }
}

@Test("中文单字也搜得到,因为文件端连单字一起索引")
func 中文单字也搜得到() throws {
    try withTemporaryStore { store, _ in
        let item = makeItem(preview: "病人血壓正常,無特殊不適")
        try store.insert(item)

        let hits = try store.search("血", limit: 20)
        #expect(hits.map(\.id) == [item.id])
    }
}

@Test("搜寻不该回传无关的项目")
func 搜寻不该回传无关的项目() throws {
    try withTemporaryStore { store, _ in
        let clinical = makeItem(preview: "病人血壓正常,建議三個月後回診")
        let unrelated = makeItem(preview: "今天天氣很好,晚上想吃拉麵")
        try store.insert(clinical)
        try store.insert(unrelated)

        let hits = try store.search("血壓", limit: 20)
        #expect(hits.map(\.id) == [clinical.id])
    }
}

@Test("只打标点符号不该炸掉,应该乾脆回空清单")
func 只有标点的查询回空清单() throws {
    try withTemporaryStore { store, _ in
        try store.insert(makeItem(preview: "病人血壓正常"))
        #expect(try store.search("、、,。", limit: 20).isEmpty)
    }
}

// MARK: - 加密

@Test("通行码不对时要明确地失败,而不是给一个看不懂的错误")
func 通行码不对要明确地失败() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("clipd-store-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    // 先用正确的通行码建库并且真的写进一笔,资料库里才会有已加密的页面可以验。
    let first = try Store(directory: directory, passphrase: "正確的通行碼")
    try first.insert(makeItem(preview: "病人血壓正常"))
    first.close()

    do {
        _ = try Store(directory: directory, passphrase: "錯誤的通行碼")
        Issue.record("通行码错误却还是把资料库打开了,加密等於没有生效。")
    } catch let error as StoreError {
        guard case .wrongPassphrase = error else {
            Issue.record("失败的理由应该是通行码不对,实际拿到的是 \(error)。")
            return
        }
    }
}

// MARK: - 去重时间窗

@Test("同样内容在时间窗内算重复,超过时间窗就不算")
func 去重时间窗会过期() throws {
    try withTemporaryStore { store, _ in
        let hash = "sha256-同一份内容"
        let item = makeItem(preview: "病人血壓正常",
                            contentHash: hash,
                            capturedAt: Date().addingTimeInterval(-60))
        try store.insert(item)

        // 六十秒前抓到的东西,用五秒的时间窗看就是「新的一次复制」。
        #expect(try store.existingID(contentHash: hash, within: 5) == nil)
        // 换成十分钟的时间窗,它就该被认出来是同一份,监看器才不会重复存。
        #expect(try store.existingID(contentHash: hash, within: 600) == item.id)
        // 内容不一样的雜凑永远不该被误认。
        #expect(try store.existingID(contentHash: "sha256-别的内容", within: 600) == nil)
    }
}

// MARK: - 钉选与删除

@Test("钉选状态可以切换,而且读得回来")
func 钉选状态可以切换() throws {
    try withTemporaryStore { store, _ in
        let item = makeItem(preview: "要留着的片语")
        try store.insert(item)
        #expect(try store.item(id: item.id)?.isPinned == false)

        try store.setPinned(true, id: item.id)
        #expect(try store.item(id: item.id)?.isPinned == true)

        try store.setPinned(false, id: item.id)
        #expect(try store.item(id: item.id)?.isPinned == false)
    }
}

@Test("删除一笔会连带删掉它的表示法与搜寻索引")
func 删除会连带清掉表示法与索引() throws {
    try withTemporaryStore { store, _ in
        let id = makeItemID()
        let item = makeItem(
            id: id,
            preview: "病人血壓正常",
            representations: [
                ItemRepresentation(uti: "public.utf8-plain-text", byteCount: 18, inlineText: "病人血壓正常"),
                ItemRepresentation(uti: "public.html", byteCount: 42, blobPath: "blobs/abc.html"),
            ]
        )
        try store.insert(item)
        try store.delete(id: id)

        #expect(try store.item(id: id) == nil)
        // 索引也要跟着不见,否则搜寻会指向一笔已经不存在的纪录。
        #expect(try store.search("血壓", limit: 20).isEmpty)

        // 用同一个识别码重新插入一笔、而且只带一个表示法。
        // 如果刚才的删除没有连带清掉 item_reps,这里会撞上 (item_id, ordinal) 的主键而失败;
        // 插得进去而且只读回一个表示法,就证明连带删除真的有发生。
        let reused = makeItem(
            id: id,
            preview: "重新用同一个识别码",
            representations: [ItemRepresentation(uti: "public.utf8-plain-text", byteCount: 9, inlineText: "重新")]
        )
        try store.insert(reused)
        #expect(try store.item(id: id)?.representations.count == 1)
    }
}

// MARK: - 笔数

@Test("count 回报的是实际笔数,插入与删除都要反映出来")
func 笔数会随插入与删除变动() throws {
    try withTemporaryStore { store, _ in
        #expect(try store.count() == 0)

        let items = (0..<3).map { index in
            makeItem(preview: "第 \(index) 笔", capturedAt: Date(timeIntervalSince1970: Double(index)))
        }
        for item in items { try store.insert(item) }
        #expect(try store.count() == 3)

        try store.delete(id: items[0].id)
        #expect(try store.count() == 2)
    }
}

@Test("关掉之後再操作要明确地拒绝,而不是踩到已经释放的资源")
func 关闭之後再操作要拒绝() throws {
    try withTemporaryStore { store, _ in
        try store.insert(makeItem(preview: "病人血壓正常"))
        store.close()

        do {
            _ = try store.count()
            Issue.record("资料库已经关闭,count 却还是成功了。")
        } catch let error as StoreError {
            guard case .alreadyClosed = error else {
                Issue.record("失败的理由应该是资料库已关闭,实际拿到的是 \(error)。")
                return
            }
        }
    }
}
