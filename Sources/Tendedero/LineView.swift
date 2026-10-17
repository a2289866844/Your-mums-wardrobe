import SwiftUI

enum Layout {
    static let panelHeight: CGFloat = 280
    static let ropeTop: CGFloat = 10
    static let spacing: CGFloat = 244
    static let cardWidth: CGFloat = 220
    static let pinAbove: CGFloat = 9.5
    static let olderControlID = UUID()
    static let newerControlID = UUID()
    static let toolbarControlID = UUID()

    static func capacity(width: CGFloat) -> Int {
        max(1, min(12, Int(max(0, width - 200) / spacing)))
    }

    /// The rope hangs as a parabola from edge to edge of the screen.
    static func sag(width: CGFloat) -> CGFloat { min(30, width * 0.018) }

    static func ropeY(x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return ropeTop }
        let f = x / width
        return ropeTop + 4 * sag(width: width) * f * (1 - f)
    }

    static func x(index: Int, count: Int, width: CGFloat) -> CGFloat {
        let gaps = CGFloat(max(count - 1, 0))
        // Held cards and falling placeholders can briefly exceed capacity.
        // Compress only that overflow, leaving room for tilt at both edges.
        let step = gaps > 0 ? min(spacing, max(0, width - cardWidth - 40) / gaps) : spacing
        let total = gaps * step
        return width / 2 - total / 2 + CGFloat(index) * step
    }
}

struct LineView: View {
    @ObservedObject var line: Line

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let visible = line.visibleItems
            ZStack(alignment: .topLeading) {
                Rope(width: width)

                if visible.isEmpty {
                    Hint(message: line.showingLibraryResults ? "沒有符合的內容" : nil)
                        .position(x: width / 2, y: Layout.ropeY(x: width / 2, width: width) + 34)
                        .transition(.opacity)
                }

                ZStack(alignment: .topLeading) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                        let x = Layout.x(index: index, count: visible.count, width: width)
                        let ropeY = Layout.ropeY(x: x, width: width)
                        PeggedView(item: item, line: line, animateArrival: item.content.historyID == nil)
                            .frame(width: Layout.cardWidth, height: Layout.panelHeight - ropeY, alignment: .top)
                            .position(x: x, y: ropeY - Layout.pinAbove + (Layout.panelHeight - ropeY) / 2)
                            .transition(.asymmetric(insertion: .move(edge: line.pagingOlder ? .leading : .trailing).combined(with: .opacity),
                                                    removal: .move(edge: line.pagingOlder ? .trailing : .leading).combined(with: .opacity)))
                    }
                }

                navigation(older: true)
                    .position(x: 25, y: 125)
                if line.hasNewerPage {
                    navigation(older: false)
                        .position(x: width - 25, y: 125)
                }
                if line.library != nil || !line.libraryStatus.isEmpty {
                    LibraryToolbar(line: line)
                        .frame(width: max(260, min(1100, width - 60)), height: 32)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .glassFrame(cornerRadius: 12)
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: HitRectsKey.self, value: [Layout.toolbarControlID: geo.frame(in: .global)])
                        })
                        .position(x: width / 2, y: 252)
                }
            }
            .animation(.easeInOut(duration: 0.22), value: line.pageRevision)
            .animation(.easeInOut(duration: 0.3), value: line.items.isEmpty)
            // Tucked away, the whole line waits above the top edge and slides
            // out from under the menu bar, the way an auto-hiding Dock does.
            .offset(y: line.revealed ? 0 : -(Layout.panelHeight + 12))
            .animation(line.revealed ? .spring(response: 0.20, dampingFraction: 0.82)
                                     : .easeIn(duration: 0.22), value: line.revealed)
        }
        .onPreferenceChange(HitRectsKey.self) { rects in
            let visibleIDs = Set(line.visibleItems.map(\.id)).union([Layout.olderControlID, Layout.newerControlID, Layout.toolbarControlID])
            line.hitRects = rects.filter { visibleIDs.contains($0.key) }
        }
    }

    private func navigation(older: Bool) -> some View {
        HistoryNavigationButton(older: older, count: max(1, line.pageSize),
                                available: older ? line.hasOlderPage : line.hasNewerPage, enabled: line.canNavigate) {
            if older { line.showOlderPage() } else { line.showNewerPage() }
        }
        .frame(width: 32, height: 44)
        .glassFrame(cornerRadius: 16)
        .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
        .opacity(older && !line.hasOlderPage ? 0.45 : 1)
        .background(GeometryReader { geo in
            Color.clear.preference(key: HitRectsKey.self,
                value: [older ? Layout.olderControlID : Layout.newerControlID: geo.frame(in: .global)])
        })
    }
}

/// Native buttons remain clickable without making the floating shelf key.
struct HistoryNavigationButton: NSViewRepresentable {
    let older: Bool
    let count: Int
    let available: Bool
    let enabled: Bool
    let action: () -> Void

    final class Coordinator: NSObject {
        var action: () -> Void = {}
        @objc func click() { action() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.target = context.coordinator
        button.action = #selector(Coordinator.click)
        button.imagePosition = .imageOnly
        button.focusRingType = .none
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        let label = older ? L("Previous \(count) items", "\(count) elementos anteriores") : L("Next \(count) items", "\(count) elementos siguientes")
        button.image = NSImage(systemSymbolName: older ? "chevron.left" : "chevron.right", accessibilityDescription: label)
        button.contentTintColor = .labelColor
        button.isEnabled = enabled && available
        let help = available ? label : L("No older items yet", "Aún no hay elementos anteriores")
        button.toolTip = help
        button.setAccessibilityLabel(help)
        button.setAccessibilityIdentifier(older ? "history-older" : "history-newer")
    }
}

private struct Hint: View {
    var message: String? = nil
    var body: some View {
        Text(message ?? L("Take a screenshot or copy something to hang it here", "Haz una captura o copia algo para colgarlo aquí"))
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
    }
}

/// A thin, neutral line: a mid gray core with a faint highlight and a soft
/// shadow, so it reads on light and dark backgrounds alike. It fades out at
/// both ends so it seems to come from beyond the screen.
struct Rope: View {
    let width: CGFloat

    private var path: Path {
        Path { p in
            let top = Layout.ropeTop
            p.move(to: CGPoint(x: -20, y: top))
            p.addQuadCurve(
                to: CGPoint(x: width + 20, y: top),
                control: CGPoint(x: width / 2, y: top + 2 * Layout.sag(width: width)))
        }
    }

    var body: some View {
        ZStack {
            path.stroke(Color.black.opacity(0.22), lineWidth: 1.4).offset(y: 1.2).blur(radius: 1.2)
            path.stroke(Color(white: 0.55), lineWidth: 1.2)
            path.stroke(Color.white.opacity(0.45), lineWidth: 0.4).offset(y: -0.35)
        }
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.08),
                .init(color: .black, location: 0.92),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        )
        .allowsHitTesting(false)
    }
}

struct HitRectsKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
