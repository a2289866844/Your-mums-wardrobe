import Foundation
import AppKit

/// 某个程式在某个时间点取得前景焦点的一笔纪录。
///
/// 这个型别刻意只存「谁」跟「什麽时候」,不存 NSRunningApplication 本身。
/// 原因是 NSRunningApplication 会随着程式结束而失效,而我们需要在事发很久之後
/// (截图最久要等 79 秒才落地)还能回头查当时是谁在前景,所以必须先把值抄下来。
public struct ActivationRecord: Sendable, Equatable {
    public let bundleID: String
    public let appName: String
    public let at: Date

    public init(bundleID: String, appName: String, at: Date) {
        self.bundleID = bundleID
        self.appName = appName
        self.at = at
    }
}

extension ActivationRecord {
    /// 从一个正在执行的程式建立纪录。没有 bundle 识别码就建不出来。
    ///
    /// 会失败是刻意的:封锁清单是靠 bundle 识别码比对的,一笔没有识别码的纪录
    /// 永远比对不到任何封锁项目,记下来只会让使用者以为自己挡住了某个程式、实际上没挡到。
    /// 宁可这一笔完全不存在,让来源退回 unknown,也不要给出一个假的安全感。
    init?(app: NSRunningApplication, at: Date) {
        guard let bundleID = app.bundleIdentifier else { return nil }
        self.init(bundleID: bundleID, appName: app.localizedName ?? bundleID, at: at)
    }
}

/// 记录「哪个程式在什麽时候变成前景」的固定容量环形缓冲区,用来回答
/// 「这则内容是从哪个程式复制来的」这个 M1 里最难答对的问题。
///
/// 为什麽需要它:macOS 完全没有剪贴板变动通知,我们只能每 200 毫秒轮询一次。
/// 等到发现内容变了的时候,使用者很可能已经切换到别的程式;截图更夸张,
/// 档案要等 5 到 79 秒才会真的落到磁碟上。所以「现在最前景的是谁」这个问题
/// 在最需要答案的时候刚好会给出错的答案,我们必须能回头查历史。
///
/// 执行绪纪律:NSWorkspace 的通知固定在主执行绪送达,而查询是从轮询用的背景佇列发出的,
/// 两边一定会并发。因此所有可变状态都由同一把 NSLock 保护;锁内只做纯粹的资料操作,
/// 绝不呼叫任何可能回头呼叫本物件的外部程式码,避免自己把自己锁死。
public final class ActivationRing: @unchecked Sendable {

    private let lock = NSLock()

    /// 固定长度的缓冲区,写满之後从头覆盖,所以记忆体用量是常数,不会随着开机时间无限成长。
    private var buffer: [ActivationRecord?]

    /// 下一笔要写进去的位置。
    private var nextIndex = 0

    /// 最後一次真的写进去的程式识别码,用来滤掉连续重复的启动通知。
    private var lastRecordedBundleID: String?

    /// NSWorkspace 通知的观察者代号,stop() 时要拿它来解除註册。
    private var observer: NSObjectProtocol?

    /// 我们自己的 bundle 识别码。允许注入是为了让测试能给一个固定值,
    /// 因为测试执行档的 Bundle.main.bundleIdentifier 在 swift test 底下并不稳定。
    private let ownBundleID: String?

    public init(capacity: Int = 64, ownBundleID: String? = Bundle.main.bundleIdentifier) {
        // 容量至少要有一格,否则後面的取馀数运算会除以零而崩溃。
        let size = max(1, capacity)
        self.buffer = Array(repeating: nil, count: size)
        self.ownBundleID = ownBundleID
    }

    deinit {
        stop()
    }

    // ── 生命週期 ──────────────────────────────────────────

    /// 开始监听程式切换。重复呼叫是安全的,第二次以後会直接返回。
    public func start() {
        lock.lock()
        let alreadyRunning = observer != nil
        lock.unlock()
        guard !alreadyRunning else { return }

        seedWithCurrentFrontmostApp()

        // 通知指定送到主佇列,理由是 AppKit 的前景程式资讯本来就该在主执行绪读,
        // 而写进缓冲区这件事有锁保护,不怕跟背景的查询撞在一起。
        let token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let app, let entry = ActivationRecord(app: app, at: Date()) else { return }
            self.record(entry)
        }

        lock.lock()
        observer = token
        lock.unlock()
    }

    /// 停止监听。已经停了再呼叫一次不会有事。
    public func stop() {
        lock.lock()
        let token = observer
        observer = nil
        lock.unlock()

        if let token {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    /// 把「此刻最前景的程式」先种进缓冲区。
    ///
    /// 这一步不能省。macOS 只在程式「切换」的瞬间发通知,如果使用者从我们启动之後
    /// 一直待在同一个程式里复制东西、中间完全没切换过,那我们一笔通知都收不到,
    /// 缓冲区会是空的,那则内容的来源就只能标成 unknown ——
    /// 明明是个很容易答对的情况,却因为没种这一笔而白白答不出来。
    ///
    /// 附带说明:种下去的时间戳记是「现在」,不是那个程式真正变成前景的时间(我们查不到)。
    /// 所以刚启动後马上发生的复制会落在切换窗口内而被判成 low,这是诚实的结果,
    /// 我们确实不知道那个程式已经在前景待了多久。
    private func seedWithCurrentFrontmostApp() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let seed = ActivationRecord(app: front, at: Date()) else { return }
        record(seed)
    }

    // ── 写入 ─────────────────────────────────────────────

    /// 记下一笔程式切换。公开出来是为了让测试能用合成的时间戳记直接驱动,
    /// 不必真的去操作一个 NSWorkspace。
    public func record(_ r: ActivationRecord) {
        // 自己的程式取得焦点时绝对不能记进去。我们的面板一弹出来就会抢走前景焦点,
        // 若照单全收,之後每一则内容的来源都会被判成「clipd 自己」,这个栏位就彻底废掉了。
        if let own = ownBundleID, r.bundleID == own { return }

        lock.lock()
        defer { lock.unlock() }

        // 同一个程式连续两次取得焦点(例如在自己的多个视窗之间来回切)并不是来源切换。
        // 照记的话会让可信度无谓地从 medium 掉到 low,等于凭空制造出不确定性。
        if lastRecordedBundleID == r.bundleID { return }

        buffer[nextIndex] = r
        nextIndex = (nextIndex + 1) % buffer.count
        lastRecordedBundleID = r.bundleID
    }

    // ── 查询 ─────────────────────────────────────────────

    /// 回答「在 t 这个瞬间,前景的是谁」。缓冲区里没有任何一笔早於 t 的纪录时回传 nil,
    /// 呼叫端应该把 nil 解读成「答不出来」,而不是「没有来源」。
    public func appAt(_ t: Date) -> ActivationRecord? {
        lock.lock()
        defer { lock.unlock() }
        return chronologicalLocked().last { $0.at <= t }
    }

    /// 回传所有「有可能是来源」的程式,以及这个判断的可信度。
    ///
    /// 刻意回传联集而不是单一最佳猜测:下游的封锁清单只要发现联集里「有任何一位」
    /// 是被封锁的程式,就应该整则丢掉。宁可多列一位而误挡,也不要少列一位而把
    /// 密码管理器或病历系统的内容存进资料库 —— 在这个问题上,过度包含才是安全的方向。
    ///
    /// 可信度的规则:
    ///   - medium:只有一位候选人,而且切换窗口内没有发生过任何程式切换。
    ///   - low   :切换窗口内刚好发生过切换,我们是真的分不出来是切换前还是切换後复制的。
    ///   - unknown:缓冲区里根本没有涵盖 t 的纪录。
    ///
    /// 这个型别永远不会回传 high。high 保留给「剪贴板自己带来的证据」——
    /// 例如 org.nspasteboard.source 标记,或浏览器附上的来源网址 ——
    /// 那些证据不经过前景程式的推断,而本型别根本看不到剪贴板,所以没有资格给出 high。
    public func candidates(
        at t: Date,
        switchWindow: TimeInterval = 0.75
    ) -> (records: [ActivationRecord], provenance: Provenance) {
        lock.lock()
        defer { lock.unlock() }

        let all = chronologicalLocked()
        guard let idx = all.lastIndex(where: { $0.at <= t }) else {
            // 完全没有纪录涵盖这个时间点,例如缓冲区已经被更新的纪录挤爆,
            // 或者这则内容比我们开始监听的时间还早。
            return ([], .unknown)
        }

        let current = all[idx]
        let sinceSwitch = t.timeIntervalSince(current.at)

        // 距离最近一次切换还没超过窗口,代表使用者可能是在切换前就按下复制、
        // 我们却在切换後才轮询到,所以前一个程式同样有嫌疑。
        guard sinceSwitch < switchWindow else {
            return ([current], .medium)
        }

        if idx > 0 {
            // 顺序刻意把「切换之前那个程式」排在前面。
            //
            // 理由是时序推理:轮询间隔是 0.2 秒,所以看到变动时,复制这个动作发生在过去 0.2 秒之内。
            // 如果同一段时间里刚好发生了程式切换,那麽真实的顺序几乎一定是「先复制、才切走」——
            // 使用者是先按了复制键,然後才去别的程式准备贴上。反过来「先切到新程式、再在 0.2 秒内
            // 完成一次复制」在人类的操作速度下几乎不可能。
            //
            // 两位候选人都会留在清单里,因为日後的黑名单只要其中任何一个被挡就该挡下整则;
            // 排序只影响「面板上要显示哪一个名字」。可信度仍然是 low,诚实标示我们无法确定。
            return ([all[idx - 1], current], .low)
        }
        // 窗口内有切换,但前面没有更早的纪录可以当第二嫌疑人。
        // 候选人只有一位,可信度仍然是 low —— 真正的来源有可能是我们从没记录过的程式。
        return ([current], .low)
    }

    /// 取出缓冲区里所有有效纪录并依时间排序。
    ///
    /// 排序是保险动作:正常情况下写入本来就是照时间顺序的,但通知在系统忙碌时
    /// 有可能稍微乱序送达,而整个来源判断都建立在「上一笔」这个概念上,
    /// 一旦顺序错了结论就会错,所以这里花常数级的成本(最多 64 笔)换取绝对正确。
    ///
    /// 必须在持有锁的情况下呼叫。
    private func chronologicalLocked() -> [ActivationRecord] {
        buffer.compactMap { $0 }.sorted { $0.at < $1.at }
    }
}
