// Original wardrobe icon: a mint paperclip holding a white snapshot on navy.
// Usage: swift scripts/make-icon.swift out.png
import AppKit

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let background = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
                              xRadius: 180, yRadius: 180)
NSColor(srgbRed: 0.06, green: 0.13, blue: 0.21, alpha: 1).setFill()
background.fill()
NSColor(srgbRed: 0.18, green: 0.42, blue: 0.51, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 226, y: 234, width: 596, height: 446),
             xRadius: 64, yRadius: 64).fill()
let photo = NSRect(x: 190, y: 286, width: 580, height: 420)
NSColor.white.setFill()
NSBezierPath(roundedRect: photo, xRadius: 54, yRadius: 54).fill()
NSColor(srgbRed: 0.72, green: 0.89, blue: 0.95, alpha: 1).setFill()
NSBezierPath(roundedRect: photo.insetBy(dx: 38, dy: 38), xRadius: 26, yRadius: 26).fill()
NSColor(srgbRed: 0.08, green: 0.52, blue: 0.58, alpha: 1).setFill()
let hills = NSBezierPath()
hills.move(to: NSPoint(x: 230, y: 326))
hills.line(to: NSPoint(x: 230, y: 400))
hills.line(to: NSPoint(x: 378, y: 540))
hills.line(to: NSPoint(x: 491, y: 430))
hills.line(to: NSPoint(x: 615, y: 558))
hills.line(to: NSPoint(x: 730, y: 452))
hills.line(to: NSPoint(x: 730, y: 326))
hills.close()
hills.fill()
NSColor(srgbRed: 1, green: 0.76, blue: 0.24, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 282, y: 570, width: 66, height: 66)).fill()
let clip = NSBezierPath()
clip.move(to: NSPoint(x: 650, y: 542))
clip.line(to: NSPoint(x: 650, y: 780))
clip.curve(to: NSPoint(x: 782, y: 780), controlPoint1: NSPoint(x: 650, y: 870),
           controlPoint2: NSPoint(x: 782, y: 870))
clip.line(to: NSPoint(x: 782, y: 584))
clip.curve(to: NSPoint(x: 710, y: 584), controlPoint1: NSPoint(x: 782, y: 524),
           controlPoint2: NSPoint(x: 710, y: 524))
clip.line(to: NSPoint(x: 710, y: 750))
clip.lineWidth = 32
clip.lineCapStyle = .round
clip.lineJoinStyle = .round
NSColor(srgbRed: 0.28, green: 0.91, blue: 0.72, alpha: 1).setStroke()
clip.stroke()
NSGraphicsContext.restoreGraphicsState()
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
