import Foundation

/// Follow changes made in macOS Screenshot Options while wardrobe is running.
@MainActor
final class ScreenshotLocationMonitor {
    private let resolve: () -> URL
    private let onChange: (URL, Date) -> Void
    private var folder: URL
    private var checkedAt: Date
    private var timer: Timer?

    init(folder: URL, checkedAt: Date = Date(), resolve: @escaping () -> URL = ScreenshotWatcher.screenshotFolder,
         onChange: @escaping (URL, Date) -> Void) {
        self.folder = folder.standardizedFileURL
        self.checkedAt = checkedAt
        self.resolve = resolve
        self.onChange = onChange
    }

    func start() {
        stop()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() { timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate() }

    func poll(at now: Date = Date()) {
        let previousCheck = checkedAt
        checkedAt = now
        let current = resolve().standardizedFileURL
        guard current != folder else { return }
        folder = current
        // Include captures written between preference checks, without replaying old files.
        onChange(current, previousCheck)
    }
}
