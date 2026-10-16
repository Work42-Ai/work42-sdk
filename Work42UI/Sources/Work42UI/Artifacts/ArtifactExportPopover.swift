// ArtifactExportPopover.swift — the "export this artifact" popover shown from an artifact card.
//
// The card only describes WHAT can be exported (`ArtifactExportFormat`); the host app does the
// exporting (it owns the artifact files and the loopback server), so the SDK stays free of
// app types. The popover is the design system's own pieces: DT tokens for type and spacing,
// `glassIconButton()` for the close control, and the chip fill for the icon tiles.

import SwiftUI

/// The ways an artifact can leave the app.
public enum ArtifactExportFormat: String, CaseIterable, Identifiable, Sendable {
    /// A single self-contained web page (styles, icons and scripts inlined), saved to a file.
    case html
    /// A plain-text Markdown copy of the content, saved to a file.
    case markdown
    /// The standalone page opened in the default browser with its print dialog raised.
    case pdf

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .html: "HTML"
        case .markdown: "Markdown"
        case .pdf: "PDF"
        }
    }

    public var subtitle: String {
        switch self {
        case .html: "Standalone web page"
        case .markdown: "Plain-text .md file"
        case .pdf: "Opens your browser’s print dialog"
        }
    }

    public var symbol: String {
        switch self {
        case .html: "chevron.left.forwardslash.chevron.right"
        case .markdown: "text.alignleft"
        case .pdf: "printer"
        }
    }

    /// Whether choosing it writes a file the user picks the location of (PDF hands off to the browser).
    public var savesFile: Bool { self != .pdf }
}

/// The export button: a symbol on the design system's glass icon button that opens the format popover.
/// One component for every place an artifact can be exported from (the tile and the detail header), so
/// they always look and behave the same. The host does the exporting through `onExport`.
public struct ArtifactExportButton: View {
    private let title: String
    private let onExport: (ArtifactExportFormat) -> Void

    @State private var isShowing = false

    public init(title: String, onExport: @escaping (ArtifactExportFormat) -> Void) {
        self.title = title
        self.onExport = onExport
    }

    public var body: some View {
        Button {
            isShowing = true
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: DT.f13, weight: .medium))
        }
        .glassIconButton()
        .help("Export \(title)")
        .accessibilityLabel("Export")
        .popover(isPresented: $isShowing, arrowEdge: .bottom) {
            ArtifactExportPopover(
                title: title,
                onSelect: { format in
                    isShowing = false
                    onExport(format)
                },
                onClose: { isShowing = false }
            )
        }
    }
}

/// The popover content: the artifact's title, a close control and one row per format.
struct ArtifactExportPopover: View {
    let title: String
    let onSelect: (ArtifactExportFormat) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DT.s12) {
            HStack(spacing: DT.s8) {
                Text(title)
                    .font(.system(size: DT.f15, weight: .semibold))
                    .foregroundStyle(DT.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: DT.f11, weight: .semibold))
                }
                .glassIconButton()
                .help("Close")
            }
            VStack(spacing: 0) {
                ForEach(Array(ArtifactExportFormat.allCases.enumerated()), id: \.element.id) { index, format in
                    if index > 0 { Divider().opacity(0.4) }
                    row(format)
                }
            }
        }
        .padding(DT.s16)
        .frame(width: 320)
    }

    private func row(_ format: ArtifactExportFormat) -> some View {
        Button {
            onSelect(format)
        } label: {
            HStack(spacing: DT.s12) {
                Image(systemName: format.symbol)
                    .font(.system(size: DT.f15, weight: .medium))
                    .foregroundStyle(DT.textPrimary)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: DT.rPanel, style: .continuous).fill(DT.chipFillSubtle))
                VStack(alignment: .leading, spacing: 1) {
                    Text(format.title)
                        .font(.system(size: DT.f13, weight: .semibold))
                        .foregroundStyle(DT.textPrimary)
                    Text(format.subtitle)
                        .font(.system(size: DT.f11))
                        .foregroundStyle(DT.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if format.savesFile {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: DT.f13, weight: .medium))
                        .foregroundStyle(DT.textSecondary)
                }
            }
            .padding(.vertical, DT.s8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Export as \(format.title)")
        .accessibilityHint(format.subtitle)
    }
}
