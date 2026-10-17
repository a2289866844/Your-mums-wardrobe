import Foundation

/// 剪贴板堆叠:使用者先在面板里把好几则内容依序标记起来,之後每按一次贴上就依序送出一则。
///
/// 这个型别刻意只保管「顺序」与「贴到第几则了」两件事,不碰资料库、不碰剪贴板、不碰画面。
/// 这样做的理由是:堆叠的行为必须能被使用者预测,而能被预测的前提是它的规则少到可以写在一页纸上,
/// 而且每一条规则都能用单元测试钉死。真正去 Store 捞内容、把内容写回剪贴板,是呼叫端的责任。
///
/// 执行绪:这个类别没有加锁,预期只在主执行绪(面板与热键的世界)上被使用。
/// 如果日後真的需要跨执行绪共用,请在外层包一层 actor,不要在这里偷偷加锁,
/// 因为半套的锁会让「顺序」这件事在竞态下变得不可预测,那正好毁掉这个型别唯一的价值。
public final class ClipboardStack {

    // MARK: - 状态

    /// 堆叠里的项目识别码,顺序就是使用者「加入」的先後顺序。
    ///
    /// 重要:这里排的是加入顺序,不是复制时间的顺序,也不是面板上的显示顺序。
    /// 使用者可能先加一则昨天复制的地址、再加一则刚刚复制的电话,
    /// 那麽贴出来就是先地址、後电话。之所以选加入顺序,是因为这是使用者当下亲手决定的顺序,
    /// 他闭着眼睛也知道自己按了什麽;若改用复制时间排,画面上看起来一样,贴出来的却会颠倒,
    /// 那种「明明照着做却不是我要的结果」是最伤信任的一种错。
    public private(set) var itemIDs: [String] = []

    /// 已经贴出去几则。它同时也是「下一则要贴的那一项」在 `itemIDs` 里的索引。
    /// 用「贴出去的数量」而不是「贴到哪一个 id」来记录,是为了让删除与重排的行为好推理。
    private var cursor: Int = 0

    public init() {}

    // MARK: - 查询

    /// 只要堆叠里还有内容就算「已经上膛」,呼叫端可以据此决定贴上要走堆叠还是走一般的最近一则。
    /// 注意:全部贴完之後项目仍然留着,所以这时候它还是 true,直到 `discard()` 被呼叫为止。
    public var isArmed: Bool { !itemIDs.isEmpty }

    /// 堆叠里总共有几则内容。
    public var count: Int { itemIDs.count }

    /// 下一次 `advance()` 会送出的那一则在 `itemIDs` 里的索引,也等於已经贴出去的则数。
    /// 全部贴完时它会等於 `count`,这是一个合法的值,代表游标停在最後面。
    public var nextIndex: Int { cursor }

    /// 这一则是否已经在堆叠里。面板用它来决定要画上编号徽章还是空的方框。
    public func contains(_ id: String) -> Bool {
        itemIDs.contains(id)
    }

    /// 这一则排在第几位,从 1 开始数,不在堆叠里就回传 nil。
    ///
    /// 之所以回传 1 起算而不是 0 起算,是因为这个数字会直接印在面板的徽章上给人看,
    /// 人是从 1 开始数东西的。让转换只发生在这一个地方,呼叫端就不会各自加一而漏掉。
    public func position(of id: String) -> Int? {
        guard let index = itemIDs.firstIndex(of: id) else { return nil }
        return index + 1
    }

    // MARK: - 编辑

    /// 把一则加到堆叠最後面。已经在堆叠里的话什麽都不做,并回传 false。
    ///
    /// 重复的项目一律拒绝,而不是再加一份。理由是:同一则内容被贴两次几乎都是误按,
    /// 而且一旦允许重复,「第几则」这个编号就会一个 id 对到两个位置,面板的徽章跟删除都会立刻变得含糊。
    /// 想连贴两次同样的内容,使用者直接按两次一般的贴上就好,不需要堆叠帮忙。
    @discardableResult
    public func add(_ id: String) -> Bool {
        guard !itemIDs.contains(id) else { return false }
        itemIDs.append(id)
        return true
    }

    /// 把一则从堆叠里拿掉。不在堆叠里就当作没这回事,安静返回。
    ///
    /// 这里不把「找不到」当成错误,是因为使用者按删除的当下,那一则很可能刚被别的路径移除了,
    /// 为这种情形丢错误只会逼呼叫端到处写 try?,却换不到任何有用的资讯。
    public func remove(_ id: String) {
        guard let index = itemIDs.firstIndex(of: id) else { return }
        itemIDs.remove(at: index)

        // 被拿掉的那一则如果排在游标前面(也就是已经贴出去了),游标要跟着往前一格,
        // 否则「还没贴的下一则」会整个错开一位,使用者会看到莫名其妙被跳过的内容。
        if index < cursor {
            cursor -= 1
        }
        // 收尾的防守:不论上面怎麽算,游标都不该跑到阵列外面去。
        cursor = min(cursor, itemIDs.count)
    }

    /// 把一则往前挪一格。已经在最前面或不在堆叠里就什麽都不做。
    public func moveUp(_ id: String) {
        guard let index = itemIDs.firstIndex(of: id), index > 0 else { return }
        itemIDs.swapAt(index, index - 1)
    }

    /// 把一则往後挪一格。已经在最後面或不在堆叠里就什麽都不做。
    public func moveDown(_ id: String) {
        guard let index = itemIDs.firstIndex(of: id), index < itemIDs.count - 1 else { return }
        itemIDs.swapAt(index, index + 1)
    }

    // MARK: - 贴出

    /// 取出下一则要贴的识别码,并把游标往前推一格。全部贴完之後回传 nil。
    ///
    /// 这里刻意不回卷到第一则。回卷表面上很贴心,实际上会在使用者毫无察觉的情况下把第一则再贴一次,
    /// 而贴上这个动作通常发生在别的程式的输入框里,错了要收拾的是使用者不是我们。
    /// 「什麽都不发生」虽然看起来笨,但它至少是安静而且明显的失败,使用者一眼就知道该重新上膛。
    public func advance() -> String? {
        guard cursor < itemIDs.count else { return nil }
        let id = itemIDs[cursor]
        cursor += 1
        return id
    }

    /// 把游标退回最前面,内容原封不动留着,让同一组内容可以再贴一轮。
    public func reset() {
        cursor = 0
    }

    /// 整个堆叠丢掉:内容与游标都清空。
    public func discard() {
        itemIDs.removeAll()
        cursor = 0
    }

    // MARK: - 给人看的状态描述

    /// 一句完整的中文句子,描述堆叠现在的状态,直接显示在面板底部。
    ///
    /// 写成完整句子而不是「3 / 5」这种缩写,是因为堆叠是一个有状态的功能:
    /// 使用者按下贴上之前,必须知道接下来会送出哪一则。一个孤零零的数字没办法回答那个问题,
    /// 一句话可以。
    public var statusSentence: String {
        if itemIDs.isEmpty {
            return "堆叠目前是空的,在面板里按右方向键可以把一则加进来。"
        }
        if cursor >= itemIDs.count {
            return "堆叠已经全部贴完了,按 Esc 可以清掉它。"
        }
        let total = Self.countingNumeral(itemIDs.count)
        let next = Self.ordinalNumeral(cursor + 1)
        return "堆叠里有\(total)则内容,下一次贴上会送出第\(next)则。"
    }

    // MARK: - 中文数字

    private static let digits = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九"]

    /// 用来数东西的数字。二在这个位置中文要说「两则」而不是「二则」,只有这一个数字要特别处理;
    /// 二十二则、十二则都还是念本来的音,所以只在个位数刚好是 2 的时候换字。
    private static func countingNumeral(_ n: Int) -> String {
        n == 2 ? "两" : numeral(n)
    }

    /// 用来排序的数字,例如「第二则」。这里的二不能换成两。
    private static func ordinalNumeral(_ n: Int) -> String {
        numeral(n)
    }

    /// 把整数写成中文数字。只处理 0 到 99,超过就直接用阿拉伯数字。
    /// 堆叠大到三位数早就超过人能记住的量,那时候诚实地印数字反而比硬念中文清楚。
    private static func numeral(_ n: Int) -> String {
        guard n >= 0 else { return String(n) }   // 负数在这个型别里不可能发生,真的发生就照实印出来,不要假装看得懂。
        switch n {
        case 0...9:
            return digits[n]
        case 10...19:
            return n == 10 ? "十" : "十" + digits[n % 10]
        case 20...99:
            let tens = digits[n / 10] + "十"
            return n % 10 == 0 ? tens : tens + digits[n % 10]
        default:
            return String(n)
        }
    }
}
