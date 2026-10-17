import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ClipdCore

/// 这一组测试只涵盖「不需要真的截图系统就能验证」的那一半:延伸属性的读取,以及稳定闸门的判断。
///
/// 刻意不测 FSEventStream 与真正的截图流程。理由是那两件事在测试环境里既无法触发也无法重现 ——
/// 我们没办法在测试里叫使用者按下快门,也没办法保证 macOS 会在某个时限内把事件送来。硬要测的话
/// 只会得到一组随机失败的测试,那比没有测试更糟,因为它会训练所有人忽略红灯。
///
/// 每个案例都在自己的暂存资料夹里造档案,彼此不共用任何状态。
@Suite("截图的延伸属性与稳定闸门")
struct ScreenshotWatcherTests {

    // MARK: - 测试用的小工具

    /// 造一个只属於这个案例的暂存资料夹,并把清理动作交给呼叫端的 defer。
    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("clipd-screenshot-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 自己动手盖上 macOS 用来标记截图的那个延伸属性。
    ///
    /// 值的格式必须跟系统写的一模一样:一个内含单一布林的二进位属性清单。本机实测确认,
    /// `PropertyListSerialization` 用二进位格式序列化一个布林所产生的 42 个位元组,
    /// 跟真实截图上那个属性的位元组完全相同,所以这里造出来的是真品而不是仿冒品。
    private func markAsScreenCapture(_ url: URL, value: Bool = true) throws {
        let plist = try PropertyListSerialization.data(
            fromPropertyList: NSNumber(value: value), format: .binary, options: 0
        )
        try setAttribute(ScreenshotMetadata.isScreenCaptureKey, to: plist, on: url)
    }

    private func setAttribute(_ name: String, to data: Data, on url: URL) throws {
        let result = url.path.withCString { path in
            data.withUnsafeBytes { setxattr(path, name, $0.baseAddress, data.count, 0, 0) }
        }
        // 写不进去就不该继续往下断言,否则後面的失败会被误读成「读取逻辑坏掉」。
        try #require(result == 0, "无法在测试档案上写入延伸属性 \(name),errno 是 \(errno)。")
    }

    /// 造一张真的能被解码器读懂的小 PNG。
    private func writeRealPNG(to url: URL) throws {
        let context = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination), "测试用的 PNG 写不出来。")
    }

    // MARK: - 延伸属性:判断这是不是一张截图

    @Test("没有盖上截图印记的档案不会被当成截图")
    func 没有印记的档案不是截图() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 档名刻意取成跟真实截图一样的繁体中文样式,用来证明判断完全不看档名。
        // 这台机器的系统语言是繁体中文,真实截图就叫「截圖 2026-07-25 14.44.14.png」;
        // 如果哪天有人把判断逻辑改回比对档名,这个案例就会立刻变红。
        let file = directory.appendingPathComponent("截圖 2026-07-25 14.44.14.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: file)

        #expect(ScreenshotMetadata.isScreenCapture(atPath: file.path) == false)
    }

    @Test("自己盖上截图印记之後就会被认出来,而且跟档名完全无关")
    func 盖上印记的档案会被认出来() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 档名取一个完全看不出是截图的名字,证明认出它的是那个延伸属性而不是档名。
        let file = directory.appendingPathComponent("完全看不出来是截图的名字.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: file)
        try markAsScreenCapture(file)

        #expect(ScreenshotMetadata.isScreenCapture(atPath: file.path))
    }

    @Test("印记的值是 false 时不算截图,有属性不等於是截图")
    func 印记为false时不是截图() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("shot.png")
        try Data([0x89]).write(to: file)
        try markAsScreenCapture(file, value: false)

        // 这一关不能只检查「属性存不存在」,必须真的把里面的布林读出来。
        #expect(ScreenshotMetadata.isScreenCapture(atPath: file.path) == false)
    }

    @Test("印记的内容不是属性清单时要安静地判定为不是截图,不能崩溃")
    func 印记内容损坏时不是截图() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("shot.png")
        try Data([0x89]).write(to: file)
        try setAttribute(
            ScreenshotMetadata.isScreenCaptureKey,
            to: Data("这不是一份属性清单".utf8),
            on: file
        )

        #expect(ScreenshotMetadata.isScreenCapture(atPath: file.path) == false)
    }

    @Test("对不存在的档案问「是不是截图」要回答不是,而不是崩溃")
    func 档案不存在时不是截图() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("从来没有存在过.png")

        // 这个情况在正式流程里真的会发生:使用者可能在我们验证的空档就把截图删掉了。
        #expect(ScreenshotMetadata.isScreenCapture(atPath: missing.path) == false)
        #expect(ScreenshotMetadata.rawAttribute(ScreenshotMetadata.isScreenCaptureKey, atPath: missing.path) == nil)
    }

    @Test("姊妹属性读得回字串,真实截图上它的值是 selection 或 display 这类字眼")
    func 截图方式读得回字串() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("shot.png")
        try Data([0x89]).write(to: file)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: "selection" as NSString, format: .binary, options: 0
        )
        try setAttribute(ScreenshotMetadata.captureTypeKey, to: plist, on: file)

        #expect(ScreenshotMetadata.captureType(atPath: file.path) == "selection")
        // 没盖这个属性的档案要回传 nil,而不是空字串 —— 呼叫端才分得出「没写」跟「写了空的」。
        let bare = directory.appendingPathComponent("bare.png")
        try Data([0x89]).write(to: bare)
        #expect(ScreenshotMetadata.captureType(atPath: bare.path) == nil)
    }

    // MARK: - 档案指纹

    @Test("档案指纹抓得到大小,档案不存在时回传 nil 而不是零")
    func 指纹在档案不存在时是nil() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("shot.png")
        try Data(repeating: 0x41, count: 1234).write(to: file)

        let fingerprint = try #require(FileFingerprint(path: file.path))
        #expect(fingerprint.size == 1234)

        // nil 跟「大小是零」是两件完全不同的事:前者是「还判断不出来」,後者是「确定是空档」。
        // 混为一谈的话,一个还没开始写的档案会被误判成已经稳定下来的空档。
        #expect(FileFingerprint(path: directory.appendingPathComponent("没有这个档").path) == nil)
    }

    // MARK: - 稳定闸门

    @Test("第一次取样没有前一次可以比,裁决必须是还在变动")
    func 第一次取样视为还在变动() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("shot.png")
        try Data(repeating: 0x41, count: 10).write(to: file)

        let first = FileFingerprint(path: file.path)
        // 只看过一眼就宣布稳定,等於完全没有闸门。第一次取样只能用来当下一次的比较基准。
        #expect(ScreenshotMetadata.verdict(previous: nil, current: first) == .stillChanging)
    }

    @Test("档案还在长大时,两次取样不一样,裁决必须是还在变动")
    func 档案还在长大时还在变动() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("shot.png")
        try Data(repeating: 0x41, count: 100).write(to: file)

        let before = FileFingerprint(path: file.path)
        // 模拟截图还在往磁碟上写的中间状态 —— 这正是「快门响了但档案还没长好」的那一段。
        try Data(repeating: 0x42, count: 5000).write(to: file)
        let after = FileFingerprint(path: file.path)

        #expect(before != after)
        #expect(ScreenshotMetadata.verdict(previous: before, current: after) == .stillChanging)
    }

    @Test("两次取样的大小与修改时间一模一样时,裁决才是安定")
    func 两次取样相同才算安定() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("shot.png")
        try Data(repeating: 0x41, count: 2048).write(to: file)

        // 两次取样之间没有任何人动这个档案,这正是「已经写完了」的样子。
        let first = FileFingerprint(path: file.path)
        let second = FileFingerprint(path: file.path)

        #expect(ScreenshotMetadata.verdict(previous: first, current: second) == .settled)
    }

    @Test("档案在两次取样之间被删掉时,裁决是不见了,不能误判成安定")
    func 档案被删掉时是不见了() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("shot.png")
        try Data(repeating: 0x41, count: 64).write(to: file)

        let before = FileFingerprint(path: file.path)
        try FileManager.default.removeItem(at: file)
        let after = FileFingerprint(path: file.path)

        // 使用者截完图马上把它拖进垃圾桶是很正常的操作,不是错误状况,
        // 但绝对不能因为「读不到就当没变」而把一个已经消失的档案判成安定。
        #expect(after == nil)
        #expect(ScreenshotMetadata.verdict(previous: before, current: after) == .missing)
    }

    // MARK: - 影像完整性

    @Test("完整的 PNG 会通过影像完整性检查")
    func 完整的png会通过() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("whole.png")
        try writeRealPNG(to: file)

        #expect(ScreenshotMetadata.isImageReadable(at: file))
    }

    @Test("零位元组的佔位档不会通过影像完整性检查")
    func 零位元组档案不会通过() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("placeholder.png")
        try Data().write(to: file)

        // 这正是这一关唯一真正挡得住的东西。本机实测:零位元组档案的状态码是 -4;
        // 而一张被截断到只剩一成的真实截图,状态码仍然是 0(完整)。也就是说这一关抓不到
        // 「写到一半」,真正挡住半成品的是前面那道大小与修改时间的稳定闸门。
        // 谁要是哪天想拿这一关取代稳定闸门,请先回来看这段话。
        #expect(ScreenshotMetadata.isImageReadable(at: file) == false)
    }

    @Test("根本不是影像的档案不会通过影像完整性检查")
    func 不是影像的档案不会通过() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("junk.png")
        try Data("这只是一段纯文字,不是影像。".utf8).write(to: file)

        #expect(ScreenshotMetadata.isImageReadable(at: file) == false)
    }

    @Test("不存在的档案不会通过影像完整性检查")
    func 不存在的档案不会通过() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(ScreenshotMetadata.isImageReadable(at: directory.appendingPathComponent("没有.png")) == false)
    }

    // MARK: - 快门时间

    @Test("拿得到快门时间,而且落在合理范围内不会是遥远的过去或未来")
    func 快门时间落在合理范围() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("shot.png")
        let before = Date()
        try writeRealPNG(to: file)
        let after = Date()

        // 暂存资料夹的档案通常没有 Spotlight 中继资料,所以这里走的是档案建立时间那条後路 ——
        // 正好可以验证那条後路真的有效。刻意只断言范围而不断言精确值:真正的截图在正式流程里
        // 会晚 5 到 79 秒才落地,精确值本来就不是这个函式该保证的东西。
        let takenAt = ScreenshotMetadata.takenAt(for: file)
        #expect(takenAt >= before.addingTimeInterval(-1))
        #expect(takenAt <= after.addingTimeInterval(1))
    }

    // MARK: - 监看位置

    @Test("监看位置一定是一个存在的资料夹,读不到偏好设定时退回桌面")
    func 监看位置永远是存在的资料夹() {
        // 本机实测 com.apple.screencapture 的 location 键目前没有设定过,所以这里走的是桌面预设值。
        // 使用者随时可以改掉那个设定,所以这个案例只断言「结果是一个真的存在的资料夹」这件不变量,
        // 而不去断言它一定等於桌面 —— 後者会在任何改过截图位置的机器上无谓地失败。
        let watcher = ScreenshotWatcher()
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: watcher.watchedDirectory.path, isDirectory: &isDirectory
        )
        #expect(exists)
        #expect(isDirectory.boolValue)
        #expect(watcher.isRunning == false)
    }
}
