// OverscrollPassthroughWebView.swift — bug/weird-scrolling-thing-that-doesn-t-allow-vertical
//
// A WKWebView subclass that chains NSEvent.scrollWheel to the parent AppKit
// view hierarchy when the web content has nothing left to scroll horizontally,
// so a SwiftUI ScrollView (or any enclosing NSScrollView) can receive scroll
// events once the inner web content is at its horizontal boundary.
//
// ┌────────────────────────────────────────────────────────────────────┐
// │  Problem                                                           │
// │  WKWebView absorbs all scrollWheel events even when the page has  │
// │  no horizontal scroll room left (or, for auto-height cards, has   │
// │  no internal scroll at all). The enclosing horizontal ScrollView  │
// │  never sees those events, so the user can't scroll past the tile. │
// │  Vertical scrolling is entirely owned by WebKit — it is NEVER     │
// │  hijacked or chained, including on nested-scroller pages.         │
// └────────────────────────────────────────────────────────────────────┘
//
// Two modes (OverscrollMode):
//
//   .alwaysPassThrough
//     Forward ALL wheel events to nextResponder, never calling super.
//     Use for AutoHeightWebView: the webview is sized to its full content
//     height, so there is nothing to scroll internally.
//
//   .passthroughAtBoundary
//     WebKit owns vertical scrolling unconditionally (page AND nested
//     overflow containers — vertical never freezes). For a pure-horizontal
//     gesture (dy == 0), chain to nextResponder only when the web content
//     has no horizontal scroll room left in the gesture direction; otherwise
//     call super so the page scrolls horizontally.
//     Use for WebSectionView (browser / web-section widgets).
//     Horizontal boundary state is detected via a lightweight JS wheel
//     listener that posts { scrollLeft, scrollWidth, clientWidth } of the
//     nearest horizontally-scrollable ancestor under the pointer via the
//     "w42overscroll" WKScriptMessageHandler. Swift caches the last values
//     and reads them synchronously in scrollWheel(with:). One-event lag at
//     the boundary is imperceptible in practice.
//
// Integration cheat-sheet
// ─────────────────────────
// AutoHeightWebView (.alwaysPassThrough):
//   let wv = OverscrollPassthroughWebView(frame: .zero, configuration: cfg)
//   wv.overscrollMode = .alwaysPassThrough
//   // Done — no script, no proxy.
//
// WebSectionView (.passthroughAtBoundary):
//   // 1. Add script to UCC BEFORE creating the config:
//   ucc.addUserScript(WKUserScript(source: OverscrollInstaller.scrollStateScript,
//                                  injectionTime: .atDocumentEnd,
//                                  forMainFrameOnly: true))
//   // 2. Create webview with config:
//   let wv = OverscrollPassthroughWebView(frame: .zero, configuration: cfg)
//   wv.overscrollMode = .passthroughAtBoundary
//   // 3. Wire proxy AFTER webview is created (proxy holds wv weakly):
//   coordinator.overscrollProxy = OverscrollInstaller.wireProxy(webView: wv, controller: ucc)
//   // 4. In dismantleNSView:
//   OverscrollInstaller.teardown(from: controller, proxy: coordinator.overscrollProxy)
//   coordinator.overscrollProxy = nil

import AppKit
import WebKit

// MARK: - OverscrollMode

/// Controls how ``OverscrollPassthroughWebView`` handles scroll-wheel events
/// that the web content cannot absorb.
public enum OverscrollMode {

    /// Forward ALL wheel events to the next responder, never calling super.
    ///
    /// The correct choice when the `WKWebView` is sized exactly to its
    /// content height (auto-height artifact card) so internal scrolling is
    /// never needed.
    case alwaysPassThrough

    /// WebKit owns vertical scrolling unconditionally. For a pure-horizontal
    /// gesture, forward the event to the next responder only when the web
    /// content is at its horizontal boundary in the gesture direction;
    /// otherwise call super so the page scrolls horizontally.
    ///
    /// The correct choice for a normally-scrollable `WKWebView` (browser /
    /// web-section widget). Horizontal boundary state comes from the
    /// JS-cached `scrollLeft` / `scrollWidth` / `clientWidth` values
    /// maintained by the listener injected via ``OverscrollInstaller``.
    case passthroughAtBoundary
}

// MARK: - OverscrollPassthroughWebView

/// A `WKWebView` subclass that overrides `scrollWheel(with:)` to chain
/// pure-horizontal wheel events up the AppKit responder chain when the web
/// content has no horizontal scroll room left in the gesture direction.
/// Vertical scrolling is always owned by WebKit and is never chained.
///
/// Wire it with ``OverscrollInstaller`` for `.passthroughAtBoundary` mode.
/// For `.alwaysPassThrough` (auto-height cards), no installer is needed —
/// just set `overscrollMode` after construction.
///
/// - Important: Main-actor–isolated. Always create and use from the main actor.
@MainActor
public final class OverscrollPassthroughWebView: PolicyWebView {

    // MARK: Public configuration

    /// How this view handles unconsumed wheel events. Set before the view
    /// appears; defaults to `.alwaysPassThrough`.
    public var overscrollMode: OverscrollMode = .alwaysPassThrough

    // MARK: Cached scroll state (used only by .passthroughAtBoundary)

    // Updated asynchronously by the JS wheel listener via
    // OverscrollHandlerProxy.userContentController(_:didReceive:).
    // Read synchronously in scrollWheel(with:). The 1-event lag at the
    // boundary transition is imperceptible on a trackpad.

    var scrollLeft: Double = 0
    var scrollWidth: Double = 1   // init to 1 to avoid zero-denominator
    var clientWidth: Double = 0

    // MARK: Deferred initial load (blank-until-attached fix)

    /// A URL load requested while this view was OUT of the window hierarchy.
    ///
    /// WKWebView frequently never paints its first navigation when `load` is
    /// called off-screen — the classic "needs a hard refresh to kick in" for a
    /// browser-based widget: one built for a not-yet-visible tab, or rebuilt
    /// after a teardown, loads detached and renders blank until the user hits
    /// refresh. We hold that request and replay it once the view is attached.
    ///
    /// Navigations issued while on screen (SPA route changes, the address bar,
    /// the Refresh button) go straight through. Re-attaching on a tab switch does
    /// NOT reload — the request is already cleared and WKWebView retains content
    /// across `removeFromSuperview`, so the "survives tab switches without
    /// reloading" behavior is preserved.
    private var deferredLoad: URLRequest?

    @discardableResult
    public override func load(_ request: URLRequest) -> WKNavigation? {
        guard window != nil else {
            deferredLoad = request
            return nil
        }
        deferredLoad = nil
        return super.load(request)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let request = deferredLoad else { return }
        deferredLoad = nil
        super.load(request)
    }

    // MARK: scrollWheel override

    public override func scrollWheel(with event: NSEvent) {
        switch overscrollMode {

        case .alwaysPassThrough:
            // Auto-height card: the webview is always exactly as tall as its
            // rendered content, so there is NEVER anything to scroll inside
            // it. Forward every wheel event straight to the enclosing scroll
            // view (the SwiftUI chat ScrollView's backing NSScrollView).
            nextResponder?.scrollWheel(with: event)

        case .passthroughAtBoundary:
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY

            // WebKit owns vertical scrolling — the page AND any nested overflow
            // container. Any event with a vertical component (including diagonal
            // gestures) goes straight to WebKit, so vertical never freezes.
            // Only a pure-horizontal gesture is a passthrough candidate.
            guard dy == 0, dx != 0 else {
                super.scrollWheel(with: event)
                return
            }

            // Prime the cache at gesture start: let WebKit process the first event so
            // the JS wheel listener measures the element under the pointer before we
            // decide. This prevents a stale "no horizontal scroll" cache from chaining
            // the whole gesture to the parent and starving a nested horizontal
            // scroller (diff / code block) of its events.
            if event.phase == .began {
                super.scrollWheel(with: event)
                return
            }

            // Mid-gesture: chain to the enclosing horizontal ScrollView only when the
            // measured horizontal scroller can't move further in the gesture
            // direction. AppKit natural-scroll convention mirrors the vertical axis:
            //   dx > 0 → toward the content's left edge
            //   dx < 0 → toward the content's right edge
            let atLeft  = scrollLeft <= 0.5
            let atRight = scrollLeft + clientWidth >= scrollWidth - 0.5
            let noHorizontalScroll = scrollWidth <= clientWidth + 0.5

            if noHorizontalScroll || (dx > 0 && atLeft) || (dx < 0 && atRight) {
                nextResponder?.scrollWheel(with: event)
            } else {
                super.scrollWheel(with: event)
            }
        }
    }

    // MARK: Scroll state update

    /// Refresh the cached horizontal scroll-boundary state from values reported
    /// by the JS listener. Called on the main actor from ``OverscrollHandlerProxy``.
    func applyScrollState(scrollLeft: Double, scrollWidth: Double, clientWidth: Double) {
        self.scrollLeft = scrollLeft
        self.scrollWidth = max(scrollWidth, 1)
        self.clientWidth = clientWidth
    }
}

// MARK: - OverscrollHandlerProxy

/// `WKScriptMessageHandler` proxy that receives `{ scrollLeft, scrollWidth,
/// clientWidth }` payloads from the injected JS and forwards them to the
/// `OverscrollPassthroughWebView`.
///
/// Holds the webview **weakly** to avoid a retain cycle:
/// `WKUserContentController` retains its handlers strongly; the UCC is owned
/// by the webview's configuration, so holding the webview strongly here would
/// create a cycle. The caller (e.g. the `WebSectionView.Coordinator`) holds
/// this proxy strongly, keeping it alive exactly as long as the webview.
///
/// Registered under ``OverscrollInstaller/handlerName`` on the webview's
/// `WKUserContentController` by ``OverscrollInstaller/wireProxy(webView:controller:)``;
/// torn down via ``OverscrollInstaller/teardown(from:proxy:)`` in `dismantleNSView`.
@MainActor
public final class OverscrollHandlerProxy: NSObject, WKScriptMessageHandler {

    weak var webView: OverscrollPassthroughWebView?

    init(webView: OverscrollPassthroughWebView) {
        self.webView = webView
        super.init()
    }

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == OverscrollInstaller.handlerName,
              let dict = message.body as? [String: Any],
              let sl   = dict["scrollLeft"]  as? Double,
              let sw   = dict["scrollWidth"] as? Double,
              let cw   = dict["clientWidth"] as? Double
        else { return }
        webView?.applyScrollState(scrollLeft: sl, scrollWidth: sw, clientWidth: cw)
    }
}

// MARK: - OverscrollInstaller

/// Namespace for the script source and wiring helpers used by
/// `.passthroughAtBoundary` mode.
///
/// The script must be added to the `WKUserContentController` **before** the
/// `WKWebViewConfiguration` is finalised (so it applies to the very first
/// navigation). The handler proxy must be registered **after** the
/// `OverscrollPassthroughWebView` is created (so the proxy can hold it
/// weakly). `teardown` must be called from `dismantleNSView` /
/// `WebSectionLiveView.teardown()` symmetrically.
public enum OverscrollInstaller {

    /// JS message handler name used in `window.webkit.messageHandlers.<name>`.
    public static let handlerName = "w42overscroll"

    /// JavaScript injected at document-end to report horizontal scroll state.
    ///
    /// Adds a `passive` + `capture` `'wheel'` listener on `window` that walks
    /// up from the event target to the nearest ancestor with computed
    /// `overflowX` `auto|scroll` AND `scrollWidth > clientWidth + 1` (falling
    /// back to `document.scrollingElement || documentElement`) and posts
    /// `{ scrollLeft, scrollWidth, clientWidth }` of THAT element via the
    /// `"w42overscroll"` message handler. Seeded once at injection so the
    /// initial state is populated before the first gesture.
    ///
    /// The listener is `passive` (never suppresses native scrolling) and
    /// `capture` (sees wheel events targeted at nested elements). This ensures
    /// wide diffs, code blocks, and other nested horizontal scrollers are
    /// correctly measured rather than only reporting the document scroller.
    ///
    /// Add as a `WKUserScript` with `injectionTime: .atDocumentEnd,
    /// forMainFrameOnly: true` **before** building the
    /// `WKWebViewConfiguration`.
    public static let scrollStateScript: String = """
    (function () {
      var h = window.webkit &&
              window.webkit.messageHandlers &&
              window.webkit.messageHandlers.w42overscroll;
      if (!h) return;
      function nearestHScroller(node) {
        while (node && node.nodeType === 1) {
          var s = window.getComputedStyle(node);
          var ox = s.overflowX;
          if ((ox === 'auto' || ox === 'scroll') &&
              node.scrollWidth > node.clientWidth + 1) {
            return node;
          }
          node = node.parentNode;
        }
        return document.scrollingElement || document.documentElement;
      }
      function reportFrom(el) {
        if (!el) return;
        h.postMessage({
          scrollLeft:  el.scrollLeft,
          scrollWidth: el.scrollWidth,
          clientWidth: el.clientWidth
        });
      }
      // wheel fires before the scroll and carries the element under the pointer,
      // so we can measure the correct horizontal scroller even before it moves.
      window.addEventListener('wheel', function (e) {
        reportFrom(nearestHScroller(e.target));
      }, { passive: true, capture: true });
      // seed once at injection so the initial state is populated.
      reportFrom(document.scrollingElement || document.documentElement);
    })();
    """

    /// Register the scroll-state handler proxy on the content controller.
    ///
    /// Call **after** the `OverscrollPassthroughWebView` is created, because
    /// the proxy holds the webview weakly. The script must have been added to
    /// the UCC (via ``scrollStateScript``) before the configuration was built.
    ///
    /// The returned proxy **must** be held alive by the caller (store it on
    /// the Coordinator or the live-view holder) for as long as the webview is
    /// alive. If released, the handler silently loses its weak reference and
    /// scroll state stops updating.
    ///
    /// Only use for `.passthroughAtBoundary` webviews. `.alwaysPassThrough`
    /// needs no proxy (scroll state is never read).
    ///
    /// - Parameters:
    ///   - webView: The `OverscrollPassthroughWebView` to update.
    ///   - controller: The webview's `WKUserContentController`.
    /// - Returns: The proxy; the caller must keep it alive.
    public static func wireProxy(
        webView: OverscrollPassthroughWebView,
        controller: WKUserContentController
    ) -> OverscrollHandlerProxy {
        let proxy = OverscrollHandlerProxy(webView: webView)
        controller.add(proxy, name: handlerName)
        return proxy
    }

    /// Remove the scroll-state message handler from the content controller.
    ///
    /// Call from `dismantleNSView` or `WebSectionLiveView.teardown()` to
    /// keep teardown symmetric with ``wireProxy(webView:controller:)``.
    ///
    /// Safe to call even when no proxy was wired (pass `nil` for `proxy`);
    /// the call becomes a no-op.
    ///
    /// - Parameters:
    ///   - controller: The webview's `WKUserContentController`.
    ///   - proxy: The proxy returned by ``wireProxy(webView:controller:)``;
    ///     pass `nil` if none was wired.
    public static func teardown(
        from controller: WKUserContentController,
        proxy: OverscrollHandlerProxy?
    ) {
        guard proxy != nil else { return }
        controller.removeScriptMessageHandler(forName: handlerName)
    }
}
