// PreviewTileCard.swift — the tile card of the design system (WOR-535).
//
// The artifact card's tile, made general so other things can wear it (a session card in chat, WOR-536): a tilted glossy
// object in a tint, carrying an SF Symbol and bleeding off the left edge; the title and a subtitle beside it on the glass
// card surface; an optional accessory (the artifact's export button) and one primary glass button that is also the whole
// tile's tap. It draws what it is given and knows nothing about artifacts or sessions.

import AppKit
import SwiftUI

/// The two homes of a tile card. Chat resolves an explicit width upstream; a list tile fills the list's width. Both have the
/// same fixed height, so a card can never churn list layout.
public enum PreviewTileSizeMode: Equatable {
    case chat(width: CGFloat)
    case thumbnail

    var cardWidth: CGFloat? {
        switch self {
        case .chat(let width): width
        case .thumbnail: nil
        }
    }

    var height: CGFloat {
        switch self {
        case .chat: 100
        case .thumbnail: 100
        }
    }
}

@MainActor
public struct PreviewTileCard<Accessory: View>: View {

    public let appearance: ArtifactCardAppearance
    public let title: String
    /// The line under the title ("Diagram · 2m ago").
    public let subtitle: String
    /// Gives the tile its own tilt, stable across launches (an artifact or session id).
    public let seed: String
    public let sizeMode: PreviewTileSizeMode
    /// The primary button's label ("Open", "Reopen").
    public let primaryTitle: String
    /// Called when the tile or its primary button is clicked.
    public let onPrimary: () -> Void
    /// Shown before the primary button (an export button); `EmptyView()` for none.
    public let accessory: Accessory

    public init(
        appearance: ArtifactCardAppearance,
        title: String,
        subtitle: String,
        seed: String,
        sizeMode: PreviewTileSizeMode,
        primaryTitle: String = "Open",
        onPrimary: @escaping () -> Void,
        accessory: Accessory
    ) {
        self.appearance = appearance
        self.title = title
        self.subtitle = subtitle
        self.seed = seed
        self.sizeMode = sizeMode
        self.primaryTitle = primaryTitle
        self.onPrimary = onPrimary
        self.accessory = accessory
    }

    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    /// A tile: a tilted 3D object bleeding off the left edge carries the symbol, and the title and subtitle sit beside it on
    /// the plain card surface. The tint lives only on the object. Built from the design system: its liquid-glass card surface
    /// (`glassCardSurface`) and DT spacing, type and colour tokens.
    public var body: some View {
        let look = Look(seed: seed)
        HStack(spacing: DT.s12) {
            object(look: look)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: DT.f15, weight: .semibold))
                    .foregroundStyle(DT.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(subtitle)
                    .font(.system(size: DT.f12))
                    .foregroundStyle(DT.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            actions
                .padding(.trailing, DT.s12)
        }
        .frame(height: sizeMode.height)
        .frame(width: sizeMode.cardWidth)
        .frame(maxWidth: sizeMode.cardWidth == nil ? .infinity : nil)
        // Transparent Liquid Glass, the design system's card surface (real `.glassEffect` on macOS 26,
        // the standard surface with a hairline before that). The object is clipped to the same shape.
        .glassCardSurface(cornerRadius: DT.rPanel)
        .clipShape(RoundedRectangle(cornerRadius: DT.rPanel, style: .continuous))
        .contentShape(Rectangle())
        // The whole tile is the primary action; the glass buttons handle their own clicks.
        .onTapGesture { onPrimary() }
        .scaleEffect(isHovering ? 1.008 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: isHovering)
        .onHover { isHovering = $0 }
        .help("\(primaryTitle) \(title)")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(appearance.kindLabel): \(title)")
    }

    /// The tile's controls, both on the design system's liquid glass: the accessory (an export button) and the primary button.
    private var actions: some View {
        HStack(spacing: DT.s8) {
            accessory
            Button {
                onPrimary()
            } label: {
                Text(primaryTitle)
                    .font(.system(size: DT.f12, weight: .semibold))
            }
            .glassPlainCapsule()
            .help("\(primaryTitle) \(title)")
        }
    }

    /// The tilted object: a glossy rounded slab in the tint (blending into its companion hue) carrying the symbol, with the
    /// symbol's own soft shadow for depth. It bleeds off the bottom-left of the card, tips a different way on each card, and
    /// lifts on hover.
    private func object(look: Look) -> some View {
        let tint = appearance.tint
        let corner: CGFloat = 20
        return ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(LinearGradient(colors: [tint.color, tint.companion], startPoint: .topLeading, endPoint: .bottomTrailing))
            // Deepen the hue so it reads as a rich, muted shade rather than a bright one.
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color.black.opacity(colorScheme == .dark ? 0.30 : 0.16))
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(LinearGradient(colors: [Color.white.opacity(0.26), Color.white.opacity(0.04), .clear], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
            ZStack {
                Image(systemName: appearance.symbol)
                    .symbolVariant(.fill)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.28))
                    .blur(radius: 2)
                    .offset(y: 2)
                Image(systemName: appearance.symbol)
                    .symbolVariant(.fill)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
            .padding(.bottom, 16)
        }
        .frame(width: 70, height: 104)
        .shadow(color: Color.black.opacity(0.30), radius: 8, y: 5)
        .rotation3DEffect(.degrees(look.turn + (isHovering ? 4 : 0)), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
        .rotationEffect(.degrees(look.tilt))
        .offset(x: 6, y: isHovering ? 8 : 14)
        .frame(width: 100, height: sizeMode.height, alignment: .topLeading)
        .clipped()
    }

    /// Per-card variety, derived from the seed so it is stable across launches.
    private struct Look {
        let turn: Double
        let tilt: Double

        init(seed: String) {
            let n = seed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
            turn = [-16, 14, -12, 16][n % 4]
            tilt = [-8, 7, -5, 8][(n / 4) % 4]
        }
    }
}
