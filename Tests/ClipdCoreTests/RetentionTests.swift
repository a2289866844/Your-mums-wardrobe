import Foundation
import Testing
@testable import ClipdCore

// MARK: - 测试用的小工具

/// 每个测试都拿一个全新的暂存资料夹与一个全新的资料库,测完整个删掉。
/// 保留期限的测试全都是在验「什麽会被删掉」,共用状态会让失败变得完全无法追查,所以一律隔离。
private func withTemporaryRetention(
    policy: RetentionPolicy,
    _ body: (Store, Retention, URL) throws -> Void
) throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("clipd-retention-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = try Store(directory: directory, passphrase: "保留期限测试用的通行码")
    defer { store.close() }   // defer 是後进先出,所以会先关档再删资料夹,顺序正确。

    let retention = Retention(store: store, blobDirectory: directory, policy: policy)
    try body(store, retention, directory)
}

/// 在磁碟上放一个指定大小的假图片档,并回传它相对於储存资料夹的路径。
/// 路径形状刻意跟正式程式一致:blobs/杂凑前两码/杂凑.png。
@discardableResult
private func writeBlob(named name: String, bytes: Int, under directory: URL) throws -> String {
    let relative = "blobs/\(name.prefix(2))/\(name).png"
    let url = directory.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: bytes).write(to: url)
    return relative
}

private func makeItem(
    id: String = makeItemID(),
    preview: String,
    capturedAt: Date = Date(),
    isPinned: Bool = false,
    blobPath: String? = nil,
    blobBytes: Int = 0
) -> ClipItem {
    var reps: [ItemRepresentation] = []
    if let blobPath {
        reps.append(ItemRepresentation(uti: "public.png", byteCount: blobBytes, blobPath: blobPath))
    }
    return ClipItem(
        id: id,
        kind: blobPath == nil ? .text : .image,
        capturedAt: capturedAt,
        contentHash: UUID().uuidString,
        preview: preview,
        searchText: preview,
        sourceBundleID: "com.apple.TextEdit",
        sourceAppName: "文字编辑",
        provenance: .medium,
        isPinned: isPinned,
        representations: reps
    )
}

/// 产生一个「几天前」的时间点。
private func daysAgo(_ days: Double) -> Date {
    Date().addingTimeInterval(-days * 86_400)
}

private let 不设限的政策 = RetentionPolicy(maximumItems: 0, maximumDays: 0,
                                           maximumBlobBytes: 0, keepsPinned: true)

// MARK: - 笔数上限

@Test("纪录笔数超过上限时,最旧的会先被清掉")
func 超过笔数上限时最旧的先被清掉() throws {
    var policy = 不设限的政策
    policy.maximumItems = 3

    try withTemporaryRetention(policy: policy) { store, retention, _ in
        // 时间刻意由旧到新,让「谁最旧」这件事完全没有模糊空间。
        for index in 0..<5 {
            try store.insert(makeItem(preview: "第 \(index) 则", capturedAt: daysAgo(Double(5 - index))))
        }

        let report = try retention.sweep()
        #expect(report.removedItems == 2)

        let remaining = try store.recent(limit: 100)
        #expect(remaining.count == 3)
        #expect(remaining.map(\.preview) == ["第 4 则", "第 3 则", "第 2 则"],
                "留下来的必须是最新的三则,被清掉的是最旧的两则")
        #expect(report.sentence.contains("纪录总数超过上限"))
    }
}

// MARK: - 天数上限

@Test("超过保留天数的纪录会被清掉,还在期限内的不会被动到")
func 超过保留天数的纪录会被清掉() throws {
    var policy = 不设限的政策
    policy.maximumDays = 30

    try withTemporaryRetention(policy: policy) { store, retention, _ in
        try store.insert(makeItem(preview: "昨天复制的", capturedAt: daysAgo(1)))
        try store.insert(makeItem(preview: "一个月又几天前复制的", capturedAt: daysAgo(35)))
        try store.insert(makeItem(preview: "两年前复制的", capturedAt: daysAgo(730)))

        let report = try retention.sweep()
        #expect(report.removedItems == 2)

        let remaining = try store.recent(limit: 100)
        #expect(remaining.map(\.preview) == ["昨天复制的"])
        #expect(report.sentence.contains("超过保留天数"))
    }
}

// MARK: - 钉选

@Test("被钉选的纪录不管多旧、超过多少上限都不会被清掉")
func 钉选的纪录一定会活下来() throws {
    var policy = 不设限的政策
    policy.maximumItems = 1
    policy.maximumDays = 7
    policy.keepsPinned = true

    try withTemporaryRetention(policy: policy) { store, retention, _ in
        try store.insert(makeItem(preview: "钉起来的老资料", capturedAt: daysAgo(500), isPinned: true))
        try store.insert(makeItem(preview: "没钉的老资料", capturedAt: daysAgo(400)))
        try store.insert(makeItem(preview: "今天刚复制的", capturedAt: Date()))

        _ = try retention.sweep()

        let remaining = try store.recent(limit: 100).map(\.preview)
        #expect(remaining.contains("钉起来的老资料"), "钉选就是拥有者明确说过「这个不要动」,清理必须听话")
        #expect(!remaining.contains("没钉的老资料"))
    }
}

@Test("关掉钉选保护之後,钉选的纪录一样会被清掉")
func 关掉钉选保护之後钉选的也会被清掉() throws {
    var policy = 不设限的政策
    policy.maximumDays = 7
    policy.keepsPinned = false

    try withTemporaryRetention(policy: policy) { store, retention, _ in
        try store.insert(makeItem(preview: "钉起来的老资料", capturedAt: daysAgo(500), isPinned: true))

        let report = try retention.sweep()
        #expect(report.removedItems == 1)
        #expect(try store.count() == 0)
    }
}

// MARK: - 孤儿档案

@Test("没有任何纪录指向的孤儿图档会被清掉,资料库与金钥档绝对不会被当成孤儿")
func 孤儿图档会被清掉而资料库不会() throws {
    try withTemporaryRetention(policy: 不设限的政策) { store, retention, directory in
        let referenced = try writeBlob(named: "aaaa1111", bytes: 4096, under: directory)
        let orphan = try writeBlob(named: "bbbb2222", bytes: 8192, under: directory)
        try store.insert(makeItem(preview: "还在用的图", blobPath: referenced, blobBytes: 4096))

        // 金钥档就住在同一个资料夹里,而它当然不会被任何纪录引用。
        // 如果扫描孤儿的范围没有限制在 blobs 子目录,它跟资料库都会被误判成孤儿而删掉。
        let keyURL = directory.appendingPathComponent("db.key")
        try Data("假装这是金钥".utf8).write(to: keyURL)

        let report = try retention.sweep()
        #expect(report.removedItems == 0, "没有任何纪录超过上限,不该有纪录被删")
        #expect(report.freedBytes == 8192)

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: directory.appendingPathComponent(orphan).path))
        #expect(fm.fileExists(atPath: directory.appendingPathComponent(referenced).path))
        #expect(fm.fileExists(atPath: keyURL.path), "金钥档被当成孤儿删掉的话,整份历史会永远打不开")
        #expect(fm.fileExists(atPath: store.fileURL.path), "资料库自己更不可以被当成孤儿")
    }
}

@Test("还有别的纪录指着同一个图档时,那个档案一个位元组都不能删")
func 仍被引用的图档不会被删掉() throws {
    var policy = 不设限的政策
    policy.maximumItems = 1

    try withTemporaryRetention(policy: policy) { store, retention, directory in
        // 档名是内容杂凑,所以复制两次同一张图片会指向同一个档案。
        let shared = try writeBlob(named: "cccc3333", bytes: 2048, under: directory)
        try store.insert(makeItem(preview: "旧的那一则", capturedAt: daysAgo(2),
                                  blobPath: shared, blobBytes: 2048))
        try store.insert(makeItem(preview: "新的那一则", capturedAt: daysAgo(1),
                                  blobPath: shared, blobBytes: 2048))

        let report = try retention.sweep()
        #expect(report.removedItems == 1)
        #expect(report.freedBytes == 0, "档案还有人在用,所以这次其实没有释放任何空间")
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(shared).path),
                "删掉还有纪录指着的图档,会让面板上出现一则打不开的图片")
    }
}

// MARK: - 图片总量上限

@Test("图片总量超过上限时,最占空间的先被清掉")
func 图片总量超过上限时最大的先被清掉() throws {
    var policy = 不设限的政策
    policy.maximumBlobBytes = 10_000

    try withTemporaryRetention(policy: policy) { store, retention, directory in
        let big = try writeBlob(named: "dddd4444", bytes: 9_000, under: directory)
        let medium = try writeBlob(named: "eeee5555", bytes: 5_000, under: directory)
        let small = try writeBlob(named: "ffff6666", bytes: 1_000, under: directory)
        // 三个档案合计 15000 位元组,超过一万的上限,所以至少要砍掉五千。
        try store.insert(makeItem(preview: "大图", capturedAt: daysAgo(3), blobPath: big, blobBytes: 9_000))
        try store.insert(makeItem(preview: "中图", capturedAt: daysAgo(2), blobPath: medium, blobBytes: 5_000))
        try store.insert(makeItem(preview: "小图", capturedAt: daysAgo(1), blobPath: small, blobBytes: 1_000))

        let report = try retention.sweep()
        #expect(report.removedItems == 1, "砍掉最大的那一张就已经回到上限以内,不该多砍")
        #expect(report.freedBytes == 9_000)

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: directory.appendingPathComponent(big).path))
        #expect(fm.fileExists(atPath: directory.appendingPathComponent(medium).path))
        #expect(fm.fileExists(atPath: directory.appendingPathComponent(small).path))
        #expect(report.sentence.contains("图片总量超过上限"))
    }
}

// MARK: - 试算

@Test("试算只会说明会发生什麽,不会真的删掉任何东西")
func 试算不会改变任何东西() throws {
    var policy = 不设限的政策
    policy.maximumItems = 1

    try withTemporaryRetention(policy: policy) { store, retention, directory in
        let kept = try writeBlob(named: "9999aaaa", bytes: 3_000, under: directory)
        let orphan = try writeBlob(named: "8888bbbb", bytes: 1_500, under: directory)
        try store.insert(makeItem(preview: "旧的", capturedAt: daysAgo(2), blobPath: kept, blobBytes: 3_000))
        try store.insert(makeItem(preview: "新的", capturedAt: daysAgo(1)))

        let before = try store.count()
        let sentence = try retention.estimate()

        #expect(sentence.contains("会删掉 1 则纪录"))
        #expect(sentence.contains("孤儿"))
        #expect(sentence.contains("还没有任何东西被删除"))

        #expect(try store.count() == before, "试算过後笔数必须一模一样")
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: directory.appendingPathComponent(kept).path))
        #expect(fm.fileExists(atPath: directory.appendingPathComponent(orphan).path),
                "连孤儿档案都不可以在试算阶段被删掉")

        // 试算讲的必须就是真的会发生的事,所以接着真的跑一次,结果要对得上。
        let report = try retention.sweep()
        #expect(report.removedItems == 1)
    }
}

@Test("没有任何东西需要清的时候,试算要明讲这次不会删掉任何东西")
func 没东西可清时的试算说明() throws {
    try withTemporaryRetention(policy: 不设限的政策) { store, retention, _ in
        try store.insert(makeItem(preview: "唯一的一则"))
        let sentence = try retention.estimate()
        #expect(sentence.contains("不会删掉任何东西"))
    }
}

// MARK: - 全部销毁

@Test("全部销毁会清空一切,而且必须诚实说明它做不到的部分")
func 全部销毁会清空一切并说清楚做不到的事() throws {
    try withTemporaryRetention(policy: 不设限的政策) { store, retention, directory in
        let blob = try writeBlob(named: "7777cccc", bytes: 2_500, under: directory)
        try store.insert(makeItem(preview: "钉起来的", isPinned: true, blobPath: blob, blobBytes: 2_500))
        try store.insert(makeItem(preview: "一般的"))

        let sentence = try retention.destroyEverything()

        #expect(try store.count() == 0, "紧急按钮连钉选的也要清掉,否则它就不是紧急按钮")
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("blobs").path))
        // 资料库档案本身必须还在:销毁内容不等於销毁资料库,金钥要不要销毁是拥有者另一个决定。
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))

        #expect(sentence.contains("写入时复制"))
        #expect(sentence.contains("快照"))
        #expect(sentence.contains("销毁加密金钥"))
        #expect(sentence.contains("备份"))
    }
}

// MARK: - 政策本身

@Test("预设政策就是量测过的那四个数字")
func 预设政策的四个数字() {
    let policy = RetentionPolicy.default
    #expect(policy.maximumItems == 20_000)
    #expect(policy.maximumDays == 365)
    #expect(policy.maximumBlobBytes == 2 * 1024 * 1024 * 1024)
    #expect(policy.keepsPinned)
}

@Test("上限设成零代表不设限,绝对不可以解读成一笔都不留")
func 上限设成零代表不设限() throws {
    try withTemporaryRetention(policy: 不设限的政策) { store, retention, _ in
        try store.insert(makeItem(preview: "很旧的一则", capturedAt: daysAgo(5_000)))
        let report = try retention.sweep()
        #expect(report.removedItems == 0, "一个被误设成零的栏位如果会清空整份历史,那是无法挽回的错误")
        #expect(try store.count() == 1)
    }
}
