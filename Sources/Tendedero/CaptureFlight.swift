import AppKit
import QuartzCore

/// Reads where on screen a screenshot was taken. macOS stores the captured
/// area on the file, in global points with the origin at the top left of
/// the main display. Returned in AppKit screen coordinates.
func captureRect(of url: URL) -> CGRect? {
    let name = "com.apple.metadata:kMDItemScreenCaptureGlobalRect"
    let data: Data? = url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return nil }
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = Data(count: size)
        let read = buffer.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
        return read == size ? buffer : nil
    }
    guard let data,
          let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [NSNumber],
          let main = NSScreen.screens.first else { return nil }
    return captureRect(globalRect: values, mainDisplayTop: main.frame.maxY)
}

func captureRect(globalRect values: [NSNumber], mainDisplayTop: CGFloat) -> CGRect? {
    guard values.count == 4 else { return nil }
    let x = CGFloat(truncating: values[0]), y = CGFloat(truncating: values[1])
    let w = CGFloat(truncating: values[2]), h = CGFloat(truncating: values[3])
    guard x.isFinite, y.isFinite, w.isFinite, h.isFinite, mainDisplayTop.isFinite,
          w > 2, h > 2 else { return nil }
    return CGRect(x: x, y: mainDisplayTop - y - h, width: w, height: h)
}

/// A moving landing target starts a new segment at the current position.
/// Late shelf changes get a short settling interval instead of a final snap.
struct CaptureFlightPath {
    private var from: CGRect
    private var to: CGRect
    private var segmentStart: TimeInterval = 0
    private var segmentDuration: TimeInterval
    private var arc: CGFloat

    var deadline: TimeInterval { segmentStart + segmentDuration }

    init(from: CGRect, to: CGRect, duration: TimeInterval, arc: CGFloat = 30) {
        self.from = from
        self.to = to
        segmentDuration = duration
        self.arc = arc
    }

    mutating func retarget(to target: CGRect?, at elapsed: TimeInterval) {
        guard let target, target != to,
              target.origin.x.isFinite, target.origin.y.isFinite,
              target.width.isFinite, target.height.isFinite,
              target.width > 0, target.height > 0 else { return }
        let current = frame(at: elapsed)
        let remaining = deadline - elapsed
        from = current
        to = target
        segmentStart = elapsed
        segmentDuration = max(0.18, remaining)
        // The current rectangle already includes the original arc's height.
        arc = 0
    }

    func frame(at elapsed: TimeInterval) -> CGRect {
        let raw = max(0, min(1, (elapsed - segmentStart) / segmentDuration))
        let k = CGFloat(raw < 0.5 ? 4 * raw * raw * raw : 1 - pow(-2 * raw + 2, 3) / 2)
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * k }
        return CGRect(x: lerp(from.minX, to.minX),
                      y: lerp(from.minY, to.minY) + sin(.pi * k) * arc,
                      width: lerp(from.width, to.width), height: lerp(from.height, to.height))
    }
}

/// The capture lifting off the screen and flying up to the line. It turns
/// into the hanging card on the way: it shrinks, tilts into place and grows
/// its glass frame and clip, so there is nothing left to change on landing.
@MainActor
final class CaptureFlight {
    static let duration: CFTimeInterval = 0.65
    /// How high the gentle arc rises halfway, in points.
    private static let arc: CGFloat = 30

    private let window: NSWindow
    private let container = CALayer()
    private let glass = CALayer()
    private let edge = CAGradientLayer()
    private let edgeMask = CAShapeLayer()
    private let photo = CALayer()
    private let clip = CAGradientLayer()

    private let from: CGRect
    private let to: CGRect
    private let tilt: CGFloat
    private let frameInterval: TimeInterval
    private var path: CaptureFlightPath
    private var destinationProvider: (() -> CGRect?)?
    private var falling = false
    private var duration: CFTimeInterval = CaptureFlight.duration
    private var start: CFTimeInterval = 0
    private var timer: Timer?
    private var completion: () -> Void = {}

    private static var current: [CaptureFlight] = []

    /// - Parameters:
    ///   - from: the captured area, in screen coordinates.
    ///   - to: the card's frame on the line, in screen coordinates, unrotated.
    ///   - tilt: the card's resting tilt in degrees, clockwise, as SwiftUI uses.
    ///   - destination: the current card frame if the shelf changes during flight.
    static func fly(image: CGImage, from: CGRect, to: CGRect, tilt: CGFloat, on screen: NSScreen,
                    destination: (() -> CGRect?)? = nil,
                    completion: @escaping () -> Void) {
        let flight = CaptureFlight(image: image, from: from, to: to, tilt: tilt, screen: screen)
        flight.destinationProvider = destination
        current.append(flight)
        flight.completion = { [weak flight] in
            completion()
            current.removeAll { $0 === flight }
        }
        flight.run()
    }

    /// A discarded card falling off the line, drawn over the whole screen so
    /// it is never cut by the line's strip. Same motion as the app always had:
    /// 520 points down, tilting further, fading, 0.55 s ease in.
    static func fall(image: CGImage, card: CGRect, tilt: CGFloat, on screen: NSScreen) {
        let flight = CaptureFlight(image: image, from: card, to: card, tilt: tilt, screen: screen)
        flight.falling = true
        flight.duration = 0.55
        current.append(flight)
        flight.completion = { [weak flight] in current.removeAll { $0 === flight } }
        flight.run()
    }

    private init(image: CGImage, from: CGRect, to: CGRect, tilt: CGFloat, screen: NSScreen) {
        self.from = from
        self.to = to
        self.tilt = tilt
        path = CaptureFlightPath(from: from, to: to, duration: Self.duration, arc: Self.arc)
        let refreshRate = screen.maximumFramesPerSecond > 0 ? screen.maximumFramesPerSecond : 60
        frameInterval = 1.0 / Double(min(120, refreshRate))
        window = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.collectionBehavior = LinePanel.overlayBehavior

        let host = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        host.wantsLayer = true
        window.contentView = host
        let scale = screen.backingScaleFactor

        container.anchorPoint = CGPoint(x: 0.5, y: 1)   // the card's top center
        container.shadowColor = NSColor.black.cgColor
        container.shadowOpacity = 0.24
        container.shadowRadius = 10
        container.shadowOffset = CGSize(width: 0, height: -5)

        glass.backgroundColor = NSColor(white: 0.97, alpha: 0.72).cgColor
        edge.colors = [NSColor(white: 1, alpha: 0.9).cgColor, NSColor(white: 1, alpha: 0.25).cgColor]
        edge.startPoint = CGPoint(x: 0.5, y: 1); edge.endPoint = CGPoint(x: 0.5, y: 0)
        edgeMask.fillColor = nil
        edgeMask.strokeColor = NSColor.black.cgColor
        edgeMask.lineWidth = 1.5
        edge.mask = edgeMask

        photo.contents = image
        photo.contentsGravity = .resizeAspect
        photo.masksToBounds = true
        photo.contentsScale = scale

        clip.colors = [NSColor(white: 0.70, alpha: 1).cgColor, NSColor(white: 0.93, alpha: 1).cgColor,
                       NSColor(white: 0.82, alpha: 1).cgColor, NSColor(white: 0.62, alpha: 1).cgColor]
        clip.locations = [0, 0.35, 0.65, 1]
        clip.startPoint = CGPoint(x: 0, y: 0.5); clip.endPoint = CGPoint(x: 1, y: 0.5)
        clip.cornerRadius = 3.5
        clip.borderColor = NSColor(white: 1, alpha: 0.7).cgColor
        clip.borderWidth = 0.6

        for layer in [container, glass, edge, photo, clip] as [CALayer] { layer.contentsScale = scale }
        container.addSublayer(glass)
        container.addSublayer(photo)
        container.addSublayer(edge)
        container.addSublayer(clip)
        host.layer?.addSublayer(container)
    }

    private func run() {
        if falling { update(1); updateFall(0) } else { update(0) }
        window.orderFrontRegardless()
        start = CACurrentMediaTime()
        let timer = Timer(timeInterval: frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let elapsed = CACurrentMediaTime() - start
        let k = min(1, elapsed / duration)
        if falling {
            updateFall(k)
        } else {
            path.retarget(to: destinationProvider?(), at: elapsed)
            update(k, frame: path.frame(at: elapsed))
        }
        guard k >= 1, falling || elapsed >= path.deadline else { return }
        timer?.invalidate()
        timer = nil
        completion()
        if falling {
            window.orderOut(nil)
            return
        }
        // The real card fades in underneath; this one fades out over it.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            window.animator().alphaValue = 0
        }, completionHandler: { [window] in
            MainActor.assumeIsolated { window.orderOut(nil) }
        })
    }

    private func updateFall(_ raw: Double) {
        let e = CGFloat(raw * raw * raw)
        let origin = window.frame.origin
        let angle = tilt + (tilt * 7 + 20) * e
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.position = CGPoint(x: to.midX - origin.x, y: to.maxY - origin.y - 520 * e)
        container.setAffineTransform(CGAffineTransform(rotationAngle: -angle * .pi / 180))
        container.opacity = Float(1 - e)
        CATransaction.commit()
    }

    private static func easeInOutCubic(_ x: Double) -> Double {
        x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    private static func smooth(_ x: Double, _ a: Double, _ b: Double) -> Double {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    private func update(_ raw: Double, frame: CGRect? = nil) {
        let k = CGFloat(Self.easeInOutCubic(raw))
        let chrome = Float(Self.smooth(Double(k), 0.35, 1))
        let origin = window.frame.origin
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * k }

        let w = frame?.width ?? lerp(from.width, to.width)
        let h = frame?.height ?? lerp(from.height, to.height)
        let topX = (frame?.midX ?? lerp(from.midX, to.midX)) - origin.x
        let topY = (frame?.maxY ?? (lerp(from.maxY, to.maxY) + sin(.pi * k) * Self.arc)) - origin.y
        let inset = 4 * k
        let radius = lerp(0, 16)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        container.position = CGPoint(x: topX, y: topY)
        // SwiftUI tilts clockwise for positive angles; Core Animation the other way.
        container.setAffineTransform(CGAffineTransform(rotationAngle: -tilt * .pi / 180 * k))
        container.shadowPath = CGPath(roundedRect: container.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)

        glass.frame = container.bounds
        glass.cornerRadius = radius
        glass.opacity = chrome
        edge.frame = container.bounds
        edgeMask.path = CGPath(roundedRect: container.bounds.insetBy(dx: 0.75, dy: 0.75),
                               cornerWidth: max(0, radius - 0.75), cornerHeight: max(0, radius - 0.75), transform: nil)
        edge.opacity = chrome
        photo.frame = container.bounds.insetBy(dx: inset, dy: inset)
        photo.cornerRadius = max(0, radius - inset)
        // The clip grips the top edge: 26 points tall, 12 of them over the card.
        clip.frame = CGRect(x: w / 2 - 4.5, y: h - 12, width: 9, height: 26)
        clip.opacity = chrome
        CATransaction.commit()
    }
}
