import AppKit
import Carbon.HIToolbox
import Foundation
import IOKit

// MARK: - 为什麽是 Carbon,不是 NSEvent 全域监看器
//
// 要抢下一组「不管哪个程式在前景都能触发」的快速键,实务上只有两条路。
// 第一条是 NSEvent.addGlobalMonitorForEvents(matching: .keyDown, ...),但它需要使用者先到
// 「系统设定 → 隐私权与安全性 → 辅助使用」把本程式打勾;没授权时监看器会安静地一个事件都收不到,
// 不报错、不抛例外、就是永远不触发 —— 这是最糟的失败模式,使用者以为程式坏了,
// 我们也拿不出任何证据指出原因。第二条是 Carbon 的 RegisterEventHotKey / InstallEventHandler,
// 这组 API 从 Mac OS 9 活到今天、至今未被弃用,由 WindowServer 直接派送,完全不需要任何权限授权。
//
// 本专案的设计目标是「第一次启动零权限弹窗」:剪贴板管理器本来就够敏感了,一开启就要求辅助使用权限,
// 会让使用者合理地怀疑我们想偷看他打的每一个字。所以这里选第二条路 —— Carbon 的型别很 C、
// 名字很旧,但它是唯一能达成零权限目标的选项。
//
// MARK: - 关於安全输入模式(Secure Input)
//
// EnableSecureEventInput() 是系统给密码栏位用的保护机制:某个程式(浏览器的密码框、登入视窗、
// 终端机的 sudo 提示)一旦开启它,系统就会挡掉其他程式偷看键盘的手段。Apple 的技术文件 TN2150
// 明确列出它封锁的三种拦截技术:CGEventTap 事件拦截、键盘事件的 HID 层读取,以及旧式输入法层拦截。
// Carbon 热键「不在」这三种之内,因为热键不是去读键盘,而是由 WindowServer 主动派送给登记者,
// 理论上应该照常运作。
//
// 但是:实务上有可信的回报指出,浏览器密码栏位持有安全输入时,某些程式的全域热键会跟着失效。
// 这些回报彼此矛盾(有人说全部失效、有人说只有含特定修饰键的失效、也有人完全遇不到),
// 我们也没有在本机复现过。因此这一条标示为「部分验证(PARTIALLY VERIFIED),证据互相矛盾」:
// 不要假设热键在安全输入期间一定有效,也不要假设一定无效。我们能做的只有诚实告知 ——
// 所以本档提供 isSecureInputActive() 与 secureInputCulprit(),让上层在使用者反映「热键没反应」时
// 查出当下是谁开着安全输入并显示出来,而不是留一个查不出原因的哑巴 bug。

// MARK: - 组合键

/// 一组全域快速键的设定:一个虚拟键码,加上一个 Carbon 修饰键遮罩。
///
/// 刻意存 Carbon 的原始数值而不是 AppKit 的 NSEvent.ModifierFlags,因为最终要交给 RegisterEventHotKey 的
/// 就是这两个数字,存成别的形式只会多一层转换、多一个出错点。可 Codable 是为了让使用者自订的组合键能直接写进设定档。
public struct HotKeyCombo: Sendable, Equatable, Codable {

    /// Carbon 虚拟键码,代表「键盘上的哪一个实体位置」而不是键帽上印的字母。
    /// 换成非 QWERTY 配置时同一个键码会打出不同的字,这正是我们要的:使用者按的永远是同一个位置。
    public let keyCode: UInt32

    /// Carbon 修饰键遮罩,由下面几个 mask 常数以位元或(|)组合而成。
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    // 把 Carbon 的 cmdKey / controlKey / optionKey / shiftKey 包一层,好让设定介面与测试不必为了拼一个遮罩就去 import Carbon。
    public static let commandMask = UInt32(cmdKey)
    public static let controlMask = UInt32(controlKey)
    public static let optionMask = UInt32(optionKey)
    public static let shiftMask = UInt32(shiftKey)

    /// V 键的虚拟键码,也就是标头档里的 kVK_ANSI_V(值为 9);写成具名常数是让日後读到的人知道这个 9 是从哪里来的。
    public static let keyCodeV = UInt32(kVK_ANSI_V)

    /// 预设组合键:Command + Shift + V。
    ///
    /// 选它的理由是使用者对「贴上 = V」已有肌肉记忆,而且这是同类工具的业界惯例。部分程式的选单里也有
    /// Command + Shift + V,但那是程式内的选单快速键,全域登记会赢;万一真被别的程式先抢走,
    /// register 会抛出错误,由上层引导使用者改设定,不会安静失败。
    public static let defaultCombo = HotKeyCombo(keyCode: keyCodeV, modifiers: commandMask | shiftMask)

    /// E 键的虚拟键码,也就是标头档里的 kVK_ANSI_E(值为 14);写成具名常数是让日後读到的人知道这个 14 是从哪里来的。
    public static let keyCodeE = UInt32(kVK_ANSI_E)

    /// 偷看模式的组合键:Command + E。
    ///
    /// 跟 defaultCombo(⌘⇧V,打开常驻面板)是两套独立的手势:按住 ⌘E 面板一直开着、用上下键挑,
    /// 放开 ⌘ 就把停在的那一则放上剪贴板(不贴、也不留面板),之後由使用者自己按 Command+V。
    /// 只带 ⌘ 一个修饰键是刻意的:这个手势靠「放开修饰键」当确认,而它的修饰键就是 ⌘ 自己。
    public static let peekCombo = HotKeyCombo(keyCode: keyCodeE, modifiers: commandMask)

    /// 给介面显示用的字串,例如预设组合键会算出「⌘⇧V」。
    ///
    /// 修饰键顺序刻意採用 ⌘ ⌃ ⌥ ⇧,让 Command 排最前面。这跟 Apple 选单列惯用的 ⌃⌥⇧⌘ 不同,是有意的取舍:
    /// 在我们的设定画面里,使用者第一眼要确认的是「这组键有没有含 Command」,放最前面最好扫读。
    /// 全专案只有这一处会产生快速键字串,所以不会出现两种顺序并存的情况。
    public var displayString: String {
        var out = ""
        if modifiers & Self.commandMask != 0 { out += "⌘" }
        if modifiers & Self.controlMask != 0 { out += "⌃" }
        if modifiers & Self.optionMask != 0 { out += "⌥" }
        if modifiers & Self.shiftMask != 0 { out += "⇧" }
        return out + Self.keyName(for: keyCode)
    }

    /// 把虚拟键码翻成键帽上看得到的样子。查不到的键码会退回「键码 123」这种诚实的写法,
    /// 而不是硬猜一个字母 —— 显示错的键名比显示一个数字更糟,使用者会照着按然後发现按不出来。
    static func keyName(for code: UInt32) -> String {
        keyNames[code] ?? "键码 \(code)"
    }

    /// 特殊键用 macOS 键帽上真正印着的符号(跨语系都看得懂,不需要翻译),英数键用字面。数值一律取自 Carbon 的
    /// kVK_* 常数而不自己写死数字,避免抄错;英数键的键码并不连续、没有公式可推,所以只能逐一对照。
    private static let keyNames: [UInt32: String] = {
        let pairs: [(Int, String)] = [
            (kVK_Return, "↩"), (kVK_Tab, "⇥"), (kVK_Space, "␣"), (kVK_Delete, "⌫"), (kVK_Escape, "⎋"),
            (kVK_LeftArrow, "←"), (kVK_RightArrow, "→"), (kVK_DownArrow, "↓"), (kVK_UpArrow, "↑"),
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"), (kVK_ANSI_E, "E"),
            (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"), (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"),
            (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"), (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"),
            (kVK_ANSI_P, "P"), (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
            (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"), (kVK_ANSI_Y, "Y"),
            (kVK_ANSI_Z, "Z"), (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
            (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"), (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
        ]
        return Dictionary(uniqueKeysWithValues: pairs.map { (UInt32($0.0), $0.1) })
    }()

    /// 转成 AppKit 的修饰键旗标,给「修饰键是否已全部放开」的判断使用。
    var appKitModifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & Self.commandMask != 0 { flags.insert(.command) }
        if modifiers & Self.controlMask != 0 { flags.insert(.control) }
        if modifiers & Self.optionMask != 0 { flags.insert(.option) }
        if modifiers & Self.shiftMask != 0 { flags.insert(.shift) }
        return flags
    }
}

// MARK: - 错误

public enum HotKeyError: Error, CustomStringConvertible {
    /// 不在主执行绪上登记。Carbon 会把处理常式挂上主 RunLoop,别条执行绪登记的热键不会被派送。
    case notOnMainThread
    /// InstallEventHandler 或 RegisterEventHotKey 失败,附上系统回传的状态码。
    case eventHandlerInstallFailed(OSStatus)
    case registrationFailed(OSStatus)

    public var description: String {
        switch self {
        case .notOnMainThread:
            return "全域快速键必须在主执行绪上登记,因为 Carbon 会把事件派送到主 RunLoop。"
        case .eventHandlerInstallFailed(let status):
            return "安装 Carbon 事件处理常式失败,系统状态码是 \(status)。"
        case .registrationFailed(let status):
            // -9878 是 Carbon 的 eventHotKeyExistsErr,意思是这组按键已经被别的程式抢走了。
            if status == -9878 {
                return "这组快速键已经被另一个程式登记走了,请改选别组按键。系统状态码是 \(status)。"
            }
            return "登记全域快速键失败,系统状态码是 \(status)。"
        }
    }
}

// MARK: - 热键

/// 全域快速键的登记器。一个实例同时只持有一组热键,重新登记会先把旧的拆掉。
///
/// 执行绪纪律:所有公开方法都必须在主执行绪上呼叫,理由写在 HotKeyError.notOnMainThread。内部状态因此不需要锁 ——
/// 唯一从外面进来的路径是 Carbon 的事件处理常式,而那个常式本来就是在主 RunLoop 上被呼叫的。
public final class HotKey {

    /// 标记「这个热键是 clipd 登记的」的四字元签章,值是 'clpd' 的 ASCII 码。事件处理常式挂在整个程式的事件目标上,
    /// 别的元件登记的热键也会经过我们,靠这个签章加上编号才能只处理自己那一组。
    fileprivate static let signature: OSType = 0x636C_7064

    /// 下一个要发出去的热键编号。只在主执行绪上被读写,所以不需要保护。
    private static var nextHotKeyID: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    fileprivate var currentHotKeyID: UInt32 = 0

    private var onPress: (() -> Void)?
    private var onModifiersReleased: (() -> Void)?

    /// 目前登记中的组合键,给介面显示用;没登记时是 nil。
    public private(set) var registeredCombo: HotKeyCombo?

    /// 只在「按住修饰键」期间才存在的两个观察手段,平常都是 nil。
    private var flagsMonitor: Any?
    private var flagsPollTimer: Timer?

    public init() {}

    deinit {
        // 这里直接拆,不检查执行绪。正常情况下本物件由主执行绪上的应用层持有并释放;万一真的在别条执行绪上释放,最差的结果是留下一组已登记的热键,不会崩溃。
        teardown()
    }

    /// 目前是否已经登记成功。
    public var isRegistered: Bool { hotKeyRef != nil }

    // MARK: 登记与解除

    /// 登记一组全域快速键。重复呼叫是安全的:会先解除上一组,再登记新的。
    ///
    /// - Parameters:
    ///   - combo: 要抢下来的按键组合。
    ///   - onPress: 每按一次就呼叫一次(按住不放时系统也会重复派送)。
    ///   - onModifiersReleased: 组合键里的修饰键「全部」放开时呼叫一次;传 nil 代表不需要这个通知。
    public func register(
        _ combo: HotKeyCombo,
        onPress: @escaping () -> Void,
        onModifiersReleased: (() -> Void)? = nil
    ) throws {
        guard Thread.isMainThread else { throw HotKeyError.notOnMainThread }

        // 先拆旧的。不先拆的话旧的 EventHotKeyRef 会永远漏在系统里,而且旧的回呼还会继续被触发。
        teardown()
        self.onPress = onPress
        self.onModifiersReleased = onModifiersReleased

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var newHandler: EventHandlerRef?
        // userData 传的是不增加保留计数的 self 指标。这样安全,因为处理常式的生命週期完全由本物件掌控:
        // teardown() 一定会先移除处理常式,之後才轮得到 self 被释放。
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(), clipdHotKeyEventHandler, 1, &spec,
            Unmanaged.passUnretained(self).toOpaque(), &newHandler
        )
        guard installStatus == noErr else {
            resetCallbacks()
            throw HotKeyError.eventHandlerInstallFailed(installStatus)
        }
        handlerRef = newHandler

        let id = Self.nextHotKeyID
        Self.nextHotKeyID += 1
        var newHotKey: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            combo.keyCode, combo.modifiers, EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &newHotKey
        )
        guard registerStatus == noErr, let newHotKey else {
            // 登记失败一定要把刚装好的处理常式拆掉,否则会留下一个永远收不到事件的处理常式。
            teardown()
            throw HotKeyError.registrationFailed(registerStatus)
        }

        hotKeyRef = newHotKey
        currentHotKeyID = id
        registeredCombo = combo
    }

    /// 解除登记。没登记过也可以呼叫,不会有事。
    public func unregister() {
        teardown()
    }

    private func teardown() {
        stopWatchingModifiers()
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        currentHotKeyID = 0
        registeredCombo = nil
        resetCallbacks()
    }

    private func resetCallbacks() {
        onPress = nil
        onModifiersReleased = nil
    }

    // MARK: 按下与「修饰键放开」

    /// 由 Carbon 事件处理常式呼叫,永远在主执行绪上。
    fileprivate func handleHotKeyPressed() {
        onPress?()
        // 只有上层要求时才开始盯修饰键。这是「循环模式」的骨架:
        // 按住修饰键不放、连点主键往下选,放开修饰键就等於确认送出。
        if onModifiersReleased != nil { startWatchingModifiersIfNeeded() }
    }

    /// 开始盯修饰键,直到组合键里的修饰键全部放开为止。
    ///
    /// 这里同时用两个手段,而且两个都只在「按住期间」存在、一放开就立刻拆掉:
    ///   1. NSEvent 的全域 .flagsChanged 监看器 —— 反应即时,但如同本档开头所述它需要辅助使用权限,没授权时会安静地永远不触发,不能单独依赖。
    ///   2. 每 40 毫秒读一次 NSEvent.modifierFlags 的计时器 —— 那是一个静态属性,读它不需要任何权限,因此在没有授权的机器上由它兜底。
    ///
    /// 两者刻意都是「按住才装、放开就拆」。这不只是省电,更是可稽核性:一个剪贴板工具若长期挂着
    /// 键盘事件监看器,使用者就算翻原始码也会疑心,不如让它在绝大多数时间里根本不存在。
    private func startWatchingModifiersIfNeeded() {
        // 连点主键时会重复进来,已经在盯了就不要装第二套。
        guard flagsMonitor == nil, flagsPollTimer == nil else { return }

        // 极短促的一次点按,有可能在我们装好监看器之前修饰键就已经放开了。
        // 不先检查这一次的话,循环模式会卡在「等一个永远不会再来的放开事件」。
        if modifiersAreAllReleased() {
            fireModifiersReleased()
            return
        }

        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] _ in
            guard let self, self.modifiersAreAllReleased() else { return }
            self.fireModifiersReleased()
        }

        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            guard let self, self.modifiersAreAllReleased() else { return }
            self.fireModifiersReleased()
        }
        // 指定 .common 模式,否则使用者正在拖曳选单或视窗时计时器会停摆,
        // 而那正是循环模式最可能被使用的时机。
        RunLoop.main.add(timer, forMode: .common)
        flagsPollTimer = timer
    }

    /// 组合键要求的修饰键是否已经一个都不剩。只看「组合键要求的那几个」,
    /// 使用者额外按着别的修饰键不影响判断。
    private func modifiersAreAllReleased() -> Bool {
        guard let combo = registeredCombo else { return true }
        let required = combo.appKitModifierFlags
        guard !required.isEmpty else { return true }
        return NSEvent.modifierFlags.intersection(required).isEmpty
    }

    private func fireModifiersReleased() {
        // 先拆再回呼,顺序不能反:回呼里很可能会去关面板、甚至重新登记热键,
        // 若那时监看器还活着,就会在同一轮里被重复触发。
        stopWatchingModifiers()
        onModifiersReleased?()
    }

    private func stopWatchingModifiers() {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
        flagsPollTimer?.invalidate()
        flagsPollTimer = nil
    }
}

// MARK: - Carbon 事件处理常式

/// Carbon 只吃纯 C 函式指标,所以这个处理常式不能是方法、也不能捕捉任何变数,
/// 只能从 userData 把 HotKey 实例还原回来。
private func clipdHotKeyEventHandler(
    _ callRef: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    // -9874 就是 Carbon 的 eventNotHandledErr。写成字面常数而不是引用符号,是为了不去赌该符号在各版本 SDK 的 Swift 介面里有没有被汇出。
    let notHandled: OSStatus = -9874
    guard let event, let userData else { return notHandled }

    var received = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &received
    )
    guard status == noErr else { return status }

    let owner = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
    // 处理常式挂在整个程式的事件目标上,别人登记的热键也会经过这里,所以必须逐一比对。
    guard received.signature == HotKey.signature, received.id == owner.currentHotKeyID else {
        return notHandled
    }
    owner.handleHotKeyPressed()
    return noErr
}

// MARK: - 安全输入模式的查询

/// 现在有没有任何程式开着安全输入模式。
///
/// 用途是诊断,不是控制流程:如本档开头所述,Carbon 热键在安全输入期间「应该」仍然有效,
/// 但证据互相矛盾。请不要拿这个结果去停用功能,只拿它对使用者解释「可能是这个原因」。
public func isSecureInputActive() -> Bool {
    IsSecureEventInputEnabled()
}

/// 尽力查出是哪一个程式开着安全输入模式,回传给使用者看的名字。
///
/// 作法是从 IORegistry 根节点读 IOConsoleUsers 属性,里面的 kCGSSessionSecureInputPID
/// 就是系统认定的持有者行程编号,再用它换成程式名称。
///
/// 重要的但书:当安全输入是由背景程式(没有介面的服务、或某些输入法元件)开启时,系统回报的这个 PID 是错的 ——
/// 有可能指向当下的前景程式,也可能是 0。换句话说这个函式给的是线索,不是事实:呼叫端必须能接受 nil,
/// 也不该把回传的名字当成指控,介面上的措辞要留有馀地。
public func secureInputCulprit() -> String? {
    guard isSecureInputActive() else { return nil }

    let root = IORegistryGetRootEntry(kIOMainPortDefault)
    guard root != 0 else { return nil }
    defer { IOObjectRelease(root) }

    guard let sessions = IORegistryEntryCreateCFProperty(
        root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0
    )?.takeRetainedValue() as? [[String: Any]] else {
        return nil
    }

    for session in sessions {
        guard let pid = (session["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value,
              pid != 0 else { continue }
        if let app = NSRunningApplication(processIdentifier: pid) {
            return app.localizedName ?? app.bundleIdentifier ?? "行程 \(pid)"
        }
        // 查不到 NSRunningApplication 代表它不是一般的 GUI 程式,只能给出行程编号。
        return "行程 \(pid)"
    }
    return nil
}

// 与上面两个自由函式完全等价的转呼叫,包含所有但书;存在的理由只是让呼叫端也能写成
// HotKey.isSecureInputActive(),不必记住它是一个模组层级的函式。
extension HotKey {
    public static func isSecureInputActive() -> Bool { ClipdCore.isSecureInputActive() }
    public static func secureInputCulprit() -> String? { ClipdCore.secureInputCulprit() }
}
