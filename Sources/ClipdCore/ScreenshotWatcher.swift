// 盯着截图资料夹,把「截图存成档案」这条路径变成一则可以进历史的内容。
// 截图到剪贴板那条路径由 PasteboardWatcher 负责,那种截图根本不产生档案;两条路径在 macOS 上是
// 独立机制,少做一条就会有一半的截图永远进不了历史。
import CoreServices
import Foundation
import ImageIO

// MARK: - 委派介面

/// 确认一张截图已经完整落地之後的回呼。
public protocol ScreenshotWatcherDelegate: AnyObject {
    /// `takenAt` 是「快门按下去的那一刻」而不是「档案出现的那一刻」,两者可以差几十秒,理由见
    /// `ScreenshotMetadata.takenAt(for:)`。回呼固定在主执行绪送达,跟 PasteboardWatcher 一致,
    /// 呼叫端才不必为了两个来源写两套执行绪假设。
    func screenshotWatcher(_ w: ScreenshotWatcher, didFind url: URL, takenAt: Date)
}

// MARK: - 错误型别

/// 这一层唯一往外丢的错误。每一句都要给使用者看,所以除了说明哪里坏掉,还要讲清楚
/// 「其他功能还能不能用」,免得使用者以为整个程式挂了。
public enum ScreenshotWatcherError: Error, CustomStringConvertible {
    case directoryUnreadable(path: String, reason: String)
    case cannotCreateEventStream(path: String)
    case cannotStartEventStream(path: String)

    public var description: String {
        switch self {
        case let .directoryUnreadable(path, reason):
            return "clipd 读不到截图资料夹 \(path),系统给的原因是 \(reason)。macOS 预设会把桌面、文件、下载这几个资料夹锁起来,程式要经过你同意才进得去,所以请到「系统设定 → 隐私权与安全性 → 档案与资料夹」把这个资料夹的存取权限授予 clipd。在你授权之前,只有「截图存成档案」这一项会失效;剪贴板监看、搜寻、贴上,以及截图到剪贴板那条路径全部照常运作,完全不受影响。"
        case let .cannotCreateEventStream(path):
            return "clipd 无法为截图资料夹 \(path) 建立档案系统事件监听器,通常代表这个路径已经不存在,或者它位在一个不支援事件通知的磁碟上(例如某些网路磁碟机)。请把截图位置换回本机资料夹再重新启动 clipd。其他功能不受影响,照常可以使用。"
        case let .cannotStartEventStream(path):
            return "clipd 已经建立了 \(path) 的档案系统事件监听器,但系统拒绝启动它,这通常是暂时性的资源不足。请重新启动 clipd 再试一次。其他功能不受影响,照常可以使用。"
        }
    }
}

// MARK: - 档案指纹与稳定裁决

/// 判断「这个档案还在不在长大」的最小证据:大小与最後修改时间。刻意不算内容雜凑 —— 截图动辄
/// 好几 MB,而稳定闸门每 150 毫秒取样一次,每次都把整个档案读进来算雜凑只为了确认它没变,
/// 代价完全不成比例。
struct FileFingerprint: Equatable {
    let size: Int64
    let modifiedAt: Date

    /// 档案不存在或权限不足时回传 nil。呼叫端要把 nil 解读成「现在还不能判断」,而不是「档案是空的」。
    init?(path: String) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modifiedAt = attributes[.modificationDate] as? Date else { return nil }
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

/// 稳定闸门的裁决。
enum StabilityVerdict: Equatable {
    case settled          // 两次取样之间完全没变,可以进下一关。
    case stillChanging    // 还在被写入,再等一轮。
    case missing          // 档案不见了,可能被使用者当场删掉或搬走。
}

// MARK: - 截图的中继资料

/// 判断「这是不是截图」以及「快门是什麽时候按的」。刻意做成无状态的静态函式:FSEvents 与使用者
/// 按快门无法在单元测试里重现,但这些判断可以,所以本档案的可测试面就集中在这里。
enum ScreenshotMetadata {
    /// macOS 帮每一张截图盖的印记,值是一个内含单一布林的二进位属性清单。
    static let isScreenCaptureKey = "com.apple.metadata:kMDItemIsScreenCapture"

    /// 姊妹属性,内容是截图方式。本机实测到的值有 "selection"(框选)与 "display"(整个萤幕)。
    static let captureTypeKey = "com.apple.metadata:kMDItemScreenCaptureType"

    /// 读一个延伸属性的原始位元组。属性不存在时回传 nil,这是正常情况不是错误。
    static func rawAttribute(_ name: String, atPath path: String) -> Data? {
        // 先问长度再配置缓冲区。猜一个固定大小的话,属性一旦变长就会被默默截断,而截断的属性清单
        // 解析出来是 nil,看起来跟「不是截图」一模一样,极难查。
        let length = path.withCString { getxattr($0, name, nil, 0, 0, 0) }
        guard length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        let read = path.withCString { cPath in
            buffer.withUnsafeMutableBytes { getxattr(cPath, name, $0.baseAddress, length, 0, 0) }
        }
        // 两次呼叫之间属性可能被改写而变长变短。长度对不上就当这一轮读失败,下一轮再读;
        // 拿一份长度不对的资料去解析只会得到假答案。
        guard read == length else { return nil }
        return Data(buffer)
    }

    /// 这是不是一张 macOS 截图。
    ///
    /// 一定要用延伸属性判断,绝对不能用档名比对。这台机器的系统语言是繁体中文,截图档名长这样:
    /// 「截圖 2026-07-25 14.44.14.png」,同一秒内的第二张还会带一个全形括号的编号。也就是说,一条比对
    /// 英文 "Screenshot" 的档名正规表示式在这台机器上一张都比对不到,而且失败得静悄悄 —— 功能看起来
    /// 有在跑,就是永远没结果。延伸属性跟系统语言、跟使用者有没有改档名都无关;本机实测七张真实截图
    /// 上这个属性全部存在。
    static func isScreenCapture(atPath path: String) -> Bool {
        guard let raw = rawAttribute(isScreenCaptureKey, atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: raw, options: [], format: nil),
              let flag = plist as? NSNumber else { return false }
        return flag.boolValue
    }

    /// 截图方式,读不到就回传 nil。目前只当诊断资讯,不参与任何判断。
    static func captureType(atPath path: String) -> String? {
        guard let raw = rawAttribute(captureTypeKey, atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: raw, options: [], format: nil)
        else { return nil }
        return plist as? String
    }

    /// 快门按下去的那一刻。
    ///
    /// 为什麽一定要区分「按快门」跟「档案出现」:呼叫端拿到这个时间後会去问前景程式历史「那一瞬间最
    /// 前面的是谁」藉此判断来源,而档案落地永远晚於快门 —— 本机实测七张截图的落差是 +5、+6、+79、+5、
    /// +6、+5、+5 秒,那个 79 秒是使用者按完快门跑去用标示工具编辑,而且没有上界。使用者在这段空档几乎
    /// 一定会切到别的程式,所以拿「档案出现的时间」去问,问到的会是他後来切过去的那个程式,来源整个
    /// 记错,而且错得很合理、完全看不出来。
    ///
    /// 诚实的但书:本机实测 kMDItemContentCreationDate 与档案建立时间相同,都比档名里的时间晚 5 秒,
    /// 所以这是「快门时间的上界」而非分毫不差的快门时间。即使如此仍远胜於用「现在」—— 上界误差是几秒,
    /// 用「现在」的误差可以到 79 秒。刻意不解析档名求精确,理由同上:档名格式随系统语言而变,不可靠。
    static func takenAt(for url: URL) -> Date {
        if let item = NSMetadataItem(url: url),
           let created = item.value(forAttribute: "kMDItemContentCreationDate") as? Date { return created }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let birth = attributes[.creationDate] as? Date { return birth }
        // 两个都读不到只可能是档案刚好在这一瞬间被删掉。回传「现在」是最差的答案,但至少让呼叫端拿到
        // 一个可用的时间;来源判断会因此退化,这是诚实的结果。
        return Date()
    }

    /// 两次取样之间档案有没有安定下来。纯函式,方便直接测试。
    static func verdict(previous: FileFingerprint?, current: FileFingerprint?) -> StabilityVerdict {
        guard let current else { return .missing }
        guard let previous else { return .stillChanging }
        return previous == current ? .settled : .stillChanging
    }

    /// 影像本身能不能被解码器接受。
    ///
    /// 重要但书,来自本机实测:把一张 748 KB 的真实截图截断到只剩一成,CGImageSourceGetStatus 仍然回报
    /// statusComplete。所以这一关抓得到的只有零位元组佔位档与根本不是影像的垃圾档(实测零位元组回报 -4),
    /// 抓不到「写到一半」。真正挡住半成品的是前面那道大小与修改时间的稳定闸门 —— 这一关是补强不是主力,
    /// 千万不要因为有了它就把稳定闸门拿掉。
    static func isImageReadable(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetStatus(source) == .statusComplete && CGImageSourceGetCount(source) > 0
    }
}

// MARK: - 事件回呼

/// FSEvents 的回呼是一根 C 函式指标,没办法捕捉任何东西,所以监看器本体要透过
/// FSEventStreamContext 的 info 栏位以不具拥有权的指标传进来。
private let screenshotEventCallback: FSEventStreamCallback = { _, info, count, pathsPointer, flagsPointer, idsPointer in
    guard let info else { return }
    let watcher = Unmanaged<ScreenshotWatcher>.fromOpaque(info).takeUnretainedValue()
    // 建立事件流时指定了 UseCFTypes,所以这里拿到的是一个装着 CFString 的 CFArray。
    guard let paths = unsafeBitCast(pathsPointer, to: NSArray.self) as? [String] else { return }
    var events: [(path: String, flags: FSEventStreamEventFlags)] = []
    events.reserveCapacity(count)
    for i in 0..<min(count, paths.count) { events.append((paths[i], flagsPointer[i])) }
    watcher.handle(events: events, latestEventID: count > 0 ? idsPointer[count - 1] : 0)
}

// MARK: - 监看器本体

/// 监看截图资料夹,确认档案完整之後交给委派。
///
/// 底线:使用者的截图档案,本类别从头到尾只读,绝对不搬、不改名、不删除、不写入。那是使用者自己的
/// 档案,我们只是旁观者。
///
/// 执行绪纪律:FSEvents 回呼与整条验证流程都跑在私有序列佇列 `queue` 上,验证用的可变状态只在那条
/// 佇列上被碰;`stream` 与 `storedDirectory` 会被主执行绪的 start()/stop() 与佇列同时存取,所以由
/// `lock` 保护。送给委派的那一刻切回主执行绪。`@unchecked Sendable` 成立的前提就是这套纪律,
/// 有人绕过佇列直接改状态,保证就不成立。
public final class ScreenshotWatcher: @unchecked Sendable {
    /// FSEvents 自己的合并延迟。0.1 秒让「写档 + 盖延伸属性」这一串动作合并成一次回呼。
    private static let streamLatency: CFTimeInterval = 0.1
    /// 收到事件後先退避多久才开始验证。截图落地是一连串写入,立刻去看只会看到半成品。
    private static let debounceDelay: TimeInterval = 0.3
    /// 稳定闸门两次取样的间隔。
    private static let settleInterval: TimeInterval = 0.15
    /// 验证最多重试几次。20 乘以 0.15 秒约三秒,足够涵盖一次大截图的写入时间。这跟「快门到落地最久
    /// 79 秒」不冲突:那 79 秒是使用者在标示工具里编辑的时间,而 FSEvents 是在档案真的开始落地时才
    /// 通知我们,我们等的只是「写完这一份」。
    private static let maxVerifyAttempts = 20
    /// 允许延伸属性「还没盖上去」的宽限次数。位元组与印记不是同一个原子动作,极短时间内可能只看到
    /// 档案还看不到印记。宽限四次约 0.6 秒,超过就当它不是截图 —— 不这样限制的话,使用者存到桌面的
    /// 每一个档案都会白白空转三秒。
    private static let attributeGraceAttempts = 4
    /// 已送出的路径最多记住几笔,避免这个集合随开机时间无限成长。
    private static let deliveredHistoryLimit = 512
    /// 上一次处理到的事件编号存在这个键底下。
    private static let lastEventIDKey = "dev.clipd.screenshotWatcher.lastEventID"

    public weak var delegate: ScreenshotWatcherDelegate?

    /// 目前监看的资料夹。使用者可以随时用截图工具列的「储存到」选单、或
    /// `defaults write com.apple.screencapture location` 改掉截图位置,所以这个值不是永久不变的。
    /// 我们在每次 start() 时重新读一次偏好设定;监看途中改掉的话要等下次重新启动才会跟上 —— 这是刻意
    /// 的取舍,为了即时跟上而去监看整个使用者目录,代价远大於换来的好处。
    public var watchedDirectory: URL {
        lock.lock(); defer { lock.unlock() }
        return storedDirectory
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return stream != nil
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.clipd.screenshot-watcher")
    private var stream: FSEventStreamRef?
    private var storedDirectory: URL
    /// 正在验证中的路径,防止同一个档案的多个事件叠出好几条验证流程。
    private var pendingPaths: Set<String> = []
    /// 已送出的路径。FSEvents 对一个档案会发很多次事件(建立、修改、改名、属性变动),没有这道防线
    /// 的话同一张截图会被送出好几遍。
    private var deliveredPaths: Set<String> = []
    private var deliveredOrder: [String] = []

    public init() { self.storedDirectory = Self.resolveScreenshotDirectory() }

    /// 事件流握着一根指向 self 的不具拥有权指标,本物件消失前一定要关掉,否则回呼会拿着一根悬空指标继续跑。
    deinit { stop() }

    /// 开始监看。重复呼叫是安全的,第二次以後直接返回。
    public func start() throws {
        guard !isRunning else { return }
        // 每次启动都重新读一次偏好设定,使用者上次关掉程式後改过截图位置才跟得上。
        let directory = Self.resolveScreenshotDirectory()
        // 先确认真的读得到。没有这一步的话,权限被挡住时事件流仍然会建立成功、只是一辈子收不到任何
        // 事件 —— 功能悄悄失效而使用者毫不知情,这正是最该避免的失败方式。
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            throw ScreenshotWatcherError.directoryUnreadable(
                path: directory.path, reason: error.localizedDescription
            )
        }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        // UseCFTypes 让回呼收到 CFArray 装的 CFString,不必自己处理 C 字串阵列。FileEvents 让通知精确到
        // 单一档案;没有它就只会收到「这个资料夹变了」,那样每次都得重扫整个桌面才知道是哪一个档案。
        // NoDefer 让第一个事件立刻送达、之後才进入合并延迟;截图是使用者刚做完的动作,先等满一个延迟
        // 再通知会让整件事感觉慢半拍。
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, screenshotEventCallback, &context,
            [directory.path] as CFArray, resumeEventID(), Self.streamLatency, flags
        ) else {
            throw ScreenshotWatcherError.cannotCreateEventStream(path: directory.path)
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            throw ScreenshotWatcherError.cannotStartEventStream(path: directory.path)
        }
        lock.lock()
        stream = created
        storedDirectory = directory
        lock.unlock()
    }

    /// 停止监看。已经停了再呼叫一次不会有事。
    public func stop() {
        lock.lock()
        let existing = stream
        stream = nil
        lock.unlock()
        guard let existing else { return }
        FSEventStreamStop(existing)
        FSEventStreamInvalidate(existing)
        FSEventStreamRelease(existing)
    }

    /// 读出截图要存到哪里。使用者可以随时改掉这个设定,所以每次启动都要重新读,不能只读一次。
    /// 本机实测这个键目前没设定过,所以走的正是下面的桌面预设值这条路。
    private static func resolveScreenshotDirectory() -> URL {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Desktop", isDirectory: true)
        guard let raw = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return desktop }
        // 绝大多数情况这是一个可能带波浪号的路径字串,但有些第三方工具会写成 file:// 网址,两种都要认。
        let path: String = raw.hasPrefix("file://")
            ? (URL(string: raw)?.path ?? raw)
            : (raw as NSString).expandingTildeInPath
        // 设定里的资料夹可能已被删掉或改名。这时候退回桌面,而不是去监看一个不存在的路径 ——
        // 监看不存在的路径不会报错,只会永远收不到事件。
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return desktop }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// 从哪一个事件编号开始收。存下上次处理到的编号,是为了让「程式重新启动那几秒内拍的截图」在下次
    /// 启动时被补送,否则那几张会永远消失。代价是同一张有机会被送出两次(上次已送出、编号却还没更新),
    /// 所以呼叫端必须用内容雜凑去重 —— Store.existingID(contentHash:within:) 正是为此存在。
    private func resumeEventID() -> FSEventStreamEventId {
        let stored = UserDefaults.standard.object(forKey: Self.lastEventIDKey) as? NSNumber
        guard let value = stored?.uint64Value, value > 0,
              value != FSEventStreamEventId(kFSEventStreamEventIdSinceNow) else {
            // 第一次启动没有历史可以续接就从「现在」开始。不从 0 开始是因为那会把整个磁碟的历史事件
            // 全部重播一遍。
            return FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        }
        return value
    }

    private func rememberEventID(_ id: FSEventStreamEventId) {
        // kFSEventStreamEventIdSinceNow 实际上就是 UInt64 的最大值(本机实测确认)。存下这个哨兵值的话,
        // 下次启动会拿它当起点而收不到任何东西,所以一定要挡掉。
        guard id > 0, id != FSEventStreamEventId(kFSEventStreamEventIdSinceNow) else { return }
        UserDefaults.standard.set(NSNumber(value: id), forKey: Self.lastEventIDKey)
    }

    /// 由 C 回呼呼叫,已经在私有序列佇列上。
    fileprivate func handle(
        events: [(path: String, flags: FSEventStreamEventFlags)],
        latestEventID: FSEventStreamEventId
    ) {
        let isFile = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
        let dropped = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagUserDropped)
        let interesting = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemXattrMod)
        for event in events {
            // 系统丢掉过事件时不会说丢了哪些,只会举这面旗。默默忽略等於默默漏掉截图,所以改成重扫
            // 一次资料夹;不是截图的档案会在延伸属性那一关被挡下来。
            if event.flags & dropped != 0 { rescanDirectory(); continue }
            guard event.flags & isFile != 0, event.flags & interesting != 0 else { continue }
            enqueue(URL(fileURLWithPath: event.path))
        }
        rememberEventID(latestEventID)
    }

    private func rescanDirectory() {
        let directory = watchedDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where !name.hasPrefix(".") {
            enqueue(directory.appendingPathComponent(name))
        }
    }

    /// 排进验证流程。必须在私有佇列上呼叫。
    private func enqueue(_ url: URL) {
        let key = url.path
        // 点号开头的档案跳过。这不是用档名判断截图,而是排除 iCloud 佔位档(桌面若开了 iCloud 同步,
        // 未下载的档案会长成 .某某.icloud)与各种暂存档。
        guard !url.lastPathComponent.hasPrefix("."),
              !deliveredPaths.contains(key), !pendingPaths.contains(key) else { return }
        pendingPaths.insert(key)
        queue.asyncAfter(deadline: .now() + Self.debounceDelay) { [weak self] in
            self?.verify(url, attempt: 0, previous: nil)
        }
    }

    /// 一轮验证。用非同步链而不是在佇列上睡觉,因为睡着的话事件就送不进来了。
    private func verify(_ url: URL, attempt: Int, previous: FileFingerprint?) {
        let key = url.path
        guard isRunning else { pendingPaths.remove(key); return }
        // 不是截图就完全不碰。宽限几轮是因为位元组与印记不是同一个原子动作写下去的。
        guard ScreenshotMetadata.isScreenCapture(atPath: key) else {
            if attempt < Self.attributeGraceAttempts {
                retry(url, attempt: attempt, previous: nil)
            } else {
                pendingPaths.remove(key)
            }
            return
        }
        let current = FileFingerprint(path: key)
        switch ScreenshotMetadata.verdict(previous: previous, current: current) {
        case .missing:
            // 档案不见了。使用者当场删掉或搬走都算正常操作,不是错误,直接放手。
            pendingPaths.remove(key)
        case .stillChanging:
            retry(url, attempt: attempt, previous: current)
        case .settled:
            guard ScreenshotMetadata.isImageReadable(at: url), canCoordinateRead(url) else {
                retry(url, attempt: attempt, previous: current)
                return
            }
            deliver(url)
        }
    }

    private func retry(_ url: URL, attempt: Int, previous: FileFingerprint?) {
        guard attempt < Self.maxVerifyAttempts else {
            // 放弃。诚实地把它从进行中移除、而且不加进已送出,使用者之後再动到这个档案时还有机会补收。
            pendingPaths.remove(url.path)
            return
        }
        queue.asyncAfter(deadline: .now() + Self.settleInterval) { [weak self] in
            self?.verify(url, attempt: attempt + 1, previous: previous)
        }
    }

    /// 确认真的读得到位元组。走 NSFileCoordinator 而不是直接开档,是因为桌面可能开着 iCloud 同步,这时候
    /// 档案有可能只是一个还没下载下来的佔位档,协调读取会等到内容真的到位。用 .withoutChanges 是明确宣告
    /// 「我只读、不会改」,这也呼应本类别的底线:使用者的截图我们只读,从不搬、不改名、不删除。
    private func canCoordinateRead(_ url: URL) -> Bool {
        var coordinationError: NSError?
        var readable = false
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url, options: [.withoutChanges], error: &coordinationError
        ) { actual in
            // 只读一个位元组就够:目的是确认内容已经在本机、开得起来,不是要把整张图搬进记忆体 ——
            // 那是呼叫端的工作,在这里做只会白白吃掉几 MB。
            guard let handle = try? FileHandle(forReadingFrom: actual) else { return }
            defer { try? handle.close() }
            readable = ((try? handle.read(upToCount: 1))?.isEmpty == false)
        }
        return readable && coordinationError == nil
    }

    private func deliver(_ url: URL) {
        let key = url.path
        pendingPaths.remove(key)
        deliveredPaths.insert(key)
        deliveredOrder.append(key)
        if deliveredOrder.count > Self.deliveredHistoryLimit {
            deliveredPaths.remove(deliveredOrder.removeFirst())
        }
        let takenAt = ScreenshotMetadata.takenAt(for: url)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.screenshotWatcher(self, didFind: url, takenAt: takenAt)
        }
    }
}
