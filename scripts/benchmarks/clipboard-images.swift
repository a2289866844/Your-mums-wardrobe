import AppKit
import ImageIO
import Foundation

@main
struct ImageBenchmark {
    @MainActor
    static func main() async throws {
        var records: [[String: Any]] = []
        for (width, height) in [(1200, 900), (4000, 3000)] {
            let fixture = try makePNG(width: width, height: height)
            var mainSamples: [Double] = [], totalSamples: [Double] = []
            for _ in 0..<3 {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipline-benchmark-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let suite = "clipline-benchmark-" + UUID().uuidString
                let preferences = UserDefaults(suiteName: suite)!
                preferences.set(true, forKey: "soundOff")
                defer { preferences.removePersistentDomain(forName: suite) }
                let board = NSPasteboard.withUniqueName()
                defer { board.releaseGlobally() }
                let line = Line(defaults: preferences, clipboardFolder: directory, copyPasteboard: board)
                let watcher = ClipboardWatcher(pasteboard: board) { payload in
                    #if OPTIMIZED
                    return line.ingestClipboardInBackground(payload)
                    #else
                    return line.ingestClipboard(payload)
                    #endif
                }
                let item = NSPasteboardItem(); item.setData(fixture, forType: .png)
                board.clearContents(); precondition(board.writeObjects([item]))
                let start = ProcessInfo.processInfo.systemUptime
                watcher.poll()
                mainSamples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                #if OPTIMIZED
                await line.waitForClipboardPreparation()
                #endif
                totalSamples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                precondition(line.items.count == 1 && line.items[0].kind == .image)
                withExtendedLifetime(watcher) {}
            }
            records.append(["width": width, "height": height, "mainMilliseconds": mainSamples,
                            "completionMilliseconds": totalSamples, "pngBytes": fixture.count])
        }
        let data = try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys, .prettyPrinted])
        print(String(decoding: data, as: UTF8.self))
    }
    static func makePNG(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for stripe in 0..<100 {
            let fraction = CGFloat(stripe) / 100
            context.setFillColor(CGColor(colorSpace: colorSpace, components: [fraction, 0.4, 1 - fraction, 1])!)
            context.fill(CGRect(x: 0, y: CGFloat(height) * fraction,
                width: CGFloat(width), height: CGFloat(height) / 100 + 1))
        }
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
