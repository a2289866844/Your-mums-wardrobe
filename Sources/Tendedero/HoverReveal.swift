import Foundation

/// A small top-center entrance, independent of the larger keep-open region.
enum HoverTrigger {
    static func region(on screen: CGRect, menuBarHeight: CGFloat,
                       topLeftArea: CGRect? = nil, topRightArea: CGRect? = nil) -> CGRect {
        let fallbackWidth = min(180, screen.width)
        var minX = screen.midX - fallbackWidth / 2
        var maxX = minX + fallbackWidth
        if let left = topLeftArea, let right = topRightArea {
            let gap = right.minX - left.maxX
            // The auxiliary areas flank a real camera housing. Ignore missing
            // or inconsistent geometry instead of turning the whole bar hot.
            if gap > 0, gap <= screen.width / 3,
               left.maxX >= screen.minX, right.minX <= screen.maxX,
               left.maxX <= screen.midX, right.minX >= screen.midX {
                minX = left.maxX
                maxX = right.minX
            }
        }
        // A small lip below the menu bar makes the notch easy to reach.
        let height = min(screen.height, max(1, menuBarHeight) + 6)
        return CGRect(x: minX, y: screen.maxY - height, width: maxX - minX, height: height)
    }

    static func contains(_ pointer: CGPoint, in region: CGRect) -> Bool {
        pointer.x >= region.minX && pointer.x < region.maxX
            && pointer.y >= region.minY && pointer.y <= region.maxY
    }
}

/// A hover reveal stays open anywhere in the upper third of its display.
/// Other reveal modes do not inherit this pointer-based dismissal rule.
struct HoverReveal {
    private var region: CGRect?

    var isActive: Bool { region != nil }

    mutating func start(on screen: CGRect) {
        let height = screen.height / 3
        region = CGRect(x: screen.minX, y: screen.maxY - height, width: screen.width, height: height)
    }

    mutating func cancel() { region = nil }

    mutating func shouldRetract(pointer: CGPoint) -> Bool {
        guard let region else { return false }
        // AppKit can report a pointer pushed against the display's top edge
        // at exactly maxY. CGRect.contains excludes that edge, which would
        // immediately close a line opened by the same top-edge hot zone.
        let inside = pointer.x >= region.minX && pointer.x < region.maxX
            && pointer.y >= region.minY && pointer.y <= region.maxY
        guard !inside else { return false }
        self.region = nil
        return true
    }
}
