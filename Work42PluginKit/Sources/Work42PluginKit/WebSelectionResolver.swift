// WebSelectionResolver.swift — the plugin's ONLY contribution to
// highlight-to-comment.
//
// The SDK (BrowserSurface + BrowserSelectionCommentLayer) owns everything the
// user sees and does: the "＋" bubble, the composer, dictate-to-comment, the
// selection lifecycle. What the SDK can't know is what a given page's selection
// *means* — a GitHub diff selection is really a file + line range; a Jira
// selection is an issue; another site is something else again.
//
// A widget supplies a `WebSelectionResolver`: given the raw selection (text,
// rect, page URL, and a generic map of nearby DOM `data-*` attributes) it
// returns a richer `ResolvedAnnotation` (a useful source label, optionally a
// refined excerpt). Resolution runs ONCE, asynchronously, right before the
// comment is handed to the composer — identically for a typed note and a
// dictated one. Returning `nil` (or no resolver at all) falls back to the SDK's
// plain page-title / host label with the raw selected text. The resolver may do
// async work (e.g. `services.shell.run("gh pr diff …")`); its own timeout
// bounds the wait.

import Foundation
import CoreGraphics

/// A raw text selection captured from a browser widget's webview, handed to a
/// `WebSelectionResolver` for enrichment. All value types — no webview, no
/// closures — so it is trivially inspectable and testable.
public struct WebSelection: Sendable {

    /// The selected text.
    public let text: String

    /// The selection's rect in the surface's view space (for reference; the
    /// SDK already handles bubble/glow positioning).
    public let viewRect: CGRect

    /// The current page URL, when known.
    public let pageURL: URL?

    /// The current page title, when known.
    public let pageTitle: String?

    /// Nearby DOM `data-*` attributes, nearest-ancestor-wins, with the `data-`
    /// prefix stripped (so GitHub's `data-path` arrives as `domContext["path"]`).
    /// Empty when the selection is in plain text with no annotated ancestors.
    public let domContext: [String: String]

    public init(
        text: String,
        viewRect: CGRect,
        pageURL: URL?,
        pageTitle: String?,
        domContext: [String: String]
    ) {
        self.text = text
        self.viewRect = viewRect
        self.pageURL = pageURL
        self.pageTitle = pageTitle
        self.domContext = domContext
    }
}

/// A resolver's enrichment of a raw selection.
public struct ResolvedAnnotation: Sendable {

    /// The source label shown on the comment card (e.g. "PR #42 · File.swift:L12–L18").
    public let sourceLabel: String

    /// An optional refined excerpt. `nil` keeps the raw selected text.
    public let excerpt: String?

    public init(sourceLabel: String, excerpt: String? = nil) {
        self.sourceLabel = sourceLabel
        self.excerpt = excerpt
    }
}

/// Maps a raw web selection into a richer annotation. Runs on the main actor,
/// asynchronously, immediately before the comment reaches the composer. Return
/// `nil` to fall back to the SDK's plain label + raw text.
public typealias WebSelectionResolver = @MainActor (WebSelection) async -> ResolvedAnnotation?

// MARK: - Resolution (pure, testable)

/// The SDK's default source label when no resolver enriches the selection:
/// page title, else URL host, else the widget's fallback, else "Web page".
/// Pure so the fallback behaviour is unit-testable without a webview.
public func plainSelectionLabel(
    pageTitle: String?,
    pageURL: URL?,
    fallbackLabel: String?
) -> String {
    if let pageTitle, !pageTitle.isEmpty { return pageTitle }
    if let host = pageURL?.host, !host.isEmpty { return host }
    if let fallbackLabel, !fallbackLabel.isEmpty { return fallbackLabel }
    return "Web page"
}

/// Resolve a selection into the (sourceLabel, excerpt) that will be attached as
/// a comment. Applies `resolver` when present; a nil resolver OR a nil result
/// falls back to the plain label + the raw selected text. This is the single
/// point BOTH the typed path and the dictated path go through, so they cannot
/// diverge — the invariant made testable here without any UI.
@MainActor
public func resolveSelectionAnnotation(
    _ selection: WebSelection,
    fallbackLabel: String,
    resolver: WebSelectionResolver?
) async -> (sourceLabel: String, excerpt: String) {
    if let resolver, let resolved = await resolver(selection) {
        let refined = resolved.excerpt
        let excerpt = (refined?.isEmpty == false) ? refined! : selection.text
        return (resolved.sourceLabel, excerpt)
    }
    return (fallbackLabel, selection.text)
}
