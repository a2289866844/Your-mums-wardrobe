import AppKit

/// A transparent strip along the top of the screen that floats over every
/// app and every Space, including full screen, never takes focus, and lets clicks pass through
/// everywhere except over the photos.
final class LinePanel: NSPanel {
    static let overlayBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .transient, .ignoresCycle
    ]
    private var shelfVisible = false
    private var visibilityGeneration = 0

    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = Self.overlayBehavior
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        contentView = content
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// A tucked shelf should not keep a transparent surface in every Space.
    /// Visible panels retain their ordering when workspace notifications repeat.
    func setShelfVisible(_ visible: Bool, hideDelay: TimeInterval = 0.28) {
        guard shelfVisible != visible || (visible && !isVisible) else { return }
        shelfVisible = visible
        visibilityGeneration += 1
        if visible {
            if alphaValue != 1 { alphaValue = 1 }
            if !isVisible { orderFrontRegardless() }
        } else {
            let generation = visibilityGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + hideDelay) { [weak self] in
                guard let self, !self.shelfVisible, self.visibilityGeneration == generation else { return }
                self.orderOut(nil)
            }
        }
    }

    /// The line hangs on the screen you are using, which is the one with the
    /// pointer: that is where you just took the screenshot.
    static func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    func placeOnScreen(_ screen: NSScreen? = nil) {
        guard let screen = screen ?? LinePanel.screenUnderPointer() else { return }
        let visible = screen.visibleFrame
        // Keep the line below the menu bar even when full screen auto-hides it.
        let menuHeight = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top)
        let top = min(visible.maxY, screen.frame.maxY - menuHeight)
        let target = NSRect(x: visible.minX, y: top - Layout.panelHeight,
                            width: visible.width, height: Layout.panelHeight)
        if frame != target { setFrame(target, display: true) }
    }
}
