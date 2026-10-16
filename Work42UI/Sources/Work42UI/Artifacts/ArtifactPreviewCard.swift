// ArtifactPreviewCard.swift — the shared artifact card.
//
// THE shared artifact card: the chat transcript's inline card and the Artifacts gallery's
// grid card are the same component in two size modes.
//
// It does NOT preview the artifact. A card is a tile: a tilted 3D object in the artifact's colour,
// carrying the type icon, bleeds off the left edge, and the title and "Kind · age" sit beside it on
// the plain card surface. The colour and the kind come from the artifact itself (`work42 artifact set`
// records them), the card only draws them, so it never renders a webview or a snapshot and can never
// churn list layout. The same tile is used in the chat transcript and, as a list, in the gallery.
//
// STATES
// ──────
//   appearance != nil — the tile.
//   appearance == nil — the artifact has no content: the fail-loud "not found" card,
//                       naming the artifact id.

import AppKit
import SwiftUI

// MARK: - Appearance

/// What an artifact card wears. Plain values so the SDK stays free of app types: the host
/// maps its own artifact metadata onto this.
public struct ArtifactCardAppearance: Equatable, Sendable {

    /// The semantic colours a card can wear (the design kit's names).
    public enum Tint: String, CaseIterable, Sendable {
        case accent, success, warning, danger, info, caution

        /// The live token colour: it follows light/dark and, for `accent`, the system accent.
        public var color: Color {
            switch self {
            case .accent: DT.systemAccent
            case .success: DT.done
            case .warning: DT.orange
            case .danger: DT.red
            case .info: DT.cyan
            case .caution: DT.amber
            }
        }

        /// A neighbouring hue the wash blends into, so each colour reads as a gradient with
        /// some depth instead of a flat tint (blue → cyan, green → cyan, orange → amber, …).
        public var companion: Color {
            switch self {
            case .accent: DT.cyan
            case .success: DT.cyan
            case .warning: DT.amber
            case .danger: DT.orange
            case .info: DT.systemAccent
            case .caution: DT.orange
            }
        }
    }

    /// The badge text ("Diagram", "Report", …).
    public var kindLabel: String
    /// The SF Symbol drawn large and faint on the card.
    public var symbol: String
    public var tint: Tint

    public init(kindLabel: String, symbol: String, tint: Tint) {
        self.kindLabel = kindLabel
        self.symbol = symbol
        self.tint = tint
    }
}

// MARK: - ArtifactPreviewCard

/// Shared tile card for artifacts (chat inline + gallery list).
@MainActor
public struct ArtifactPreviewCard: View {

    /// The two homes of the card. Chat resolves an explicit width upstream; the gallery list tile
    /// fills the list's width. Both have the same fixed height, so the card can never churn list layout.
    public enum SizeMode: Equatable {
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

    public let appearance: ArtifactCardAppearance?
    public let title: String
    public let artifactId: String
    /// Shown as a relative "2m ago" under the title when provided.
    public let timestamp: Date?
    public let sizeMode: SizeMode
    /// Called when the tile or its Open button is clicked. The argument is `artifactId`.
    public let onExpand: (String) -> Void
    /// Called when a format is chosen in the export popover. `nil` hides the export button.
    public let onExport: ((ArtifactExportFormat) -> Void)?

    public init(
        appearance: ArtifactCardAppearance?,
        title: String,
        artifactId: String,
        timestamp: Date? = nil,
        sizeMode: SizeMode,
        onExpand: @escaping (String) -> Void,
        onExport: ((ArtifactExportFormat) -> Void)? = nil
    ) {
        self.appearance = appearance
        self.title = title
        self.artifactId = artifactId
        self.timestamp = timestamp
        self.sizeMode = sizeMode
        self.onExpand = onExpand
        self.onExport = onExport
    }

    @State private var isHovering = false
    @State private var showExport = false
    @Environment(\.colorScheme) private var colorScheme

    public var body: some View {
        if let appearance {
            washCard(appearance)
        } else {
            missingCard
        }
    }

    // MARK: - Colour wash card

    /// A tile: a tilted 3D object bleeding off the left edge carries the type icon, and the title and
    /// "Kind · age" sit beside it on the plain card surface. The artifact's colour lives only on the object.
    /// Built from the design system: its liquid-glass card surface (`glassCardSurface`) and DT spacing, type
    /// and colour tokens. Only the object is specific to artifacts.
    @ViewBuilder
    private func washCard(_ appearance: ArtifactCardAppearance) -> some View {
        let look = Look(seed: artifactId)
        HStack(spacing: DT.s12) {
            object(appearance, look: look)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: DT.f15, weight: .semibold))
                    .foregroundStyle(DT.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(subtitle(appearance))
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
        // The whole tile opens the artifact; the glass buttons handle their own clicks.
        .onTapGesture { onExpand(artifactId) }
        .scaleEffect(isHovering ? 1.008 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: isHovering)
        .onHover { isHovering = $0 }
        .help("Open \(title)")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(appearance.kindLabel): \(title)")
    }

    /// The tile's controls, built exactly like the app's own glass buttons, just without the accent colour:
    /// the export button is the reload button's twin (a bare symbol on `glassIconButton()`), and Open is
    /// "Add Widget"'s twin (icon + semibold label on the glass capsule, neutral foreground).
    private var actions: some View {
        HStack(spacing: DT.s8) {
            if let onExport {
                Button {
                    showExport = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .glassIconButton()
                .help("Export \(title)")
                .accessibilityLabel("Export")
                .popover(isPresented: $showExport, arrowEdge: .bottom) {
                    ArtifactExportPopover(
                        title: title,
                        onSelect: { format in
                            showExport = false
                            onExport(format)
                        },
                        onClose: { showExport = false }
                    )
                }
            }
            Button {
                onExpand(artifactId)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: DT.f13, weight: .semibold))
                    Text("Open")
                        .font(.system(size: DT.f13, weight: .semibold))
                }
            }
            .glassPlainCapsule()
            .help("Open \(title)")
        }
    }

    /// "Diagram · 2m ago" (or just the kind when there is no timestamp).
    private func subtitle(_ appearance: ArtifactCardAppearance) -> String {
        guard let timestamp else { return appearance.kindLabel }
        return "\(appearance.kindLabel) · \(Self.relativeFormatter.localizedString(for: timestamp, relativeTo: Date()))"
    }

    /// The tilted object: a lit rounded slab in the artifact colour carrying the type icon. The hue is deepened
    /// (and a little more at the base, where it blends into its companion hue), a soft highlight falls from the
    /// top-left, a thin rim light runs along the edge, and a gentle glow of the colour spills onto the glass
    /// behind it. The icon casts its own soft shadow. It bleeds off the bottom-left of the card, tips a different
    /// way on each card, and lifts on hover.
    private func object(_ appearance: ArtifactCardAppearance, look: Look) -> some View {
        let tint = appearance.tint
        let corner: CGFloat = 20
        // Deepening is stronger in dark appearance, where a bright slab would glare.
        let depth: Double = colorScheme == .dark ? 1 : 0.55
        let slab = RoundedRectangle(cornerRadius: corner, style: .continuous)
        return ZStack {
            // Hue: the artifact colour into its companion.
            slab.fill(LinearGradient(colors: [tint.color, tint.companion], startPoint: .topLeading, endPoint: .bottomTrailing))
            // Deepen, a little more towards the base.
            slab.fill(LinearGradient(
                colors: [Color.black.opacity(0.20 * depth), Color.black.opacity(0.40 * depth)],
                startPoint: .top, endPoint: .bottom))
            // The companion hue warming the base.
            slab.fill(LinearGradient(
                colors: [tint.companion.opacity(0.35), .clear],
                startPoint: .bottom, endPoint: UnitPoint(x: 0.5, y: 0.6)))
            // Soft highlight from the top-left.
            slab.fill(RadialGradient(
                colors: [Color.white.opacity(0.24), .clear],
                center: .topLeading, startRadius: 0, endRadius: 64))
            // Rim light.
            slab.strokeBorder(
                LinearGradient(colors: [Color.white.opacity(0.34), Color.white.opacity(0.10)], startPoint: .top, endPoint: .bottom),
                lineWidth: 1)
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
        .shadow(color: tint.color.opacity(0.18), radius: 10, y: 8)
        .shadow(color: Color.black.opacity(0.25), radius: 3, y: 2)
        .rotation3DEffect(.degrees(look.turn + (isHovering ? 4 : 0)), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
        .rotationEffect(.degrees(look.tilt))
        .offset(x: 6, y: isHovering ? 8 : 14)
        .frame(width: 100, height: sizeMode.height, alignment: .topLeading)
        .background(alignment: .topLeading) {
            // The glow spilling onto the glass behind the object.
            Circle()
                .fill(tint.companion.opacity(0.18))
                .frame(width: 140, height: 140)
                .blur(radius: 28)
                .offset(x: -28, y: -8)
        }
    }

    /// Per-artifact variety, derived from the id so it is stable across launches.
    private struct Look {
        let turn: Double
        let tilt: Double

        init(seed: String) {
            let n = seed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
            turn = [-16, 14, -12, 16][n % 4]
            tilt = [-8, 7, -5, 8][(n / 4) % 4]
        }
    }

    // MARK: - Fail-loud state

    /// The artifact has no content. Names the missing artifact id explicitly, never a silent drop.
    @ViewBuilder
    private var missingCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: DT.f12))
                .foregroundStyle(DT.amber)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Artifact not found: \(artifactId)")
                    .font(.system(size: DT.f12, weight: .semibold))
                    .foregroundStyle(DT.textPrimary)
                Text("It has no content yet. Run 'work42 artifact set \(artifactId)' to create it.")
                    .font(.system(size: DT.f11))
                    .foregroundStyle(DT.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(width: sizeMode.cardWidth)
        .background(
            RoundedRectangle(cornerRadius: DT.rCard, style: .continuous)
                .fill(DT.amber.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DT.rCard, style: .continuous)
                .strokeBorder(DT.amber.opacity(0.25), lineWidth: 0.5)
        )
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
