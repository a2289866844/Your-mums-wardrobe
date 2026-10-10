import Foundation

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
