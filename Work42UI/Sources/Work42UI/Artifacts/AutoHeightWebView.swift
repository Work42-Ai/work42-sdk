// AutoHeightWebView.swift — feat/spec-as-html.7
//
// A WKWebView wrapper that measures its content height via a
// WKScriptMessageHandler and publishes the result through an ObservableObject
// observed ONLY by the small card child view (AutoHeightWebHost), NOT by the
// surrounding chat list.
//
// Per-frame-@State-write gotcha (see MEMORY.md / known codebase issue):
// Writing `document.body.scrollHeight` straight into a @State var on the
// chat list body causes the WHOLE transcript to re-render ~60fps during
// any height animation. The fix here: AutoHeightModel is the ObservableObject
// that publishes the height; AutoHeightWebHost owns a @StateObject private
// var (isolated to the card subtree) that it observes. The chat-list body
// never observes AutoHeightModel, so height changes never re-evaluate the
// outer body.

import SwiftUI
import WebKit

// MARK: - Height model (ObservableObject)

/// Holds the measured content height of a WKWebView. Owned as a `@StateObject`
/// inside `AutoHeightWebHost` so only the card subtree subscribes — the chat-
/// list body is never a subscriber and is never re-evaluated on height changes.
@MainActor
public final class AutoHeightModel: ObservableObject {
    /// Measured `document.body.scrollHeight` in points, updated whenever the
    /// web content's intrinsic height changes. Starts at a reasonable minimum
    /// so the card has non-zero height before the first measurement arrives.
    @Published public var contentHeight: CGFloat = 200

    public init() {}
}

// MARK: - AutoHeightWebView (NSViewRepresentable)

/// A `WKWebView` that loads a URL and posts `document.body.scrollHeight` back
/// via a `WKScriptMessageHandler` named `"w42height"`. Height changes are
/// delivered to `AutoHeightModel` on the main actor.
///
/// The injected user script fires on `DOMContentLoaded` / `load` and also
/// wires a `ResizeObserver` on `document.body` so any dynamic content
/// expansion (mermaid diagrams, lazy images) triggers a re-measurement.
@MainActor
public struct AutoHeightWebView: NSViewRepresentable {

    /// The artifact URL to load.
    public let url: URL
    /// Height model to publish into. Owned by `AutoHeightWebHost`; only
    /// the card child observes it.
    public let model: AutoHeightModel
    /// Opaque token that changes when the artifact's CONTENT changes (e.g. a
    /// content hash / mtime). When it changes the web view reloads in place —
    /// this is what makes a live card react to the agent rewriting the
    /// artifact, without recreating the WKWebView (no flash, no layout churn).
    public let reloadToken: String

    public init(url: URL, model: AutoHeightModel, reloadToken: String = "") {
        self.url = url
        self.model = model
        self.reloadToken = reloadToken
    }

    // MARK: NSViewRepresentable

    public func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let ucc = WKUserContentController()
        ucc.add(coordinator, name: Coordinator.handlerName)
        ucc.addUserScript(WKUserScript(
            source: Coordinator.heightScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        let config = WKWebViewConfiguration()
        config.userContentController = ucc
        // Use OverscrollPassthroughWebView in .alwaysPassThrough mode: the
        // card is sized to its content height so there is nothing to scroll
        // internally — all wheel events must chain to the parent chat scroll.
        let webView = Work42WebView.make(OverscrollPassthroughWebView.self, configuration: config, role: .offscreen)
        webView.overscrollMode = .alwaysPassThrough
        webView.navigationDelegate = coordinator
        // Transparent: card background shows through
        webView.setValue(false, forKey: "drawsBackground")
        webView.load(URLRequest(url: url))
        coordinator.lastURL = url
        // Re-fetch on theme change: the artifact server bakes the ACTIVE
        // theme's resolved tokens into the served shell CSS, so an
        // already-rendered card must reload to match a new theme (AC9).
        coordinator.themeObserver = NotificationCenter.default.addObserver(
            forName: .work42ThemeDidChange, object: nil, queue: .main
        ) { [weak webView] _ in
            // Queue is .main; hop is safe (WKWebView is main-actor).
            MainActor.assumeIsolated { _ = webView?.reload() }
        }
        return webView
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.model = model
        // URL changed → full load. Same URL but a new content token → reload in
        // place so a live card reflects the agent rewriting the artifact.
        if url.absoluteString != coordinator.lastURL?.absoluteString {
            coordinator.lastURL = url
            coordinator.lastReloadToken = reloadToken
            webView.load(URLRequest(url: url))
        } else if reloadToken != coordinator.lastReloadToken {
            coordinator.lastReloadToken = reloadToken
            webView.reload()
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    public static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: Coordinator.handlerName)
        if let observer = coordinator.themeObserver {
            NotificationCenter.default.removeObserver(observer)
            coordinator.themeObserver = nil
        }
    }

    // MARK: - Coordinator

    public final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let handlerName = "w42height"

        /// Weak-ish reference: strong is fine here since Coordinator owns no strong
        /// ref to the WKWebView (WebKit owns Coordinator indirectly via UCC).
        var model: AutoHeightModel
        var lastURL: URL?
        /// Last content token seen; a change triggers an in-place reload.
        var lastReloadToken: String = ""
        /// Token for the theme-change reload observer; removed on dismantle.
        var themeObserver: (any NSObjectProtocol)?

        init(model: AutoHeightModel) { self.model = model }

        // MARK: WKScriptMessageHandler

        public func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == Self.handlerName else { return }
            let height: CGFloat
            if let n = message.body as? NSNumber {
                height = CGFloat(n.doubleValue)
            } else if let d = message.body as? Double {
                height = CGFloat(d)
            } else {
                return
            }
            // Guard: never shrink below the minimum (avoids flicker on
            // interim DOMContentLoaded before resources load)
            let clamped = max(80, height)
            if abs(clamped - model.contentHeight) > 1 {
                // Main-actor call is fine: WebKit message handlers arrive on main.
                model.contentHeight = clamped
            }
        }

        // MARK: WKNavigationDelegate

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Kick an explicit height poll after navigation finishes —
            // the injected script should already have fired but this is
            // a safety net for pages where the body settles after load.
            webView.evaluateJavaScript(
                "window.webkit.messageHandlers.w42height.postMessage(document.body.scrollHeight);",
                completionHandler: nil
            )
        }

        // MARK: Injected height-reporting script

        /// JS injected at document end. Reports body scroll height on:
        ///   - DOMContentLoaded (fast first measurement)
        ///   - load event (after images / stylesheets)
        ///   - ResizeObserver on the body (dynamic content, mermaid, etc.)
        ///   - MutationObserver on the body (content added after load)
        static let heightScript = #"""
        (function(){
          var handler = window.webkit && window.webkit.messageHandlers
                        && window.webkit.messageHandlers.w42height;
          if (!handler) return;
          function report() {
            handler.postMessage(document.body ? document.body.scrollHeight : 0);
          }
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', report);
          } else {
            report();
          }
          window.addEventListener('load', report);
          if (typeof ResizeObserver !== 'undefined') {
            var ro = new ResizeObserver(report);
            ro.observe(document.body || document.documentElement);
          }
          if (typeof MutationObserver !== 'undefined') {
            var mo = new MutationObserver(function(){ setTimeout(report, 50); });
            mo.observe(document.body || document.documentElement,
                       { childList: true, subtree: true, attributes: true });
          }
        })();
        """#
    }
}

// MARK: - AutoHeightWebHost (the SwiftUI consumer)

/// SwiftUI host that owns the `AutoHeightModel` as a `@StateObject` and sizes
/// itself to `model.contentHeight`. Only this view subscribes to the model;
/// the surrounding chat list does NOT — so height changes never trigger a
/// transcript-level re-render.
///
/// Usage: `AutoHeightWebHost(url: resolvedURL)` inside `InlineArtifactCard`.
@MainActor
public struct AutoHeightWebHost: View {
    public let url: URL

    @StateObject private var model = AutoHeightModel()

    public init(url: URL) { self.url = url }

    public var body: some View {
        AutoHeightWebView(url: url, model: model)
            .frame(height: model.contentHeight)
    }
}
