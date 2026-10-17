import CoreGraphics

/// 右上角热区的纯几何判定。
///
/// 抽到 Core 层、而且只吃 CGRect 与 CGPoint(不碰 NSScreen、不碰 AppKit),是为了让它可以被单元测试:
/// 测试不必真的去接一台萤幕,给几个矩形就能验证判定逻辑,而这段座标数学(尤其是多萤幕、边界该不该
/// 算进去)正是整个热区功能里最容易算错、又最难在真机上重现的部分。
public enum HotCornerGeometry {

    /// 判断一个座标是否落在任何一台萤幕(以其 frame 表示)的右上角热区里。
    ///
    /// 座标系是 AppKit 的左下角原点,所以「上缘」是 maxY、「右缘」是 maxX。热区是以右上角为中心、
    /// 边长 2×threshold 的一个方块:游标只要落在离某台萤幕右上角 threshold 之内就算数。
    /// 多萤幕时,任何一台萤幕的右上角都算(每台各自都有一个角落,跟 macOS 内建的「热点角落」一致)。
    ///
    /// - Parameters:
    ///   - point: 要判断的座标,通常是 `NSEvent.mouseLocation`。
    ///   - threshold: 热区的半径(点)。越大越容易命中、也越容易误触。
    ///   - screenFrames: 每一台萤幕的 frame。呼叫端通常传 `NSScreen.screens.map(\.frame)`。
    public static func isInTopRightCorner(
        _ point: CGPoint,
        threshold: CGFloat,
        screenFrames: [CGRect]
    ) -> Bool {
        for frame in screenFrames {
            let nearRight = point.x >= frame.maxX - threshold && point.x <= frame.maxX + threshold
            let nearTop = point.y >= frame.maxY - threshold && point.y <= frame.maxY + threshold
            if nearRight && nearTop { return true }
        }
        return false
    }
}
