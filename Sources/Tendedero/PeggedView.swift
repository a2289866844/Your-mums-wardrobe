import SwiftUI

/// One clipboard card with its clothespin. All the charm lives here: it drops onto
/// the line, swings, sways with the breeze and falls when you pull it off.
struct PeggedView: View {
    let item: Pegged
    @ObservedObject var line: Line
    var animateArrival = true

    @State private var swing: Double = 0
    @State private var arrived = false
    @State private var hovering = false
    @State private var breezeTask: Task<Void, Never>?
    @State private var nudgeTask: Task<Void, Never>?

    private var copied: Bool { line.copiedID == item.id }
    private var dragging: Bool { line.draggingID == item.id }
    private var pressed: Bool { line.pressedID == item.id }

    var body: some View {
        VStack(spacing: -12) {
            Clothespin()
                .zIndex(1)
            card
        }
        .rotationEffect(.degrees(swing + item.tilt), anchor: .top)
        .offset(y: arrived ? 0 : -46)
        // The fall itself is drawn over the whole screen by CaptureFlight, so
        // the card here just steps aside at once.
        .opacity(item.falling || item.flying ? 0 : (arrived ? 1 : 0))
        .transaction { t in if item.falling { t.animation = nil } }
        .animation(.easeOut(duration: 0.16), value: item.flying)
        .onAppear(perform: arrive)
        .onDisappear {
            breezeTask?.cancel()
            nudgeTask?.cancel()
        }
        .onChange(of: item.flying) { was, now in if was && !now { land() } }
        .onChange(of: line.gust) { _, _ in
            if line.revealed && !pressed && !dragging { breeze() }
        }
        .onChange(of: copied) { _, isCopied in if isCopied { nudge(3) } }
    }

    /// A consistent silhouette keeps wide captures readable and mixed
    /// clipboard content aligned, without cropping the original image.
    static let cardSize = CGSize(width: Layout.cardWidth, height: 182)
    static let cardOffsetBelowTop: CGFloat = 26 - 12

    private var symbol: String {
        switch item.kind {
        case .image: return "photo"
        case .text: return "text.alignleft"
        case .link: return "link"
        case .file: return "doc"
        }
    }

    private var typeName: String {
        switch item.kind {
        case .image: return L("Image", "Imagen")
        case .text: return L("Text", "Texto")
        case .link: return L("Link", "Enlace")
        case .file: return L("File", "Archivo")
        }
    }

    private var tint: Color {
        switch item.kind {
        case .image: return .teal
        case .text: return .orange
        case .link: return .blue
        case .file: return .purple
        }
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .image:
            Image(nsImage: item.thumb)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .padding(3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .text:
            Text(item.previewText ?? item.title)
                .font(.system(size: 13))
                .lineSpacing(3)
                .lineLimit(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .padding(.bottom, 8)
        case .link:
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "link")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(tint)
                Text(item.linkURL?.host ?? item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                Text(item.linkURL?.absoluteString ?? item.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(15)
        case .file:
            VStack(spacing: 8) {
                Image(nsImage: item.thumb).resizable().scaledToFit().frame(width: 46, height: 46)
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(item.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(12)
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            content
                .frame(height: 142)
                .frame(maxWidth: .infinity)
                .background(tint.opacity(item.kind == .image ? 0.035 : 0.06))
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            HStack(spacing: 5) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(typeName).fontWeight(.medium)
                if item.content.isPinned == true { Image(systemName: "pin.fill").font(.system(size: 8)) }
                if let source = item.content.sourceAppName {
                    Text(source).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 4)
                // The native Copy button in GrabArea owns this part of the footer.
                Color.clear.frame(width: CardCopyButton.width, height: CardCopyButton.height)
            }
            .font(.system(size: 10))
            .padding(.horizontal, 7)
            .frame(height: 32)
        }
        .padding(Frame.inset)
        .frame(width: Self.cardSize.width, height: Self.cardSize.height)
        .glassFrame(cornerRadius: Frame.radius)
        .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
        .scaleEffect(pressed ? 0.97 : 1, anchor: .top)
        .animation(pressed ? .easeInOut(duration: 0.45) : .spring(response: 0.3, dampingFraction: 0.6), value: pressed)
        .opacity(dragging ? 0.45 : 1)
        .overlay(alignment: .topLeading) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 20, height: 20)
                .glassFrame(circle: true)
                .padding(3)
                .opacity(hovering && !dragging ? 1 : 0)
                .allowsHitTesting(false)
        }
        .overlay(GrabArea(item: item, line: line, copied: copied, copyFailed: line.copyFailedID == item.id))
        .animation(.easeOut(duration: 0.18), value: hovering)
        .animation(.easeOut(duration: 0.2), value: copied)
        .onHover { hovering = $0 }
        .background(GeometryReader { g in
            Color.clear.preference(key: HitRectsKey.self,
                                   value: item.falling || item.flying ? [:] : [item.id: g.frame(in: .global)])
        })
    }

    private func arrive() {
        // Browsing saved cards is a page change, not a fresh capture. Keep
        // their native controls still instead of replaying the long swing.
        guard animateArrival else {
            arrived = true
            return
        }
        // A capture that flew in is already in place; the flight did the arriving.
        if item.flying {
            arrived = true
            return
        }
        swing = 6
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) { arrived = true }
        // Settle new captures promptly instead of recompositing their glass
        // and shadow for several seconds. Idle breeze keeps its own animation.
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { swing = 0 }
    }

    /// Landing after the flight: no jump, just a small sway from rest.
    private func land() {
        nudge(2.2)
    }

    private func breeze() {
        let delay = Double.random(in: 0...0.35)
        breezeTask?.cancel()
        breezeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, line.revealed, !pressed, !dragging else { return }
            nudge(Double.random(in: 1.6...3.4))
        }
    }

    private func nudge(_ degrees: Double) {
        nudgeTask?.cancel()
        withAnimation(.easeOut(duration: 0.3)) { swing = degrees }
        nudgeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.3))
            guard !Task.isCancelled else { return }
            withAnimation(.interpolatingSpring(stiffness: 38, damping: 2.4)) { swing = 0 }
        }
    }
}

enum Frame {
    static let radius: CGFloat = 16
    static let inset: CGFloat = 4
}

extension View {
    /// A crisp glass: the system's blurred material with a thin specular
    /// edge, lit from above. No refraction, so the background stays sharp
    /// around the frame instead of bending like gel.
    func glassFrame(cornerRadius: CGFloat = 0, circle: Bool = false, capsule: Bool = false) -> some View {
        let shape: AnyShape = circle ? AnyShape(Circle())
            : capsule ? AnyShape(Capsule())
            : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        return background(.ultraThinMaterial, in: shape)
            .overlay(
                shape.stroke(
                    LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0.12)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.75)
            )
            .overlay(shape.stroke(Color.black.opacity(0.10), lineWidth: 0.5).padding(-0.5))
    }
}

/// A minimal aluminium clip: a brushed metal pill with a slot where it
/// grips the line, and a soft shadow so it reads on any background.
struct Clothespin: View {
    private let metal = LinearGradient(
        stops: [
            .init(color: Color(white: 0.70), location: 0),
            .init(color: Color(white: 0.93), location: 0.35),
            .init(color: Color(white: 0.82), location: 0.65),
            .init(color: Color(white: 0.62), location: 1),
        ],
        startPoint: .leading, endPoint: .trailing)

    var body: some View {
        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
            .fill(metal)
            .frame(width: 9, height: 26)
            .overlay(
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .stroke(LinearGradient(colors: [Color.white.opacity(0.9), Color.black.opacity(0.18)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.6)
            )
            .overlay(alignment: .top) {
                // The slot the line passes through.
                Capsule()
                    .fill(Color.black.opacity(0.32))
                    .frame(width: 5, height: 1.4)
                    .padding(.top, 8.5)
            }
            .shadow(color: .black.opacity(0.30), radius: 2, y: 1.5)
            .allowsHitTesting(false)
    }
}
