// MarkdownPreview.swift - The shared rendered-markdown view (spec widget, `.md`
// files in the File widget's Preview mode, meeting summaries, menu surfaces).
//
// Renders in a WebView (`MarkdownWebView`) so docs get browser-grade FREE-FORM
// text selection + copy across the whole document (the block-based MarkdownUI
// renderer only selects one block at a time), host-routed links,
// system-accent-tinted selection, and an optional in-preview comment layer.
// The chat keeps using MarkdownUI directly.

import SwiftUI
import AppKit

/// The policy boundary for every Work42-owned markdown/HTML document.
///
/// All consumers receive the same active-theme document styling, selectable
/// text, canonical outbound-link routing, local-resource handling, and
/// same-document anchor behavior. Those behaviors are not widget options.
/// - `comments` / `onAddComment` / `onViewComment`: the opt-in Preview comment
///   layer (file Preview only). `comments` paints the marks; the callbacks fire
///   with the anchor view + rect so the host can present its popover.
public struct MarkdownPreview: View {
    @Environment(\.openURL) private var openURL

    private let text: String
    private let baseURL: URL?
    private let commentsEnabled: Bool
    private let comments: [MarkdownCommentRange]
    private let onAddComment: ((NSView, CGRect, Int, Int, String) -> Void)?
    private let onViewComment: ((NSView, CGRect, Int) -> Void)?
    /// Fired when a live text selection appears / clears — lets the host publish
    /// it for dictation-to-comment (highlight → push-to-talk → comment).
    private let onSelectionChanged: ((Int, Int, String) -> Void)?
    private let onSelectionCleared: (() -> Void)?
    /// Optional resolver that maps an artifact id to its absolute ArtifactServer
    /// URL. When non-nil, standalone `[[artifact:<id>]]` token lines in the
    /// markdown are rendered as live auto-sized iframes. Nil (the default) means
    /// all surfaces other than the spec widget — no breaking change.
    private let artifactURLResolver: ((String) -> URL?)?
    /// Optional resolver mapping an artifact id to its human title (meta.json),
    /// so an inline embed's header matches the artifact card. Nil → the embed
    /// header falls back to the id.
    private let artifactTitleResolver: ((String) -> String?)?
    /// Called with an artifact id when an inline embed's ⤢ Expand button is
    /// pressed, so the host can open that artifact full-surface.
    private let onArtifactExpand: ((String) -> Void)?
    /// When true, the preview sizes itself to its rendered content (the page
    /// reports its height via a ResizeObserver) so it can sit inside an outer
    /// ScrollView with other views stacked below — e.g. the Testing Plan
    /// widget's plan body above its flows list. The default (false) keeps the
    /// fill-the-space behaviour for surfaces that own their whole widget.
    private let autoHeight: Bool
    /// Raw HTML appended after the markdown inside the same document — the
    /// host's bundled components (e.g. the Testing Plan's HTML-rendered
    /// flows). See `MarkdownWebView.trailingHTML`.
    private let trailingHTML: String
    /// Page → host bridge for anchoring native UI from in-document controls.
    /// See `MarkdownWebView.onBridgeMessage`.
    private let onBridgeMessage: ((_ payload: [String: Any], _ view: NSView, _ rect: CGRect) -> Void)?

    @State private var measuredHeight: CGFloat = 0

    /// The diagram whose Expand button was pressed — presents the native dialog.
    private struct DiagramExpandItem: Identifiable {
        let id = UUID()
        let svg: String
    }
    @State private var diagramExpand: DiagramExpandItem?

    public init(
        text: String,
        baseURL: URL? = nil,
        commentsEnabled: Bool = false,
        comments: [MarkdownCommentRange] = [],
        onAddComment: ((NSView, CGRect, Int, Int, String) -> Void)? = nil,
        onViewComment: ((NSView, CGRect, Int) -> Void)? = nil,
        onSelectionChanged: ((Int, Int, String) -> Void)? = nil,
        onSelectionCleared: (() -> Void)? = nil,
        artifactURLResolver: ((String) -> URL?)? = nil,
        artifactTitleResolver: ((String) -> String?)? = nil,
        onArtifactExpand: ((String) -> Void)? = nil,
        autoHeight: Bool = false,
        trailingHTML: String = "",
        onBridgeMessage: ((_ payload: [String: Any], _ view: NSView, _ rect: CGRect) -> Void)? = nil
    ) {
        self.text = text
        self.baseURL = baseURL
        self.commentsEnabled = commentsEnabled
        self.comments = comments
        self.onAddComment = onAddComment
        self.onViewComment = onViewComment
        self.onSelectionChanged = onSelectionChanged
        self.onSelectionCleared = onSelectionCleared
        self.artifactURLResolver = artifactURLResolver
        self.artifactTitleResolver = artifactTitleResolver
        self.onArtifactExpand = onArtifactExpand
        self.autoHeight = autoHeight
        self.trailingHTML = trailingHTML
        self.onBridgeMessage = onBridgeMessage
    }

    public var body: some View {
        let routedOpenLink: (URL) -> Void = { url in
            Self.routeOpenLink(url, host: { openURL($0) })
        }
        let webView = MarkdownWebView(
            text: text,
            baseURL: baseURL,
            onOpenLink: routedOpenLink,
            commentsEnabled: commentsEnabled,
            comments: comments,
            onAddComment: onAddComment,
            onViewComment: onViewComment,
            onSelectionChanged: onSelectionChanged,
            onSelectionCleared: onSelectionCleared,
            artifactURLResolver: artifactURLResolver,
            artifactTitleResolver: artifactTitleResolver,
            onContentHeight: autoHeight
                ? { h in
                    DispatchQueue.main.async {
                        if abs(measuredHeight - h) > 0.5 { measuredHeight = h }
                    }
                }
                : nil,
            trailingHTML: trailingHTML,
            onBridgeMessage: onBridgeMessage,
            onDiagramExpand: { svg in diagramExpand = DiagramExpandItem(svg: svg) },
            onArtifactExpand: onArtifactExpand
        )
        Group {
            if autoHeight {
                webView
                    .frame(maxWidth: .infinity)
                    .frame(height: max(measuredHeight, 1))
            } else {
                webView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Present a diagram full-size in the native dialog when its card-header
        // Expand button is pressed (any markdown surface — spec, file preview…).
        .sheet(item: $diagramExpand) { item in
            DiagramExpandDialog(svg: item.svg) { diagramExpand = nil }
        }
    }

    /// Routes every outbound document link through the inherited host action.
    /// Kept internal so tests can prove the mandatory policy without exposing
    /// a widget-level customization point.
    static func routeOpenLink(_ url: URL, host: (URL) -> Void) {
        host(url)
    }
}
