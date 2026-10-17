#!/bin/bash
# Build a native fixture host. This does not launch it or change TCC/settings.
# CLIPLINE_PERFORMANCE_DEMO=1 enables isolated capture/library fixtures, 120 mixed
# records, and native Reset performance / Start benchmark controls. Main-runloop
# heartbeat lateness is a responsiveness proxy, not a frame-rate or input-latency metric.
# CLIPLINE_FIXTURE_SOURCE_DIR can select a saved Tendedero source snapshot; use
# CLIPLINE_PREBUILT_BIN to link existing ClipdCore objects without invoking SwiftPM.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$PWD"
APP="${1:-$ROOT/build/wardrobe Verification.app}"
mkdir -p "$ROOT/build"
if [[ -e "$APP" ]]; then
  echo "Verification app already exists; retain it or move it before rebuilding." >&2
  exit 2
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
RUNTIME="$(mktemp -d "$ROOT/build/verification-runtime.XXXXXX")"
SUITE="io.github.a2289866844.clipline.verification.$(uuidgen | tr '[:upper:]' '[:lower:]')"
mkdir -p "$RUNTIME/Screenshots" "$RUNTIME/Clipboard"
cat > "$WORK/main.swift" <<'SWIFT'
import AppKit
import ClipdCore

@MainActor
final class CopyDemoAction: NSObject {
    var run: () -> Void = {}
    var copyFixture: () -> Void = {}
    var createScreenshot: () -> Void = {}
    var resetPerformance: () -> Void = {}
    var startBenchmark: () -> Void = {}
    @objc func showCards() { run() }
    @objc func copyFixtureText() { copyFixture() }
    @objc func addScreenshot() { createScreenshot() }
    @objc func resetProbe() { resetPerformance() }
    @objc func benchmark() { startBenchmark() }
}

// Fixture-only timing proxy. Sampling stays in memory; JSON writes happen once a second.
@MainActor
final class PerformanceProbe {
    private var samples: [Double] = []
    private var previous = ProcessInfo.processInfo.systemUptime
    private var started = Date()
    private var timer: Timer?
    private var writer: Timer?
    private let destination: URL
    var phase = "idle"
    var switches = 0
    init(runtime: URL) {
        destination = runtime.appendingPathComponent("performance.json")
        let heartbeat = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase != "complete" else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.samples.append(max(0, (now - self.previous - 0.01) * 1000))
                self.previous = now
            }
        }
        RunLoop.main.add(heartbeat, forMode: .common)
        timer = heartbeat
        let output = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self, self.phase != "complete" { self.write() }
            }
        }
        RunLoop.main.add(output, forMode: .common)
        writer = output
    }
    func reset(phase: String = "manual") {
        samples.removeAll(keepingCapacity: true)
        started = Date()
        previous = ProcessInfo.processInfo.systemUptime
        switches = 0
        self.phase = phase
        write()
    }
    func write() {
        let sorted = samples.sorted()
        func percentile(_ fraction: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
        }
        let result: [String: Any] = ["phase": phase, "switches": switches,
            "startedAt": started.timeIntervalSince1970, "timestamp": Date().timeIntervalSince1970,
            "durationSeconds": Date().timeIntervalSince(started), "sampleCount": sorted.count,
            "intervalMilliseconds": 10, "p50LatenessMilliseconds": percentile(0.5),
            "p95LatenessMilliseconds": percentile(0.95), "p99LatenessMilliseconds": percentile(0.99),
            "maxLatenessMilliseconds": sorted.last ?? 0,
            "over50Milliseconds": sorted.filter { $0 > 50 }.count,
            "over100Milliseconds": sorted.filter { $0 > 100 }.count,
            "metric": "max(0, actual heartbeat spacing - 10ms); main runloop common modes",
            "workload": "120 mixed records; 20 page switches at 350ms; 10 older then 10 newer"]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]) {
            try? data.write(to: destination, options: .atomic)
            if phase == "complete" {
                try? data.write(to: destination.deletingLastPathComponent().appendingPathComponent("benchmark-result.json"), options: .atomic)
            }
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let resource = Bundle.main.url(forResource: "Runtime", withExtension: "plist")!
    let configuration = NSDictionary(contentsOf: resource)!
    let runtime = URL(fileURLWithPath: configuration["folder"] as! String, isDirectory: true)
    let suite = configuration["suite"] as! String
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(true, forKey: "soundOff")
    defaults.set(true, forKey: "welcomed")
    let performanceDemo = configuration["performanceDemo"] as? Bool ?? false
    let copyDemo = configuration["copyDemo"] as? Bool ?? false
    let captureDemo = configuration["captureDemo"] as? Bool ?? false
    defaults.set(captureDemo, forKey: "clipboardEnabled")
    let copyBoard = (copyDemo || captureDemo) ? NSPasteboard(name: .init(suite + ".copy-demo")) : .general
    let line = Line(defaults: defaults, clipboardFolder: runtime.appendingPathComponent("Clipboard", isDirectory: true), copyPasteboard: copyBoard)
    var library: ClipdLibrary?
    if configuration["libraryDemo"] as? Bool == true {
        let archive = runtime.appendingPathComponent("Archive")
        let store = try! Store(directory: archive)
        for index in 1...(performanceDemo ? 120 : 14) {
            let text = "Clipd 歷史第 \(index) 筆\n" + String(repeating: "完整內容與中文搜尋：烏龍茶 \(index)。\n", count: 45)
            var representations = [ItemRepresentation(uti: "public.utf8-plain-text", byteCount: text.utf8.count, inlineText: text)]
            let imageRecord = performanceDemo && index % 3 == 0
            if imageRecord {
                let image = NSImage(size: NSSize(width: 900, height: 600))
                image.lockFocus()
                NSColor(calibratedHue: CGFloat(index % 40) / 40, saturation: 0.6, brightness: 0.85, alpha: 1).setFill()
                NSRect(x: 0, y: 0, width: 900, height: 600).fill()
                ("Fixture image \(index)" as NSString).draw(at: NSPoint(x: 70, y: 270), withAttributes: [.font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.white])
                image.unlockFocus()
                let data = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
                let blob = "blobs/fixture-\(index).png"
                try! FileManager.default.createDirectory(at: archive.appendingPathComponent("blobs"), withIntermediateDirectories: true)
                try! data.write(to: archive.appendingPathComponent(blob))
                representations = [ItemRepresentation(uti: "public.png", byteCount: data.count, blobPath: blob)]
            }
            let record = ClipItem(id: makeItemID(), kind: imageRecord ? .image : .text, capturedAt: Date().addingTimeInterval(Double(index - 200)),
                contentHash: ClipboardStore.digest(Data(text.utf8)), preview: "Clipd 歷史第 \(index) 筆", searchText: text,
                sourceBundleID: "test.editor", sourceAppName: "文字編輯", isPinned: index == 3,
                representations: representations)
            try! store.insert(record)
        }
        library = try! ClipdLibrary(directory: archive, store: store, cacheDirectory: runtime.appendingPathComponent("Clipboard"))
    }
    let delegate = AppDelegate(line: line, screenshotFolder: runtime.appendingPathComponent("Screenshots", isDirectory: true), defaults: defaults, library: library, capturePasteboard: copyBoard)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    let demoAction = CopyDemoAction()
    var demoWindow: NSWindow?
    var telemetryTimer: Timer?
    let performance = performanceDemo ? PerformanceProbe(runtime: runtime) : nil
    var benchmarkTimer: Timer?
    if copyDemo || captureDemo {
        let fullText = "Copy in one click\n" + String(repeating: "The full text is copied, including content beyond this preview.\n", count: 20)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: captureDemo ? 300 : 260, height: performanceDemo ? 280 : (captureDemo ? 180 : 100)),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = captureDemo ? "Capture verification" : "Copy verification"
        window.identifier = .init("clipline-verification-controls")
        window.isReleasedWhenClosed = false
        let show = NSButton(title: "Show cards", target: demoAction, action: #selector(CopyDemoAction.showCards))
        show.identifier = .init("show-cards")
        show.setAccessibilityIdentifier("show-cards")
        show.frame = NSRect(x: 60, y: captureDemo ? 24 : 32, width: captureDemo ? 180 : 140, height: 32)
        show.bezelStyle = .rounded
        window.contentView?.addSubview(show)
        demoAction.run = {
            if line.revealed { delegate.perform(NSSelectorFromString("toggle")) }
            delegate.perform(NSSelectorFromString("toggle"))
            if captureDemo && !performanceDemo {
                _ = delegate.applicationShouldHandleReopen(app, hasVisibleWindows: true)
            }
            if !captureDemo { window.orderOut(nil) }
        }
        if captureDemo {
            let copy = NSButton(title: "Copy fixture text", target: demoAction, action: #selector(CopyDemoAction.copyFixtureText))
            copy.identifier = .init("copy-fixture-text")
            copy.setAccessibilityIdentifier("copy-fixture-text")
            copy.frame = NSRect(x: 60, y: 116, width: 180, height: 32)
            copy.bezelStyle = .rounded
            window.contentView?.addSubview(copy)
            demoAction.copyFixture = {
                copyBoard.clearContents()
                let success = copyBoard.setString(fullText, forType: .string)
                let result: [String: Any] = ["action": "copy-fixture-text", "success": success,
                                           "timestamp": Date().timeIntervalSince1970]
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                    try? data.write(to: runtime.appendingPathComponent("capture-action.json"), options: .atomic)
                }
            }
            let screenshot = NSButton(title: "Create screenshot", target: demoAction, action: #selector(CopyDemoAction.addScreenshot))
            screenshot.identifier = .init("create-screenshot")
            screenshot.setAccessibilityIdentifier("create-screenshot")
            screenshot.frame = NSRect(x: 60, y: 70, width: 180, height: 32)
            screenshot.bezelStyle = .rounded
            window.contentView?.addSubview(screenshot)
            demoAction.createScreenshot = {
                let destination = runtime.appendingPathComponent("Screenshots/Fixture-\(UUID().uuidString).png")
                var success = false
                if let icon = Bundle.main.url(forResource: "wardrobe", withExtension: "png"),
                   let data = try? Data(contentsOf: icon) {
                    success = (try? data.write(to: destination, options: .atomic)) != nil
                }
                let result: [String: Any] = ["action": "create-screenshot", "success": success,
                                           "file": destination.lastPathComponent, "timestamp": Date().timeIntervalSince1970]
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                    try? data.write(to: runtime.appendingPathComponent("capture-action.json"), options: .atomic)
                }
            }
            let timer = Timer(timeInterval: 0.2, repeats: true) { _ in
                MainActor.assumeIsolated {
                    // Read fixture geometry only. Production state remains private.
                    let children = Mirror(reflecting: delegate).children
                    let panelValue = children.first { $0.label == "panel" }?.value
                    let panel = panelValue.flatMap { value in
                        (value as? LinePanel) ?? (Mirror(reflecting: value).children.first?.value as? LinePanel)
                    }
                    func unwrap(_ value: Any?) -> Any? {
                        guard let value else { return nil }
                        let mirror = Mirror(reflecting: value)
                        return mirror.displayStyle == .optional ? mirror.children.first?.value : value
                    }
                    let watcher = unwrap(Mirror(reflecting: delegate).children.first { $0.label == "watcher" }?.value)
                    let watcherChildren = watcher.map { Mirror(reflecting: $0).children }
                    let watcherFolder = watcherChildren?.first { $0.label == "folder" }?.value as? URL
                    let watcherActive = watcherChildren?.first { $0.label == "active" }?.value as? Bool ?? false
                    let watcherSource = unwrap(watcherChildren?.first { $0.label == "source" }?.value)
                    func rect(_ value: NSRect) -> [String: Double] {
                        ["x": value.minX, "y": value.minY, "width": value.width, "height": value.height]
                    }
                    let pointer = NSEvent.mouseLocation
                    var result: [String: Any] = [
                        "timestamp": Date().timeIntervalSince1970,
                        "revealed": line.revealed, "itemCount": line.items.count,
                        "visibleCount": line.visibleItems.count, "hitRectCount": line.hitRects.count,
                        "preparedImageCount": line.items.filter { $0.kind == .image && $0.thumbnailPrepared }.count,
                        "visibleImagesReady": line.visibleItems.filter { $0.kind == .image }.allSatisfy(\.thumbnailPrepared),
                        "pointerMonitorCount": (children.first { $0.label == "pointerMonitors" }?.value as? [Any])?.count ?? -1,
                        "hasDeadlineTimer": unwrap(children.first { $0.label == "deadlineTimer" }?.value) != nil,
                        "clipboardEnabled": defaults.bool(forKey: "clipboardEnabled"),
                        "screenshotWatcher": ["present": watcher != nil, "active": watcherActive,
                                              "folder": watcherFolder?.path ?? "", "sourceAttached": watcherSource != nil] as [String: Any],
                        "items": line.items.map { ["id": $0.id.uuidString, "kind": $0.kind.rawValue,
                                                   "file": $0.url.lastPathComponent, "flying": $0.flying] as [String: Any] },
                        "hitRects": line.hitRects.map { ["id": $0.key.uuidString, "frame": rect($0.value)] as [String: Any] },
                        "pointer": ["x": pointer.x, "y": pointer.y],
                        "pasteboardChangeCount": copyBoard.changeCount,
                        "pasteboardTypes": (copyBoard.types ?? []).map(\.rawValue),
                        "copied": line.copiedID != nil, "failed": line.copyFailedID != nil
                    ]
                    if let panel {
                        result["panelFrame"] = rect(panel.frame)
                        result["ignoresMouseEvents"] = panel.ignoresMouseEvents
                        result["panelVisible"] = panel.isVisible
                    }
                    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                        try? data.write(to: runtime.appendingPathComponent("capture-state.json"), options: .atomic)
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            telemetryTimer = timer
        }
        if let performance {
            let reset = NSButton(title: "Reset performance", target: demoAction, action: #selector(CopyDemoAction.resetProbe))
            reset.frame = NSRect(x: 60, y: 208, width: 180, height: 32)
            reset.bezelStyle = .rounded
            reset.setAccessibilityIdentifier("reset-performance")
            window.contentView?.addSubview(reset)
            let start = NSButton(title: "Start benchmark", target: demoAction, action: #selector(CopyDemoAction.benchmark))
            start.frame = NSRect(x: 60, y: 246, width: 180, height: 32)
            start.bezelStyle = .rounded
            start.setAccessibilityIdentifier("start-benchmark")
            window.contentView?.addSubview(start)
            demoAction.resetPerformance = {
                benchmarkTimer?.invalidate()
                benchmarkTimer = nil
                performance.reset()
            }
            demoAction.startBenchmark = {
                benchmarkTimer?.invalidate()
                demoAction.run()
                if line.canNavigate {
                    for _ in 0..<120 where line.hasNewerPage { line.showNewerPage() }
                }
                performance.reset(phase: "benchmark")
                let timer = Timer(timeInterval: 0.35, repeats: true) { timer in
                    MainActor.assumeIsolated {
                        if performance.switches < 10 { line.showOlderPage() }
                        else if performance.switches < 20 { line.showNewerPage() }
                        else {
                            timer.invalidate()
                            performance.phase = "complete"
                            performance.write()
                            return
                        }
                        performance.switches += 1
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                benchmarkTimer = timer
            }
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        demoWindow = window
        app.setActivationPolicy(.regular)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let showFeedback = line.onCopyFeedback
            line.onCopyFeedback = {
                showFeedback?()
                var result: [String: Any] = ["copied": line.copiedID != nil, "failed": line.copyFailedID != nil,
                                           "hasPNG": copyBoard.data(forType: .png) != nil,
                                           "hasOwnCopyMarker": (copyBoard.types ?? []).contains(ClipboardWatcher.ownCopyType),
                                           "matchesFullFixtureText": copyBoard.string(forType: .string) == fullText,
                                           "pasteboardTypes": (copyBoard.types ?? []).map(\.rawValue)]
                for type in [NSPasteboard.PasteboardType.string, .URL, .fileURL] {
                    if let value = copyBoard.string(forType: type) { result[type.rawValue] = value }
                }
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                    try? data.write(to: runtime.appendingPathComponent("copy-result.json"), options: .atomic)
                }
            }
            guard !captureDemo else { return }
            _ = line.ingestClipboard(.text(fullText))
            _ = line.ingestClipboard(.link(URL(string: "https://example.com/copy-demo")!))
            let file = runtime.appendingPathComponent("Example.txt")
            try? Data("A synthetic file for Copy verification.\n".utf8).write(to: file)
            _ = line.ingestClipboard(.files([file]))
            if let icon = Bundle.main.url(forResource: "wardrobe", withExtension: "png"),
               let data = try? Data(contentsOf: icon) { _ = line.ingestClipboard(.image(data)) }
            if configuration["historyDemo"] as? Bool == true {
                for index in 1...14 {
                    _ = line.ingestClipboard(.text("History item \(index)\n" + String(repeating: "Full editable text for item \(index).\n", count: 32)))
                }
            }
        }
    }
    withExtendedLifetime((delegate, demoWindow, demoAction, telemetryTimer, performance, benchmarkTimer)) { app.run() }
}
SWIFT
SOURCES=()
SOURCE_DIR="${CLIPLINE_FIXTURE_SOURCE_DIR:-$ROOT/Sources/Tendedero}"
for source in "$SOURCE_DIR"/*.swift; do
  [[ "$(basename "$source")" == "main.swift" ]] || SOURCES+=("$source")
done
if [[ -n "${CLIPLINE_PREBUILT_BIN:-}" ]]; then
  BIN="$CLIPLINE_PREBUILT_BIN"
else
  swift build -c debug >/dev/null
  BIN="$(swift build -c debug --show-bin-path)"
fi
xcrun swiftc -O -module-name Tendedero -target "$(uname -m)-apple-macosx15.0" \
  -I "$BIN/Modules" -F "$BIN" -framework SQLCipher \
  -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
  "$BIN"/ClipdCore.build/*.o "${SOURCES[@]}" "$WORK/main.swift" -o "$WORK/wardrobeVerification"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN/SQLCipher.framework" "$APP/Contents/Frameworks/SQLCipher.framework"
cp "$WORK/wardrobeVerification" "$APP/Contents/MacOS/wardrobeVerification"
cp docs/clipline-icon.png "$APP/Contents/Resources/wardrobe.png"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>wardrobeVerification</string>
<key>CFBundleIdentifier</key><string>io.github.a2289866844.clipline.verification</string>
<key>CFBundleName</key><string>wardrobe Verification</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.2.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
python3 - "$APP/Contents/Resources/Runtime.plist" "$RUNTIME" "$SUITE" "${CLIPLINE_COPY_DEMO:-0}" "${CLIPLINE_HISTORY_DEMO:-0}" "${CLIPLINE_LIBRARY_DEMO:-0}" "${CLIPLINE_CAPTURE_DEMO:-0}" "${CLIPLINE_PERFORMANCE_DEMO:-0}" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as file:
    plistlib.dump({'folder': sys.argv[2], 'suite': sys.argv[3], 'copyDemo': sys.argv[4] == '1', 'historyDemo': sys.argv[5] == '1', 'libraryDemo': sys.argv[6] == '1' or sys.argv[8] == '1', 'captureDemo': sys.argv[7] == '1' or sys.argv[8] == '1', 'performanceDemo': sys.argv[8] == '1'}, file)
PY
codesign --force --deep --sign - "$APP" >/dev/null
echo "Built: $APP"
echo "Screenshot folder: $RUNTIME/Screenshots"
echo "Clipboard folder: $RUNTIME/Clipboard"
echo "Performance JSON (when enabled): $RUNTIME/performance.json"
echo "Isolated shelf preferences: $SUITE"
echo "Not launched. No Desktop access or screenshot preference changes."
