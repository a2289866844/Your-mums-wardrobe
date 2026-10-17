import Foundation
import Testing
import ClipdCore   // 这里刻意不用 @testable:被测的全是公开 API,测试也应该只透过公开 API 验证。

// 这一组测试只涵盖 HotKeyCombo 这个纯资料型别:预设值、显示字串、以及设定档的读写往返。
//
// 刻意「不」测 HotKey.register:登记全域热键需要一个活着的主 RunLoop 与真实的视窗伺服器连线,
// 在 swift test 底下要嘛登记不到、要嘛登记到了却永远收不到事件,写出来的会是一个看心情通过的测试。
// 热键真的按下去有没有反应,只能靠人手在真机上验;把它伪装成自动化测试只会製造虚假的安全感。
//
// 键码的数值全部照抄自 Carbon 的 Events.h,并在註解里写出常数名称。
// 这样做等於把「键码对应」这件事也钉住:哪天有人把对照表改错,这里会立刻变红。

@Suite("全域快速键的组合设定")
struct HotKeyTests {

    // MARK: - 预设组合键

    @Test("预设组合键就是 Command 加 Shift 加 V")
    func defaultComboIsCommandShiftV() {
        let combo = HotKeyCombo.defaultCombo
        #expect(combo.keyCode == 9)                                  // kVK_ANSI_V
        #expect(combo.modifiers == 256 | 512)                        // cmdKey | shiftKey
        #expect(combo.modifiers == HotKeyCombo.commandMask | HotKeyCombo.shiftMask)
    }

    @Test("四个修饰键遮罩的数值必须跟 Carbon 的定义一致")
    func modifierMasksMatchCarbon() {
        #expect(HotKeyCombo.commandMask == 256)     // cmdKey     == 1 << 8
        #expect(HotKeyCombo.shiftMask == 512)       // shiftKey   == 1 << 9
        #expect(HotKeyCombo.optionMask == 2048)     // optionKey  == 1 << 11
        #expect(HotKeyCombo.controlMask == 4096)    // controlKey == 1 << 12
    }

    @Test("V 键的键码常数是 9")
    func keyCodeVIsNine() {
        #expect(HotKeyCombo.keyCodeV == 9)          // kVK_ANSI_V
    }

    // MARK: - 偷看模式的组合键(按住 ⌘E)

    @Test("偷看模式的组合键就是 Command 加 E,而且只带 Command 一个修饰键")
    func peekComboIsCommandE() {
        let combo = HotKeyCombo.peekCombo
        #expect(combo.keyCode == 14)                                 // kVK_ANSI_E
        #expect(combo.modifiers == 256)                              // 只有 cmdKey,不该混进别的修饰键
        #expect(combo.modifiers == HotKeyCombo.commandMask)
    }

    @Test("E 键的键码常数是 14")
    func keyCodeEIs14() {
        #expect(HotKeyCombo.keyCodeE == 14)         // kVK_ANSI_E
    }

    @Test("偷看模式的组合键显示成 ⌘E")
    func peekComboRendersAsCommandE() {
        #expect(HotKeyCombo.peekCombo.displayString == "⌘E")
    }

    @Test("偷看模式与打开常驻面板必须是两组不同的键,不能不小心设成一样")
    func peekComboDiffersFromDefaultCombo() {
        #expect(HotKeyCombo.peekCombo != HotKeyCombo.defaultCombo)
    }

    // MARK: - 显示字串

    @Test("预设组合键显示成 ⌘⇧V")
    func defaultComboRendersWithRealSymbols() {
        #expect(HotKeyCombo.defaultCombo.displayString == "⌘⇧V")
    }

    @Test("只有 Control 加 Option 时显示成 ⌃⌥K,不该冒出没按的修饰键")
    func controlOptionRendersWithoutExtraSymbols() {
        let combo = HotKeyCombo(
            keyCode: 40,                            // kVK_ANSI_K
            modifiers: HotKeyCombo.controlMask | HotKeyCombo.optionMask
        )
        #expect(combo.displayString == "⌃⌥K")
    }

    @Test("四个修饰键全按时,顺序固定是 ⌘⌃⌥⇧")
    func allModifiersRenderInFixedOrder() {
        let all = HotKeyCombo.commandMask | HotKeyCombo.controlMask
            | HotKeyCombo.optionMask | HotKeyCombo.shiftMask
        let combo = HotKeyCombo(keyCode: 49, modifiers: all)   // kVK_Space
        #expect(combo.displayString == "⌘⌃⌥⇧␣")
    }

    @Test("完全没有修饰键时只显示主键本身")
    func noModifiersRendersOnlyTheKey() {
        let combo = HotKeyCombo(keyCode: 36, modifiers: 0)     // kVK_Return
        #expect(combo.displayString == "↩")
    }

    @Test("数字键与特殊键都要显示成键帽上看得到的样子")
    func digitsAndSpecialKeysUseKeycapLabels() {
        #expect(HotKeyCombo(keyCode: 18, modifiers: HotKeyCombo.commandMask).displayString == "⌘1")   // kVK_ANSI_1
        #expect(HotKeyCombo(keyCode: 53, modifiers: 0).displayString == "⎋")                          // kVK_Escape
        #expect(HotKeyCombo(keyCode: 126, modifiers: 0).displayString == "↑")                         // kVK_UpArrow
    }

    @Test("对照表里没有的键码要退回诚实的「键码 N」,不能硬猜一个字母")
    func unknownKeyCodeFallsBackToItsNumber() {
        let combo = HotKeyCombo(keyCode: 200, modifiers: HotKeyCombo.commandMask)
        #expect(combo.displayString == "⌘键码 200")
    }

    // MARK: - 设定档的读写往返

    @Test("编码再解码回来要跟原本一模一样,使用者自订的组合键才不会在重开後走样")
    func codableRoundTripPreservesTheCombo() throws {
        let original = HotKeyCombo(
            keyCode: 40,                            // kVK_ANSI_K
            modifiers: HotKeyCombo.commandMask | HotKeyCombo.optionMask
        )
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(HotKeyCombo.self, from: data)
        #expect(restored == original)
        #expect(restored.displayString == original.displayString)
    }

    @Test("预设组合键本身也要能完整走完一次编码解码")
    func defaultComboSurvivesCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(HotKeyCombo.defaultCombo)
        let restored = try JSONDecoder().decode(HotKeyCombo.self, from: data)
        #expect(restored == HotKeyCombo.defaultCombo)
        #expect(restored.displayString == "⌘⇧V")
    }

    @Test("编码出来的栏位名称必须固定,否则旧版设定档会在升级後读不回来")
    func encodedKeysAreStable() throws {
        let data = try JSONEncoder().encode(HotKeyCombo.defaultCombo)
        let json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "编码结果应该是一个 JSON 物件"
        )
        #expect(json.keys.sorted() == ["keyCode", "modifiers"])
    }

    // MARK: - 相等性

    @Test("键码或修饰键任何一边不同就是不同的组合键")
    func combosDifferWhenEitherFieldDiffers() {
        let base = HotKeyCombo(keyCode: 9, modifiers: HotKeyCombo.commandMask)
        #expect(base != HotKeyCombo(keyCode: 8, modifiers: HotKeyCombo.commandMask))
        #expect(base != HotKeyCombo(keyCode: 9, modifiers: HotKeyCombo.controlMask))
        #expect(base == HotKeyCombo(keyCode: 9, modifiers: HotKeyCombo.commandMask))
    }
}
