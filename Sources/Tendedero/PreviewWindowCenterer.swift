import AppKit
import ApplicationServices

/// Open images in Preview and move only the window belonging to that document.
@MainActor
final class PreviewWindowCenterer {
    static let shared = PreviewWindowCenterer()

    enum Status: String { case centered, needsAccessibility, unavailable, openFailed }
    var onResult: (Status) -> Void = { status in
        log.notice("Preview window centering: \(status.rawValue, privacy: .public)")
    }
    /// Fixture hosts check permission without opening a system permission prompt.
    var promptsForAccess = true
    private var requestedAccess = false
    private var request = UUID()
    private var pending: Task<Void, Never>?

    func open(_ url: URL) {
        pending?.cancel()
        let token = UUID()
        request = token
        guard let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview"),
              let screen = LinePanel.screenUnderPointer(), let primary = NSScreen.screens.first else {
            NSWorkspace.shared.open(url)
            onResult(.unavailable)
            return
        }
        let visible = screen.visibleFrame
        let primaryTop = primary.frame.maxY
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: configuration) { [weak self] app, error in
            let pid = app?.processIdentifier
            DispatchQueue.main.async {
                guard let self, self.request == token else { return }
                guard error == nil, let pid else { self.onResult(.openFailed); return }
                guard AXIsProcessTrusted() else {
                    self.onResult(.needsAccessibility)
                    if self.promptsForAccess && !self.requestedAccess {
                        self.requestedAccess = true
                        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
                    }
                    return
                }
                self.pending = Task { [weak self] in
                    await self?.center(url, pid: pid, visible: visible, primaryTop: primaryTop, token: token)
                }
            }
        }
    }

    private func center(_ url: URL, pid: pid_t, visible: CGRect, primaryTop: CGFloat, token: UUID) async {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        let deadline = ProcessInfo.processInfo.systemUptime + 2.5
        var previousSize: CGSize?
        var stableSince = ProcessInfo.processInfo.systemUptime
        while !Task.isCancelled && request == token && ProcessInfo.processInfo.systemUptime < deadline {
            if let window = matchingWindow(in: app, for: url), let size = windowSize(window),
               let point = Self.centeredPosition(size: size, visible: visible, primaryTop: primaryTop) {
                let now = ProcessInfo.processInfo.systemUptime
                if previousSize != size { previousSize = size; stableSince = now }
                else if now - stableSince >= 0.1 {
                    var position = point
                    if let value = AXValueCreate(.cgPoint, &position),
                       AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success {
                        try? await Task.sleep(for: .milliseconds(100))
                        guard !Task.isCancelled, request == token else { return }
                        if windowSize(window) == size, let actual = windowPosition(window),
                           abs(actual.x - point.x) < 2, abs(actual.y - point.y) < 2 {
                            onResult(.centered)
                            return
                        }
                        stableSince = ProcessInfo.processInfo.systemUptime
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if !Task.isCancelled && request == token { onResult(.unavailable) }
    }

    struct Identity {
        let document: String?
        let focused: Bool
    }

    /// A window is eligible only when its document path matches exactly.
    static func matchingIndex(_ windows: [Identity], for url: URL) -> Int? {
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        let exact = windows.indices.filter { index in
            guard let document = windows[index].document else { return false }
            let candidate = document.hasPrefix("/") ? URL(fileURLWithPath: document) : URL(string: document)
            return candidate?.isFileURL == true
                && candidate?.resolvingSymlinksInPath().standardizedFileURL.path == target
        }
        if let focused = exact.first(where: { windows[$0].focused }) { return focused }
        if exact.count == 1 { return exact[0] }
        return nil
    }

    /// AX uses the primary display's top-left origin; AppKit uses bottom-left.
    static func centeredPosition(size: CGSize, visible: CGRect, primaryTop: CGFloat) -> CGPoint? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              visible.minX.isFinite, visible.minY.isFinite, visible.width.isFinite, visible.height.isFinite,
              visible.width > 0, visible.height > 0, primaryTop.isFinite else { return nil }
        return CGPoint(x: visible.midX - size.width / 2,
                       y: primaryTop - visible.midY - size.height / 2)
    }

    private func matchingWindow(in app: AXUIElement, for url: URL) -> AXUIElement? {
        guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        let focused = attribute(app, kAXFocusedWindowAttribute)
        let identities = windows.map { window in
            AXUIElementSetMessagingTimeout(window, 0.05)
            let rawDocument = attribute(window, kAXDocumentAttribute)
            let document = (rawDocument as? URL)?.absoluteString ?? (rawDocument as? String)
            return Identity(document: document,
                            focused: focused.map { CFEqual($0, window) } ?? false)
        }
        return Self.matchingIndex(identities, for: url).map { windows[$0] }
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func windowSize(_ window: AXUIElement) -> CGSize? {
        guard let raw = attribute(window, kAXSizeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(raw as! AXValue, .cgSize, &size) ? size : nil
    }

    private func windowPosition(_ window: AXUIElement) -> CGPoint? {
        guard let raw = attribute(window, kAXPositionAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(raw as! AXValue, .cgPoint, &point) ? point : nil
    }
}
