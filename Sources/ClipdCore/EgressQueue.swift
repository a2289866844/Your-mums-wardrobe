// clipd 的出境佇列 —— 任何要离开这台机器的内容,一律先在这里排队、倒数、随时可以被取消,
// 时间到了才成批送出去。
//
// 这个档案存在的理由是:抓下来跟送出去是两件风险完全不同的事。抓下来只是留在自己的机器上,
// 送出去却是不可逆的 —— 位元组一旦上了线就再也收不回来。所以这里每一条规则都往
// 「宁可晚一点送,也不要送错」的方向倒,而且每一次延後都要用完整的句子讲给使用者听。
//
// 拥有者已经拍板的前提,不要在这里偷偷改回去:内容预设就是会往外送的,没有逐则批准这一关。
// 这个档案负责的是「送出去之前留一段可以反悔的时间」,不是「问要不要送」。

import Foundation
import Network

// MARK: - 对外的型别

/// 出境佇列真正把资料交出去的那一端。
///
/// 刻意做成协定,是因为「送去哪里」是日後才会决定的事,而排队、倒数、取消这些规则现在就必须成立;
/// 把它抽出来,这些规则才测得动,也才不必为了测试真的把东西送上网路。
public protocol EgressDestination: AnyObject, Sendable {
    /// 给人看的名字,会直接出现在面板与事件句子里。
    var displayName: String { get }
    /// 现在有没有真的接上。false 时佇列整个停住,连试都不会试,理由见 `EgressQueue.prepareSendPlan`。
    var isConnected: Bool { get }
    /// 送出一整批。回传的字串是给稽核纪录用的回条,例如对方给的批次编号。
    func send(batch: [QueuedItem]) async throws -> String
}

/// 一则排队项目现在的处境。
public enum QueueState: String, Codable, Sendable {
    case waiting     // 还在倒数,随时可以取消
    case sending     // 位元组正在线上,取消已经不保证来得及
    case sent        // 对方收下了
    case cancelled   // 在送出去之前就被拦下来了
    case expired     // 排太久已经不该再送,永远不会上传
    case failed      // 重试到放弃为止,仍然没送成功
}

extension QueueState {
    /// 已经有结论、不会再变的状态。
    var isFinished: Bool { self != .waiting && self != .sending }
}

/// 佇列里的一则。刻意只带识别码、雜凑与大小,不带任何内容本身:
/// 这个档案会被写到磁碟上、也会被印进事件句子,让内容有机会溜进这两个地方是没有必要的风险。
public struct QueuedItem: Codable, Sendable, Equatable {
    public let itemID: String
    public let contentHash: String
    public let bytes: Int
    public let enqueuedAt: Date
    /// 最早可以送出去的时刻。它是 `let`,任何延後都要透过 `rescheduled` 做出一份新的复本,
    /// 就地改值会让「这一则的倒数被谁改过、改成什麽」这条线索整条断掉。
    public let releaseAt: Date
    public let batchID: String
    public var attempts: Int
    public var state: QueueState
    /// 非 nil 代表这一则的倒数被重新计算过,内容是一句解释原因的完整中文句子。
    public var rearmedReason: String?
    /// 使用者按下取消的时刻。它跟 `state` 是两回事:送出去之後才按的取消不会把状态改成已取消。
    public var cancelRequestedAt: Date?
    /// 有结论的时刻(送出、取消、过期、放弃都算),旧纪录靠它决定什麽时候可以从档案里清掉。
    public var finishedAt: Date?
    public var lastFailureReason: String?

    public init(
        itemID: String,
        contentHash: String,
        bytes: Int,
        enqueuedAt: Date,
        releaseAt: Date,
        batchID: String,
        attempts: Int = 0,
        state: QueueState = .waiting,
        rearmedReason: String? = nil,
        cancelRequestedAt: Date? = nil,
        finishedAt: Date? = nil,
        lastFailureReason: String? = nil
    ) {
        self.itemID = itemID
        self.contentHash = contentHash
        self.bytes = bytes
        self.enqueuedAt = enqueuedAt
        self.releaseAt = releaseAt
        self.batchID = batchID
        self.attempts = attempts
        self.state = state
        self.rearmedReason = rearmedReason
        self.cancelRequestedAt = cancelRequestedAt
        self.finishedAt = finishedAt
        self.lastFailureReason = lastFailureReason
    }

    /// 做出一份倒数时间不同的新复本。
    public func rescheduled(to newRelease: Date, reason: String?) -> QueuedItem {
        QueuedItem(itemID: itemID, contentHash: contentHash, bytes: bytes, enqueuedAt: enqueuedAt,
                   releaseAt: newRelease, batchID: batchID, attempts: attempts, state: state,
                   rearmedReason: reason ?? rearmedReason, cancelRequestedAt: cancelRequestedAt,
                   finishedAt: finishedAt, lastFailureReason: lastFailureReason)
    }

    /// 原本谈好的倒数长度。重新计时之後这个值会跟着变短,所以它代表的是「上一次讲好的那段等待」。
    public var holdSeconds: TimeInterval { max(0, releaseAt.timeIntervalSince(enqueuedAt)) }

    /// 这一则是「已经上传出去,之後才被要求删除」,而不是「被取消」。
    /// 介面上这两件事绝对不可以写成同一句话,理由写在 `EgressQueue.cancel` 上面。
    public var wasSentThenCancelled: Bool { state == .sent && cancelRequestedAt != nil }
}

/// 网路现在的样子。只用得到两件事:通不通、以及这条路是不是被系统标成计费连线。
public struct NetworkCondition: Sendable, Equatable {
    public var isOnline: Bool
    public var isExpensive: Bool
    public init(isOnline: Bool, isExpensive: Bool) {
        self.isOnline = isOnline
        self.isExpensive = isExpensive
    }
}

public enum EgressError: Error, CustomStringConvertible {
    case cannotWriteQueueFile(path: String, reason: String)
    case unknownItem(itemID: String)
    case noDestination

    /// 这些句子有机会直接出现在使用者眼前,所以一律写成完整的句子。
    public var description: String {
        switch self {
        case let .cannotWriteQueueFile(path, reason):
            return "出境佇列的存档 \(path) 写不进去,原因是 \(reason);为了不让排队纪录只活在记忆体里,这一次的异动整个退回了。"
        case let .unknownItem(itemID):
            return "佇列里找不到识别码是 \(itemID) 的项目,所以这次的取消没有对象,什麽都没有做。"
        case .noDestination:
            return "这台机器上还没有接上任何云端目的地,所以这一批没有送出去;它们会继续留在本机的佇列里等着,内容也仍然搜得到、贴得出来。"
        }
    }
}

// MARK: - 还没接上任何地方时的诚实替身

/// 还没有接上云端时用的目的地。
///
/// 它存在的理由是:没有目的地时最糟糕的做法,是让程式假装上传成功、把项目标成已送出。
/// 那会让使用者以为内容已经在云端,实际上一则也没有出去。所以这个替身把话讲死 ——
/// 它明说自己没接上,佇列因此整个停住,项目停在等待中,内容仍然好好地留在本机。
public final class UnconnectedDestination: EgressDestination {
    public init() {}
    public var displayName: String { "还没有接上任何云端目的地" }
    public var isConnected: Bool { false }

    /// 正常路径根本不会走到这里(佇列看到 `isConnected == false` 就停住了)。
    /// 万一有人绕过佇列直接呼叫,它也必须失败,而不是回一个假的回条。
    public func send(batch: [QueuedItem]) async throws -> String {
        _ = batch.count   // 连笔数都不往外讲,这个替身没有资格产生任何一句像是成功的话。
        throw EgressError.noDestination
    }
}

// MARK: - 佇列本体

/// 延迟、成批、可以取消的出境佇列。
///
/// 标 `@unchecked Sendable` 成立的理由:所有可变状态(`items`、`pausedByBreaker`、旗标与回呼)
/// 的读写全部走同一把 `lock`,而且绝不在持有锁的时候呼叫外部程式码 —— 事件句子一律等到解锁之後才送,
/// 网路那一段也一律在锁外面 await。只要有人在锁里面呼叫 `onEvent` 或 `destination`,这个保证就不成立。
public final class EgressQueue: @unchecked Sendable {

    // MARK: 常数(每一个数字旁边都要写清楚它为什麽是这个数字)

    /// 十五秒内进来的算同一批。人手动复制一份东西的节奏大概就是这个量级,
    /// 把它们收成一批,面板上才是一行倒数,而不是十行各自跳动。
    static let batchWindowSeconds: TimeInterval = 15
    /// 突波的两道门槛:十五秒内十则,或六十秒内二十五则。
    static let burstShortWindowSeconds: TimeInterval = 15
    static let burstShortThreshold = 10
    static let burstLongWindowSeconds: TimeInterval = 60
    static let burstLongThreshold = 25
    /// 突波成立时整批往後延两分钟,让使用者有足够时间看到那句提示并按下取消。
    static let burstExtensionSeconds: TimeInterval = 120
    /// 断路器:一小时内超过六十则就停住。
    static let breakerWindowSeconds: TimeInterval = 3600
    static let breakerThreshold = 60
    /// 重新启动时重新计时的规则:三十秒与原本倒数的两成,取大的那一个。
    static let restartMinimumHoldSeconds: TimeInterval = 30
    static let restartHoldFraction: Double = 0.2
    /// 排超过二十四小时就过期,永远不再送。
    static let stalenessLimitSeconds: TimeInterval = 24 * 3600
    /// 网路回来之後重新给的那段短倒数。短,但绝对不是零。
    static let reconnectHoldSeconds: TimeInterval = 60
    /// 两批之间至少隔一秒,任何情况下都不会一次把积压的东西全部冲出去。
    static let releaseSpacingSeconds: TimeInterval = 1
    /// 退避阶梯:5、15、45 秒,然後 2、5、15 分锺,最後停在 30 分锺。
    static let backoffLadder: [TimeInterval] = [5, 15, 45, 120, 300, 900, 1800]
    static let maximumAttempts = 12
    /// 有结论的旧纪录留一小时,让面板还看得到刚刚发生的事,也让突波与断路器的计数有资料可数。
    static let finishedRetentionSeconds: TimeInterval = 3600

    // MARK: 设定与相依

    private let fileURL: URL
    private let destination: EgressDestination?
    private let batchSize: Int
    private let batchBytes: Int
    private let clock: () -> Date
    /// 测试注入的网路状态。nil 代表走正式路径,由 NWPathMonitor 更新 `storedCondition`。
    private let injectedNetwork: (() -> NetworkCondition)?

    private let lock = NSLock()
    private let monitorQueue = DispatchQueue(label: "dev.clipd.egress.network")
    private var items: [QueuedItem] = []
    private var pausedByBreaker = false
    private var lastReleaseAt = Date.distantPast
    private var isSending = false
    private var inFlightTask: Task<String, Error>?
    private var wasOffline = false
    private var announcedExpensive = false
    private var announcedUnconnected = false
    private var loadProblem: String?
    private var storedOnEvent: ((String) -> Void)?
    /// 还没有人接事件之前先存着。启动时重新计时那几句话就是在设定 `onEvent` 之前产生的,
    /// 直接丢掉等於把最该被看到的一句话吞掉。
    private var backlog: [String] = []
    /// 正式路径下由 NWPathMonitor 更新。一开始先当作通的,因为 `start()` 之後几毫秒内
    /// 就会有真正的答案;先假设不通反而会让第一批莫名其妙多等一轮。
    private var storedCondition = NetworkCondition(isOnline: true, isExpensive: false)
    private var monitor: NWPathMonitor?
    private var timer: DispatchSourceTimer?

    public convenience init(fileURL: URL, destination: EgressDestination?, batchSize: Int, batchBytes: Int) {
        self.init(fileURL: fileURL, destination: destination, batchSize: batchSize,
                  batchBytes: batchBytes, now: { Date() }, readNetwork: nil)
    }

    /// 测试用的建构子:时钟与网路状态都换成可以自己写死的闭包,其馀每一步都跟正式路径同一份程式码。
    init(fileURL: URL, destination: EgressDestination?, batchSize: Int, batchBytes: Int,
         now: @escaping () -> Date, readNetwork: (() -> NetworkCondition)?) {
        self.fileURL = fileURL
        self.destination = destination
        self.batchSize = max(1, batchSize)
        self.batchBytes = max(1, batchBytes)
        self.clock = now
        self.injectedNetwork = readNetwork
        // 读档与重新计时都在建构子里做完:这一刻就是「启动」,而启动的规矩是绝不放行任何
        // 已经到期的倒数。晚一步做,就有机会先被 tick 撞见一个到期的项目而直接送出去。
        loadAndRearm()
    }

    deinit { stop() }

    // MARK: 对外的读取

    /// 还没有结论的那几则(等待中与正在送出的),给面板画倒数用。
    public var pending: [QueuedItem] {
        lock.withLock { items.filter { !$0.state.isFinished }.sorted { $0.enqueuedAt < $1.enqueuedAt } }
    }

    /// 佇列里所有还留着的纪录,含已送出、已取消、已过期与已放弃,给稽核与面板的「最近」区块用。
    public var recent: [QueuedItem] {
        lock.withLock { items.sorted { $0.enqueuedAt < $1.enqueuedAt } }
    }

    /// 一句可以原样贴到面板页脚的完整中文句子。
    public var statusSentence: String {
        lock.lock()
        defer { lock.unlock() }
        let t = clock()
        if let loadProblem { return loadProblem }

        let waiting = items.filter { $0.state == .waiting }
        let sending = items.filter { $0.state == .sending }
        if pausedByBreaker {
            return "出境佇列已经整个暂停了,因为一小时之内排进来的项目超过 \(Self.breakerThreshold) 则,这个量看起来不像有人在手动复制;"
                + "目前有 \(waiting.count) 则停在佇列里,要等你亲自按下继续才会再往外送。"
        }
        if !sending.isEmpty {
            return "现在正在送出 \(sending.count) 则内容,另外还有 \(waiting.count) 则在排队等倒数结束。"
        }
        if waiting.isEmpty {
            return "出境佇列现在是空的,没有任何内容在等着送出去。"
        }
        let condition = currentNetworkLocked()
        if !condition.isOnline {
            return "网路目前不通,所以 \(waiting.count) 则内容全部停在佇列里等着,这段时间不会消耗任何一次重试机会。"
        }
        if condition.isExpensive {
            return "现在这条网路被系统标记为计费连线,所以 \(waiting.count) 则内容会一直等到换回一般网路才送出去。"
        }
        guard let destination, destination.isConnected else {
            let name = destination?.displayName ?? "这台机器上还没有设定任何云端目的地"
            return "现在没有连上可以上传的地方(\(name)),所以有 \(waiting.count) 则内容排在佇列里等着;"
                + "它们仍然好好地留在本机,搜寻与贴上都不受影响。"
        }
        let nearest = waiting.map(\.releaseAt).min() ?? t
        let seconds = max(0, Int(nearest.timeIntervalSince(t).rounded()))
        let batches = Set(waiting.map(\.batchID)).count
        return "佇列里有 \(waiting.count) 则内容分成 \(batches) 批,正在等着送往「\(destination.displayName)」,"
            + "最快的一批还有 \(seconds) 秒就会送出去,在那之前都可以取消。"
    }

    /// 事件句子的出口。设定它的当下会把还没送出去的那几句一次补上。
    public var onEvent: ((String) -> Void)? {
        get { lock.withLock { storedOnEvent } }
        set {
            lock.lock()
            storedOnEvent = newValue
            let waiting = backlog
            backlog = []
            lock.unlock()
            guard let newValue else { return }
            for sentence in waiting { newValue(sentence) }
        }
    }

    // MARK: 排队

    /// 把一则内容排进出境佇列。回传的是它排进去之後的样子(倒数可能已经被同批的兄弟拉长了)。
    @discardableResult
    public func enqueue(itemID: String, contentHash: String, bytes: Int, holdSeconds: TimeInterval) throws -> QueuedItem {
        var sentences: [String] = []
        lock.lock()
        let backupItems = items
        let backupPaused = pausedByBreaker
        let t = clock()
        pruneLocked(t)

        let batchID = openBatchLocked(at: t) ?? "batch-\(UInt64(t.timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8))"
        var release = t.addingTimeInterval(max(0, holdSeconds))
        // 同一批里最长的那个倒数说了算,不是最短的。理由是一批的安全程度等於它里面最敏感的那一则:
        // 只要有一则需要多等一会儿,整批就得陪它等,否则那一则会跟着别人提早被送出去。
        if let longest = items.filter({ $0.batchID == batchID && $0.state == .waiting }).map(\.releaseAt).max(),
           longest > release {
            release = longest
        }

        let item = QueuedItem(itemID: itemID, contentHash: contentHash, bytes: max(0, bytes),
                              enqueuedAt: t, releaseAt: release, batchID: batchID)
        items.append(item)
        applyReleaseLocked(batchID: batchID, release: release, reason: nil)

        // 突波本身就是讯号。真正危险的情况不是复制一段字,而是有人正在把一份纪录一格一格抄出去;
        // 那种抄法一定会在短时间内产生一长串项目,所以这里不看内容,只看节奏,并且把现在还在等的
        // 每一批一起往後延 —— 那份被抄出去的纪录本来就会横跨好几批。
        if let burst = burstReasonLocked(at: t) {
            let floor = t.addingTimeInterval(Self.burstExtensionSeconds)
            extendAllWaitingLocked(notEarlierThan: floor, reason: burst)
            sentences.append(burst)
        }

        // 断路器:这道闸存在的唯一理由,是让一个失控的回圈没有办法安安静静地把一千则送出去。
        // 一小时六十则已经远远超过人手复制的速度,超过就停住,等使用者亲自看过再说。
        if !pausedByBreaker, enqueuedWithinLocked(Self.breakerWindowSeconds, at: t) > Self.breakerThreshold {
            pausedByBreaker = true
            sentences.append("一小时之内已经有超过 \(Self.breakerThreshold) 则内容排进出境佇列,这个速度不像是有人在手动复制,"
                + "所以出境已经全部暂停;这些内容仍然好好地留在本机,要等你亲自按下继续才会再往外送。")
        }

        do {
            // 先把整份佇列落地,再让倒数开始。顺序反过来的话,一个只活在记忆体里的排队项目会在当机之後
            // 无声无息地消失,而使用者却以为它排在那里等着被取消。
            try persistLocked()
        } catch {
            items = backupItems
            pausedByBreaker = backupPaused
            lock.unlock()
            throw error
        }
        let stored = items.last(where: { $0.itemID == itemID }) ?? item
        lock.unlock()
        emit(sentences)
        return stored
    }

    // MARK: 取消

    /// 取消一则。
    ///
    /// 这里最重要的一条纪律:位元组一旦上了线就收不回来。所以只有还在等待中的项目才会变成「已取消」;
    /// 已经送出去的项目状态一律维持「已送出」,只是额外记下取消的时刻。介面上永远不可以把後者写成
    /// 「已取消」—— 实际发生的事是「已经上传出去了,之後才去请对方删掉」,这两件事对使用者的意义
    /// 完全不同,写错就是骗人。
    public func cancel(itemID: String) throws {
        try cancelMatching(reason: "指定的这一则", where: { $0.itemID == itemID },
                           missing: EgressError.unknownItem(itemID: itemID))
    }

    /// 取消一整批。面板上一批就是一行,所以使用者按的多半是这一个。
    public func cancelBatch(_ batchID: String) throws {
        try cancelMatching(reason: "这一批", where: { $0.batchID == batchID }, missing: nil)
    }

    /// 取消所有还没送出去的东西。网路刚回来那句提示旁边的按钮就是接这里。
    public func cancelAll() throws {
        try cancelMatching(reason: "佇列里所有", where: { _ in true }, missing: nil)
    }

    private func cancelMatching(reason subject: String, where matches: (QueuedItem) -> Bool, missing: EgressError?) throws {
        var sentences: [String] = []
        lock.lock()
        let backupItems = items
        let t = clock()
        var touchedWaiting = 0
        var touchedSending = 0
        var alreadySent = 0
        var found = false

        for index in items.indices where matches(items[index]) {
            found = true
            switch items[index].state {
            case .waiting:
                items[index].state = .cancelled
                items[index].cancelRequestedAt = t
                items[index].finishedAt = t
                touchedWaiting += 1
            case .sending:
                // 只记下「使用者要求取消」,状态先不动:这一刻还不知道对方收到了没有,
                // 结果要等 `tick` 里那次 await 回来才算数。
                items[index].cancelRequestedAt = t
                touchedSending += 1
            case .sent:
                items[index].cancelRequestedAt = t
                alreadySent += 1
            case .cancelled, .expired, .failed:
                break
            }
        }
        guard found else {
            lock.unlock()
            if let missing { throw missing }
            return
        }

        if touchedSending > 0 { inFlightTask?.cancel() }

        do {
            try persistLocked()
        } catch {
            items = backupItems
            lock.unlock()
            throw error
        }
        lock.unlock()

        if touchedWaiting > 0 {
            sentences.append("\(subject)共 \(touchedWaiting) 则已经在送出去之前拦下来了,它们一则都没有离开这台机器。")
        }
        if touchedSending > 0 {
            sentences.append("\(subject)里有 \(touchedSending) 则的位元组已经在线上了,已经请对方停下来,"
                + "但是能不能来得及不是我们说了算;结果确定之後会再讲一次。")
        }
        if alreadySent > 0 {
            sentences.append("\(subject)里有 \(alreadySent) 则在你按下取消之前就已经上传出去了,"
                + "所以这不是取消上传,而是「已经上传,之後才要求删除」,请照这个理解看待它。")
        }
        emit(sentences)
    }

    /// 断路器跳掉之後,由使用者亲自按下的继续。
    /// 继续之後不是马上放行,而是每一批重新给一段短倒数,理由跟网路回来那一段一样:
    /// 一次把积压的东西全部冲出去,正是断路器当初要挡的那个画面。
    public func resume() throws {
        var sentences: [String] = []
        lock.lock()
        let backupItems = items
        guard pausedByBreaker else { lock.unlock(); return }
        pausedByBreaker = false
        let t = clock()
        let reason = "出境已经由你亲自按下继续,每一批都重新给了 \(Int(Self.reconnectHoldSeconds)) 秒的倒数,不会一次全部送出去。"
        extendAllWaitingLocked(notEarlierThan: t.addingTimeInterval(Self.reconnectHoldSeconds), reason: reason)
        do { try persistLocked() } catch { items = backupItems; pausedByBreaker = true; lock.unlock(); throw error }
        lock.unlock()
        sentences.append(reason)
        emit(sentences)
    }

    // MARK: 送出

    private struct SendPlan {
        let batchID: String
        let items: [QueuedItem]
    }

    /// 佇列的心跳。每次呼叫最多送出一批,而且只在所有闸门都放行时才真的碰网路。
    public func tick() async {
        guard let plan = prepareSendPlan() else { return }
        guard let destination else {
            // 理论上走不到这里(`prepareSendPlan` 已经确认过目的地),但真的走到了也绝不能让这一批
            // 永远卡在「正在送出」——那会让面板显示一件根本没有在发生的事。
            finish(plan: plan, error: EgressError.noDestination)
            return
        }

        // 用 Task 包起来,取消才有对象可以叫停。要讲清楚的是:`cancel()` 只是「请对方停下来」,
        // 对方若已经把位元组读走,这一声叫停救不回任何东西 —— 这正是倒数存在的理由。
        let task = Task { try await destination.send(batch: plan.items) }
        lock.withLock { inFlightTask = task }
        let result = await task.result
        lock.withLock { inFlightTask = nil }

        switch result {
        case let .success(receipt): finish(plan: plan, receipt: receipt)
        case let .failure(error): finish(plan: plan, error: error)
        }
    }

    /// 所有「现在能不能送」的判断都收在这里,而且全部在锁里面做完,回传之後才碰网路。
    private func prepareSendPlan() -> SendPlan? {
        var sentences: [String] = []
        lock.lock()
        let t = clock()
        // 心跳每秒都会来一次,所以这里必须分清楚「有没有真的改到东西」。
        // 每一拍都无条件写一次档,等於整天不停地磨磁碟,而且绝大多数那几次写进去的内容一模一样。
        var changed = pruneLocked(t)
        changed = expireStaleLocked(t, into: &sentences) || changed

        func hold() -> SendPlan? {
            if changed { try? persistLocked() }
            lock.unlock()
            emit(sentences)
            return nil
        }

        if isSending || pausedByBreaker { return hold() }

        let condition = currentNetworkLocked()
        if !condition.isOnline {
            // 离线时整个停住,连一次尝试都不烧。网路不通时去打那通电话,只会白白把退避阶梯往上推,
            // 等网路真的回来时反而要等更久。
            if !wasOffline {
                wasOffline = true
                sentences.append("网路目前不通,出境佇列整个停住等它回来,这段时间不会消耗任何一次重试机会。")
            }
            return hold()
        }
        if wasOffline {
            wasOffline = false
            // 网路一回来绝对不可以把积压的东西一次冲出去 —— 那一瞬间使用者根本来不及反应。
            // 重新给一段短、但绝对不是零的倒数,而且每一批错开一秒,并且主动把「全部取消」摆到他面前。
            let backlogged = rearmAfterReconnectLocked(t)
            if backlogged > 0 {
                changed = true
                sentences.append("网路刚刚恢复了,佇列里积压的 \(backlogged) 则内容不会立刻送出去,"
                    + "每一批都重新给了 \(Int(Self.reconnectHoldSeconds)) 秒的倒数、而且彼此错开;"
                    + "如果这些内容你现在不想送,可以按「全部取消」把它们一次拦下来。")
            }
            return hold()
        }
        if condition.isExpensive {
            // 计费连线上永远不送。使用者用手机热点时最不希望发生的事,就是背景默默把几十 MB 送上去。
            if !announcedExpensive {
                announcedExpensive = true
                sentences.append("现在这条网路被系统标记为计费连线,出境会一直等到换回一般网路才继续。")
            }
            return hold()
        }
        announcedExpensive = false

        guard let destination, destination.isConnected else {
            // 没接上就完全不去打那通电话:项目停在等待中、尝试次数保持零,
            // 才不会在还没有目的地的这段期间把重试额度白白烧完。
            if !announcedUnconnected {
                announcedUnconnected = true
                let name = destination?.displayName ?? "任何云端目的地"
                sentences.append("目前还没有接上\(name),所以佇列里的内容会一直等在这里,"
                    + "它们仍然好好地留在本机,搜寻与贴上都不受影响。")
            }
            return hold()
        }
        announcedUnconnected = false

        // 两批之间至少隔一秒。这一行同时守住「重新连线不要一次冲出去」与「平常也不要连发」。
        guard t.timeIntervalSince(lastReleaseAt) >= Self.releaseSpacingSeconds else { return hold() }
        guard let plan = readyBatchLocked(t) else { return hold() }

        let backupItems = items
        for index in items.indices where plan.items.contains(where: { $0.itemID == items[index].itemID }) {
            items[index].state = .sending
        }
        isSending = true
        lastReleaseAt = t
        do {
            try persistLocked()
        } catch {
            items = backupItems
            isSending = false
            lock.unlock()
            emit(sentences + ["这一批本来要送出去了,但是佇列存档写不进去,所以整批退回继续等待,原因是 \(error)。"])
            return nil
        }
        let marked = items.filter { $0.batchID == plan.batchID && $0.state == .sending }
        lock.unlock()
        emit(sentences)
        return SendPlan(batchID: plan.batchID, items: marked)
    }

    private func finish(plan: SendPlan, receipt: String) {
        var sentences: [String] = []
        lock.lock()
        let t = clock()
        var sentThenCancelled = 0
        for index in items.indices where plan.items.contains(where: { $0.itemID == items[index].itemID }) {
            items[index].state = .sent
            items[index].finishedAt = t
            if items[index].cancelRequestedAt != nil { sentThenCancelled += 1 }
        }
        isSending = false
        try? persistLocked()
        lock.unlock()

        sentences.append("这一批 \(plan.items.count) 则内容已经送出去了,对方给的回条是 \(receipt)。")
        if sentThenCancelled > 0 {
            // 这句话必须说得很死。介面上绝对不可以把这种情况写成「已取消」——
            // 真正发生的事是「已经上传出去了,之後才要求删除」,把它讲成取消就是对使用者说谎。
            sentences.append("其中有 \(sentThenCancelled) 则在你按下取消的时候已经送出去了,"
                + "所以它们的结果是「已经上传,之後才要求删除」,不是「已取消」。")
        }
        emit(sentences)
    }

    private func finish(plan: SendPlan, error: Error) {
        var sentences: [String] = []
        lock.lock()
        let t = clock()
        var givenUp = 0
        var cancelled = 0
        var retried = 0
        var wait: TimeInterval = 0
        for index in items.indices where plan.items.contains(where: { $0.itemID == items[index].itemID }) {
            items[index].attempts += 1
            items[index].lastFailureReason = "\(error)"
            // 送出去失败、而且期间使用者按过取消 —— 这一则是真的被拦下来了,没有任何位元组落地。
            if items[index].cancelRequestedAt != nil {
                items[index].state = .cancelled
                items[index].finishedAt = t
                cancelled += 1
                continue
            }
            let tooOld = t.timeIntervalSince(items[index].enqueuedAt) >= Self.stalenessLimitSeconds
            if items[index].attempts >= Self.maximumAttempts || tooOld {
                items[index].state = .failed
                items[index].finishedAt = t
                givenUp += 1
                continue
            }
            let step = Self.backoffLadder[min(items[index].attempts - 1, Self.backoffLadder.count - 1)]
            wait = step
            items[index] = items[index].rescheduled(
                to: t.addingTimeInterval(step),
                reason: "上一次送出失败了,所以这一批往後退 \(Int(step)) 秒再试一次。"
            )
            items[index].state = .waiting
            retried += 1
        }
        isSending = false
        try? persistLocked()
        lock.unlock()

        if retried > 0 {
            sentences.append("这一批 \(retried) 则内容没有送出去,原因是 \(error);已经排在 \(Int(wait)) 秒之後再试一次。")
        }
        if cancelled > 0 {
            sentences.append("这一批里有 \(cancelled) 则在送出失败之前你就按了取消,它们确实一个位元组都没有离开这台机器。")
        }
        if givenUp > 0 {
            sentences.append("这一批里有 \(givenUp) 则已经试到放弃了,不会再送;它们仍然留在本机历史里,随时搜得到也贴得出来。")
        }
        emit(sentences)
    }

    // MARK: 启动与停止

    /// 开始跑心跳与网路监看。没有呼叫它的话,佇列只会在别人主动呼叫 `tick()` 时前进。
    public func start() {
        lock.lock()
        if timer == nil {
            let source = DispatchSource.makeTimerSource(queue: monitorQueue)
            source.schedule(deadline: .now() + 1, repeating: 1)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                Task { await self.tick() }
            }
            source.resume()
            timer = source
        }
        if monitor == nil, injectedNetwork == nil {
            let pathMonitor = NWPathMonitor()
            pathMonitor.pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                let condition = NetworkCondition(isOnline: path.status == .satisfied, isExpensive: path.isExpensive)
                self.lock.withLock { self.storedCondition = condition }
            }
            pathMonitor.start(queue: monitorQueue)
            monitor = pathMonitor
        }
        let waiting = backlog
        backlog = []
        let handler = storedOnEvent
        lock.unlock()
        guard let handler else {
            lock.withLock { backlog.insert(contentsOf: waiting, at: 0) }
            return
        }
        for sentence in waiting { handler(sentence) }
    }

    /// 停下心跳与监看。已经在线上的那一批不会被这里叫停,因为那已经不是我们能决定的事。
    public func stop() {
        lock.lock()
        timer?.cancel()
        timer = nil
        monitor?.cancel()
        monitor = nil
        lock.unlock()
    }

    // MARK: 启动时的重新计时

    private func loadAndRearm() {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            loadProblem = "读不到出境佇列的存档 \(fileURL.path),原因是 \(error.localizedDescription);"
                + "这一次启动会从空的佇列开始,先前排队的内容不会被送出去,它们仍然留在本机历史里。"
            return
        }
        let snapshot: Snapshot
        do {
            snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        } catch {
            loadProblem = "出境佇列的存档 \(fileURL.path) 解读不了,原因是 \(error.localizedDescription);"
                + "这一次启动会从空的佇列开始,先前排队的内容不会被送出去,它们仍然留在本机历史里。"
            return
        }

        let t = clock()
        pausedByBreaker = snapshot.pausedByBreaker
        var restored: [QueuedItem] = []
        var rearmed = 0
        var expired = 0
        for item in snapshot.items {
            guard !item.state.isFinished else { restored.append(item); continue }
            if t.timeIntervalSince(item.enqueuedAt) >= Self.stalenessLimitSeconds {
                // 排了超过一天的东西不该再送。使用者当初复制它时的处境早就过去了,
                // 现在把它送出去,对他而言等於是一件他不记得自己同意过的事。留在本机历史,永远不上传。
                var stale = item
                stale.state = .expired
                stale.finishedAt = t
                stale.rearmedReason = "这一则从排进佇列到现在已经超过二十四小时,已经改成过期,永远不会上传,但它仍然留在本机历史里。"
                restored.append(stale)
                expired += 1
                continue
            }
            // 关键的一条:启动时绝对不能让一个已经到期的倒数直接引爆。
            // 具体的画面是这样的 —— 有人复制了一段东西、笔电阖上三天,倒数在睡眠中「过完了」;
            // 如果照旧值判断,掀开萤幕的那一瞬间它就上传了,而那三天里使用者完全没有机会反悔。
            // 所以每一则都重新计时:三十秒与原本倒数两成之中取大的那个,并且明白标记它被重新计时过。
            let hold = max(Self.restartMinimumHoldSeconds, item.holdSeconds * Self.restartHoldFraction)
            var revived = item.rescheduled(
                to: t.addingTimeInterval(hold),
                reason: "这一则的倒数在程式没有执行的那段时间里过完了,启动时重新给了 \(Int(hold)) 秒,让你还来得及取消。"
            )
            revived.state = .waiting
            restored.append(revived)
            rearmed += 1
        }
        items = restored
        if rearmed > 0 {
            backlog.append("重新启动之後,佇列里有 \(rearmed) 则内容重新开始倒数,而不是立刻送出去,让你还来得及取消。")
        }
        if expired > 0 {
            backlog.append("佇列里有 \(expired) 则内容已经排了超过二十四小时,已经改成过期、永远不会上传;它们仍然留在本机历史里。")
        }
        if pausedByBreaker {
            backlog.append("上一次执行时出境被断路器停住了,这个状态跟着存档一起留了下来,要等你亲自按下继续才会再往外送。")
        }
    }

    /// 网路回来时重新给倒数,每一批往後错开一秒,回传被重新计时的则数。
    private func rearmAfterReconnectLocked(_ t: Date) -> Int {
        let batches = orderedWaitingBatchesLocked()
        var count = 0
        for (offset, batchID) in batches.enumerated() {
            let release = t.addingTimeInterval(Self.reconnectHoldSeconds + Double(offset) * Self.releaseSpacingSeconds)
            let reason = "网路刚恢复,这一批重新给了倒数而不是立刻送出去,而且跟其他批错开,不会一次全部冲出去。"
            for index in items.indices where items[index].batchID == batchID && items[index].state == .waiting {
                items[index] = items[index].rescheduled(to: release, reason: reason)
                count += 1
            }
        }
        return count
    }

    // MARK: 锁内的小工具

    private func currentNetworkLocked() -> NetworkCondition {
        injectedNetwork?() ?? storedCondition
    }

    /// 还开着、可以继续收东西的那一批:十五秒内、而且还没有满。
    /// 满了就换一批,批次上限才有意义 —— 一批送出去就是一次网路请求,不能无限长。
    private func openBatchLocked(at t: Date) -> String? {
        let candidates = items.filter { $0.state == .waiting && t.timeIntervalSince($0.enqueuedAt) < Self.batchWindowSeconds }
        guard let newest = candidates.max(by: { $0.enqueuedAt < $1.enqueuedAt }) else { return nil }
        let members = items.filter { $0.batchID == newest.batchID && $0.state == .waiting }
        guard members.count < batchSize, members.reduce(0, { $0 + $1.bytes }) < batchBytes else { return nil }
        return newest.batchID
    }

    private func applyReleaseLocked(batchID: String, release: Date, reason: String?) {
        for index in items.indices where items[index].batchID == batchID && items[index].state == .waiting {
            guard items[index].releaseAt != release else { continue }
            items[index] = items[index].rescheduled(to: release, reason: reason)
        }
    }

    private func extendAllWaitingLocked(notEarlierThan floor: Date, reason: String) {
        for index in items.indices where items[index].state == .waiting && items[index].releaseAt < floor {
            items[index] = items[index].rescheduled(to: floor, reason: reason)
        }
    }

    private func enqueuedWithinLocked(_ window: TimeInterval, at t: Date) -> Int {
        items.filter { t.timeIntervalSince($0.enqueuedAt) <= window }.count
    }

    private func burstReasonLocked(at t: Date) -> String? {
        let short = enqueuedWithinLocked(Self.burstShortWindowSeconds, at: t)
        if short >= Self.burstShortThreshold {
            return "刚刚 \(Int(Self.burstShortWindowSeconds)) 秒之内就有 \(short) 则内容排进佇列,"
                + "这种一格一格连续复制的节奏本身就是个讯号,所以整批的倒数往後延了 \(Int(Self.burstExtensionSeconds)) 秒,让你有时间决定要不要拦下来。"
        }
        let long = enqueuedWithinLocked(Self.burstLongWindowSeconds, at: t)
        if long >= Self.burstLongThreshold {
            return "刚刚一分锺之内就有 \(long) 则内容排进佇列,这种连续复制的节奏本身就是个讯号,"
                + "所以整批的倒数往後延了 \(Int(Self.burstExtensionSeconds)) 秒,让你有时间决定要不要拦下来。"
        }
        return nil
    }

    @discardableResult
    private func expireStaleLocked(_ t: Date, into sentences: inout [String]) -> Bool {
        var expired = 0
        for index in items.indices where !items[index].state.isFinished {
            guard t.timeIntervalSince(items[index].enqueuedAt) >= Self.stalenessLimitSeconds else { continue }
            items[index].state = .expired
            items[index].finishedAt = t
            items[index].rearmedReason = "这一则在佇列里排了超过二十四小时,已经改成过期,永远不会上传。"
            expired += 1
        }
        if expired > 0 {
            sentences.append("佇列里有 \(expired) 则内容排了超过二十四小时,已经改成过期、永远不会上传;它们仍然留在本机历史里。")
        }
        return expired > 0
    }

    /// 有结论、而且结论已经旧到没有人会再看的纪录就清掉,免得这个档案无限长大。
    @discardableResult
    private func pruneLocked(_ t: Date) -> Bool {
        let before = items.count
        items.removeAll { item in
            guard item.state.isFinished, let finishedAt = item.finishedAt else { return false }
            return t.timeIntervalSince(finishedAt) > Self.finishedRetentionSeconds
        }
        return items.count != before
    }

    private func orderedWaitingBatchesLocked() -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for item in items.filter({ $0.state == .waiting }).sorted(by: { $0.enqueuedAt < $1.enqueuedAt }) {
            if seen.insert(item.batchID).inserted { ordered.append(item.batchID) }
        }
        return ordered
    }

    /// 挑出一批可以送的。整批必须一起到期才送,因为倒数本来就是整批共用的那一个。
    private func readyBatchLocked(_ t: Date) -> SendPlan? {
        let due = items.filter { $0.state == .waiting && $0.releaseAt <= t }
        guard let earliest = due.min(by: { $0.releaseAt < $1.releaseAt }) else { return nil }
        let members = items.filter { $0.batchID == earliest.batchID && $0.state == .waiting }
            .sorted { $0.enqueuedAt < $1.enqueuedAt }
        guard members.allSatisfy({ $0.releaseAt <= t }) else { return nil }

        // 一次请求带走的量有上限:超过就留到下一轮。第一则一定放得进去,否则一个特别大的项目
        // 会永远卡在门口,谁也送不出去。
        var chunk: [QueuedItem] = []
        var bytes = 0
        for member in members {
            if !chunk.isEmpty, chunk.count >= batchSize || bytes + member.bytes > batchBytes { break }
            chunk.append(member)
            bytes += member.bytes
        }
        return chunk.isEmpty ? nil : SendPlan(batchID: earliest.batchID, items: chunk)
    }

    // MARK: 落地

    private struct Snapshot: Codable {
        var version: Int
        var savedAt: Date
        var pausedByBreaker: Bool
        var items: [QueuedItem]
    }

    private func persistLocked() throws {
        let snapshot = Snapshot(version: 1, savedAt: clock(), pausedByBreaker: pausedByBreaker, items: items)
        let data: Data
        do {
            data = try JSONEncoder().encode(snapshot)
        } catch {
            throw EgressError.cannotWriteQueueFile(path: fileURL.path, reason: error.localizedDescription)
        }

        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        do {
            // 资料夹本身也收成 0o700:这个档案里有雜凑与时间戳,同一台机器上的其他帐号没有理由看得到。
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        } catch {
            throw EgressError.cannotWriteQueueFile(path: fileURL.path, reason: error.localizedDescription)
        }

        // 先用 0o600 建好暂存档再写内容,最後才换到正式位置。
        // 不用 Data.write(options: .atomic) 的理由是它自己会另外产生一个新档案,权限跟着 umask 走,
        // 那一瞬间档案就有可能是别人读得到的;先建档再写,权限从第一个位元组开始就是对的。
        let temporary = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw EgressError.cannotWriteQueueFile(path: temporary.path, reason: "建立暂存档失败。")
        }
        do {
            try data.write(to: temporary)
            if manager.fileExists(atPath: fileURL.path) {
                // 换档是档案系统层级的原子操作,读的人永远只会看到完整的旧档或完整的新档。
                _ = try manager.replaceItemAt(fileURL, withItemAt: temporary, backupItemName: nil,
                                              options: [.usingNewMetadataOnly])
            } else {
                try manager.moveItem(at: temporary, to: fileURL)
            }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            try? manager.removeItem(at: temporary)
            throw EgressError.cannotWriteQueueFile(path: fileURL.path, reason: error.localizedDescription)
        }
    }

    // MARK: 事件

    /// 一定要在锁外面呼叫。接事件的那一端是介面层,它有可能反过来问佇列现在的状态,
    /// 在锁里面呼叫它就是一个现成的死锁。
    private func emit(_ sentences: [String]) {
        guard !sentences.isEmpty else { return }
        lock.lock()
        let handler = storedOnEvent
        if handler == nil { backlog.append(contentsOf: sentences) }
        lock.unlock()
        guard let handler else { return }
        for sentence in sentences { handler(sentence) }
    }
}
