// ArtifactPreviewCard.swift — the shared artifact card.
//
// THE shared artifact card: the chat transcript's inline card and the Artifacts gallery's
// grid card are the same component in two size modes. The tile itself is `PreviewTileCard`; this wraps it for artifacts
// (the kind and age subtitle, the export button, the not-found state).
//
// It does NOT preview the artifact. A card is a tile: a tilted 3D object in the artifact's colour,
// carrying the type icon, bleeds off the left edge, and the title and "Kind · age" sit beside it on
// the plain card surface. The colour and the kind come from the artifact itself (`artifact_set`
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

    /// The two homes of the card (the tile card's size modes).
    public typealias SizeMode = PreviewTileSizeMode

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

    public var body: some View {
        if let appearance {
            PreviewTileCard(
                appearance: appearance, title: title, subtitle: subtitle(appearance), seed: artifactId,
                sizeMode: sizeMode, primaryTitle: "Open", onPrimary: { onExpand(artifactId) }, accessory: exportButton
            )
        } else {
            missingCard
        }
    }

    /// The export button, when the host supports exporting.
    @ViewBuilder
    private var exportButton: some View {
        if let onExport {
            ArtifactExportButton(title: title, onExport: onExport)
        }
    }

    /// "Diagram · 2m ago" (or just the kind when there is no timestamp).
    private func subtitle(_ appearance: ArtifactCardAppearance) -> String {
        guard let timestamp else { return appearance.kindLabel }
        return "\(appearance.kindLabel) · \(Self.relativeFormatter.localizedString(for: timestamp, relativeTo: Date()))"
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
                Text("It has no content yet. Run 'artifact_set \(artifactId)' to create it.")
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
