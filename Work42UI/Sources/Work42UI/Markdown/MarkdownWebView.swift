// MarkdownWebView.swift - A WKWebView-based markdown renderer.
//
// Renders markdown → themed HTML in a real web view so docs get browser-grade
// FREE-FORM text selection + copy across the whole document (which the
// block-based MarkdownUI renderer can't do), host-routed links,
// system-accent-tinted selection, and an optional in-preview comment
// layer with the same UX as the native editor gutter. `MarkdownPreview` wraps
// this so every non-chat markdown surface benefits without call-site churn.

import SwiftUI
import WebKit
import AppKit

/// A 1-based inclusive source line range that carries a comment, projected into
/// the preview so the block(s) covering it get an accent mark.
public struct MarkdownCommentRange: Equatable, Sendable {
    public let startLine: Int
    public let endLine: Int
    public init(startLine: Int, endLine: Int) {
        self.startLine = startLine
        self.endLine = endLine
    }
}

@MainActor
/// WKWebView that can hand its scroll-wheel events to the enclosing SwiftUI
/// ScrollView. In auto-height mode the webview is sized to its full content,
/// so it has nothing to scroll itself — but a stock WKWebView still consumes
/// wheel events, which freezes the outer scroll whenever the cursor is over
/// the document. Forwarding to the next responder restores normal scrolling.
private final class PassthroughScrollWebView: WKWebView {
    var forwardsScrollEvents = false

    override func scrollWheel(with event: NSEvent) {
        if forwardsScrollEvents {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// Internal rendering engine for `MarkdownPreview`. Keeping this type out of
/// Work42UI's public API prevents document widgets from bypassing the shared
/// theme, navigation, selection, and resource policies owned by the preview.
struct MarkdownWebView: NSViewRepresentable {

    private let text: String
    /// The doc's own URL — the base for resolving relative image/link paths and
    /// for distinguishing same-doc `#anchor` links from outbound links.
    private let baseURL: URL?
    /// Called for any outbound user-activated link after resolving it to one
    /// canonical URL. The host owns intent dispatch and destination selection.
    /// Mandatory route supplied by `MarkdownPreview`, the public document
    /// policy boundary. The renderer must never decide to open an outbound URL
    /// itself or silently fall back to a process-global notification.
    private let onOpenLink: (URL) -> Void

    /// Comment layer. Enabled only for the file Preview; other surfaces render
    /// read-only. `comments` drives the persistent marks; the callbacks fire on
    /// the floating add-button click and on a mark click, with the anchor view +
    /// rect so the caller can present an NSPopover next to it.
    private let commentsEnabled: Bool
    private let comments: [MarkdownCommentRange]
    private let onAddComment: ((NSView, CGRect, Int, Int, String) -> Void)?
    private let onViewComment: ((NSView, CGRect, Int) -> Void)?
    /// Fired when a live text selection appears / clears (1-based line span +
    /// excerpt), so the host can publish it for dictation-to-comment.
    private let onSelectionChanged: ((Int, Int, String) -> Void)?
    private let onSelectionCleared: (() -> Void)?

    /// Optional resolver that maps an artifact id to its absolute ArtifactServer
    /// URL. When non-nil, standalone `[[artifact:<id>]]` token lines in the
    /// markdown are replaced with live auto-sized iframes. Nil means no artifact
    /// embedding (token lines render as literal text). Supplied by Work42App so
    /// Work42UI stays free of Flow42Core.
    private let artifactURLResolver: ((String) -> URL?)?
    /// Artifact id → human title (meta.json) resolver. Lets the inline-embed
    /// header show the same title as the artifact card instead of the raw id.
    /// Nil → the bridge falls back to the id. Supplied by Work42App.
    private let artifactTitleResolver: ((String) -> String?)?
    /// Auto-height reporting. When non-nil the page installs a ResizeObserver
    /// that posts the document height to this callback (main thread), so the
    /// host can size the webview to its content and embed it inside an outer
    /// ScrollView. A webview without this callback must own its scroll space —
    /// inside a ScrollView it collapses (no intrinsic height).
    private let onContentHeight: ((CGFloat) -> Void)?
    /// Raw HTML appended AFTER the converted markdown fragment, inside the
    /// same document (same template, same theme). This is how a host bundles
    /// non-markdown components — e.g. the Testing Plan widget's HTML-rendered
    /// flows — into one scrolling document. The caller is responsible for
    /// escaping and for rewriting any local `<img>` srcs (the markdown
    /// fragment's rewrite pass does not touch this string).
    private let trailingHTML: String
    /// Generic page → host bridge (`w42bridge` message handler). The page
    /// posts `{type, ..., rect: {x,y,w,h}}`; the callback receives the payload
    /// plus the webview + view-space rect so the host can anchor native UI
    /// (menus, popovers) at the click point — the same anchoring pattern as
    /// the comment layer.
    private let onBridgeMessage: ((_ payload: [String: Any], _ view: NSView, _ rect: CGRect) -> Void)?
    /// Fired with a diagram's SVG when its card-header Expand button is pressed,
    /// so the host can present the native expand dialog. Every markdown surface
    /// gets this (the diagram bridge is always injected).
    private let onDiagramExpand: ((String) -> Void)?
    /// Fired with an artifact id when an inline-embed card header's Expand button
    /// is pressed, so the host can open that artifact full-surface (mirrors the
    /// gallery card's ⤢ affordance).
    private let onArtifactExpand: ((String) -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    init(
        text: String,
        baseURL: URL? = nil,
        onOpenLink: @escaping (URL) -> Void,
        commentsEnabled: Bool = false,
        comments: [MarkdownCommentRange] = [],
        onAddComment: ((NSView, CGRect, Int, Int, String) -> Void)? = nil,
        onViewComment: ((NSView, CGRect, Int) -> Void)? = nil,
        onSelectionChanged: ((Int, Int, String) -> Void)? = nil,
        onSelectionCleared: (() -> Void)? = nil,
        artifactURLResolver: ((String) -> URL?)? = nil,
        artifactTitleResolver: ((String) -> String?)? = nil,
        onContentHeight: ((CGFloat) -> Void)? = nil,
        trailingHTML: String = "",
        onBridgeMessage: ((_ payload: [String: Any], _ view: NSView, _ rect: CGRect) -> Void)? = nil,
        onDiagramExpand: ((String) -> Void)? = nil,
        onArtifactExpand: ((String) -> Void)? = nil
    ) {
        self.text = text
        self.baseURL = baseURL
        self.onOpenLink = onOpenLink
        self.commentsEnabled = commentsEnabled
        self.comments = comments
        self.onAddComment = onAddComment
        self.onViewComment = onViewComment
        self.onSelectionChanged = onSelectionChanged
        self.onSelectionCleared = onSelectionCleared
        self.artifactURLResolver = artifactURLResolver
        self.artifactTitleResolver = artifactTitleResolver
        self.onContentHeight = onContentHeight
        self.trailingHTML = trailingHTML
        self.onBridgeMessage = onBridgeMessage
        self.onDiagramExpand = onDiagramExpand
        self.onArtifactExpand = onArtifactExpand
    }

    public func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Serve local images + the bundled mermaid library over the w42res://
        // scheme (WKWebView blocks direct file loads under loadHTMLString).
        config.setURLSchemeHandler(
            MarkdownResourceSchemeHandler(
                mermaidLibrary: CanvasTemplate.mermaidLibrary(),
                highlightLibrary: CanvasTemplate.highlightLibrary()
            ),
            forURLScheme: MarkdownResourceSchemeHandler.scheme
        )
        // Always create the content controller and register the diagram-expand
        // handler at build time — the diagram bridge is always injected (see
        // MarkdownDocumentTemplate), and its Expand button posts to
        // `w42Diagram`, which is only exposed to the page if the handler existed
        // when the page loaded.
        let ucc = WKUserContentController()
        ucc.add(context.coordinator, name: Coordinator.diagramName)
        if commentsEnabled {
            ucc.add(context.coordinator, name: Coordinator.messageName)
            ucc.addUserScript(WKUserScript(
                source: Coordinator.commentUserScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }
        if onContentHeight != nil {
            ucc.add(context.coordinator, name: Coordinator.heightMessageName)
            ucc.addUserScript(WKUserScript(
                source: Coordinator.heightUserScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }
        if onBridgeMessage != nil {
            ucc.add(context.coordinator, name: Coordinator.bridgeMessageName)
        }
        config.userContentController = ucc
        let webView = PassthroughScrollWebView(frame: .zero, configuration: config)
        // Auto-height mode: the view is sized to its content, so wheel events
        // belong to the enclosing ScrollView.
        webView.forwardsScrollEvents = onContentHeight != nil
        webView.navigationDelegate = context.coordinator
        // Transparent background so the doc sits on the tile surface.
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.baseURL = baseURL
        context.coordinator.commentsEnabled = commentsEnabled
        context.coordinator.comments = comments
        context.coordinator.onContentHeight = onContentHeight
        context.coordinator.onBridgeMessage = onBridgeMessage
        context.coordinator.onDiagramExpand = onDiagramExpand
        context.coordinator.onArtifactExpand = onArtifactExpand
        context.coordinator.onSelectionChanged = onSelectionChanged
        context.coordinator.onSelectionCleared = onSelectionCleared
        context.coordinator.trailingHTML = trailingHTML
        context.coordinator.load(webView, text: text, dark: colorScheme == .dark)
        return webView
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onOpenLink = onOpenLink
        context.coordinator.onAddComment = onAddComment
        context.coordinator.onViewComment = onViewComment
        context.coordinator.onSelectionChanged = onSelectionChanged
        context.coordinator.onSelectionCleared = onSelectionCleared
        context.coordinator.baseURL = baseURL
        context.coordinator.commentsEnabled = commentsEnabled
        context.coordinator.artifactURLResolver = artifactURLResolver
        context.coordinator.artifactTitleResolver = artifactTitleResolver
        context.coordinator.onContentHeight = onContentHeight
        context.coordinator.onBridgeMessage = onBridgeMessage
        context.coordinator.onDiagramExpand = onDiagramExpand
        context.coordinator.onArtifactExpand = onArtifactExpand
        context.coordinator.trailingHTML = trailingHTML
        context.coordinator.reloadIfNeeded(webView, text: text, dark: colorScheme == .dark)
        // Comment-only changes update the marks in place (no reload, so scroll +
        // any live selection survive).
        context.coordinator.applyComments(comments, to: webView)
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            onOpenLink: onOpenLink,
            onAddComment: onAddComment,
            onViewComment: onViewComment,
            artifactURLResolver: artifactURLResolver,
            artifactTitleResolver: artifactTitleResolver
        )
    }

    public static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.messageName)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.heightMessageName)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.bridgeMessageName)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.diagramName)
    }

    // MARK: - Coordinator

    public final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let messageName = "w42comment"
        static let heightMessageName = "w42height"

        /// ResizeObserver → height messages so the host can auto-size the
        /// webview to its content (see `onContentHeight`). Measures
        /// `body.offsetHeight` (content + body padding), NOT
        /// `documentElement.scrollHeight` — the latter can never report less
        /// than the viewport, so once the host sizes the frame to a reading it
        /// ratchets and never shrinks when the content settles.
        static let heightUserScript = """
        (function () {
          const post = () => {
            const h = document.body.offsetHeight;
            window.webkit.messageHandlers.\(heightMessageName).postMessage(h);
          };
          new ResizeObserver(post).observe(document.body);
          post();
        })();
        """

        var onContentHeight: ((CGFloat) -> Void)?

        static let bridgeMessageName = "w42bridge"
        /// Generic page → host bridge callback (payload, webview, view rect).
        var onBridgeMessage: ((_ payload: [String: Any], _ view: NSView, _ rect: CGRect) -> Void)?

        /// Diagram-bridge expand handler (`w42Diagram`). Matches
        /// `DiagramMessageProxy.name`. Fired with the diagram's SVG after
        /// resolving the posted id.
        static let diagramName = "w42Diagram"
        var onDiagramExpand: ((String) -> Void)?
        /// Inline-embed Expand → open the artifact full-surface (posted on the
        /// same `w42Diagram` handler with `{type:"artifact-expand", id}`).
        var onArtifactExpand: ((String) -> Void)?

        /// Raw HTML appended after the markdown fragment at load time.
        var trailingHTML = ""

        var onOpenLink: (URL) -> Void
        var onAddComment: ((NSView, CGRect, Int, Int, String) -> Void)?
        var onViewComment: ((NSView, CGRect, Int) -> Void)?
        /// A live text selection appeared (1-based line span + excerpt) — used to
        /// publish it for dictation-to-comment. Fired on selection, not "+"-click.
        var onSelectionChanged: ((Int, Int, String) -> Void)?
        var onSelectionCleared: (() -> Void)?
        var baseURL: URL?
        var commentsEnabled = false
        var comments: [MarkdownCommentRange] = []
        /// Artifact id → absolute ArtifactServer URL resolver. Nil when the
        /// surface doesn't support inline artifact embeds (default for all
        /// markdown surfaces except the spec widget).
        var artifactURLResolver: ((String) -> URL?)?
        var artifactTitleResolver: ((String) -> String?)?
        private var lastKey: String?
        private var lastCommentsKey: String?

        init(
            onOpenLink: @escaping (URL) -> Void,
            onAddComment: ((NSView, CGRect, Int, Int, String) -> Void)?,
            onViewComment: ((NSView, CGRect, Int) -> Void)?,
            artifactURLResolver: ((String) -> URL?)? = nil,
            artifactTitleResolver: ((String) -> String?)? = nil
        ) {
            self.onOpenLink = onOpenLink
            self.onAddComment = onAddComment
            self.onViewComment = onViewComment
            self.artifactURLResolver = artifactURLResolver
            self.artifactTitleResolver = artifactTitleResolver
        }

        func load(_ webView: WKWebView, text: String, dark: Bool) {
            // Preprocess [[artifact:<id>]] tokens before cmark conversion.
            // When a resolver is provided, standalone token lines are replaced
            // with raw HTML divs that cmark passes through (CMARK_OPT_UNSAFE /
            // HTML block type 6). The bridge script then converts them to
            // live auto-sized iframes at runtime.
            var anyArtifacts = false
            let processedText = MarkdownArtifactRewriter.preprocess(
                markdown: text,
                artifactURLResolver: artifactURLResolver,
                artifactTitleResolver: artifactTitleResolver,
                foundAny: &anyArtifacts
            )
            // Source positions are only needed when the comment layer maps
            // selections → lines; skip the extra attributes otherwise.
            let rawFragment = MarkdownHTMLConverter.html(from: processedText, sourcePositions: commentsEnabled)
            // Rewrite local <img> srcs to the w42res:// scheme so the scheme
            // handler can serve them (relative paths resolve against the doc's
            // own directory). http(s)/data srcs pass through untouched.
            var fragment = MarkdownImageRewriter.rewrite(html: rawFragment, baseURL: baseURL)
            // Host-supplied component HTML rides in the same document, after
            // the markdown. The caller pre-rewrote its local <img> srcs (they
            // may resolve against different base dirs than the doc's own).
            fragment += trailingHTML
            let html = MarkdownDocumentTemplate.compose(
                fragment: fragment,
                dark: dark,
                accent: Self.accent(dark: dark),
                commentsEnabled: commentsEnabled,
                // Inject bridge CSS+JS when a resolver is wired in (the script
                // is a no-op if the preprocessor found no tokens, so we don't
                // track anyArtifacts here — keeping it always-on when the
                // resolver is present avoids a second reload if the spec is
                // later edited to add a token).
                injectArtifactBridge: artifactURLResolver != nil
            )
            webView.loadHTMLString(html, baseURL: baseURL)
            lastKey = key(text: text, dark: dark)
            // Re-apply on the next load (didFinish) — reset so applyComments runs.
            lastCommentsKey = nil
        }

        func reloadIfNeeded(_ webView: WKWebView, text: String, dark: Bool) {
            guard key(text: text, dark: dark) != lastKey else { return }
            // Mark the new key BEFORE the async scroll capture so re-entrant
            // updateNSView calls don't double-load.
            lastKey = key(text: text, dark: dark)
            // Preserve the scroll position across the reload: an in-document
            // control (config/device capsule) re-renders the document on
            // write, and a selector must not jump the page to the top. The
            // offset is restored in `didFinish`.
            webView.evaluateJavaScript("window.scrollY") { [weak self] value, _ in
                guard let self else { return }
                self.pendingScrollY = (value as? NSNumber)?.doubleValue
                self.load(webView, text: text, dark: dark)
            }
        }

        /// Scroll offset to restore after the next `didFinish` (reload-only;
        /// nil on first load).
        private var pendingScrollY: Double?

        private func key(text: String, dark: Bool) -> String {
            // ThemeRuntime.generation: the document CSS bakes resolved theme
            // tokens at compose time, so a same-mode theme swap (same text,
            // same dark flag, new token values) must still read as stale and
            // trigger a re-compose on the next updateNSView (AC9).
            "\(dark)|\(ThemeRuntime.generation)|\(commentsEnabled)|\(baseURL?.path ?? "")|\(artifactURLResolver != nil)|\(text.hashValue)|\(trailingHTML.hashValue)"
        }

        // MARK: Comment marks

        /// Push the current comment ranges into the page (idempotent). Cheap
        /// no-op when nothing changed so per-frame `updateNSView` calls are free.
        func applyComments(_ ranges: [MarkdownCommentRange], to webView: WKWebView) {
            self.comments = ranges
            guard commentsEnabled else { return }
            let ck = ranges.map { "\($0.startLine)-\($0.endLine)" }.joined(separator: ",")
            guard ck != lastCommentsKey else { return }
            lastCommentsKey = ck
            evaluateApply(ranges, in: webView)
        }

        private func evaluateApply(_ ranges: [MarkdownCommentRange], in webView: WKWebView) {
            let items = ranges
                .map { "{\"startLine\":\($0.startLine),\"endLine\":\($0.endLine)}" }
                .joined(separator: ",")
            webView.evaluateJavaScript("window.w42ApplyComments && window.w42ApplyComments([\(items)]);", completionHandler: nil)
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Restore the pre-reload scroll offset (see `reloadIfNeeded`).
            if let y = pendingScrollY, y > 0 {
                webView.evaluateJavaScript("window.scrollTo(0, \(y));", completionHandler: nil)
            }
            pendingScrollY = nil
            guard commentsEnabled else { return }
            // The document (+ user script) is ready — paint the initial marks.
            lastCommentsKey = comments.map { "\($0.startLine)-\($0.endLine)" }.joined(separator: ",")
            evaluateApply(comments, in: webView)
        }

        // MARK: Script messages (add / view comment)

        public func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            if message.name == Self.diagramName {
                guard let dict = message.body as? [String: Any],
                      let type = dict["type"] as? String,
                      let id = dict["id"] as? String, !id.isEmpty else { return }
                // Inline-embed Expand: open the artifact full-surface. The id is
                // the artifact id (not a diagram id), handed straight to the host.
                if type == "artifact-expand" {
                    onArtifactExpand?(id)
                    return
                }
                // Diagram Expand: resolve the posted id to its SVG, then hand it
                // to the host to present the native dialog.
                guard type == "expand", let web = message.webView else { return }
                web.evaluateJavaScript(
                    "window.__w42Diagram ? __w42Diagram.svg('\(id)') : ''"
                ) { [weak self] result, _ in
                    let svg = (result as? String) ?? ""
                    if !svg.isEmpty { self?.onDiagramExpand?(svg) }
                }
                return
            }
            if message.name == Self.heightMessageName {
                if let h = (message.body as? NSNumber)?.doubleValue, h > 0 {
                    onContentHeight?(CGFloat(h))
                }
                return
            }
            if message.name == Self.bridgeMessageName {
                guard let dict = message.body as? [String: Any],
                      let web = message.webView else { return }
                var rect = CGRect.zero
                if let r = dict["rect"] as? [String: Any] {
                    let x = (r["x"] as? NSNumber)?.doubleValue ?? 0
                    let y = (r["y"] as? NSNumber)?.doubleValue ?? 0
                    let w = (r["w"] as? NSNumber)?.doubleValue ?? 0
                    let h = (r["h"] as? NSNumber)?.doubleValue ?? 0
                    // Same coordinate mapping as the comment layer: JS rects
                    // are viewport-top-left; WKWebView is a flipped NSView.
                    rect = web.isFlipped
                        ? NSRect(x: x, y: y, width: w, height: h)
                        : NSRect(x: x, y: web.bounds.height - y - h, width: w, height: h)
                }
                onBridgeMessage?(dict, web, rect)
                return
            }
            guard message.name == Self.messageName,
                  let dict = message.body as? [String: Any],
                  let type = dict["type"] as? String,
                  let web = message.webView else { return }
            // Live-selection publish for dictation-to-comment (no rect needed).
            if type == "select-clear" { onSelectionCleared?(); return }
            if type == "select" {
                let s = (dict["startLine"] as? NSNumber)?.intValue ?? 1
                let e = (dict["endLine"] as? NSNumber)?.intValue ?? s
                onSelectionChanged?(s, e, dict["excerpt"] as? String ?? "")
                return
            }
            guard let rectDict = dict["rect"] as? [String: Any] else { return }
            let startLine = (dict["startLine"] as? NSNumber)?.intValue ?? 1
            let endLine = (dict["endLine"] as? NSNumber)?.intValue ?? startLine
            let excerpt = dict["excerpt"] as? String ?? ""
            let cx = (rectDict["x"] as? NSNumber)?.doubleValue ?? 0
            let cy = (rectDict["y"] as? NSNumber)?.doubleValue ?? 0
            let cw = (rectDict["w"] as? NSNumber)?.doubleValue ?? 0
            let ch = (rectDict["h"] as? NSNumber)?.doubleValue ?? 0
            // JS rect is CSS/viewport px (top-left origin, y-down). WKWebView is
            // a *flipped* NSView, so those coordinates map straight through; only
            // flip y for the (rare) non-flipped case to anchor the popover right
            // at the selection instead of far down the view.
            let viewRect = web.isFlipped
                ? NSRect(x: cx, y: cy, width: cw, height: ch)
                : NSRect(x: cx, y: web.bounds.height - cy - ch, width: cw, height: ch)
            switch type {
            case "add": onAddComment?(web, viewRect, startLine, endLine, excerpt)
            case "view": onViewComment?(web, viewRect, startLine)
            default: break
            }
        }

        // MARK: Accent

        /// ACTIVE-THEME accent RGB for links, selection, and comment marks
        /// (the macOS accent under the System palette). Keep the resolved
        /// theme color as the fallback if AppKit cannot convert its color
        /// space; falling back to system blue would violate custom themes.
        static func accent(dark: Bool) -> MarkdownDocumentTemplate.Accent {
            let raw = DT.resolvedAccent(isDark: dark)
            let c = raw.usingColorSpace(.sRGB) ?? raw
            return MarkdownDocumentTemplate.Accent(
                r: Int((c.redComponent * 255).rounded()),
                g: Int((c.greenComponent * 255).rounded()),
                b: Int((c.blueComponent * 255).rounded())
            )
        }

        // MARK: Link routing

        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            // Only intercept user clicks; allow the initial document load itself.
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            // Same-doc `#anchor` (not a line token) → let the web view scroll.
            if url.isFileURL, let frag = url.fragment, !frag.isEmpty,
               url.path == baseURL?.path, Self.lineToken(frag) == nil {
                decisionHandler(.allow)
                return
            }

            // Content surfaces never navigate outbound links themselves. Hand
            // one canonical URL to the host's visible Open Link intent. WebKit
            // has already resolved ordinary relative hrefs against `baseURL`;
            // the fallback also normalizes the `path:line` spelling that
            // WebKit parses as a custom scheme.
            let canonicalURL = Self.canonicalLinkURL(url, baseURL: baseURL)
            onOpenLink(canonicalURL)
            decisionHandler(.cancel)
        }

        /// Return the canonical URL dispatched to Open Link. HTTP/custom URLs
        /// pass through untouched. Local references are standardized and a
        /// trailing `:line` is represented as `#L<line>` so the Files handler
        /// can interpret it without the original href or source base.
        static func canonicalLinkURL(_ url: URL, baseURL: URL?) -> URL {
            let scheme = url.scheme?.lowercased()
            let isLocalReference = scheme == nil || scheme == "file" || scheme == "applewebdata"
                || (scheme?.contains(".") == true && baseURL?.isFileURL == true)
            guard isLocalReference else { return url.absoluteURL }
            guard let (fileURL, line) = resolveLocalLink(url, baseURL: baseURL) else {
                return url.absoluteURL
            }
            guard let line else { return fileURL }
            var components = URLComponents(url: fileURL, resolvingAgainstBaseURL: false)
            components?.fragment = "L\(line)"
            return components?.url ?? fileURL
        }

        /// Resolve any non-web link to an absolute local file URL + optional
        /// 1-based line, handling `file://` URLs, relative paths, and the
        /// `path:line` / `path#Lnn` line-suffix forms LLMs commonly produce.
        static func resolveLocalLink(_ url: URL, baseURL: URL?) -> (URL, Int?)? {
            // Case 1: WebKit already resolved it to a real file URL.
            if url.isFileURL {
                var path = url.path
                var line = url.fragment.flatMap(lineToken)
                if line == nil {
                    let (p, l) = splitTrailingLine(path)
                    path = p; line = l
                }
                return (URL(fileURLWithPath: path).standardizedFileURL, line)
            }
            // Case 2: a colon in the first path segment made WebKit read the ref
            // as a bogus scheme (e.g. `Foo.swift:42` → scheme `foo.swift`).
            // Reconstruct from the raw string, resolved against the base dir.
            guard let baseDir = baseURL?.deletingLastPathComponent() else { return nil }
            var raw = url.absoluteString
            var line: Int? = nil
            if let hashIdx = raw.lastIndex(of: "#") {
                line = lineToken(String(raw[raw.index(after: hashIdx)...]))
                raw = String(raw[..<hashIdx])
            }
            if line == nil {
                let (p, l) = splitTrailingLine(raw)
                raw = p; line = l
            }
            guard !raw.isEmpty else { return nil }
            let resolved = URL(fileURLWithPath: raw, relativeTo: baseDir).standardizedFileURL
            return (resolved, line)
        }

        /// Extract a 1-based line from a fragment like `L42`, `l42`, or `42`.
        static func lineToken(_ fragment: String) -> Int? {
            var s = fragment
            if s.hasPrefix("L") || s.hasPrefix("l") { s.removeFirst() }
            // `L42-L50` → take the first number.
            if let dash = s.firstIndex(where: { $0 == "-" }) { s = String(s[..<dash]) }
            return Int(s)
        }

        /// Split a trailing `:NN` line suffix off a path. `"a/b.swift:42"` →
        /// `("a/b.swift", 42)`; no suffix → `(path, nil)`. Only fires when the
        /// text after the last colon is all digits (so `C:` style stays intact).
        static func splitTrailingLine(_ path: String) -> (String, Int?) {
            guard let colon = path.lastIndex(of: ":") else { return (path, nil) }
            let after = String(path[path.index(after: colon)...])
            guard !after.isEmpty, after.allSatisfy(\.isNumber), let n = Int(after) else {
                return (path, nil)
            }
            return (String(path[..<colon]), n)
        }

        // MARK: Injected comment script

        /// The in-page comment layer: shows a floating "add comment" button next
        /// to a live text selection, posts the selected source-line range on
        /// click, paints accent marks on commented blocks (via
        /// `window.w42ApplyComments`), and posts a "view" message on a mark
        /// click. Static + constant — dynamic data flows in via evaluateJavaScript.
        static let commentUserScript = #"""
        (function(){
          if (window.__w42CommentInit) return;
          window.__w42CommentInit = true;

          var LEAF = {P:1,LI:1,H1:1,H2:1,H3:1,H4:1,H5:1,H6:1,PRE:1,BLOCKQUOTE:1,TD:1,TH:1,DD:1,DT:1};

          function sourcePos(el){
            var sp = el.getAttribute && el.getAttribute('data-sourcepos');
            if(!sp) return null;
            var m = sp.match(/^(\d+):\d+-(\d+):\d+$/);
            if(!m) return null;
            return { start: parseInt(m[1],10), end: parseInt(m[2],10) };
          }
          function blockOf(node){
            var el = (node && node.nodeType === 3) ? node.parentElement : node;
            while(el && !(el.getAttribute && el.getAttribute('data-sourcepos'))) el = el.parentElement;
            return el;
          }
          function selectionInfo(){
            var sel = window.getSelection();
            if(!sel || sel.isCollapsed || sel.rangeCount === 0) return null;
            var r = sel.getRangeAt(0);
            var text = sel.toString();
            if(!text || !text.trim()) return null;
            var b1 = blockOf(r.startContainer), b2 = blockOf(r.endContainer);
            if(!b1 || !b2) return null;
            var p1 = sourcePos(b1), p2 = sourcePos(b2);
            if(!p1 || !p2) return null;
            var rect = r.getBoundingClientRect();
            return {
              startLine: Math.min(p1.start, p2.start),
              endLine: Math.max(p1.end, p2.end),
              excerpt: text,
              rect: { x: rect.left, y: rect.top, w: rect.width, h: rect.height }
            };
          }
          function post(msg){
            if(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.w42comment){
              window.webkit.messageHandlers.w42comment.postMessage(msg);
            }
          }

          var addBtn = document.createElement('button');
          addBtn.id = 'w42-add';
          addBtn.textContent = '+';
          addBtn.title = 'Comment (⌘K)';
          document.body.appendChild(addBtn);
          var pending = null;

          function hideAdd(){ addBtn.style.display = 'none'; pending = null; post({ type:'select-clear' }); }
          function refreshAdd(){
            var info = selectionInfo();
            if(!info){ hideAdd(); return; }
            pending = info;
            // Gutter-style: pin to the left margin, vertically at the selection
            // start — mirrors the file editor's "+" at the start of the line.
            addBtn.style.top = Math.max(4, info.rect.y) + 'px';
            addBtn.style.left = '4px';
            addBtn.style.display = 'inline-flex';
            // Publish the live selection so push-to-talk can dictate a comment
            // on it without opening the dialog.
            post({ type:'select', startLine:info.startLine, endLine:info.endLine, excerpt:info.excerpt });
          }
          function commit(info, rect){
            post({ type:'add', startLine:info.startLine, endLine:info.endLine, excerpt:info.excerpt,
                   rect:{ x:rect.x, y:rect.y, w:rect.w, h:rect.h } });
            hideAdd();
            var s = window.getSelection(); if(s) s.removeAllRanges();
          }

          document.addEventListener('mouseup', function(){ setTimeout(refreshAdd, 10); });
          document.addEventListener('keyup', function(){ setTimeout(refreshAdd, 10); });
          document.addEventListener('mousedown', function(e){ if(e.target !== addBtn) hideAdd(); });
          addBtn.addEventListener('mousedown', function(e){ e.preventDefault(); });
          addBtn.addEventListener('click', function(e){
            e.preventDefault();
            var info = pending || selectionInfo();
            if(!info) return;
            var br = addBtn.getBoundingClientRect();
            commit(info, { x:br.left, y:br.top, w:br.width, h:br.height });
          });

          // ⌘K (⌃K) — comment on the current selection, anchored to it. The same
          // universal shortcut the file editor uses; not a replacement for the
          // "+" affordance.
          document.addEventListener('keydown', function(e){
            if((e.metaKey || e.ctrlKey) && (e.key === 'k' || e.key === 'K')){
              var info = selectionInfo();
              if(!info) return;
              e.preventDefault();
              commit(info, info.rect);
            }
          });

          window.w42ApplyComments = function(ranges){
            document.querySelectorAll('.w42-commented').forEach(function(el){
              el.classList.remove('w42-commented'); el.classList.remove('w42-comment-host');
            });
            document.querySelectorAll('.w42-comment-marker').forEach(function(el){ el.remove(); });
            if(!ranges || !ranges.length) return;
            var marked = {};
            var blocks = document.querySelectorAll('[data-sourcepos]');
            blocks.forEach(function(el){
              if(!LEAF[el.tagName]) return;
              var pos = sourcePos(el); if(!pos) return;
              for(var i=0;i<ranges.length;i++){
                var rg = ranges[i];
                if(pos.start <= rg.endLine && pos.end >= rg.startLine){
                  el.classList.add('w42-commented');
                  var keyed = rg.startLine + ':' + rg.endLine;
                  if(!marked[keyed] && pos.start <= rg.startLine && pos.end >= rg.startLine){
                    marked[keyed] = true;
                    el.classList.add('w42-comment-host');
                    var mk = document.createElement('span');
                    mk.className = 'w42-comment-marker';
                    mk.textContent = '💬';
                    mk.setAttribute('data-line', rg.startLine);
                    mk.addEventListener('click', function(ev){
                      ev.stopPropagation();
                      var mr = this.getBoundingClientRect();
                      var ln = parseInt(this.getAttribute('data-line'),10);
                      post({ type:'view', startLine:ln, endLine:ln, excerpt:'',
                             rect:{ x:mr.left, y:mr.top, w:mr.width, h:mr.height } });
                    });
                    el.insertBefore(mk, el.firstChild);
                  }
                  break;
                }
              }
            });
          };
        })();
        """#
    }
}
