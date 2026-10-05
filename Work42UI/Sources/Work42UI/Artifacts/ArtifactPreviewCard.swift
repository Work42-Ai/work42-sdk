// ArtifactPreviewCard.swift — the shared artifact preview card.
//
// THE shared artifact card: the chat transcript's inline card and the
// Artifacts gallery's thumbnail are the same component in two size modes.
//
// LIVE HTML (feat/artifacts-native-artifacts-and-diagrams-controls .4)
// ────────────────────────────────────────────────────────────────────
// The preview is a LIVE webview of the real artifact — not a static PNG
// snapshot. The earlier snapshot pipeline (ArtifactSnapshotRenderer +
// ArtifactPreviewCache) existed to avoid a chat layout-hang from many
// auto-height webviews; that churn is solved two ways here:
//   1. The webview is framed to a FIXED preview height (clipped miniature),
//      so it never drives list layout (no auto-height growth).
//   2. AutoHeightWebView's height model is isolated to this card subtree; the
//      chat-list/gallery body never observes it.
// A `reloadToken` (content hash) makes the card react live to the agent
// rewriting the artifact — an in-place reload, no flash, no recreate.
//
// STATES
// ──────
//   .live(URL)   — the artifact's loopback URL; rendered live + clipped.
//   .unresolved  — the artifact server isn't running / URL unresolved: the
//                  fail-loud "not available" card, naming the artifact id.

import AppKit
import SwiftUI

// MARK: - ArtifactPreviewCard

/// Shared live-preview card for artifacts (chat inline + gallery thumbnail).
@MainActor
public struct ArtifactPreviewCard: View {

    /// What the preview area shows (resolved upstream).
    public enum PreviewState: Equatable {
        /// A rendered PNG snapshot on disk — shown full-width, high quality.
        /// This is the preferred preview: a static, crisp image (no live churn).
        case image(URL)
        /// The artifact's loopback URL — rendered live, clipped to the card.
        /// Used as an immediate fallback while the snapshot is still rendering.
        case live(URL)
        /// The server isn't running / URL unresolved — fail-loud card.
        case unresolved
    }

    /// The two homes of the card. Chat resolves an explicit width upstream
    /// (16:9 preview, 4:3 below the narrow threshold). Thumbnail (gallery)
    /// fills its grid column with a 16:9 preview. Every state renders the same
    /// fixed footprint, so the card can never churn list layout.
    public enum SizeMode: Equatable {
        case chat(width: CGFloat)
        case thumbnail

        public static let narrowThreshold: CGFloat = 360

        var cardWidth: CGFloat? {
            switch self {
            case .chat(let width): width
            case .thumbnail: nil
            }
        }

        var previewHeight: CGFloat? {
            switch self {
            case .chat(let width):
                width < Self.narrowThreshold ? width * 3 / 4 : width * 9 / 16
            case .thumbnail:
                nil
            }
        }
    }

    public let state: PreviewState
    public let title: String
    public let artifactId: String
    /// Opaque token that changes when the artifact content changes (content
    /// hash / mtime). Threaded to the live webview so the card reacts in place.
    public let reloadToken: String
    /// Shown as a relative "2m ago" in the header when provided (chat mode).
    public let timestamp: Date?
    public let sizeMode: SizeMode
    /// Called on ⤢ or a preview click. The argument is `artifactId`.
    public let onExpand: (String) -> Void

    public init(
        state: PreviewState,
        title: String,
        artifactId: String,
        reloadToken: String = "",
        timestamp: Date? = nil,
        sizeMode: SizeMode,
        onExpand: @escaping (String) -> Void
    ) {
        self.state = state
        self.title = title
        self.artifactId = artifactId
        self.reloadToken = reloadToken
        self.timestamp = timestamp
        self.sizeMode = sizeMode
        self.onExpand = onExpand
    }

    /// Isolated to this card subtree — the live webview posts heights here; we
    /// ignore them for sizing (fixed clipped frame) but AutoHeightWebView needs
    /// a model, and the isolation keeps the outer body from re-rendering.
    @StateObject private var heightModel = AutoHeightModel()

    public var body: some View {
        switch state {
        case .unresolved:
            unresolvedCard
        case .image(let url):
            imageCard(url: url)
        case .live(let url):
            liveCard(url: url)
        }
    }

    // MARK: - Image (snapshot) card — the preferred preview

    @ViewBuilder
    private func imageCard(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader
            Divider().opacity(0.25)
            Button {
                onExpand(artifactId)
            } label: {
                snapshotImage(url: url)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(title) full-surface")
        }
        .frame(width: sizeMode.cardWidth)
        .background(DT.surface)
        .clipShape(RoundedRectangle(cornerRadius: DT.rCard, style: .continuous))
        .overlay(cardBorder)
    }

    /// The cached PNG (high interpolation). `reloadToken` is part of the SwiftUI
    /// identity so changed content swaps in the fresh snapshot.
    ///  • chat: full-width at natural aspect — the renderer captures
    ///    content-height, so fit-to-width shows the whole preview, no crop.
    ///  • thumbnail: fills a fixed 16:9 box, top-aligned + clipped, so every
    ///    gallery card is the SAME height in the grid.
    /// Decoded-PNG cache keyed by (path, content token). `NSImage(contentsOf:)`
    /// re-reads + re-decodes the file on EVERY SwiftUI body pass (constant
    /// during chat streaming); this decodes once per content generation and
    /// serves cache hits thereafter. NSCache evicts under memory pressure.
    private static let imageCache = NSCache<NSString, NSImage>()

    private func cachedImage(_ url: URL) -> NSImage? {
        // reloadToken is the content hash — it changes exactly when the snapshot
        // content changes, so it's a safe, stat-free cache key.
        let key = "\(url.path)|\(reloadToken)" as NSString
        if let hit = Self.imageCache.object(forKey: key) { return hit }
        guard let img = NSImage(contentsOf: url) else { return nil }
        Self.imageCache.setObject(img, forKey: key)
        return img
    }

    @ViewBuilder
    private func snapshotImage(url: URL) -> some View {
        if let img = cachedImage(url) {
            let base = Image(nsImage: img).resizable().interpolation(.high)
            switch sizeMode {
            case .chat:
                base
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .id(reloadToken)
            case .thumbnail:
                Color.clear
                    .modifier(PreviewFrame(sizeMode: sizeMode))
                    .overlay(alignment: .top) {
                        base.aspectRatio(contentMode: .fill)
                    }
                    .clipped()
                    .id(reloadToken)
            }
        } else {
            DT.backdrop
                .frame(maxWidth: .infinity)
                .modifier(PreviewFrame(sizeMode: sizeMode))
        }
    }

    // MARK: - Live card

    @ViewBuilder
    private func liveCard(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader
            Divider().opacity(0.25)
            Button {
                onExpand(artifactId)
            } label: {
                // Live artifact, clipped to the fixed preview frame. Wheel
                // events pass through (OverscrollPassthroughWebView), and
                // the card click opens the full surface.
                AutoHeightWebView(url: url, model: heightModel, reloadToken: reloadToken)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .allowsHitTesting(false)
                    .frame(maxWidth: .infinity)
                    .modifier(PreviewFrame(sizeMode: sizeMode))
                    .clipped()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(title) full-surface")
        }
        .frame(width: sizeMode.cardWidth)
        .background(DT.surface)
        .clipShape(RoundedRectangle(cornerRadius: DT.rCard, style: .continuous))
        .overlay(cardBorder)
    }

    // MARK: - Fail-loud state

    /// The artifact server is not running or the URL could not be resolved.
    /// Names the missing artifact id explicitly — never a silent drop.
    @ViewBuilder
    private var unresolvedCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: DT.f12))
                .foregroundStyle(DT.amber)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Artifact not available: \(artifactId)")
                    .font(.system(size: DT.f12, weight: .semibold))
                    .foregroundStyle(DT.textPrimary)
                Text("The artifact server is not running. Start Work 42 or run 'work42 artifact url \(artifactId)' to load it.")
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

    // MARK: - Shared subviews

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private var cardHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "doc.richtext")
                .font(.system(size: DT.f11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: DT.f12, weight: .semibold))
                .foregroundStyle(DT.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if let timestamp, case .chat = sizeMode {
                Text(Self.relativeFormatter.localizedString(for: timestamp, relativeTo: Date()))
                    .font(.system(size: DT.f10))
                    .foregroundStyle(DT.textTertiary)
            }
            expandButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03))
    }

    private var expandButton: some View {
        Button {
            onExpand(artifactId)
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: DT.f11, weight: .medium))
        }
        .glassIconButton()
        .help("Open \(title) full-surface")
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: DT.rCard, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
    }
}

// MARK: - Preview frame

/// Per-mode preview sizing: chat = explicit height from the width contract;
/// thumbnail = 16:9 of whatever width the grid column grants.
private struct PreviewFrame: ViewModifier {
    let sizeMode: ArtifactPreviewCard.SizeMode

    func body(content: Content) -> some View {
        if let height = sizeMode.previewHeight {
            content.frame(height: height)
        } else {
            content.aspectRatio(16 / 9, contentMode: .fit)
        }
    }
}
