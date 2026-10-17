import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// 贴回去的时候要保留多少东西。
public enum PasteStyle: Sendable {
    /// 把当初抓下来、而且现在还重建得出来的每一种表示法通通放回剪贴板,
    /// 让接收端自己去挑它最想要的那一种(例如 Pages 会挑富文字、终端机会挑纯文字)。
    case original
    /// 只放纯文字。使用者要的是「把格式洗掉」,所以富文字与 HTML 一律不写。
    case plainText
}

/// 一次贴上动作的结果。`message` 是一句完整的中文句子,UI 可以原封不动直接显示给使用者看,
/// 不需要再自己拼字串,也因此不会出现「UI 说成功、实际上什麽都没发生」的落差。
public struct PasteOutcome: Sendable {
    /// 内容是不是已经在剪贴板上了。就算按键送不出去,只要这个是 true,使用者自己按 Command+V 仍然贴得到。
    public let wroteToPasteboard: Bool
    /// 我们是不是真的送出了那一次合成的 Command+V。
    public let postedKeystroke: Bool
    /// 要显示给使用者看的完整句子。
    public let message: String

    public init(wroteToPasteboard: Bool, postedKeystroke: Bool, message: String) {
        self.wroteToPasteboard = wroteToPasteboard
        self.postedKeystroke = postedKeystroke
        self.message = message
    }
}

/// 贴回引擎:把一则纪录放上剪贴板,然後把它送进「我们的面板跳出来之前」那个最前景的程式里。
///
/// 这个类别刻意只做两件事,而且分成两个方法:写剪贴板与送按键。
/// 分开的理由是这两件事的失败方式完全不同 —— 写剪贴板几乎不会失败,
/// 送按键则会因为权限或安全输入而被系统整个吃掉,而使用者必须知道是哪一种。
///
/// 使用限制:请只在主执行绪上呼叫。送按键与关面板都是 AppKit 的事,而且顺序有强烈的先後关係。
public final class Paster {

    /// 送出 Command+V 之前要等多久。
    ///
    /// 这个值必须可以调,因为「面板关掉之後,焦点要多久才真的回到前一个程式」每个程式都不一样:
    /// 原生的 Cocoa 程式通常一两个更新周期就还原了,Electron 与远端桌面类的程式则明显更慢。
    /// 等太短会贴不进去(按键落在还没交出焦点的旧视窗上),等太长使用者会觉得卡顿。
    /// 没有一个数字对所有程式都对 —— Alfred 之所以也在偏好设定里放同一颗旋钮,就是这个原因。
    public var delayBeforeKeystroke: TimeInterval

    /// 实际要写进去的那一块剪贴板。正式执行时是 `NSPasteboard.general`。
    private let board: NSPasteboard

    public convenience init(delayBeforeKeystroke: TimeInterval = 0.04) {
        self.init(pasteboard: .general, delayBeforeKeystroke: delayBeforeKeystroke)
    }

    /// 测试专用的建构子:让测试传一块自己命名的剪贴板进来。
    /// 测试绝对不可以去写 `NSPasteboard.general`,那是使用者当下真正在用的剪贴板,
    /// 跑一次测试就把人家剪好的东西洗掉,是这个专案里最不能犯的错。
    init(pasteboard: NSPasteboard, delayBeforeKeystroke: TimeInterval = 0.04) {
        self.board = pasteboard
        self.delayBeforeKeystroke = delayBeforeKeystroke
    }

    // MARK: 写剪贴板

    /// 把一则纪录写上剪贴板,回传写完之後的 `changeCount`。
    ///
    /// 呼叫端必须把回传值指派给 `PasteboardWatcher.selfWriteChangeCount`。
    /// 少了这一步,轮询在下一个周期就会看到剪贴板变了,然後把我们自己刚刚贴上去的东西
    /// 当成一则新内容再抓一次 —— 使用者每贴一次历史就多一笔重复,用不到一天列表就废了。
    ///
    /// - Parameter blobLoader: 拿相对路径(`ItemRepresentation.blobPath`)换回原始位元组。
    ///   图片是存在磁碟上的外部档案,不在 `ClipItem` 里面,所以一定要由外面提供读取方式。
    ///   读不到就回 `nil`,这个方法会诚实地跳过那一种表示法,不会拿空资料充数。
    @discardableResult
    public func write(_ item: ClipItem, style: PasteStyle, blobLoader: (String) -> Data?) -> Int {
        // 刻意先把要写的内容整个组好,最後一步才清空剪贴板。
        // 反过来做的话,遇到一则完全重建不出内容的纪录,使用者原本剪贴板上的东西就被白白洗掉了。
        let payload = makePasteboardItem(item, style: style, blobLoader: blobLoader)

        guard let payload else {
            // 一个位元组都拼不出来。这时候什麽都不做才是对的:
            // 宁可让使用者发现「按了没反应」,也不要把 preview 那种被截断的一行摘要
            // 当成真正的内容贴出去 —— 那会变成一份看起来像真的、其实是残缺的资料。
            return board.changeCount
        }

        board.clearContents()
        // writeObjects 会把同一个 NSPasteboardItem 上挂着的所有型别一次写成「同一则内容的多种表示法」,
        // 而不是好几则各自独立的内容。这一点对接收端的挑选逻辑是关键的。
        _ = board.writeObjects([payload])
        return board.changeCount
    }

    /// 组出要写上去的那一个剪贴板项目。完全组不出东西时回 `nil`。
    private func makePasteboardItem(
        _ item: ClipItem,
        style: PasteStyle,
        blobLoader: (String) -> Data?
    ) -> NSPasteboardItem? {
        let entry = NSPasteboardItem()

        switch style {
        case .plainText:
            // 只写 public.utf8-plain-text 这一种。`NSPasteboard.PasteboardType.string` 其实就是同一个识别码,
            // 这里刻意把它写成显式的 UTI,是为了让「只写这一种」这件事在程式码上一眼可见。
            guard let text = bestPlainText(of: item), !text.isEmpty else { return nil }
            guard entry.setData(Data(text.utf8), forType: Self.plainTextType) else { return nil }
            return entry

        case .original:
            var wroteAny = false
            var used = Set<String>()
            for rep in orderedRepresentations(of: item) {
                guard !used.contains(rep.uti) else { continue }   // 同一个型别只能设一次,重複设会失败。
                guard let data = bytes(of: rep, blobLoader: blobLoader) else { continue }
                if entry.setData(data, forType: NSPasteboard.PasteboardType(rep.uti)) {
                    used.insert(rep.uti)
                    wroteAny = true
                }
            }
            if wroteAny { return entry }

            // 每一种表示法都重建不出来(例如整则只剩下别家程式的私有二进位型别,当初没有留下位元组)。
            // 退一步用纯文字再试一次,至少让使用者贴得到字,而不是完全落空。
            return makePasteboardItem(item, style: .plainText, blobLoader: blobLoader)
        }
    }

    /// 决定各种表示法写上剪贴板的先後顺序。
    ///
    /// 顺序不是美观问题:接收端(例如 TextEdit、Pages、浏览器)是照剪贴板上的型别顺序
    /// 由前往後挑第一个自己认得的,所以资讯量最多的要排前面。
    /// 纯文字一定排最後,否则富文字程式会挑到纯文字,使用者贴过去就发现格式全没了。
    private func orderedRepresentations(of item: ClipItem) -> [ItemRepresentation] {
        item.representations.enumerated()
            .sorted { a, b in
                let ra = Self.rank(of: a.element.uti)
                let rb = Self.rank(of: b.element.uti)
                // 同一层级的维持原本的相对顺序,让结果是稳定、可预期、可以写测试的。
                return ra == rb ? a.offset < b.offset : ra < rb
            }
            .map(\.element)
    }

    /// 数字越小越优先。
    private static func rank(of uti: String) -> Int {
        if uti == UTType.png.identifier || uti == UTType.tiff.identifier { return 0 }
        if uti == plainTextUTI || uti == UTType.plainText.identifier || uti == UTType.utf8TabSeparatedText.identifier {
            return 2
        }
        return 1
    }

    /// 把一种表示法还原成真正的位元组。还原不出来就回 `nil`,绝对不回空的 `Data`。
    /// 回空资料会让上面误以为写成功,使用者按下贴上却得到空白,而且完全查不出是哪一步出的错。
    private func bytes(of rep: ItemRepresentation, blobLoader: (String) -> Data?) -> Data? {
        if let path = rep.blobPath {
            // 图片这类大内容存在磁碟上的外部档案里,只有呼叫端知道资料夹在哪。
            guard let blob = blobLoader(path), !blob.isEmpty else { return nil }
            return blob
        }
        if let text = rep.inlineText {
            return Data(text.utf8)
        }
        // 既没有外部档案也没有内嵌文字,代表当初只记下了位元组数。
        // 这是抓取阶段对认不出来的私有型别刻意做的取舍,不是这里的错误,所以安静跳过就好。
        return nil
    }

    /// 挑出这一则最适合当「纯文字」的内容。
    private func bestPlainText(of item: ClipItem) -> String? {
        // 第一顺位:当初就是以 public.utf8-plain-text 抓下来的那一份,最忠於原样。
        if let exact = item.representations.first(where: { $0.uti == Self.plainTextUTI })?.inlineText {
            return exact
        }
        // 第二顺位:任何一种在型别系统上算得上文字的表示法(含 public.file-url 这种)。
        for rep in item.representations {
            guard let text = rep.inlineText, !text.isEmpty else { continue }
            guard let type = UTType(rep.uti) else { continue }
            if type.conforms(to: .text) || type == .url || type == .fileURL { return text }
        }
        // 最後的退路只用 searchText,而且只在这一则本来就是文字或网址时才用。
        // 这里绝对不用 preview:preview 是为了在面板上显示一行而做过截断的摘要,
        // 把它当成内容贴出去,使用者拿到的会是一份被砍掉一半、看起来却很正常的资料。
        if item.kind == .text || item.kind == .link {
            let fallback = item.searchText
            return fallback.isEmpty ? nil : fallback
        }
        return nil
    }

    // MARK: 送按键

    /// 把 Command+V 送进「面板跳出来之前」那个最前景的程式。
    ///
    /// 顺序是这整个功能的关键,而且顺序错了不会报错,只会安静地贴错地方,所以在这里写清楚:
    ///
    ///   1. 先把面板关掉(或至少让它交出 key window 的身分)。
    ///   2. 同步地把内容写上剪贴板 —— 也就是先呼叫 `write(_:style:blobLoader:)`,不要放到非同步里。
    ///   3. 等 `delayBeforeKeystroke` 这麽久,让系统真的把焦点交还给前一个程式。
    ///   4. 才送出合成的 Command+V。
    ///
    /// 第 1 步一定要在第 4 步之前完成。面板还是 key window 的时候送 Command+V,
    /// 那一下会直接贴进我们自己的搜寻框里 —— 使用者看到的是搜寻框突然多出一堆字、
    /// 而目标程式什麽都没有,却完全不知道发生了什麽事。
    ///
    /// 这个方法假设第 2 步已经做完了,所以在无法送按键时仍然回报 `wroteToPasteboard: true`:
    /// 内容确实已经在剪贴板上,使用者自己按 Command+V 一定贴得到。
    ///
    /// - Parameter completion: 一定会在主佇列上被呼叫一次,成功失败都会。
    public func pasteIntoPreviousApp(completion: @escaping (PasteOutcome) -> Void) {
        // 安全输入模式:某个密码栏位正在独占键盘。这时候系统会把所有合成事件丢掉,
        // 而且不会给任何错误码 —— 送出去就像掉进黑洞一样。先问清楚,不要白送。
        if IsSecureEventInputEnabled() {
            finish(completion, PasteOutcome(
                wroteToPasteboard: true,
                postedKeystroke: false,
                message: "内容已经放上剪贴板了,但是现在有一个密码栏位正在独占键盘输入,系统不允许任何程式代送按键,所以请你自己按一下 Command+V 贴上。"
            ))
            return
        }

        // 没有辅助使用权限时,送出去的事件同样会被系统吃掉。
        // 这里最重要的不是「不要送」,而是「不要送完还回报成功」——
        // 一个工具嘴巴说贴好了、画面上却什麽都没有,使用者第二次就不会再相信它,然後就不用了。
        // 这一类工具被弃用的原因,几乎都是这一个行为,不是效能也不是介面。
        guard canPostKeystrokes() else {
            finish(completion, PasteOutcome(
                wroteToPasteboard: true,
                postedKeystroke: false,
                message: "内容已经放上剪贴板了,但是系统还没有授权 clipd 代送按键,所以请你自己按一下 Command+V 贴上。你可以到「系统设定 → 隐私权与安全性 → 辅助使用」里把 clipd 打开,之後就会自动帮你贴上。"
            ))
            return
        }

        let delay = max(0, delayBeforeKeystroke)
        // 这里刻意强参考 self,不用 weak。上面已经承诺 completion 一定会被呼叫一次,
        // 若在这几十毫秒内 self 刚好被释放就默默不呼叫,呼叫端的面板会永远停在等待状态。
        // 多留住这个物件几十毫秒的代价,远小於一个不会有结果的等待。
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if self.postCommandV() {
                completion(PasteOutcome(
                    wroteToPasteboard: true,
                    postedKeystroke: true,
                    message: "内容已经放上剪贴板,而且已经把 Command+V 送进刚才那个程式了。"
                ))
            } else {
                completion(PasteOutcome(
                    wroteToPasteboard: true,
                    postedKeystroke: false,
                    message: "内容已经放上剪贴板了,但是这一次建立按键事件失败,所以没有帮你贴上,请你自己按一下 Command+V。"
                ))
            }
        }
    }

    /// 真正合成并送出那一组 Command+V。建立事件失败时回 `false`,不会假装成功。
    private func postCommandV() -> Bool {
        // 用 combinedSessionState 而不是 privateState:我们要模拟的是「使用者在这个登入工作阶段里按下了按键」,
        // 所以修饰键的目前状态必须跟整个工作阶段一致,否则接收端看到的按键组合会跟我们想的不一样。
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }

        let vKey = CGKeyCode(kVK_ANSI_V)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return false }

        // 按下与放开两个事件都要带 Command 旗标。
        // 只在按下时带的话,有些程式会在收到「没有带 Command 的 V 放开」时判定组合键已经中断,
        // 结果是贴上有时成功有时失败 —— 这种间歇性的错最难被回报,也最难被相信。
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        // 送到 annotated session tap:事件会走完整个工作阶段的事件链,
        // 前景程式收到它的方式跟收到真人按键完全一样。
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }

    // MARK: 权限

    /// 现在有没有权限代送按键。这只是查询,不会跳出任何系统对话框。
    public func canPostKeystrokes() -> Bool {
        CGPreflightPostEventAccess()
    }

    /// 向系统要求代送按键的权限,会跳出系统的授权对话框。
    ///
    /// 刻意不回传结果:使用者是在系统设定里勾选的,勾完之後这个行程通常还要重开才会生效,
    /// 所以「呼叫当下的回传值」不能拿来当作之後能不能送按键的依据,真正该问的永远是 `canPostKeystrokes()`。
    public func requestKeystrokePermission() {
        _ = CGRequestPostEventAccess()
    }

    // MARK: 小工具

    /// 保证 completion 一律在主佇列上被呼叫,让呼叫端可以放心直接更新 UI。
    private func finish(_ completion: @escaping (PasteOutcome) -> Void, _ outcome: PasteOutcome) {
        if Thread.isMainThread {
            completion(outcome)
        } else {
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    private static let plainTextUTI = UTType.utf8PlainText.identifier
    private static let plainTextType = NSPasteboard.PasteboardType(UTType.utf8PlainText.identifier)
}
