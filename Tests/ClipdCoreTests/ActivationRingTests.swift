import Foundation
import Testing
@testable import ClipdCore

/// 这一整组测试完全用合成的时间戳记透过 record() 驱动环形缓冲区,
/// 不碰真正的 NSWorkspace。理由是程式切换在测试环境里既无法控制也无法重现,
/// 而我们真正要验证的是「时间点 → 候选人与可信度」这条纯粹的判断逻辑。
@Suite("前景程式环形缓冲区")
struct ActivationRingTests {

    /// 固定的基准时间,让每个案例的时间关系一眼看得出来,也不会因为跑测试的当下时刻而漂移。
    private let base = Date(timeIntervalSince1970: 1_000_000)

    /// 测试用的自身识别码。刻意给一个固定值,因为 swift test 底下
    /// Bundle.main.bundleIdentifier 会是测试执行档的,不稳定也不该拿来当断言基础。
    private let selfID = "dev.clipd.app"

    private func makeRing(capacity: Int = 8) -> ActivationRing {
        ActivationRing(capacity: capacity, ownBundleID: selfID)
    }

    private func record(_ id: String, _ offset: TimeInterval) -> ActivationRecord {
        ActivationRecord(bundleID: id, appName: id, at: base.addingTimeInterval(offset))
    }

    @Test("只有一个程式而且窗口内没有切换时,应该回报 medium 与唯一一位候选人")
    func 单一程式没有切换时为medium() {
        let ring = makeRing()
        ring.record(record("com.apple.Safari", 0))

        // 查询点距离最後一次切换已经五秒,远超过 750 毫秒的窗口,所以判断是可靠的。
        let result = ring.candidates(at: base.addingTimeInterval(5))

        #expect(result.provenance == .medium)
        #expect(result.records.count == 1)
        #expect(result.records.first?.bundleID == "com.apple.Safari")
    }

    @Test("切换发生在查询前 200 毫秒时,应该回报 low 并把前後两个程式都列为候选人")
    func 窗口内发生切换时为low且有两位候选人() {
        let ring = makeRing()
        ring.record(record("com.apple.Safari", 0))
        ring.record(record("com.apple.Notes", 10))

        // 使用者很可能是在 Safari 里按下复制,我们却在焦点已经跳到备忘录之後才轮询到。
        let result = ring.candidates(at: base.addingTimeInterval(10.2))

        #expect(result.provenance == .low)
        #expect(result.records.count == 2)
        // 候选人是联集:两个都要在清单里,下游只要有任何一个被封锁就该整则丢掉。
        let ids = Set(result.records.map(\.bundleID))
        #expect(ids == ["com.apple.Safari", "com.apple.Notes"])
    }

    @Test("窗口内发生切换时,排在第一位的必须是切换之前那个程式,因为复制一定发生在切走之前")
    func 窗口内切换时切换前的程式要排第一() {
        let ring = makeRing()
        ring.record(record("com.apple.Safari", 0))
        ring.record(record("com.apple.Notes", 10))

        let result = ring.candidates(at: base.addingTimeInterval(10.2))

        // 这个排序不是美观问题,它决定面板上会显示哪一个程式名字。
        // 轮询间隔是 0.2 秒,所以复制发生在过去 0.2 秒之内;同一段时间里若发生了切换,
        // 真实顺序几乎必然是「先在 Safari 复制,才切到备忘录准备贴上」。
        // 反过来「先切到备忘录、再在 0.2 秒内完成一次复制」以人的操作速度来说几乎不可能。
        #expect(result.records.first?.bundleID == "com.apple.Safari")
        #expect(result.records.last?.bundleID == "com.apple.Notes")
    }

    @Test("切换发生在查询前两秒时,焦点已经稳定下来,应该回报 medium 与一位候选人")
    func 窗口外发生切换时回到medium() {
        let ring = makeRing()
        ring.record(record("com.apple.Safari", 0))
        ring.record(record("com.apple.Notes", 10))

        let result = ring.candidates(at: base.addingTimeInterval(12))

        #expect(result.provenance == .medium)
        #expect(result.records.count == 1)
        #expect(result.records.first?.bundleID == "com.apple.Notes")
    }

    @Test("查询时间点早於任何一笔纪录时,应该诚实回报 unknown 而不是乱猜")
    func 没有纪录涵盖查询时间时为unknown() {
        let ring = makeRing()
        ring.record(record("com.apple.Safari", 10))

        let result = ring.candidates(at: base)

        #expect(result.provenance == .unknown)
        #expect(result.records.isEmpty)
        #expect(ring.appAt(base) == nil)
    }

    @Test("缓冲区写满之後,最旧的纪录会被覆盖掉而不是让记忆体一直长大")
    func 容量满了会覆盖最旧的纪录() {
        let ring = makeRing(capacity: 3)
        ring.record(record("app.a", 0))
        ring.record(record("app.b", 1))
        ring.record(record("app.c", 2))
        ring.record(record("app.d", 3))

        // 第一笔已经被第四笔挤掉,所以那个时间点变成查不到 —— 这正是容量有上限的证据。
        #expect(ring.appAt(base) == nil)
        #expect(ring.appAt(base.addingTimeInterval(1))?.bundleID == "app.b")
        #expect(ring.appAt(base.addingTimeInterval(3))?.bundleID == "app.d")
    }

    @Test("我们自己的 bundle 识别码永远不会被记录,面板抢走焦点不能变成来源")
    func 自身程式不会被记录() {
        let ring = makeRing()
        ring.record(ActivationRecord(bundleID: selfID, appName: "clipd", at: base))

        // 面板弹出来时会取得前景焦点,如果照记,之後每一则内容的来源都会变成 clipd 自己。
        #expect(ring.appAt(base.addingTimeInterval(1)) == nil)

        ring.record(record("com.apple.Safari", 2))
        #expect(ring.appAt(base.addingTimeInterval(3))?.bundleID == "com.apple.Safari")
    }
}
