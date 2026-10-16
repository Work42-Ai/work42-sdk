// ArtifactPreviewCard.swift — the shared artifact card.
//
// THE shared artifact card: the chat transcript's inline card and the Artifacts gallery's
// grid card are the same component in two size modes.
//
// It does NOT preview the artifact. A card is a colour wash: a gradient of the artifact's
// colour, a type badge, a large faint type icon, the title and when it changed. The colour
// and the kind come from the artifact itself (`work42 artifact set` records them), the card
// only draws them, so it never renders a webview or a snapshot and can never churn list
// layout. The whole card is the button that opens the artifact; there is no expand control.
//
// STATES
// ──────
//   appearance != nil — the colour wash card.
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

/// Shared colour-wash card for artifacts (chat inline + gallery grid).
@MainActor
public struct ArtifactPreviewCard: View {

    /// The two homes of the card. Chat resolves an explicit width upstream; the grid card
    /// fills its column. Both have a fixed height, so the card can never churn list layout.
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
            case .chat: 112
            case .thumbnail: 124
            }
        }
    }

    public let appearance: ArtifactCardAppearance?
    public let title: String
    public let artifactId: String
    /// Shown as a relative "2m ago" under the title when provided.
    public let timestamp: Date?
    public let sizeMode: SizeMode
    /// Called when the card is clicked. The argument is `artifactId`.
    public let onExpand: (String) -> Void

    public init(
        appearance: ArtifactCardAppearance?,
        title: String,
        artifactId: String,
        timestamp: Date? = nil,
        sizeMode: SizeMode,
        onExpand: @escaping (String) -> Void
    ) {
        self.appearance = appearance
        self.title = title
        self.artifactId = artifactId
        self.timestamp = timestamp
        self.sizeMode = sizeMode
        self.onExpand = onExpand
    }

    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    public var body: some View {
        if let appearance {
            washCard(appearance)
        } else {
            missingCard
        }
    }

    // MARK: - Colour wash card

    /// Built from the design system: the `Card` surface, the `.sessionChip` badge tinted by
    /// `DT.resolveChipTint` (the same resolver `HeaderLabelChip` uses), and DT spacing and type tokens.
    /// Only the wash behind the card is specific to artifacts.
    @ViewBuilder
    private func washCard(_ appearance: ArtifactCardAppearance) -> some View {
        let tint = appearance.tint.color
        let chip = DT.resolveChipTint(tint, colorScheme: colorScheme)
        Button {
            onExpand(artifactId)
        } label: {
            Card(padding: DT.s12) {
                VStack(alignment: .leading, spacing: DT.s4) {
                    Text(appearance.kindLabel)
                        .font(.system(size: DT.f10, weight: .semibold))
                        .foregroundStyle(chip.foreground)
                        .sessionChip(fill: chip.fill, stroke: chip.stroke)
                    Spacer(minLength: DT.s4)
                    Text(title)
                        .font(.system(size: DT.f15, weight: .semibold))
                        .foregroundStyle(DT.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let timestamp {
                        Text(Self.relativeFormatter.localizedString(for: timestamp, relativeTo: Date()))
                            .font(.system(size: DT.f11))
                            .foregroundStyle(DT.textSecondary)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(width: sizeMode.cardWidth)
            .frame(maxWidth: sizeMode.cardWidth == nil ? .infinity : nil)
            .frame(height: sizeMode.height)
            .background { wash(tint: tint, symbol: appearance.symbol) }
            .clipShape(RoundedRectangle(cornerRadius: DT.rCard, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Open \(title)")
        .accessibilityLabel("\(appearance.kindLabel): \(title)")
        .accessibilityHint("Opens the artifact")
    }

    /// The artifact's colour as a soft diagonal wash, with its type icon large and faint in the corner.
    private func wash(tint: Color, symbol: String) -> some View {
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(
                colors: [tint.opacity(0.30), tint.opacity(0.10), .clear],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Image(systemName: symbol)
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(tint.opacity(isHovering ? 0.30 : 0.20))
                .padding(.trailing, DT.s12)
                .padding(.bottom, DT.s4)
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
