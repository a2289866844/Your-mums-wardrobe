import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ClipdCore

/// 这一组测试只验证「写剪贴板」这一半,完全不碰 `pasteIntoPreviousApp`。
///
/// 不测送按键有两个理由,而且都不是偷懒:
/// 第一,合成的 Command+V 会真的送进当下最前景的那个程式 —— 在开发者的机器上跑一次测试,
/// 就等於对着他正在用的编辑器按了一下贴上,这是测试绝对不该造成的副作用。
/// 第二,结果完全取决於这台机器有没有给辅助使用权限、当下是不是在安全输入模式,
/// 同一份程式码在不同机器上会得到不同答案,这种断言不具意义。
/// 那一段路径靠的是程式码里写死的「先检查、不通过就不送」,以及真人手动验证。
///
/// 另外,每一个案例都用自己命名的临时剪贴板,绝对不碰 `NSPasteboard.general`——
/// 那是使用者当下真正在用的剪贴板,跑测试把人家剪好的东西洗掉是不可接受的。
@Suite("贴回引擎的剪贴板写入")
struct PasterTests {

    private let plainTextUTI = UTType.utf8PlainText.identifier
    private let rtfUTI = UTType.rtf.identifier
    private let htmlUTI = UTType.html.identifier
    private let pngUTI = UTType.png.identifier

    /// 开一块只属於这个案例的临时剪贴板,用完立刻还给系统。
    private func withScratchBoard(_ body: (NSPasteboard) throws -> Void) rethrows {
        let board = NSPasteboard(name: NSPasteboard.Name("dev.clipd.tests.paster.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        try body(board)
    }

    private func makeItem(
        kind: ItemKind = .text,
        searchText: String = "",
        representations: [ItemRepresentation]
    ) -> ClipItem {
        ClipItem(
            id: makeItemID(),
            kind: kind,
            capturedAt: Date(timeIntervalSince1970: 1_000_000),
            contentHash: "0123456789abcdef",
            preview: "面板上显示的那一行摘要,刻意跟真正的内容不一样,用来确认它不会被当成内容贴出去",
            searchText: searchText,
            representations: representations
        )
    }

    private func inline(_ uti: String, _ text: String) -> ItemRepresentation {
        ItemRepresentation(uti: uti, byteCount: Data(text.utf8).count, blobPath: nil, inlineText: text)
    }

    /// 一个「读不到任何东西」的 blob 读取器,给根本不含外部档案的案例用。
    private func noBlobs(_ path: String) -> Data? { nil }

    @Test("原样贴上时,每一种重建得出来的表示法都要放回剪贴板")
    func 原样贴上会写回所有表示法() {
        withScratchBoard { board in
            let paster = Paster(pasteboard: board)
            let item = makeItem(representations: [
                inline(plainTextUTI, "哈囉,这是一段中文纯文字。"),
                inline(rtfUTI, "{\\rtf1\\ansi 这是富文字版本}"),
            ])

            paster.write(item, style: .original, blobLoader: noBlobs)

            // 纯文字与富文字都要在同一块板上,接收端才有得挑。
            #expect(board.string(forType: .string) == "哈囉,这是一段中文纯文字。")
            let rtf = board.data(forType: NSPasteboard.PasteboardType(rtfUTI))
            #expect(rtf.flatMap { String(data: $0, encoding: .utf8) } == "{\\rtf1\\ansi 这是富文字版本}")
        }
    }

    @Test("纯文字样式只能写 public.utf8-plain-text,富文字与 HTML 一律要被丢掉")
    func 纯文字样式会丢掉富文字表示法() {
        withScratchBoard { board in
            let paster = Paster(pasteboard: board)
            let item = makeItem(representations: [
                inline(plainTextUTI, "使用者要的是洗掉格式之後的这一段字。"),
                inline(rtfUTI, "{\\rtf1\\ansi 有格式的版本}"),
                inline(htmlUTI, "<b>有格式的版本</b>"),
            ])

            paster.write(item, style: .plainText, blobLoader: noBlobs)

            #expect(board.string(forType: .string) == "使用者要的是洗掉格式之後的这一段字。")
            // 这里断言「不存在」而不是断言型别清单完全相等,因为系统有可能自行补上衍生型别,
            // 那不是我们写的,拿它当断言基础会让测试变得脆弱。真正要守住的是富文字没有被写上去。
            #expect(board.data(forType: NSPasteboard.PasteboardType(rtfUTI)) == nil)
            #expect(board.data(forType: NSPasteboard.PasteboardType(htmlUTI)) == nil)
        }
    }

    @Test("write() 回传的 changeCount 一定比写入之前大,呼叫端才有东西可以拿去让轮询忽略自己")
    func 写入之後changeCount会变大() {
        withScratchBoard { board in
            let paster = Paster(pasteboard: board)
            let item = makeItem(representations: [inline(plainTextUTI, "任何一段内容都可以。")])

            let before = board.changeCount
            let after = paster.write(item, style: .original, blobLoader: noBlobs)

            #expect(after > before)
            // 回传值必须就是这块板当下的 changeCount,不能是别的东西,
            // 否则指派给 PasteboardWatcher.selfWriteChangeCount 之後根本比对不到,历史照样会长出重複纪录。
            #expect(after == board.changeCount)
        }
    }

    @Test("富文字必须排在纯文字前面,否则支援格式的程式会挑到纯文字,使用者贴过去就发现格式没了")
    func 富文字要排在纯文字前面() throws {
        try withScratchBoard { board in
            let paster = Paster(pasteboard: board)
            // 刻意把纯文字放在阵列的第一个,来证明顺序是这个类别重新决定的,不是照抄进来的顺序。
            let item = makeItem(representations: [
                inline(plainTextUTI, "纯文字版本"),
                inline(rtfUTI, "{\\rtf1\\ansi 富文字版本}"),
            ])

            paster.write(item, style: .original, blobLoader: noBlobs)

            let types = board.types?.map(\.rawValue) ?? []
            let rtfIndex = try #require(types.firstIndex(of: rtfUTI))
            let plainIndex = try #require(types.firstIndex(of: plainTextUTI))
            #expect(rtfIndex < plainIndex)
        }
    }

    @Test("图片的位元组要透过 blobLoader 用 blobPath 取回来,再写上剪贴板")
    func 图片透过blobLoader取回位元组() {
        withScratchBoard { board in
            let paster = Paster(pasteboard: board)
            let fakePNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02])
            let path = "blobs/ab/abcdef.png"
            let item = makeItem(
                kind: .image,
                representations: [ItemRepresentation(uti: pngUTI, byteCount: fakePNG.count, blobPath: path)]
            )

            var askedFor: [String] = []
            paster.write(item, style: .original) { requested in
                askedFor.append(requested)
                return requested == path ? fakePNG : nil
            }

            #expect(askedFor == [path])
            #expect(board.data(forType: NSPasteboard.PasteboardType(pngUTI)) == fakePNG)
        }
    }

    @Test("blobLoader 读不到档案时,那一种表示法要被跳过,不可以写上一份空资料假装成功")
    func 读不到blob时跳过该表示法() {
        withScratchBoard { board in
            let paster = Paster(pasteboard: board)
            let item = makeItem(
                kind: .image,
                representations: [
                    ItemRepresentation(uti: pngUTI, byteCount: 1234, blobPath: "blobs/ff/遗失了.png"),
                    inline(plainTextUTI, "图片旁边附带的说明文字"),
                ]
            )

            // 磁碟上的档案被使用者手动删掉了,或是资料夹搬走了,这在长期使用下一定会发生。
            paster.write(item, style: .original, blobLoader: noBlobs)

            #expect(board.data(forType: NSPasteboard.PasteboardType(pngUTI)) == nil)
            // 剩下重建得出来的那一种仍然要照写,不能因为图片掉了就整则放弃。
            #expect(board.string(forType: .string) == "图片旁边附带的说明文字")
        }
    }

    @Test("一则内容完全重建不出来时,原本剪贴板上的东西不可以被清掉")
    func 完全重建不出内容时不动原本的剪贴板() {
        withScratchBoard { board in
            board.clearContents()
            board.setString("使用者自己剪好、还没贴出去的重要内容", forType: .string)
            let untouched = board.changeCount

            let paster = Paster(pasteboard: board)
            // 只剩下一个别家程式的私有二进位型别:当初没有留下位元组,现在一个 byte 都拼不出来。
            let item = makeItem(
                kind: .other,
                representations: [ItemRepresentation(uti: "dyn.ah62d4rv4gu8zsmvsdq", byteCount: 4096)]
            )

            let after = paster.write(item, style: .original, blobLoader: noBlobs)

            #expect(after == untouched)
            #expect(board.string(forType: .string) == "使用者自己剪好、还没贴出去的重要内容")
        }
    }

    @Test("退而求其次拿 searchText 当纯文字时,绝对不可以拿被截断的 preview 去充数")
    func 退路只用searchText不用preview() {
        withScratchBoard { board in
            let paster = Paster(pasteboard: board)
            // 表示法里只有认不出内容的型别,但这一则本来就是文字,所以还有 searchText 这条退路。
            let item = makeItem(
                kind: .text,
                searchText: "这是完整的原始文字,长度远远超过面板上那一行摘要。",
                representations: [ItemRepresentation(uti: "dyn.ah62d4rv4gu8zsmvsdq", byteCount: 4096)]
            )

            paster.write(item, style: .original, blobLoader: noBlobs)

            #expect(board.string(forType: .string) == "这是完整的原始文字,长度远远超过面板上那一行摘要。")
            #expect(board.string(forType: .string) != item.preview)
        }
    }
}
