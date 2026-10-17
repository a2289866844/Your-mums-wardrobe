import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import ClipdCore   // 这里刻意不用 @testable:被测的全部是公开 API,测试也只该透过公开 API 验证。

// 这一组测试锁住的是「截图变得搜寻得到」这件事。
//
// 没有办法附一张固定的样本图进版本库(二进位档会让 diff 无法审查,而且不同机器上的
// 萤幕截图长得也不一样),所以每一张测试用的图都是当场用 CoreGraphics 画出来的:
// 我们自己决定要写哪几个字、用多大的字级、画在哪个位置,再把画出来的点阵图丢回去辨识,
// 这样「期待的答案」永远是已知的,不必信任任何外部档案。
//
// ── 关於断言的宽松程度 ────────────────────────────────────────────────
// 文字辨识不是一个确定性的函式:同一张图在不同 macOS 版本、甚至不同晶片上,
// 认出来的字可能差一两个。若这里要求逐字元完全相同,这些测试会在某一次系统更新之後
// 集体变红,而那时候真正该修的东西其实什麽也没坏 —— 那种测试最後一定会被人加上略过标记,
// 等於白写。所以底下一律用「至少认对六成字元」这种带余裕的判准:
// 它挡得住「整段变成乱码」「中文全部掉光」这类真正的回归,却容得下正常的版本差异。

@Suite("截图文字辨识")
struct OCRTests {

    // MARK: - 画测试图的工具

    /// 一段要画到图上的文字,以及它的字级与位置。
    ///
    /// 座标沿用 CoreGraphics 的习惯,以左下角为原点,所以 y 越大代表越靠近图的上缘。
    private struct Placed {
        let text: String
        let pointSize: CGFloat
        let x: CGFloat
        let y: CGFloat
    }

    /// 把几段文字画成一张白底黑字的点阵图。
    ///
    /// 字型刻意不写死成某一个名字。写死「PingFang TC」之类的名字有一个很难查的失败方式:
    /// 万一那个字型在某台机器上叫别的名字,CoreText 会安静地退回 Helvetica,
    /// 而 Helvetica 没有汉字,画出来是一整排空白 —— 测试会说「辨识不出中文」,
    /// 但真正坏掉的是画图这一端。改用 CTFontCreateForString 让系统自己去挑一个
    /// 画得出这段字的字型,就不会有这个陷阱。
    private func makeImage(_ items: [Placed], width: Int, height: Int) -> CGImage {
        // 用 noneSkipLast 而不是带 alpha 的格式:测试图不需要透明度,
        // 而且不透明的点阵图正好对应真实截图的样子。
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            // 这里若失败代表参数本身就不合法(例如宽高是零),那是测试自己写错,不是被测程式有问题。
            fatalError("测试图的绘图环境建不起来,请检查传进来的宽高是不是合法的。")
        }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))

        for item in items {
            let fallbackSeed = CTFontCreateWithName("Helvetica" as CFString, item.pointSize, nil)
            let length = (item.text as NSString).length
            let font = CTFontCreateForString(fallbackSeed, item.text as CFString, CFRange(location: 0, length: length))
            let fontKey = kCTFontAttributeName as NSAttributedString.Key
            let attributed = NSAttributedString(string: item.text, attributes: [fontKey: font])
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: item.x, y: item.y)
            CTLineDraw(line, context)
        }

        guard let image = context.makeImage() else {
            fatalError("测试图画完之後取不出点阵图,这代表绘图环境的状态不对。")
        }
        return image
    }

    /// 把一张图编码成 PNG,用来验证「从 PNG 资料进来」的那条路。
    private func pngData(of image: CGImage) -> Data {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer, UTType.png.identifier as CFString, 1, nil
        ) else {
            fatalError("PNG 编码器建不起来,这是测试环境的问题,不是被测程式的问题。")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            fatalError("PNG 编码没有写完,这是测试环境的问题,不是被测程式的问题。")
        }
        return buffer as Data
    }

    /// 算出「认对了几成字元」。
    ///
    /// 用的是多重集合的交集除以期待字数,而不是逐位置比对:辨识结果可能多一个空格、
    /// 少一个标点、或者把一行拆成两行,那些差异不该被算成认错字。
    /// 比较前会先把所有空白拿掉,因为空白在哪里是排版问题,不是辨识对错的问题。
    private func characterOverlap(expected: String, produced: String) -> Double {
        let wanted = expected.filter { !$0.isWhitespace }
        guard !wanted.isEmpty else { return 1 }

        var pool: [Character: Int] = [:]
        for character in produced where !character.isWhitespace {
            pool[character, default: 0] += 1
        }

        var matched = 0
        for character in wanted {
            guard let available = pool[character], available > 0 else { continue }
            pool[character] = available - 1
            matched += 1
        }
        return Double(matched) / Double(wanted.count)
    }

    /// 认对六成字元就算通过,理由写在档案开头。
    private static let acceptableOverlap = 0.6

    // MARK: - 认得出字

    @Test("一行大字繁体中文要认得出大部分的字")
    func largeTraditionalChineseIsRecognised() async throws {
        let expected = "病歷摘要 血壓正常"
        let image = makeImage([Placed(text: expected, pointSize: 64, x: 24, y: 60)], width: 900, height: 200)

        // 刻意走 PNG 那条入口,因为真实的截图就是以 PNG 的样子进到程式里的。
        let result = try await OCRService().recognize(pngData: pngData(of: image))

        let overlap = characterOverlap(expected: expected, produced: result.text)
        #expect(overlap >= Self.acceptableOverlap, "只认对了 \(Int(overlap * 100))% 的字元,读到的是「\(result.text)」")
        #expect(result.lineCount == 1, "一行字应该被读成一行,实际读成 \(result.lineCount) 行")
        #expect(!result.isLowConfidence, "这麽大的字不该被判成信心不足,引擎说:\(result.engineNote)")
        #expect(!result.engineNote.isEmpty)
    }

    @Test("避开 GPU 仍保留中文、英文与阅读顺序")
    func recognitionWithoutGPUKeepsBothLanguages() async throws {
        let image = makeImage([
            Placed(text: "病歷摘要 血壓正常", pointSize: 64, x: 24, y: 180),
            Placed(text: "Patient Blood Pressure", pointSize: 56, x: 24, y: 60)
        ], width: 1100, height: 300)

        let result = try await OCRService(avoidsGPU: true).recognize(cgImage: image)
        #expect(characterOverlap(expected: "病歷摘要 血壓正常", produced: result.text) >= Self.acceptableOverlap)
        #expect(result.text.lowercased().contains("patient"))
        #expect(result.lineCount == 2)
        #expect(result.text.components(separatedBy: "\n").last?.lowercased().contains("patient") == true)
        #expect(!result.isLowConfidence)
    }

    @Test("一行英文要认得出大部分的字")
    func englishLineIsRecognised() async throws {
        let expected = "Patient Blood Pressure"
        let image = makeImage([Placed(text: expected, pointSize: 56, x: 24, y: 60)], width: 900, height: 200)

        let result = try await OCRService().recognize(cgImage: image)

        let overlap = characterOverlap(expected: expected, produced: result.text)
        #expect(overlap >= Self.acceptableOverlap, "只认对了 \(Int(overlap * 100))% 的字元,读到的是「\(result.text)」")
        #expect(!result.isLowConfidence, "这麽大的字不该被判成信心不足,引擎说:\(result.engineNote)")
    }

    @Test("中文与英文混在同一行时两边都要认得到")
    func mixedChineseAndEnglishIsRecognised() async throws {
        let image = makeImage(
            [Placed(text: "血壓 Patient 120", pointSize: 60, x: 24, y: 60)],
            width: 900, height: 200
        )

        let result = try await OCRService().recognize(cgImage: image)

        // 这一条锁的是语言顺序那个设定。若哪天有人把英文调到最前面,
        // 中文会整段消失而英文照样漂亮,所以两边都要分开检查,只看整体相似度会漏掉。
        #expect(result.text.contains("血") || result.text.contains("壓"), "中文整段掉光了,读到的是「\(result.text)」")
        #expect(result.text.lowercased().contains("patient"), "英文没读到,读到的是「\(result.text)」")
    }

    // MARK: - 认不清楚的时候要老实说

    @Test("刻意画得极小的字要回报信心不足")
    func tinyTextIsReportedAsLowConfidence() async throws {
        // 七点的字在一倍的点阵图上只有十个像素高,人凑近看都很吃力。
        // 这种情况下辨识引擎照样会吐出一串字,而且吐得理直气壮 —— 那正是最危险的情况:
        // 下游会拿 isLowConfidence 决定要不要把这段字当成可信的搜寻依据,
        // 所以「认不清楚」一定要被讲出来,不能靠下游自己猜。
        let image = makeImage(
            [Placed(text: "病歷摘要 血壓正常 Patient", pointSize: 7, x: 24, y: 100)],
            width: 900, height: 200
        )

        let result = try await OCRService().recognize(cgImage: image)

        #expect(result.isLowConfidence, "这麽小的字被当成可信的了,引擎说:\(result.engineNote)")
        #expect(result.medianGlyphHeightPoints < 11, "量到的字高中位数是 \(result.medianGlyphHeightPoints) 点,不该这麽大")
    }

    @Test("整张全白的图要回传空字串,而且不可以丢例外")
    func blankImageReturnsEmptyTextWithoutThrowing() async throws {
        // 使用者截到一块空白区域是很常见的事(截到侧边栏、截到载入中的画面)。
        // 这不是错误,程式必须安静地回一段空文字,而不是丢例外把整条抓取流程打断。
        let image = makeImage([], width: 800, height: 300)

        let result = try await OCRService().recognize(cgImage: image)

        #expect(result.text.isEmpty, "白底图上读出了「\(result.text)」")
        #expect(result.lineCount == 0)
        #expect(!result.engineNote.isEmpty, "就算什麽都没读到,也要留下一句说明给後面查问题的人看")
    }

    // MARK: - 阅读顺序

    @Test("左侧栏加右主文的版面不可以读成左右交错")
    func twoColumnLayoutIsNotInterleaved() async throws {
        // 若照 y 座标由上往下排,侧栏的每一行都会插进主文的行与行之间,
        // 读出来是「侧栏一、主文一、侧栏二、主文二……」这种两边交错的东西。
        // 那段文字看起来有字、字也都对,但语意整个是断的,搜寻时几乎命中不了任何词。
        let image = makeImage([
            Placed(text: "Sidebar Alpha", pointSize: 34, x: 40, y: 800),
            Placed(text: "Sidebar Beta", pointSize: 34, x: 40, y: 720),
            Placed(text: "Sidebar Gamma", pointSize: 34, x: 40, y: 640),
            Placed(text: "Body line one", pointSize: 34, x: 420, y: 800),
            Placed(text: "Body line two", pointSize: 34, x: 420, y: 720),
            Placed(text: "Body line three", pointSize: 34, x: 420, y: 640),
        ], width: 1200, height: 1000)

        let result = try await OCRService().recognize(cgImage: image)
        let lines = result.text.split(separator: "\n").map(String.init)

        let sidebarIndices = lines.indices.filter { lines[$0].localizedCaseInsensitiveContains("Sidebar") }
        let bodyIndices = lines.indices.filter { lines[$0].localizedCaseInsensitiveContains("Body") }

        // 前提检查:两边至少都要认到一行,否则这次辨识根本没有能判断顺序的材料。
        #expect(!sidebarIndices.isEmpty && !bodyIndices.isEmpty,
                "两栏至少各要认到一行才判断得了顺序,实际读到的是 \(lines)")

        if let lastSidebar = sidebarIndices.last, let firstBody = bodyIndices.first {
            #expect(lastSidebar < firstBody, "两栏被读成交错的了,实际顺序是 \(lines)")
        }
    }

    // MARK: - 输出正规化

    @Test("全形数字与字母要被折成半形,否则搜寻会对不起来")
    func fullwidthCharactersAreNormalised() async throws {
        // OCR 读回来的宽度形式并不一致:同一个画面上可能同时出现全形的「５００ｍｇ」
        // 与半形的「500mg」。不先折成同一种,使用者打「500mg」会搜不到那一笔。
        let image = makeImage(
            [Placed(text: "５００ｍｇ ＮＯＲＭＡＬ", pointSize: 60, x: 24, y: 60)],
            width: 900, height: 200
        )

        let result = try await OCRService().recognize(cgImage: image)

        #expect(result.text.lowercased().contains("500mg"), "全形没有被折成半形,读到的是「\(result.text)」")
        #expect(!result.text.contains("５"), "结果里还留着全形数字,读到的是「\(result.text)」")
    }

    // MARK: - 坏输入要说清楚为什麽

    @Test("空的图片资料要丢出说得出理由的错误")
    func emptyDataThrows() async {
        await #expect(throws: OCRError.self) {
            _ = try await OCRService().recognize(pngData: Data())
        }
    }

    @Test("不是图片的资料要丢出说得出理由的错误")
    func garbageDataThrows() async {
        // 这里检查的不只是「有丢例外」,还包括那句话是不是人看得懂的完整中文句子 ——
        // 这段文字最後会原样出现在使用者眼前,不是只写给开发者看的。
        do {
            _ = try await OCRService().recognize(pngData: Data([0x01, 0x02, 0x03, 0x04]))
            Issue.record("不是图片的资料却没有丢例外")
        } catch let error as OCRError {
            #expect(error.description.contains("图片"), "错误讯息不像给人看的:\(error.description)")
        } catch {
            Issue.record("丢出来的不是 OCRError,而是 \(error)")
        }
    }

    @Test("小到不可能有字的图要直接被挡下来,而不是回一段误导人的空结果")
    func tooSmallImageThrows() async {
        let image = makeImage([], width: 4, height: 4)
        await #expect(throws: OCRError.self) {
            _ = try await OCRService().recognize(cgImage: image)
        }
    }

    @Test("读不到的档案路径要丢出说得出理由的错误")
    func unreadableFileThrows() async {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipd-ocr-这个档案不存在.png")
        await #expect(throws: OCRError.self) {
            _ = try await OCRService().recognize(imageAt: missing)
        }
    }

    // MARK: - 磁碟上的图

    @Test("从磁碟上的档案辨识,结果要跟直接给点阵图一样")
    func recognisingFromDiskMatchesInMemory() async throws {
        let expected = "血壓正常"
        let image = makeImage([Placed(text: expected, pointSize: 64, x: 24, y: 60)], width: 900, height: 200)

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipd-ocr-test-\(UUID().uuidString).png")
        try pngData(of: image).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let fromDisk = try await OCRService().recognize(imageAt: url)
        let inMemory = try await OCRService().recognize(cgImage: image)

        #expect(fromDisk.text == inMemory.text, "同一张图从档案读跟从记忆体读结果不一样:「\(fromDisk.text)」对「\(inMemory.text)」")
        #expect(characterOverlap(expected: expected, produced: fromDisk.text) >= Self.acceptableOverlap)
    }
}
