import Foundation
import Testing
@testable import ClipdCore

// MARK: - 测试用的小工具

/// 可以自己拨的时钟。整份测试一秒都不会真的睡,理由是这个佇列的每一条规则都是以分锺、
/// 小时、甚至一整天为单位的;照真实时间等下去,这些规则永远测不到。
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// 可以自己写死的网路状态。
private final class NetworkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = NetworkCondition(isOnline: true, isExpensive: false)
    var condition: NetworkCondition {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// 假的目的地:只把「它被要求送出什麽」记下来,永远不碰网路。
private final class FakeDestination: EgressDestination, @unchecked Sendable {
    let displayName = "测试用的假目的地"
    private let lock = NSLock()
    private var connected: Bool
    private var batches: [[QueuedItem]] = []
    private var failure: Error?

    init(connected: Bool = true, failure: Error? = nil) {
        self.connected = connected
        self.failure = failure
    }

    var isConnected: Bool { lock.withLock { connected } }
    var sentBatches: [[QueuedItem]] { lock.withLock { batches } }

    func send(batch: [QueuedItem]) async throws -> String {
        let pending: Error? = lock.withLock {
            batches.append(batch)
            return failure
        }
        if let pending { throw pending }
        return "假回条-\(batch.count)"
    }
}

/// 事件句子的收集器。介面与稽核纪录看到的就是这些句子,所以测试直接对着它们断言。
private final class SentenceLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var sentences: [String] { lock.withLock { stored } }
    func append(_ sentence: String) { lock.withLock { stored.append(sentence) } }
    func contains(_ fragment: String) -> Bool { sentences.contains { $0.contains(fragment) } }
}

/// 每一个测试都拿一个全新的暂存资料夹,测完整个删掉,绝不共用同一个佇列存档。
private func makeQueueFileURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("clipd-egress-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("egress.json")
}

private func removeQueueDirectory(_ fileURL: URL) {
    try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
}

private func makeQueue(
    fileURL: URL,
    destination: EgressDestination?,
    clock: TestClock,
    network: NetworkBox,
    batchSize: Int = 5,
    batchBytes: Int = 1_000_000,
    log: SentenceLog? = nil
) -> EgressQueue {
    let queue = EgressQueue(fileURL: fileURL, destination: destination, batchSize: batchSize,
                            batchBytes: batchBytes, now: { clock.now }, readNetwork: { network.condition })
    if let log { queue.onEvent = { log.append($0) } }
    return queue
}

// MARK: - 分批与倒数

@Test("十五秒内进来的算同一批,而且整批的倒数取最长的那一个")
func 同一批的倒数取最长的那一个() async throws {
    let fileURL = makeQueueFileURL()
    defer { removeQueueDirectory(fileURL) }
    let clock = TestClock()
    let network = NetworkBox()
    let destination = FakeDestination()
    let queue = makeQueue(fileURL: fileURL, destination: destination, clock: clock, network: network, batchSize: 10)

    let first = try queue.enqueue(itemID: "A", contentHash: "h1", bytes: 100, holdSeconds: 5)
    clock.advance(2)
    let second = try queue.enqueue(itemID: "B", contentHash: "h2", bytes: 100, holdSeconds: 60)

    #expect(first.batchID == second.batchID)
    let pending = queue.pending
    #expect(pending.count == 2)
    // 一批只能有一个倒数,而且必须是最长的那一个 —— 一批的安全程度等於它里面最敏感的那一则。
    #expect(Set(pending.map(\.releaseAt)).count == 1)
    #expect(pending[0].releaseAt == second.enqueuedAt.addingTimeInterval(60))

    // 走到第一则原本的时间时,一则都不准送出去。
    clock.advance(10)
    await queue.tick()
    #expect(destination.sentBatches.isEmpty)

    clock.advance(60)
    await queue.tick()
    #expect(destination.sentBatches.count == 1)
    #expect(destination.sentBatches[0].count == 2, "同一批必须一起送出去,而不是拆成两次请求。")
}

@Test("短时间内连续复制会被认定为突波,整批的倒数因此往後延")
func 突波会把整批的倒数往後延() async throws {
    let fileURL = makeQueueFileURL()
    defer { removeQueueDirectory(fileURL) }
    let clock = TestClock()
    let network = NetworkBox()
    let destination = FakeDestination()
    let log = SentenceLog()
    let queue = makeQueue(fileURL: fileURL, destination: destination, clock: clock,
                          network: network, batchSize: 20, log: log)

    let start = clock.now
    for index in 0..<10 {
        _ = try queue.enqueue(itemID: "I\(index)", contentHash: "h\(index)", bytes: 100, holdSeconds: 5)
        clock.advance(1)
    }

    // 第十则进来的那一刻突波成立,整批被推到那一刻之後两分锺。
    let floor = start.addingTimeInterval(9 + 120)
    #expect(queue.pending.allSatisfy { $0.releaseAt >= floor })
    #expect(queue.pending.allSatisfy { $0.rearmedReason != nil }, "被延後的每一则都要留下原因,不能安静地改时间。")
    #expect(log.contains("排进佇列"))

    // 原本谈好的五秒早就过了,但因为突波,现在还不能送。
    clock.advance(20)
    await queue.tick()
    #expect(destination.sentBatches.isEmpty)

    clock.advance(120)
    await queue.tick()
    #expect(destination.sentBatches.count == 1)
}

@Test("倒数还没开始,整份佇列就已经用 0600 的权限落地了,而且改写之後权限不会跑掉")
func 存档在倒数开始之前就落地而且权限是零六零零() throws {
    let fileURL = makeQueueFileURL()
    defer { removeQueueDirectory(fileURL) }
    let clock = TestClock()
    let network = NetworkBox()
    let queue = makeQueue(fileURL: fileURL, destination: FakeDestination(), clock: clock, network: network)

    _ = try queue.enqueue(itemID: "A", contentHash: "h1", bytes: 100, holdSeconds: 60)
    #expect(FileManager.default.fileExists(atPath: fileURL.path), "倒数开始之前就必须已经写到磁碟上。")

    func permissions() throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }
    #expect(try permissions() == 0o600)

    // 第二次写会走换档那一条路径,权限最容易在这里悄悄跑掉,所以再确认一次。
    clock.advance(1)
    _ = try queue.enqueue(itemID: "B", contentHash: "h2", bytes: 100, holdSeconds: 60)
    #expect(try permissions() == 0o600)
}

// MARK: - 断路器

@Test("一小时内排进来的量超过门槛就跳断路器,出境整个停住,要按继续才会再动")
func 断路器超过门槛就把出境停住() async throws {
    let fileURL = makeQueueFileURL()
    defer { removeQueueDirectory(fileURL) }
    let clock = TestClock()
    let network = NetworkBox()
    let destination = FakeDestination()
    let log = SentenceLog()
    let queue = makeQueue(fileURL: fileURL, destination: destination, clock: clock, network: network, log: log)

    for index in 0...EgressQueue.breakerThreshold {   // 六十一则,刚好越过门槛
        _ = try queue.enqueue(itemID: "I\(index)", contentHash: "h\(index)", bytes: 10, holdSeconds: 5)
        clock.advance(2)
    }

    #expect(log.contains("出境已经全部暂停"))
    #expect(queue.statusSentence.contains("暂停"))

    // 停住就是真的停住:时间再怎麽走,一批都不会出去。
    clock.advance(10_000)
    await queue.tick()
    #expect(destination.sentBatches.isEmpty)

    // 按下继续之後也不是马上冲出去,而是每一批重新给一段倒数。
    try queue.resume()
    await queue.tick()
    #expect(destination.sentBatches.isEmpty)
    clock.advance(EgressQueue.reconnectHoldSeconds + 1)
    await queue.tick()
    #expect(destination.sentBatches.count == 1)
}

// MARK: - 取消

@Test("在倒数结束之前取消,那一则一个位元组都不会离开这台机器")
func 释放之前取消就不会被送出去() async throws {
    let fileURL = makeQueueFileURL()
    defer { removeQueueDirectory(fileURL) }
    let clock = TestClock()
    let network = NetworkBox()
    let destination = FakeDestination()
    let log = SentenceLog()
    let queue = makeQueue(fileURL: fileURL, destination: destination, clock: clock, network: network, log: log)

    _ = try queue.enqueue(itemID: "A", contentHash: "h1", bytes: 100, holdSeconds: 60)
    try queue.cancel(itemID: "A")

    clock.advance(600)
    await queue.tick()

    #expect(destination.sentBatches.isEmpty)
    #expect(queue.pending.isEmpty)
    let row = try #require(queue.recent.first { $0.itemID == "A" })
    #expect(row.state == .cancelled)
    #expect(log.contains("一则都没有离开这台机器"))
}

@Test("已经送出去之後才按取消,句子必须说成「已经上传,之後才要求删除」,绝不能写成已取消")
func 送出之後才取消要讲成上传後删除() async throws {
    let fileURL = makeQueueFileURL()
    defer { removeQueueDirectory(fileURL) }
    let clock = TestClock()
    let network = NetworkBox()
    let destination = FakeDestination()
    let log = SentenceLog()
    let queue = makeQueue(fileURL: fileURL, destination: destination, clock: clock, network: network, log: log)

    _ = try queue.enqueue(itemID: "A", contentHash: "h1", bytes: 100, holdSeconds: 5)
    clock.advance(10)
    await queue.tick()
    #expect(destination.sentBatches.count == 1)

    try queue.cancel(itemID: "A")

    let row = try #require(queue.recent.first { $0.itemID == "A" })
    #expect(row.state == .sent, "位元组已经上线了,状态就不可以退回成已取消。")
    #expect(row.wasSentThenCancelled)
    #expect(log.contains("已经上传"))
    #expect(log.contains("要求删除"))
    #expect(!log.contains("已取消"), "这一则的结果绝对不可以被写成已取消。")
}

// MARK: - 重新启动

@Test("重新启动时不会引爆睡觉期间就到期的倒数,而是重新计时并留下标记")
func 重新启动重新计时而不是立刻送出() async throws {
    let fileURL = makeQueueFileURL()
    defer { removeQueueDirectory(fileURL) }
    let clock = TestClock()
    let network = NetworkBox()
    let destination = FakeDestination()

    let before = makeQueue(fileURL: fileURL, destination: destination, clock: clock, network: network)
    _ = try before.enqueue(itemID: "A", contentHash: "h1", bytes: 100, holdSeconds: 10)

    // 笔电阖上,倒数在没有人看着的时候过完了。
    clock.advance(600)

    let after = makeQueue(fileURL: fileURL, destination: destination, clock: clock, network: network)
    let revived = try #require(after.pending.first)
    #expect(revived.state == .waiting)
    #expect(revived.rearmedReason != nil, "重新计时过的项目一定要被标记出来。")
    // 三十秒与原本倒数两成之中取大的那一个,这里是三十秒。
    #expect(revived.releaseAt == clock.now.addingTimeInterval(EgressQueue.restartMinimumHoldSeconds))

    await after.tick()
    #expect(destination.sentBatches.isEmpty, "启动的那一瞬间绝对不可以送出任何东西。")

    clock.advance(EgressQueue.restartMinimumHoldSeconds + 1)
    await after.tick()
    #expect(destination.sentBatches.count == 1)
}

@Test("排了超过二十四小时的项目会变成过期而不是被送出去,而且仍然留在纪录里")
func 超过二十四小时的项目会过期() async throws {
    let fileURL = makeQueueFileURL()
    defer { removeQueueDirectory(fileURL) }
    let clock = TestClock()
    let network = NetworkBox()
    let destination = FakeDestination()

    let before = makeQueue(fileURL: fileURL, destination: destination, clock: clock, network: network)
    _ = try before.enqueue(itemID: "A", contentHash: "h1", bytes: 100, holdSeconds: 10)

    clock.advance(25 * 3600)

    let after = makeQueue(fileURL: fileURL, destination: destination, clock: clock, network: network)
    let row = try #require(after.recent.first { $0.itemID == "A" })
    #expect(row.state == .expired)
    #expect(after.pending.isEmpty)

    clock.advance(600)
    await after.tick()
    #expect(destination.sentBatches.isEmpty, "过期的项目永远不可以被送出去。")
}

// MARK: - 没有目的地与没有网路

@Test("还没接上云端时,项目一直停在等待中、一次重试都不烧,而且状态句子说得很老实")
func 没接上目的地时项目一直等着() async throws {
    let fileURL = makeQueueFileURL()
    defer { removeQueueDirectory(fileURL) }
    let clock = TestClock()
    let network = NetworkBox()
    let log = SentenceLog()
    let queue = makeQueue(fileURL: fileURL, destination: UnconnectedDestination(),
                          clock: clock, network: network, log: log)

    _ = try queue.enqueue(itemID: "A", contentHash: "h1", bytes: 100, holdSeconds: 1)
    clock.advance(60)
    await queue.tick()
    await queue.tick()

    let row = try #require(queue.pending.first)
    #expect(row.state == .waiting)
    #expect(row.attempts == 0, "没有目的地时连试都不该试,不然重试额度会被白白烧完。")
    #expect(queue.statusSentence.contains("还没有接上任何云端目的地"))
    #expect(log.contains("留在本机"))
}

@Test("离线时整个停住不烧重试次数,网路回来也不会一次全部冲出去")
func 离线不烧重试重新连上不冲出去() async throws {
    let fileURL = makeQueueFileURL()
    defer { removeQueueDirectory(fileURL) }
    let clock = TestClock()
    let network = NetworkBox()
    let destination = FakeDestination()
    let log = SentenceLog()
    let queue = makeQueue(fileURL: fileURL, destination: destination, clock: clock, network: network, log: log)

    network.condition = NetworkCondition(isOnline: false, isExpensive: false)
    _ = try queue.enqueue(itemID: "A", contentHash: "h1", bytes: 100, holdSeconds: 5)
    clock.advance(60)
    await queue.tick()

    #expect(destination.sentBatches.isEmpty)
    #expect(queue.pending.allSatisfy { $0.attempts == 0 })
    #expect(queue.statusSentence.contains("网路目前不通"))

    network.condition = NetworkCondition(isOnline: true, isExpensive: false)
    await queue.tick()
    #expect(destination.sentBatches.isEmpty, "网路一回来就冲出去,正是这条规则要挡的事。")
    let rearmed = try #require(queue.pending.first)
    #expect(rearmed.releaseAt >= clock.now.addingTimeInterval(EgressQueue.reconnectHoldSeconds))
    #expect(log.contains("全部取消"), "重新连线的提示必须顺便把「全部取消」这条路摆在使用者面前。")

    clock.advance(EgressQueue.reconnectHoldSeconds + 1)
    await queue.tick()
    #expect(destination.sentBatches.count == 1)
}
