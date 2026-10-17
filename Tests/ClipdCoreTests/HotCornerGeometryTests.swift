import CoreGraphics
import Testing

import ClipdCore   // 这里刻意不用 @testable:被测的是公开 API,测试也应该只透过公开 API 验证。

// 这一整组验证的是「右上角热区」的座标数学。它没有画面、没有滑鼠,纯粹是几何,
// 却是整个热区功能里最容易算错、又最难在真机上重现的部分(边界该不该算进去、多萤幕各自的角落),
// 所以把它抽成纯函式并在这里逐个钉死。座标系是 AppKit 的左下角原点:上缘是 maxY、右缘是 maxX。

@Suite("右上角热区的几何判定")
struct HotCornerGeometryTests {

    /// 一台 1000×800、原点在 (0,0) 的萤幕,右上角就在 (1000, 800)。
    private let singleScreen = [CGRect(x: 0, y: 0, width: 1000, height: 800)]

    @Test("正好落在右上角那一点上,算命中")
    func exactCorner() {
        #expect(HotCornerGeometry.isInTopRightCorner(CGPoint(x: 1000, y: 800), threshold: 6, screenFrames: singleScreen))
    }

    @Test("在热区方块内(离角落不到 threshold)算命中")
    func justInside() {
        #expect(HotCornerGeometry.isInTopRightCorner(CGPoint(x: 997, y: 798), threshold: 6, screenFrames: singleScreen))
    }

    @Test("正好在 threshold 边界上,采闭区间,算命中")
    func onThresholdBoundary() {
        // 右缘允许区间是 [1000-6, 1000+6]=[994,1006];上缘是 [794,806]。取两条的内侧边界。
        #expect(HotCornerGeometry.isInTopRightCorner(CGPoint(x: 994, y: 794), threshold: 6, screenFrames: singleScreen))
    }

    @Test("横向差一点点就超出 threshold,不算命中")
    func justOutsideHorizontally() {
        #expect(!HotCornerGeometry.isInTopRightCorner(CGPoint(x: 993, y: 800), threshold: 6, screenFrames: singleScreen))
    }

    @Test("纵向差一点点就超出 threshold,不算命中")
    func justOutsideVertically() {
        #expect(!HotCornerGeometry.isInTopRightCorner(CGPoint(x: 1000, y: 793), threshold: 6, screenFrames: singleScreen))
    }

    @Test("游标略微越过萤幕右上角(在 +threshold 之内)仍算命中")
    func slightlyBeyondEdgeStillCounts() {
        // 游标偶尔会被系统回报成刚好压在或越过萤幕边缘,+threshold 那一侧要一起收进来才不会在角落漏接。
        #expect(HotCornerGeometry.isInTopRightCorner(CGPoint(x: 1006, y: 806), threshold: 6, screenFrames: singleScreen))
    }

    @Test("另外三个角落都不算右上角热区")
    func otherCornersAreNotHot() {
        let bottomLeft = CGPoint(x: 0, y: 0)
        let topLeft = CGPoint(x: 0, y: 800)
        let bottomRight = CGPoint(x: 1000, y: 0)
        #expect(!HotCornerGeometry.isInTopRightCorner(bottomLeft, threshold: 6, screenFrames: singleScreen))
        #expect(!HotCornerGeometry.isInTopRightCorner(topLeft, threshold: 6, screenFrames: singleScreen))
        #expect(!HotCornerGeometry.isInTopRightCorner(bottomRight, threshold: 6, screenFrames: singleScreen))
    }

    @Test("萤幕正中央离任何角落都很远,不算命中")
    func centerIsNotHot() {
        #expect(!HotCornerGeometry.isInTopRightCorner(CGPoint(x: 500, y: 400), threshold: 6, screenFrames: singleScreen))
    }

    @Test("多萤幕时,第二台萤幕的右上角同样算热区")
    func secondScreenCornerCounts() {
        // 第一台 1000×800 在左,第二台 1000×1000 接在它右边(原点 x=1000),右上角在 (2000, 1000)。
        let screens = [CGRect(x: 0, y: 0, width: 1000, height: 800),
                       CGRect(x: 1000, y: 0, width: 1000, height: 1000)]
        #expect(HotCornerGeometry.isInTopRightCorner(CGPoint(x: 1998, y: 998), threshold: 6, screenFrames: screens))
    }

    @Test("多萤幕排列里的桌面空档(不贴任何角落)不算命中")
    func gapBetweenScreensIsNotHot() {
        let screens = [CGRect(x: 0, y: 0, width: 1000, height: 800),
                       CGRect(x: 1000, y: 0, width: 1000, height: 1000)]
        // (1000, 400) 卡在两台交界的中段:离第一台角落 (1000,800) 纵向差 400,离第二台角落 (2000,1000) 更远。
        #expect(!HotCornerGeometry.isInTopRightCorner(CGPoint(x: 1000, y: 400), threshold: 6, screenFrames: screens))
    }

    @Test("完全没有萤幕时,永远不算命中")
    func noScreensNeverHot() {
        #expect(!HotCornerGeometry.isInTopRightCorner(CGPoint(x: 1000, y: 800), threshold: 6, screenFrames: []))
    }
}
