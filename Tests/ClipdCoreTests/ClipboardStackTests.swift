import Testing
import ClipdCore   // 这里刻意不用 @testable:堆叠的每一条规则都是公开行为,测试也只透过公开 API 验证。

// 这一组测试锁住的是「贴出去的顺序」。
// 顺序一旦坏掉,症状不是当机也不是报错,而是使用者在别人的输入框里贴出错的内容,
// 那种错误发生在我们看不到的地方,也没办法事後补救,所以这里的每一条规则都必须钉死。

@Suite("剪贴板堆叠")
struct ClipboardStackTests {

    /// 建一个已经依序加入指定项目的堆叠,省掉每个测试重复三行。
    private func stack(_ ids: String...) -> ClipboardStack {
        let s = ClipboardStack()
        for id in ids { _ = s.add(id) }
        return s
    }

    // MARK: - 加入:顺序是加入顺序

    @Test("加入的先後顺序就是堆叠的顺序,与复制时间无关")
    func addPreservesInsertionOrder() {
        // 故意用倒过来的识别码加入,确认没有人偷偷帮我们排序。
        let s = stack("C", "A", "B")
        #expect(s.itemIDs == ["C", "A", "B"])
        #expect(s.count == 3)
        #expect(s.isArmed)
    }

    @Test("重复加入同一则会被拒绝,回传 false 而且不会多出一份")
    func duplicateAddIsRejected() {
        let s = ClipboardStack()
        #expect(s.add("A"))
        #expect(s.add("A") == false)
        #expect(s.itemIDs == ["A"])
        #expect(s.count == 1)
    }

    @Test("空的堆叠还没上膛,加入一则之後就上膛了")
    func armedOnlyAfterFirstAdd() {
        let s = ClipboardStack()
        #expect(s.isArmed == false)
        #expect(s.add("A"))
        #expect(s.isArmed)
    }

    // MARK: - 贴出:依序,而且不回卷

    @Test("贴出时依照加入顺序一则一则送,送完之後回传 nil")
    func advanceReturnsItemsInOrderThenNil() {
        let s = stack("A", "B", "C")
        #expect(s.advance() == "A")
        #expect(s.advance() == "B")
        #expect(s.advance() == "C")
        #expect(s.advance() == nil)
    }

    @Test("贴完之後再按也不会回卷到第一则,游标停在最後面")
    func advanceDoesNotWrapAround() {
        let s = stack("A", "B")
        #expect(s.advance() == "A")
        #expect(s.advance() == "B")
        // 连按好几次,每一次都必须是 nil;只要有一次回传 "A" 就代表回卷了。
        #expect(s.advance() == nil)
        #expect(s.advance() == nil)
        #expect(s.advance() == nil)
        #expect(s.nextIndex == 2)
        #expect(s.count == 2)
    }

    @Test("nextIndex 会随着贴出一则一则往前走")
    func nextIndexTracksHowManyHaveBeenPasted() {
        let s = stack("A", "B", "C")
        #expect(s.nextIndex == 0)
        _ = s.advance()
        #expect(s.nextIndex == 1)
        _ = s.advance()
        #expect(s.nextIndex == 2)
    }

    // MARK: - 删除:剩下的顺序不能乱,游标不能错开

    @Test("删掉中间一则,剩下的顺序不变,还没贴的下一则也不变")
    func removeInTheMiddleKeepsTheRestInOrder() {
        let s = stack("A", "B", "C", "D")
        s.remove("B")
        #expect(s.itemIDs == ["A", "C", "D"])
        #expect(s.nextIndex == 0)
        #expect(s.advance() == "A")
        #expect(s.advance() == "C")
    }

    @Test("删掉已经贴出去的那一则,游标要跟着往前一格,下一则不会被跳过")
    func removingAnAlreadyPastedItemKeepsTheCursorAligned() {
        let s = stack("A", "B", "C")
        #expect(s.advance() == "A")   // A 已经贴出去了,游标停在 B
        s.remove("A")
        #expect(s.itemIDs == ["B", "C"])
        #expect(s.nextIndex == 0)     // 前面少了一则,游标要跟着退一格
        #expect(s.advance() == "B")   // 若游标没退,这里会错跳成 C
    }

    @Test("删掉还没贴的那一则,游标原地不动")
    func removingAPendingItemLeavesTheCursorWhereItIs() {
        let s = stack("A", "B", "C")
        #expect(s.advance() == "A")
        s.remove("C")
        #expect(s.itemIDs == ["A", "B"])
        #expect(s.nextIndex == 1)
        #expect(s.advance() == "B")
        #expect(s.advance() == nil)
    }

    @Test("删掉不在堆叠里的识别码不会有任何影响")
    func removingAnUnknownIDIsANoOp() {
        let s = stack("A", "B")
        s.remove("Z")
        #expect(s.itemIDs == ["A", "B"])
        #expect(s.nextIndex == 0)
    }

    @Test("把最後一则删掉之後,游标不会停在阵列外面")
    func removingTheLastPendingItemKeepsTheCursorInRange() {
        let s = stack("A")
        #expect(s.advance() == "A")
        s.remove("A")
        #expect(s.itemIDs.isEmpty)
        #expect(s.nextIndex == 0)
        #expect(s.advance() == nil)
    }

    // MARK: - 重排

    @Test("往前挪一格会与前一则交换位置")
    func moveUpSwapsWithThePreviousItem() {
        let s = stack("A", "B", "C")
        s.moveUp("C")
        #expect(s.itemIDs == ["A", "C", "B"])
    }

    @Test("最前面的一则再往前挪也不会有事")
    func moveUpAtTheTopDoesNothing() {
        let s = stack("A", "B")
        s.moveUp("A")
        #expect(s.itemIDs == ["A", "B"])
    }

    @Test("往後挪一格会与後一则交换位置")
    func moveDownSwapsWithTheNextItem() {
        let s = stack("A", "B", "C")
        s.moveDown("A")
        #expect(s.itemIDs == ["B", "A", "C"])
    }

    @Test("最後面的一则再往後挪也不会有事")
    func moveDownAtTheBottomDoesNothing() {
        let s = stack("A", "B")
        s.moveDown("B")
        #expect(s.itemIDs == ["A", "B"])
    }

    @Test("重排不在堆叠里的识别码不会有任何影响")
    func movingAnUnknownIDIsANoOp() {
        let s = stack("A", "B")
        s.moveUp("Z")
        s.moveDown("Z")
        #expect(s.itemIDs == ["A", "B"])
    }

    // MARK: - 重来与丢弃

    @Test("重来会把游标退回最前面,内容全部留着")
    func resetKeepsTheItemsAndRewindsTheCursor() {
        let s = stack("A", "B")
        #expect(s.advance() == "A")
        s.reset()
        #expect(s.itemIDs == ["A", "B"])
        #expect(s.nextIndex == 0)
        #expect(s.advance() == "A")
    }

    @Test("丢弃会把内容与游标一起清空,堆叠回到没上膛的状态")
    func discardEmptiesEverything() {
        let s = stack("A", "B")
        _ = s.advance()
        s.discard()
        #expect(s.itemIDs.isEmpty)
        #expect(s.count == 0)
        #expect(s.nextIndex == 0)
        #expect(s.isArmed == false)
        #expect(s.advance() == nil)
    }

    // MARK: - 位置与是否在堆叠里

    @Test("位置从 1 开始数,不在堆叠里的回传 nil")
    func positionIsOneBased() {
        let s = stack("A", "B", "C")
        #expect(s.position(of: "A") == 1)
        #expect(s.position(of: "B") == 2)
        #expect(s.position(of: "C") == 3)
        #expect(s.position(of: "Z") == nil)
    }

    @Test("重排之後位置要跟着改")
    func positionFollowsReordering() {
        let s = stack("A", "B")
        s.moveUp("B")
        #expect(s.position(of: "B") == 1)
        #expect(s.position(of: "A") == 2)
    }

    @Test("contains 只认真的加进去的那几则")
    func containsOnlyReportsItemsThatWereAdded() {
        let s = stack("A")
        #expect(s.contains("A"))
        #expect(s.contains("Z") == false)
    }

    // MARK: - 面板底部那句话

    @Test("空的、贴到一半、全部贴完,三种状态的句子必须各不相同")
    func statusSentenceDiffersAcrossStates() {
        let empty = ClipboardStack().statusSentence

        let s = stack("A", "B", "C")
        let fresh = s.statusSentence
        _ = s.advance()
        let partway = s.statusSentence
        _ = s.advance()
        _ = s.advance()
        let exhausted = s.statusSentence

        #expect(empty != fresh)
        #expect(fresh != partway)
        #expect(partway != exhausted)
        #expect(empty != exhausted)
    }

    @Test("空的时候要告诉使用者怎麽把内容加进来")
    func statusSentenceForEmptyStackExplainsHowToStart() {
        #expect(ClipboardStack().statusSentence == "堆叠目前是空的,在面板里按右方向键可以把一则加进来。")
    }

    @Test("还没开始贴的时候要说清楚有几则、下一次会送出哪一则")
    func statusSentenceForAFreshStackNamesTheNextItem() {
        #expect(stack("A", "B", "C").statusSentence == "堆叠里有三则内容,下一次贴上会送出第一则。")
    }

    @Test("贴到一半时,句子里的序号要跟着游标走")
    func statusSentencePartwayNamesTheRightOrdinal() {
        let s = stack("A", "B", "C")
        _ = s.advance()
        #expect(s.statusSentence == "堆叠里有三则内容,下一次贴上会送出第二则。")
    }

    @Test("刚好两则的时候中文要说「两则」而不是「二则」")
    func statusSentenceUsesTheColloquialFormForTwo() {
        #expect(stack("A", "B").statusSentence == "堆叠里有两则内容,下一次贴上会送出第一则。")
    }

    @Test("全部贴完时要说贴完了,并告诉使用者可以清掉")
    func statusSentenceForAnExhaustedStackSaysSo() {
        let s = stack("A")
        _ = s.advance()
        #expect(s.statusSentence == "堆叠已经全部贴完了,按 Esc 可以清掉它。")
    }
}
