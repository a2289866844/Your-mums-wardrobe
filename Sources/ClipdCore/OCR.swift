// clipd 的截图文字辨识 —— 把一张点阵图变成搜寻得到的文字。
//
// 一张截图若只以点阵图的样子躺在纪录里,使用者事後几乎不可能找回它:面板上能依靠的只剩
// 「什麽时候截的」跟「从哪个程式来的」。把图里的字读出来写进 searchText,截图才真的变成可以
// 搜寻的资料,所以这个档案的辨识品质是一项产品特性,不是实作细节。
//
// 隐私与权限:Vision 的文字辨识整个跑在本机上,不需要任何 entitlement、不会连任何伺服器、
// 也不会跳出任何权限询问视窗,後面的人读到这里不必再去补权限描述档。反过来说,若哪天有人想
// 把辨识改成送去云端处理,那是一个必须先跟使用者讲清楚的产品决策,不是可以顺手改掉的实作
// 细节 —— 剪贴板里可能有病历、密码提示、私人对话。
//
// 底下每一个设定值都是在这台机器上量出来的,不是抄来的预设值,也不是凭感觉挑的。要改动任何
// 一个之前,请先读它旁边那段量测纪录:那些数字是实际跑出来、而且踩过坑才换来的。

import CoreGraphics
import CoreML
import Foundation
import ImageIO
import Vision

// MARK: - 对外的结果与错误

/// 一次辨识的完整结果。刻意不只回传文字:呼叫端需要知道「这段文字有多可信」才能决定要不要
/// 把它当成搜寻依据,而那个判断需要字高与信心分布这些结构性资讯,不是一个字串能表达的。
public struct OCRResult: Sendable {
    public let text: String                       // 已重建阅读顺序、正规化、折叠过行内空白的文字,行间以换行分隔
    public let lineCount: Int                     // `text` 里的行数,什麽都没读到时是 0
    public let medianGlyphHeightPoints: Double    // 字高中位数,单位是点,换算方式见 `assumedBackingScale`
    public let isLowConfidence: Bool              // 这次辨识可不可靠,推导过程见 `assemble`,刻意不看 Vision 自报的信心
    public let engineNote: String                 // 一句写给人看的完整中文句子,出问题时这就是第一手线索
}

/// 辨识途中可能发生的所有失败。每一个 case 都有完整中文句子的说明,因为这些错误最後会原样
/// 出现在使用者眼前(抓取协调器会把 `"\(error)"` 直接放进给使用者看的讯息里)。
public enum OCRError: Error, CustomStringConvertible {
    case emptyImageData                                          // 资料是空的,连解码都不必试
    case imageDecodingFailed(reason: String)                     // 不是任何系统认得的图片格式,或档案已损毁
    case imageTooSmall(widthPixels: Int, heightPixels: Int)      // 小到不可能有字,再跑只会回一个误导人的空结果
    case fileUnreadable(path: String, reason: String)            // 路径不存在、权限不足、或档案还没写完
    case recognitionFailed(reason: String)                       // Vision 自己回报失败

    public var description: String {
        switch self {
        case .emptyImageData:
            "要辨识的图片资料是空的,里面一个位元组都没有,所以这次辨识没有开始。"
        case .imageDecodingFailed(let reason):
            "这份资料没办法被解读成一张图片,系统给的理由是「\(reason)」,所以这次辨识没有开始。"
        case .imageTooSmall(let width, let height):
            "这张图只有 \(width)×\(height) 像素,小到不可能容得下任何文字,所以这次辨识直接放弃了。"
        case .fileUnreadable(let path, let reason):
            "读不到「\(path)」这个档案,系统给的理由是「\(reason)」,所以这次辨识没有开始。"
        case .recognitionFailed(let reason):
            "文字辨识引擎在跑到一半时失败了,它给的理由是「\(reason)」。"
        }
    }
}

// MARK: - 辨识服务本体

/// 在本机把图片里的文字读出来。这个类别没有任何可变状态:每一次辨识都自己建一份全新的请求,
/// 所以它天生就能从任何执行绪、任何 Task 同时呼叫,不需要外部上锁。
public final class OCRService: Sendable {
    private let avoidsGPU: Bool

    /// Resident capture utilities can reserve the GPU for desktop rendering.
    /// Prefer the Neural Engine, with a CPU fallback supported by the request.
    public init(avoidsGPU: Bool = false) {
        self.avoidsGPU = avoidsGPU
    }

    // MARK: 量测出来的设定值

    /// 辨识语言的顺序。中文一定要排在最前面。
    ///
    /// 量测纪录(这是整个档案里最危险的一个设定,因为它失败时完全没有声音):把 en-US 排到
    /// 最前面之後,辨识结果跟「只开英文」是逐位元组一模一样的 —— 12 行、400 个字元,而正确
    /// 顺序是 17 行、591 个字元。更糟的是前者回报的平均信心还比较高(0.833 对 0.494),原因
    /// 正是那些难认的中文行整个消失了,剩下的都是好认的英文,平均自然漂亮。也就是说:排错
    /// 顺序不但会掉字,还会让品质指标看起来变好,没有人会发现。
    ///
    /// 繁体与简体共用同一个模型,所以 zh-Hant 与 zh-Hans 之间谁先谁後不影响结果,两个都列
    /// 出来只是为了让读到这行的人知道两种字都吃得下。
    private static let recognitionLanguages: [Locale.Language] = [
        Locale.Language(identifier: "zh-Hant"),
        Locale.Language(identifier: "zh-Hans"),
        Locale.Language(identifier: "en-US"),
    ]

    /// 最小文字高度,以图片高度的比例表示。
    ///
    /// 量测纪录:旧版 SDK 的预设值是 1/32,用那个值去跑一张正常的 Retina 截图会得到「零个」
    /// 结果 —— 不是认错字,是整张图完全没有任何观测值。这个预设值後来又被 Apple 改过,所以
    /// 这里一律写死 0.005,绝不继承系统当下的预设值。
    private static let minimumTextHeightFraction: Float = 0.005

    /// 把像素换算成点时假设的萤幕倍率。
    ///
    /// Vision 只知道像素,不知道这张图是用几倍的萤幕截出来的,而 clipd 的输入永远是 macOS
    /// 截图、现役的 Mac 又全部是 Retina,所以这里一律假设两倍。万一真的进来一张一倍的图,
    /// 算出来的点数会只有真实值的一半,判断会偏向「我不太确定」那一边 —— 那正是我们要的偏向,
    /// 理由见 `assemble` 里推导 `isLowConfidence` 的那一段。
    private static let assumedBackingScale = 2.0

    // 放大的两条界线。量测纪录:字够大时放大反而会让字元错误率从 3% 变成 7%,插值补出来的
    // 边缘对辨识引擎来说是杂讯而不是资讯,所以只在字真的太小时才放大,并且留一条硬上限。
    private static let upscaleBelowPoints = 10.0            // 字高中位数低於这个点数才值得放大两倍重跑
    private static let neverUpscaleAbovePoints = 11.0       // 字高中位数超过这个点数就绝对不可以放大

    // 信心判断的三个门槛,推导过程写在 `assemble` 里。
    private static let lowConfidenceGlyphHeightPoints = 11.0    // 字高中位数低於此即判定信心不足
    private static let lowConfidenceThreshold: Float = 0.3      // Vision 报到这个值(含)以下代表连它自己也没把握
    private static let lowConfidenceShareLimit = 0.25           // 这个比例以上的区块信心偏低,整批就算不可信
    private static let textExpectedShorterSidePoints = 64.0     // 短边至少这麽多点,才算「这张图本来就该有字」

    /// 放大後的像素数上限,超过就不放大了。一张 5141×3339 的图放大两倍会变成 6870 万像素,
    /// 光是点阵就要吃掉两百多 MB 记忆体;对一个常驻在选单列的小工具来说,那样的记忆体尖峰
    /// 比多认几个字严重得多。
    private static let upscaledPixelBudget = 32_000_000

    /// 小於这个边长的图直接当成呼叫端出错。
    private static let minimumUsablePixelSide = 8

    // MARK: 对外的三个入口

    /// 辨识一份图片资料(实务上是 PNG,但任何系统认得的格式都吃得下)。
    public func recognize(pngData: Data) async throws -> OCRResult {
        guard !pngData.isEmpty else { throw OCRError.emptyImageData }
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil) else {
            throw OCRError.imageDecodingFailed(reason: "认不出这是哪一种图片格式")
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw OCRError.imageDecodingFailed(reason: "格式认得出来,但第一张影格解不开,资料可能只有一半")
        }
        return try await recognize(cgImage: image)
    }

    /// 辨识磁碟上的一个图档。截图是先落到磁碟上才被处理的,所以这条路是最常走的一条。
    public func recognize(imageAt url: URL) async throws -> OCRResult {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw OCRError.fileUnreadable(path: url.path, reason: "档案不存在、没有读取权限、或者还没被写完")
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw OCRError.imageDecodingFailed(reason: "「\(url.lastPathComponent)」解不出任何影格,档案可能损毁或只写了一半")
        }
        return try await recognize(cgImage: image)
    }

    /// 辨识一张已经解好的图片。上面两个入口最後都会走到这里。
    public func recognize(cgImage: CGImage) async throws -> OCRResult {
        guard cgImage.width >= Self.minimumUsablePixelSide,
              cgImage.height >= Self.minimumUsablePixelSide else {
            throw OCRError.imageTooSmall(widthPixels: cgImage.width, heightPixels: cgImage.height)
        }

        // 第一趟一律用原始解析度跑。量测纪录:辨识时间跟解析度几乎无关 —— 787×511 花了 359
        // 毫秒,5141×3339 花了 388 毫秒,像素多了 43 倍时间只多 8%。所以「为了快一点先缩小」
        // 这个直觉在这里是错的:省不到时间,却会把小字直接缩到认不出来。
        let first = try await pass(on: cgImage, upscaleFactor: 1)

        var chosen = first
        var upscaleNote = ""

        // 只有在字真的太小的时候才放大重跑,而且字高一旦超过硬上限就绝对不放大。两个条件都写
        // 出来是刻意的:上限那一条在目前的数值下不会单独成立,但它是量测结论本身(放大大字会
        // 让错误率从 3% 升到 7%),必须留在程式里而不是只留在注解里。
        let worthUpscaling = !first.lines.isEmpty
            && first.medianPoints < Self.upscaleBelowPoints
            && first.medianPoints <= Self.neverUpscaleAbovePoints
        if worthUpscaling {
            let upscaledPixels = cgImage.width * cgImage.height * 4
            if upscaledPixels > Self.upscaledPixelBudget {
                upscaleNote = "字偏小本来该放大重跑,但放大後会超过记忆体预算,所以这次维持原尺寸。"
            } else if let bigger = Self.upscaled(cgImage, factor: 2),
                      let second = try? await pass(on: bigger, upscaleFactor: 2),
                      second.characterCount > first.characterCount {
                chosen = second
                upscaleNote = "因为字高中位数低於 \(Int(Self.upscaleBelowPoints)) 点,所以又用放大两倍的影像重跑了一次,而且那一次读到的字比较多,採用的是放大後的结果。"
            } else {
                upscaleNote = "字偏小,放大两倍重跑过一次,但没有读到更多字,所以採用的还是原尺寸的结果。"
            }
        }

        return Self.assemble(chosen, image: cgImage, upscaleNote: upscaleNote)
    }
}

// MARK: - 单趟辨识

extension OCRService {
    /// 一趟辨识跑完之後、还没组成对外结果之前的中间产物。
    fileprivate struct Pass {
        let lines: [OrderedLine]
        let medianPoints: Double        // 一律换算回「原始图片的点」,与这一趟有没有放大无关
        let lowConfidenceShare: Double  // 信心落在门槛以下的区块占的比例
        let characterCount: Int
    }

    /// 一个已经带好版面座标的文字区块。座标一律换成左上角为原点,因为人是从左上开始读的。
    fileprivate struct OrderedLine {
        let text: String
        let minX: Double
        let maxX: Double
        let topY: Double
        var width: Double { maxX - minX }
    }

    fileprivate func pass(on image: CGImage, upscaleFactor: Int) async throws -> Pass {
        var request = RecognizeTextRequest()

        // 一定要用 accurate。量测纪录:fast 等级只支援六种拉丁语系语言,拿它去读中文时不会
        // 报错也不会拒绝,而是把「病歷摘要」认成「EiJiBR」—— 一段看起来像英文、其实完全是
        // 垃圾的字串,会安安静静地被写进搜寻索引里。
        request.recognitionLevel = .accurate
        request.recognitionLanguages = Self.recognitionLanguages
        request.minimumTextHeightFraction = Self.minimumTextHeightFraction

        // 开着语言校正。量测纪录:它对中文其实什麽也没做(Apple 只为六种拉丁语系语言备了
        // 校正模型),但它对英文有用,而且对中文没有任何副作用,所以留着。
        request.usesLanguageCorrection = true

        if avoidsGPU {
            for (stage, devices) in request.supportedComputeStageDevices {
                let device = devices.first { if case .neuralEngine = $0 { return true }; return false }
                    ?? devices.first { if case .cpu = $0 { return true }; return false }
                guard let device else {
                    throw OCRError.recognitionFailed(reason: "这台装置没有可用的非 GPU 文字辨识运算装置")
                }
                request.setComputeDevice(device, for: stage)
            }
        }

        let observations: [RecognizedTextObservation]
        do { observations = try await request.perform(on: image) }
        catch { throw OCRError.recognitionFailed(reason: "\(error)") }

        var lines: [OrderedLine] = []
        var heights: [Double] = []
        var lowConfidenceCount = 0

        for observation in observations {
            // 只跟第一个候选拿字。量测纪录:一旦把中文打开,就算跟它要 topCandidates(3),
            // Vision 也只会回一个候选,所以「多要几个候选再自己挑」这条路根本不存在。
            // 这也是 `observation.transcript` 的内容,但那个属性要 macOS 26 才有,而这个
            // 套件的最低版本是 macOS 15,所以一律走候选这条路。
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = Self.normalizeLine(candidate.string)
            guard !text.isEmpty else { continue }

            let box = observation.boundingBox

            // 字高要换算回「原始图片的点」。若这一趟跑的是放大过的影像,除了萤幕倍率之外还要
            // 再除掉放大倍数,否则字高会凭空翻倍,让本来该被判成信心不足的小字看起来突然合格,
            // 那正是最危险的那种误判。
            let pixels = Double(box.height) * Double(image.height)
            heights.append(pixels / (Self.assumedBackingScale * Double(upscaleFactor)))

            if candidate.confidence <= Self.lowConfidenceThreshold {
                lowConfidenceCount += 1
            }

            // Vision 的正规化座标以「左下角」为原点,人的阅读顺序以「左上角」为原点,这里一次
            // 把 y 轴翻过来,後面的排序就都不必再想这件事。
            let minX = Double(box.origin.x)
            let maxX = minX + Double(box.width)
            let topY = 1.0 - (Double(box.origin.y) + Double(box.height))
            lines.append(OrderedLine(text: text, minX: minX, maxX: maxX, topY: topY))
        }

        let ordered = Self.readingOrder(of: lines)
        return Pass(
            lines: ordered,
            medianPoints: Self.median(of: heights),
            lowConfidenceShare: lines.isEmpty ? 0 : Double(lowConfidenceCount) / Double(lines.count),
            characterCount: ordered.reduce(0) { $0 + $1.text.count }
        )
    }

    /// 把一趟结果组成对外的 `OCRResult`。
    fileprivate static func assemble(_ pass: Pass, image: CGImage, upscaleNote: String) -> OCRResult {
        let text = pass.lines.map(\.text).joined(separator: "\n")

        // 这张图大到本来就该有字吗?用来区分「白底空图」跟「有字但一个都没认出来」。
        let shorterSidePoints = Double(min(image.width, image.height)) / assumedBackingScale
        let textWasExpected = shorterSidePoints >= textExpectedShorterSidePoints

        // 信心不能照 Vision 回报的数字用。量测纪录:一旦把中文打开,Vision 只会吐出 0.3、0.5、
        // 1.0 这三个值,而且 topCandidates(3) 永远只回一个候选 —— 它根本没有在给我们一个连续的
        // 机率。所以这里改成从「结构」推:字够不够大、有多少区块连它自己都说没把握、以及一张
        // 够大的图里是不是一个字都没读到。
        //
        // 下游会拿 isLowConfidence 决定要不要把这笔内容挡下来、不给使用者当搜寻依据,所以两种
        // 误判的代价并不对等:误判成「不确定」只是少了一笔搜寻资料,误判成「有把握」却会让一段
        // 乱码被当成原文用掉。宁可偏向不确定。
        let isLowConfidence = pass.lines.isEmpty
            ? textWasExpected
            : (pass.medianPoints < lowConfidenceGlyphHeightPoints
                || pass.lowConfidenceShare > lowConfidenceShareLimit)

        var note = "这次辨识用的是 accurate 等级,语言顺序是繁体中文、简体中文、英文,"
            + "在 \(image.width)×\(image.height) 像素的图上读到 \(pass.lines.count) 行文字,"
            + "字高中位数是 \(String(format: "%.1f", pass.medianPoints)) 点。" + upscaleNote
        if pass.lines.isEmpty && !textWasExpected {
            note += "这张图小到本来就不预期有字,所以没有读到文字并不代表辨识失败。"
        }

        return OCRResult(
            text: text,
            lineCount: pass.lines.count,
            medianGlyphHeightPoints: pass.medianPoints,
            isLowConfidence: isLowConfidence,
            engineNote: note
        )
    }
}

// MARK: - 阅读顺序重建

extension OCRService {
    private static let leftMarginTolerance = 0.06   // 判定两段文字共用同一条左边界时允许的误差(占图宽的比例)
    private static let sameColumnOverlapRatio = 0.6 // 横向重叠到这个比例以上就算同一栏,用来收容置中与齐行排版
    private static let headingWidthMultiple = 1.5   // 一段文字比整栏宽这麽多倍以上时,只归栏不撑栏

    /// 累积中的一栏。
    private struct Column {
        let leftEdge: Double
        var minX: Double
        var maxX: Double
        var lines: [OrderedLine]
        var width: Double { maxX - minX }
    }

    /// 从版面座标把阅读顺序重建出来:先分栏,再在每一栏里由上往下读。
    ///
    /// 一定要先分栏。若单纯照 y 由上往下排,遇到「左边一条侧栏、右边一大片内文」的版面时,侧栏
    /// 的每一行都会插进内文的行与行之间,读出来是一段两边交错的乱码 —— 那种文字看起来「有字」,
    /// 搜寻却完全对不上,比读不到还糟。
    fileprivate static func readingOrder(of lines: [OrderedLine]) -> [OrderedLine] {
        guard lines.count > 1 else { return lines }

        var columns: [Column] = []
        for line in lines.sorted(by: { $0.minX < $1.minX }) {
            if let index = columns.firstIndex(where: { belongs(line, to: $0) }) {
                columns[index].lines.append(line)
                // 横跨整个版面的大标题会同时压到侧栏与内文之上。让它撑宽任何一栏,下一行侧栏文字
                // 就会被吸进内文那一栏,两栏从此黏成一团,所以宽度差太多时只归栏、不撑栏。
                if line.width <= columns[index].width * headingWidthMultiple {
                    columns[index].minX = min(columns[index].minX, line.minX)
                    columns[index].maxX = max(columns[index].maxX, line.maxX)
                }
            } else {
                columns.append(Column(leftEdge: line.minX, minX: line.minX, maxX: line.maxX, lines: [line]))
            }
        }

        // 栏由左到右,栏内由上到下;同一列上的两段文字则由左到右。
        return columns
            .sorted { $0.leftEdge < $1.leftEdge }
            .flatMap { column in
                column.lines.sorted { $0.topY == $1.topY ? $0.minX < $1.minX : $0.topY < $1.topY }
            }
    }

    /// 这一行属不属於这一栏。
    private static func belongs(_ line: OrderedLine, to column: Column) -> Bool {
        let overlap = min(column.maxX, line.maxX) - max(column.minX, line.minX)
        guard overlap > 0 else { return false }
        // 条件一:共用同一条左边界。这是最常见的情形,同一栏的文字几乎都是靠左对齐的。
        if abs(line.minX - column.leftEdge) <= leftMarginTolerance { return true }
        // 条件二:两者横向范围几乎重合,留给置中与齐行排版。比例用「较宽的那一边」当分母,
        // 才不会让一条窄侧栏被一行横跨全页的标题吸走。
        return overlap >= sameColumnOverlapRatio * max(column.width, line.width)
    }
}

// MARK: - 文字正规化与小工具

extension OCRService {
    /// 把一行辨识出来的文字整理成可以直接进搜寻索引的样子。
    ///
    /// 要做正规化是因为 OCR 吐出来的字宽度形式并不一致:同一份画面里可能同时出现全形的
    /// 「５００ｍｇ」与半形的「500mg」,带音标的字母有时是预先组合好的、有时是拆开的。不先统一,
    /// 存进去的字跟使用者打出来的字就长得不一样,搜寻会无声地失败;NFKC(相容分解後再组合)
    /// 正好把全形折成半形、把组合字接回去。空白只折叠「行内」的连续空白,不动行与行之间的
    /// 换行 —— 行的切分是上面辛苦重建出来的阅读顺序,把它一起折掉等於白做。
    fileprivate static func normalizeLine(_ raw: String) -> String {
        raw.precomposedStringWithCompatibilityMapping
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    /// 中位数。空阵列回传 0,呼叫端会把 0 视为「没有量到字高」。
    fileprivate static func median(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// 把图片放大整数倍。失败时回传 nil,呼叫端会安静地沿用原尺寸的结果。
    fileprivate static func upscaled(_ image: CGImage, factor: Int) -> CGImage? {
        let width = image.width * factor
        let height = image.height * factor
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        // 放大时用高品质插值。用最近邻会放出一格一格的锯齿,那对辨识引擎来说是杂讯而不是资讯。
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
