// WebSectionView.swift - Reusable embedded web section (NSViewRepresentable).
//
// Wraps a WKWebView so a real web app can be embedded as a native
// SwiftUI widget, driven entirely by a `WebSectionSpec` value. The
// component is web-app-agnostic — it never branches on the specific
// site. Jira is the first consumer; new integrations are a new
// WebSectionSpec, not new WebKit code.
//
// Subtask T-005.1 scope (this file): build the WKWebView from a
// WKWebViewConfiguration + WKUserContentController, back it with a
// PERSISTENT WKWebsiteDataStore keyed by `spec.dataStoreKey` (so login
// survives restarts), and LOAD `spec.url`. Nothing else.
//
// Clean seams left for later subtasks:
//   .2 — selector isolation: a `WKUserScript` is added to the
//        `WKUserContentController` (see `userContentController` below;
//        the install point is marked SEAM .2).
//   .3 — DONE: SPA navigation + SSO/login popups. A `Coordinator`
//        (NSObject) acts as `WKNavigationDelegate` (re-runs the isolation
//        script on navigation events for SPA route changes) and
//        `WKUIDelegate` (routes `window.open` SSO popups into this same
//        webview). Auth persistence is provided by the persistent
//        (non-ephemeral) `WKWebsiteDataStore` from .1, keyed by
//        `spec.dataStoreKey`, so login survives app restarts.
//   .4 — JS->Swift signals: register a `WKScriptMessageHandler` on the
//        same `WKUserContentController`.
//   .7 — live-view caching (LiveWidgetBackends-style) so tab switches
//        don't reload. This file deliberately creates a fresh webview
//        per `makeNSView`; caching is wired by the widget owner later.

import AppKit
import Foundation
import Observation
import SwiftUI
import WebKit

// MARK: - WebSectionStatus

/// Navigation lifecycle status for an embedded web section.
///
/// Published by `WebSectionLiveView.status` and set from the `Coordinator`'s
/// `WKNavigationDelegate` callbacks so consumers (e.g. `CachedWebSectionView`,
/// `BrowserChromeRow`) can show a loading indicator or an error+Retry state
/// without any per-site branching. (Decision 6, lanky-pine.3)
public enum WebSectionStatus: Equatable {
    /// A navigation is in progress (provisional navigation started but not
    /// yet finished or failed).
    case loading
    /// The last navigation finished successfully.
    case loaded
    /// The last navigation failed.
    ///
    /// - Parameter description: `error.localizedDescription` from the failing
    ///   `WKNavigationDelegate` callback. Shown verbatim in the error view.
    case failed(description: String)
}

/// Embeds one section of a web app as a native view, configured by a
/// `WebSectionSpec`. See file header for the subtask boundaries.
public struct WebSectionView: NSViewRepresentable {

    /// The configuration that drives this section. Changing the `url`
    /// reloads the page; the persistent store is keyed by
    /// `dataStoreKey` so the session is preserved.
    public let spec: WebSectionSpec

    /// OPTIONAL JS->Swift signal callback (subtask T-005.4). When non-nil,
    /// a `WKScriptMessageHandler` is registered on the webview's
    /// `WKUserContentController` under `Self.messageHandlerName` and the
    /// matching signal `WKUserScript` is injected; the closure fires
    /// (on the main actor) for each `WebSectionSignal` the page posts
    /// (section loaded, title changed). When nil, NO handler is registered
    /// and the injected JS post is a guarded no-op — the seam costs nothing
    /// for consumers that don't need it.
    public var onSignal: ((WebSectionSignal) -> Void)?

    /// Optional content-surface link interception. When present, outbound
    /// user-activated links are cancelled and forwarded to the host. Ordinary
    /// BrowserSurface consumers leave this nil and retain normal navigation.
    public var onOpenLink: ((URL) -> Void)?

    /// Name the JS->Swift message handler is registered under, matching
    /// the `window.webkit.messageHandlers.<name>` lookup in the injected
    /// signal script. Stable + web-app-agnostic (not Jira-specific).
    public static let messageHandlerName = "webSection"

    /// Name the JS->Swift message handler for text-selection events
    /// (AC2 — cozy-nimbus). The handler is always registered (zero cost
    /// when `selectionHandler` is nil — the Coordinator discards the
    /// message). Distinct from `messageHandlerName` so the two seams
    /// don't collide on the same `WKUserContentController`.
    public static let selectionHandlerName = "w42Selection"

    /// Name the JS->Swift message handler for intercepted link clicks is registered under
    /// (`WebSectionScript.linkInterceptor`).
    public static let linkHandlerName = "w42Link"

    /// Name the JS->Swift message handler for element-picker events
    /// (lanky-pine.2). The handler is always registered; the Coordinator
    /// discards messages when `pickHandler` and `onPickerStopped` are both
    /// nil — zero cost for consumers that don't need it.
    public static let elementPickHandlerName = "w42ElementPick"

    /// Name of the JS->Swift message handler for the deterministic
    /// content-ready signal. The injected readiness script posts to it once
    /// `document.readyState === "complete"` AND two `requestAnimationFrame`s
    /// have elapsed (guaranteeing a first paint), so the loading overlay lifts
    /// on real painted content, not merely on `didFinish`. Always registered.
    public static let contentReadyHandlerName = "w42ContentReady"

    public init(
        spec: WebSectionSpec,
        onSignal: ((WebSectionSignal) -> Void)? = nil,
        onOpenLink: ((URL) -> Void)? = nil
    ) {
        self.spec = spec
        self.onSignal = onSignal
        self.onOpenLink = onOpenLink
    }

    public func makeNSView(context: Context) -> WKWebView {
        context.coordinator.onOpenLink = onOpenLink
        return Self.buildWebView(spec: spec, onSignal: onSignal, coordinator: context.coordinator)
    }

    /// Build a fully-configured `WKWebView` for a spec, wiring the
    /// isolation user script, the optional JS->Swift signal seam, the
    /// persistent data store, and the navigation/UI delegates to the
    /// supplied `coordinator`.
    ///
    /// Factored out of `makeNSView` so the LiveWidgetBackends-style cache
    /// (subtask T-005.7 / AC8) can construct the SAME configured webview
    /// once and reuse it across SwiftUI tear-down + remount. The webview
    /// holds its delegates *weakly*, so the caller is responsible for
    /// keeping `coordinator` alive as long as the returned webview lives
    /// (see `WebSectionLiveView`, which bundles the two).
    static func buildWebView(
        spec: WebSectionSpec,
        onSignal: ((WebSectionSignal) -> Void)?,
        coordinator: Coordinator
    ) -> WKWebView {
        // A WKUserContentController is the hook for everything the
        // later subtasks layer on: injected user scripts (.2 selector
        // isolation) and JS->Swift message handlers (.4 signals). We
        // create it now so the configuration is final and the seams
        // have a home, even though .1 adds nothing to it.
        let userContentController = WKUserContentController()
        // SEAM .2: selector-isolation WKUserScript. The script source is
        // generated by the pure `WebSectionScript.isolation(selector:)`
        // (testable without WebKit), then injected at `.atDocumentEnd`
        // so the DOM exists when it runs. Injecting via WKUserScript
        // (rather than inline <script>/eval) bypasses the target site's
        // Content-Security-Policy. Main frame only is fine for Jira; the
        // SPA-navigation re-injection lives in SEAM .3.
        let isolationScript = WKUserScript(
            source: WebSectionScript.isolation(selector: spec.selector),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        userContentController.addUserScript(isolationScript)
        // Always-on Flutter accessibility. Flutter web only renders its
        // semantics tree while accessibility is enabled, and it resets on load /
        // hot-restart. This script auto-clicks the `flt-semantics-placeholder`
        // whenever it appears, so the semantic nodes are ALWAYS present for the
        // preview scan + highlight picker to read from ONE shared source of
        // truth. Feature-detected — a no-op (self-stopping) on non-Flutter pages,
        // so it is safe on every web tile.
        let flutterSemanticsScript = WKUserScript(
            source: WebSectionScript.flutterSemanticsEnabler,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        userContentController.addUserScript(flutterSemanticsScript)
        // SEAM .4 (DONE): JS->Swift signals. Only wired when a consumer
        // supplied `onSignal` — otherwise the seam is inert and the page
        // posts to a handler that was never registered (the injected
        // script guards that case). Two pieces:
        //   1. Inject the signal WKUserScript so the page posts `loaded`/
        //      `title` payloads to `messageHandlers.<messageHandlerName>`.
        //   2. Register a WKScriptMessageHandler under the same name.
        // RETAIN-CYCLE NOTE: `WKUserContentController` retains its message
        // handlers *strongly*, and the controller is owned by the webview,
        // which SwiftUI keeps alongside the Coordinator. Registering the
        // Coordinator directly would create
        // userContentController -> Coordinator and (since the Coordinator
        // would need the webview to fire callbacks) risk a cycle that
        // outlives the view. So we register a tiny `MessageHandlerProxy`
        // that holds a WEAK reference to the Coordinator (same shape as
        // how the Coordinator itself is a non-owning delegate), and we
        // explicitly tear the handler down in `dismantleNSView`.
        if onSignal != nil {
            let signalScript = WKUserScript(
                source: WebSectionScript.signal(
                    selector: spec.selector,
                    handlerName: Self.messageHandlerName
                ),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
            userContentController.addUserScript(signalScript)
            let proxy = MessageHandlerProxy(coordinator: coordinator)
            coordinator.messageProxy = proxy
            userContentController.add(proxy, name: Self.messageHandlerName)
        }

        // SEAM — Text-selection tracking (AC2 cozy-nimbus). Always
        // inject the selection script and register the handler so the
        // webview can report selected text back to Swift without a
        // teardown/rebuild cycle. The Coordinator discards the message
        // when `selectionHandler` is nil — zero cost for consumers that
        // don't need it. A dedicated `SelectionHandlerProxy` mirrors the
        // MessageHandlerProxy pattern to avoid the retain-cycle risk.
        let selectionScript = WKUserScript(
            source: WebSectionScript.selectionTracking(handlerName: Self.selectionHandlerName),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        userContentController.addUserScript(selectionScript)
        let selectionProxy = SelectionHandlerProxy(coordinator: coordinator)
        coordinator.selectionProxy = selectionProxy
        userContentController.add(selectionProxy, name: Self.selectionHandlerName)

        // SEAM — Link interception. Single-page apps change page with history.pushState, which the
        // navigation delegate never sees, so clicks on links another widget owns are caught inside the
        // page. Inert until the host sets patterns (`WebSectionLiveView.setLinkPatterns`).
        let linkScript = WKUserScript(
            source: WebSectionScript.linkInterceptor(handlerName: Self.linkHandlerName),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        userContentController.addUserScript(linkScript)
        let linkProxy = LinkHandlerProxy(coordinator: coordinator)
        coordinator.linkProxy = linkProxy
        userContentController.add(linkProxy, name: Self.linkHandlerName)

        // SEAM — Element picker (lanky-pine.2). Always inject:
        //   1. The picker-core.js asset at .atDocumentStart so
        //      window.__pickerCore is available before the picker shim runs.
        //   2. The elementPicker IIFE at .atDocumentEnd which wires the
        //      webkit.messageHandlers transport and exposes __w42Picker.
        // Both scripts are unconditional — the Coordinator discards messages
        // when both `pickHandler` and `onPickerStopped` are nil. The
        // ElementPickHandlerProxy mirrors SelectionHandlerProxy to avoid
        // retain-cycle risks with WKUserContentController.
        if let pickerCoreURL = Bundle.module.url(forResource: "picker-core", withExtension: "js"),
           let pickerCoreSource = try? String(contentsOf: pickerCoreURL, encoding: .utf8) {
            let pickerCoreScript = WKUserScript(
                source: pickerCoreSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
            userContentController.addUserScript(pickerCoreScript)
        }
        // Resolve the system accent color to a hex string so the picker
        // overlays match the user's chosen macOS appearance accent.
        // On macOS 26, NSColor.controlAccentColor.usingColorSpace(.sRGB)
        // returns nil for dynamic system colors, so we fall back to reading
        // the AppleAccentColor UserDefaults key directly.
        let pickerAccentHex = Self.systemAccentColorHex()
        let pickerScript = WKUserScript(
            source: WebSectionScript.elementPicker(handlerName: Self.elementPickHandlerName, accentHex: pickerAccentHex),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        userContentController.addUserScript(pickerScript)
        let pickProxy = ElementPickHandlerProxy(coordinator: coordinator)
        coordinator.pickProxy = pickProxy
        userContentController.add(pickProxy, name: Self.elementPickHandlerName)

        // SEAM — Diagram expand. Register the `w42Diagram` handler at BUILD time
        // (before load) so `window.webkit.messageHandlers.w42Diagram` exists
        // when the injected diagram bridge runs — a handler added after the page
        // loads is not exposed to that page. Always-on; the expand sink
        // (`coordinator.diagramExpandHandler`) is wired later by
        // `DiagramOverlayLayer`, and Expand presses are dropped until it is.
        let diagramProxy = DiagramMessageProxy()
        diagramProxy.onExpand = { [weak coordinator] svg in
            coordinator?.diagramExpandHandler?(svg)
        }
        coordinator.diagramProxy = diagramProxy
        userContentController.add(diagramProxy, name: DiagramMessageProxy.name)

        // SEAM — Flutter mockup. Same build-time registration so
        // `window.webkit.messageHandlers.w42FlutterMockup` exists for the injected
        // component runtime; the sink (`coordinator.flutterMockupHandler`) is wired
        // later by the app-side FlutterMockupController.
        let flutterMockupProxy = FlutterMockupProxy()
        flutterMockupProxy.onMessage = { [weak coordinator] body in
            coordinator?.flutterMockupHandler?(body)
        }
        coordinator.flutterMockupProxy = flutterMockupProxy
        userContentController.add(flutterMockupProxy, name: FlutterMockupProxy.name)

        // SEAM — Overscroll passthrough (feat/spec-as-html.11). Inject the
        // scroll-state script BEFORE finalising the configuration so it fires
        // on every navigation. The handler proxy is registered AFTER the
        // OverscrollPassthroughWebView is created (the proxy holds it weakly).
        let overscrollScript = WKUserScript(
            source: OverscrollInstaller.scrollStateScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        userContentController.addUserScript(overscrollScript)

        // SEAM — Deterministic content-ready signal. Inject at document start so
        // it can hook `load`/`readystatechange`, then post `w42ContentReady`
        // once the document is complete AND two rAFs have elapsed (first paint
        // guaranteed). This is what makes the loading overlay lift on real
        // painted content rather than on `didFinish` alone. Re-runs on every
        // full navigation (document-start scripts fire per full load); SPA
        // pushState navigations keep the already-painted state.
        let contentReadyScript = WKUserScript(
            source: Self.contentReadyScript(handlerName: Self.contentReadyHandlerName),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        userContentController.addUserScript(contentReadyScript)
        let contentReadyProxy = ContentReadyProxy(coordinator: coordinator)
        coordinator.contentReadyProxy = contentReadyProxy
        userContentController.add(contentReadyProxy, name: Self.contentReadyHandlerName)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController
        // Persistent (non-ephemeral) data store keyed by the spec so
        // login sessions survive app restarts. NOTE (T-005.3): this is the
        // persistent store — `WKWebsiteDataStore(forIdentifier:)`, NOT
        // `.nonPersistent()` — which is what lets an SSO/login completed
        // via the WKUIDelegate popup path below persist across relaunch.
        // macOS does not inherit
        // Safari/Chrome cookies — the user authenticates once inside
        // this webview and WebKit keeps the session under this
        // identifier.
        //
        // EPHEMERAL opt-in (`spec.ephemeral`, default false): a consumer
        // that serves local, app-authored content needing no persisted
        // auth (the agent canvas, spec Decision 5) gets a
        // `WKWebsiteDataStore.nonPersistent()` instead — nothing is written
        // to disk and `dataStoreKey` maps to no on-disk identity. This is
        // the only branch on the flag; the component stays web-app-agnostic.
        configuration.websiteDataStore = spec.ephemeral
            ? WKWebsiteDataStore.nonPersistent()
            : Self.persistentDataStore(forKey: spec.dataStoreKey)

        // Use OverscrollPassthroughWebView so wheel events chain to the
        // enclosing chat scroll view when the page is at its top/bottom
        // boundary (feat/spec-as-html.11).
        let webView = OverscrollPassthroughWebView(frame: .zero, configuration: configuration)
        webView.overscrollMode = .passthroughAtBoundary
        // SEAM .3: navigation + UI delegates. The Coordinator re-runs the
        // isolation script on SPA navigation (Jira switches issues without
        // a full reload, so the `.atDocumentEnd` user script above doesn't
        // fire) and routes SSO/login popups (`window.open`) back into this
        // same webview so Atlassian auth flows complete inside the widget.
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        // SEAM .4: a JS->Swift message handler is wired here / on the
        // userContentController by the next subtask. Left untouched.

        webView.load(URLRequest(url: spec.url))

        // Wire the overscroll handler proxy AFTER the webview is created so
        // the proxy can hold a weak reference to it (avoids a retain cycle
        // through the UCC → config → webview chain).
        coordinator.overscrollProxy = OverscrollInstaller.wireProxy(
            webView: webView,
            controller: userContentController
        )

        return webView
    }

    /// SwiftUI builds one `Coordinator` per representable instance; it is
    /// the `WKNavigationDelegate`/`WKUIDelegate` for the webview. It owns
    /// no view state — it only needs the `selector` so it can re-inject
    /// the isolation script on SPA navigation.
    public func makeCoordinator() -> Coordinator {
        Coordinator(selector: spec.selector, onSignal: onSignal)
    }

    /// Navigation + UI delegate for the embedded webview.
    ///
    /// SPA navigation case: the `.atDocumentEnd` `WKUserScript` only runs
    /// on a full document load. Jira (a React SPA) swaps issues without a
    /// page reload, which fires `didFinish` and same-document navigation
    /// callbacks but not a fresh document load — so the isolation would be
    /// lost. The Coordinator re-evaluates the SAME isolation source on
    /// those events to keep the section cropped. (The injected script's
    /// own `MutationObserver` handles in-place re-renders; this handles
    /// route changes that may tear down and rebuild the observer's tree.)
    ///
    /// Popup case: Atlassian SSO/login often opens via `window.open`,
    /// which WebKit surfaces through `createWebViewWith`. Returning a new
    /// webview here would strand the popup outside the widget, so instead we
    /// load the popup's request in the existing webview and return nil.
    @MainActor
    public final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let isolationSource: String

        /// OPTIONAL JS->Swift signal sink (subtask T-005.4). Nil when the
        /// consumer didn't ask for signals, in which case no message
        /// handler is registered at all.
        private let onSignal: ((WebSectionSignal) -> Void)?

        /// OPTIONAL status-update callback (lanky-pine.3). Set by
        /// `WebSectionLiveView` so the Coordinator can write navigation
        /// lifecycle changes directly into the observable model without
        /// creating a retain cycle (the closure captures `live` weakly via
        /// a `[weak live]` capture list).
        var onStatusChange: ((WebSectionStatus) -> Void)?

        /// OPTIONAL content-ready callback. Fired by the injected readiness
        /// script (via `ContentReadyProxy`) once the page is complete AND has
        /// painted. `WebSectionLiveView` sets `hasPaintedContent = true` here so
        /// the loading overlay lifts on real content, not merely on `didFinish`.
        var onContentReady: (() -> Void)?

        /// OPTIONAL current-URL callback. Fires on `didFinish` with the page the
        /// webview actually landed on, so consumers can persist the real page
        /// after IN-PAGE navigation (link clicks), not just the last typed URL.
        var onURLChange: ((URL) -> Void)?

        /// Optional outbound-link sink installed only by content-style hosts.
        /// Browser-oriented views leave this nil and navigate normally.
        var onOpenLink: ((URL) -> Void)?

        /// Optional link router for browser-style hosts (which leave `onOpenLink` nil). Asked
        /// about a link the user clicked (or a `target=_blank` / `window.open` popup); returning
        /// true means the host took the link and the in-place navigation is cancelled, false
        /// means navigate here as usual. Never consulted for same-document anchors, redirects or
        /// script-driven navigations, so login flows are unaffected.
        var linkRouter: ((URL) -> Bool)?

        /// OPTIONAL text-selection callback (AC2 / AC7 — cozy-nimbus).
        /// Receives the selected text, the view-space `CGRect` bounding the
        /// selection, and an optional file path extracted from the surrounding
        /// GitHub diff DOM `data-path` (e.g. `Sources/Foo/Bar.swift`), nil when
        /// the selection is outside a diff file section. An empty string +
        /// `.zero` means the selection was cleared.
        ///
        /// AC7: the diff line / side are NO LONGER read from the DOM — the
        /// consumer (the PR widget) recovers the precise `(line, side)`
        /// anchor by matching the text against the PR's unified diff
        /// (`UnifiedDiffLocator`). Settable after construction so
        /// `WebSectionLiveView` can wire it without rebuilding the `WKWebView`.
        var selectionHandler: ((String, CGRect, [String: String]) -> Void)?

        /// The weak-proxy content-ready message handler. Held strongly here so
        /// it outlives a single representable; torn down in `dismantleNSView`.
        var contentReadyProxy: ContentReadyProxy?

        /// The weak-proxy message handler registered on the
        /// `WKUserContentController`. Held here (strongly) so it lives as
        /// long as the Coordinator; the proxy itself only weakly references
        /// us, so there is no cycle. Torn down in `dismantleNSView`.
        var messageProxy: MessageHandlerProxy?

        /// The weak-proxy message handler for text-selection events.
        /// Same retain-cycle-avoidance pattern as `messageProxy`.
        /// Torn down in `dismantleNSView`.
        var selectionProxy: SelectionHandlerProxy?

        /// The weak-proxy message handler for intercepted link clicks. Torn down in `dismantleNSView`.
        var linkProxy: LinkHandlerProxy?

        /// URL patterns other widgets own, pushed into the page for the link interceptor.
        var linkPatterns: [WebLinkPattern] = []
        /// Every web link click is handed to `linkRouter` (Open Link decides). Supersedes `linkPatterns`.
        var interceptAllLinks = false

        /// Where an intercepted link goes when the router declines it. Nil loads it in the web view,
        /// which is what the click would have done; tests inject their own.
        var interceptedLinkFallback: ((URL) -> Void)?

        /// OPTIONAL element-pick callback (lanky-pine.2 / AC3).
        /// Receives the CSS selector, the view-space bounding rect, the
        /// element's normalized text, and the page URL when JS posts a
        /// `capture` payload. The picker remains armed for subsequent picks;
        /// the consumer (BrowserHighlightLayer) takes the snapshot and appends
        /// a `.browserHighlight` PendingComment. Settable after construction
        /// so `WebSectionLiveView` can wire it without rebuilding the WKWebView.
        ///
        /// Parameters: (selector, viewRect, text, pageUrl)
        var pickHandler: ((String, CGRect, String, String) -> Void)?

        /// OPTIONAL callback fired when the picker is stopped (AC6). The JS
        /// posts `{ type: "stop" }` when the user presses Esc or when Swift
        /// calls `window.__w42Picker.stop()`. The consumer (BrowserWidgetModel
        /// / BrowserHighlightLayer) flips `isPicking` back to false and clears
        /// any overlay state. Settable after construction like `pickHandler`.
        var onPickerStopped: (() -> Void)?

        /// OPTIONAL callback fired when the user deselects a previously-picked
        /// element by clicking it again (toggle-deselect). The JS posts
        /// `{ type: "deselect", selector }` and this closure receives the
        /// selector so the consumer (BrowserHighlightLayer) can remove the
        /// corresponding `.browserHighlight` PendingComment from the store.
        /// Settable after construction like `pickHandler`.
        var deselectHandler: ((String) -> Void)?

        /// The weak-proxy message handler for element-picker events.
        /// Same retain-cycle-avoidance pattern as `messageProxy`.
        /// Torn down in `dismantleNSView`.
        var pickProxy: ElementPickHandlerProxy?

        /// The weak-proxy scroll-state handler for overscroll passthrough
        /// (feat/spec-as-html.11). Non-nil when the webview was built via
        /// `buildWebView` (which always wires the `.passthroughAtBoundary`
        /// handler). Torn down in `dismantleNSView`.
        var overscrollProxy: OverscrollHandlerProxy?

        /// OPTIONAL diagram-expand sink. The `w42Diagram` message handler is
        /// ALWAYS registered at build time (so `window.webkit.messageHandlers.
        /// w42Diagram` exists when the page loads — a dynamically-added handler
        /// is not exposed to an already-loaded page); this callback is wired
        /// later by `DiagramOverlayLayer` when it mounts. Fires with the
        /// diagram's SVG when its Expand button is pressed. Nil = dropped.
        var diagramExpandHandler: ((String) -> Void)?

        /// The weak-proxy message handler for the diagram-expand signal. Same
        /// retain-cycle-avoidance pattern as the others. Torn down in
        /// `dismantleNSView`.
        var diagramProxy: DiagramMessageProxy?

        /// OPTIONAL Flutter-mockup sink. The `w42FlutterMockup` handler is always
        /// registered at build time; this callback is wired by the app-side
        /// `FlutterMockupController` when the artifact host mounts. Fires with the
        /// raw message body (`{type,id,app,device}`). Nil = dropped.
        var flutterMockupHandler: (([String: Any]) -> Void)?

        /// The weak-proxy handler for the Flutter-mockup signal. Same teardown as
        /// the others (`dismantleNSView`).
        var flutterMockupProxy: FlutterMockupProxy?

        init(selector: String, onSignal: ((WebSectionSignal) -> Void)? = nil) {
            // Precompute the (pure, deterministic) isolation source once;
            // it never changes for a given selector.
            self.isolationSource = WebSectionScript.isolation(selector: selector)
            self.onSignal = onSignal
            super.init()
        }

        /// Decode a JS payload from the injected signal script into a
        /// `WebSectionSignal` and forward it to `onSignal`. Called by the
        /// `MessageHandlerProxy`. Tolerant of unexpected shapes: an
        /// unrecognized `type` is dropped rather than crashing.
        func handleMessageBody(_ body: Any) {
            guard let onSignal,
                  let dict = body as? [String: Any],
                  let typeString = dict["type"] as? String,
                  let kind = WebSectionSignal.Kind(rawValue: typeString)
            else { return }
            let title = dict["title"] as? String
            onSignal(WebSectionSignal(kind: kind, title: title))
        }

        /// Push `linkPatterns` into the page. Safe to call before the interceptor exists (it is guarded)
        /// and again after every navigation, since a full load starts with empty patterns.
        func pushLinkPatterns(to webView: WKWebView) {
            let payload = linkPatterns.map { ["source": $0.source, "flags": $0.flags] }
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("window.__w42Links && (window.__w42Links.patterns = \(json), window.__w42Links.all = \(interceptAllLinks));", completionHandler: nil)
        }

        /// A click on a claimed link was cancelled in the page; hand the URL to the host's router and, if
        /// it declines, let the link go where the click would have. Called by `LinkHandlerProxy`.
        func handleInterceptedLinkBody(_ body: Any, webView: WKWebView?) {
            guard let dict = body as? [String: Any],
                  let raw = dict["url"] as? String,
                  let url = URL(string: raw) else { return }
            if linkRouter?(url) == true { return }
            if let interceptedLinkFallback {
                interceptedLinkFallback(url)
            } else if let webView {
                webView.evaluateJavaScript("window.__w42Links ? window.__w42Links.replay() : false") { result, _ in
                    if (result as? Bool) != true { webView.load(URLRequest(url: url)) }
                }
            }
        }

        /// Decode a JS payload from the injected selection-tracking script
        /// and call `selectionHandler`. Called by `SelectionHandlerProxy`.
        ///
        /// Coordinate transform: the JS reports coordinates in CSS-pixel
        /// PAGE space (viewport-relative `getBoundingClientRect()` +
        /// `window.scrollX/Y`). We convert them to VIEW space by
        /// subtracting the scroll offset and scaling by `devicePixelRatio`
        /// — `WebSectionView.selectionViewRect` is the pure, testable form
        /// of that math.
        func handleSelectionMessageBody(_ body: Any) {
            guard let handler = selectionHandler,
                  let dict = body as? [String: Any],
                  let type = dict["type"] as? String
            else { return }

            if type == "clear" {
                handler("", .zero, [:])
                return
            }
            guard type == "textSelection",
                  let text = dict["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let x = dict["x"] as? Double,
                  let y = dict["y"] as? Double,
                  let w = dict["width"] as? Double,
                  let h = dict["height"] as? Double,
                  let scrollX = dict["scrollX"] as? Double,
                  let scrollY = dict["scrollY"] as? Double,
                  let dpr = dict["devicePixelRatio"] as? Double
            else { return }

            // `domContext` is a generic map of nearby ancestor `data-*`
            // attributes (data- prefix stripped). Empty for plain text with no
            // annotated ancestors. A widget's WebSelectionResolver interprets
            // whichever keys it needs (GitHub reads `path`); the SDK keeps this
            // site-neutral. JS objects bridge as `[String: Any]`, so map the
            // string values across explicitly.
            var domContext: [String: String] = [:]
            if let rawContext = dict["domContext"] as? [String: Any] {
                for (key, value) in rawContext {
                    if let string = value as? String { domContext[key] = string }
                }
            }

            let viewRect = WebSectionView.selectionViewRect(
                pageX: x, pageY: y,
                width: w, height: h,
                scrollX: scrollX, scrollY: scrollY,
                devicePixelRatio: dpr
            )
            handler(text, viewRect, domContext)
        }

        /// Decode a JS payload from the injected element-picker script and
        /// dispatch to `pickHandler` or `onPickerStopped`. Called by
        /// `ElementPickHandlerProxy`.
        ///
        /// Coordinate transform: the JS reports `x`/`y` in CSS-pixel PAGE
        /// space (`getBoundingClientRect().left + scrollX`, `.top + scrollY`),
        /// same convention as the selection tracker. We reuse the same
        /// `selectionViewRect` transform (subtract scroll, no DPR scaling) to
        /// convert to WKWebView view space.
        func handlePickMessageBody(_ body: Any) {
            guard let dict = body as? [String: Any],
                  let type = dict["type"] as? String
            else { return }

            if type == "stop" {
                onPickerStopped?()
                return
            }
            if type == "deselect" {
                if let selector = dict["selector"] as? String {
                    DispatchQueue.main.async { [weak self] in
                        self?.deselectHandler?(selector)
                    }
                }
                return
            }
            guard type == "capture",
                  let handler = pickHandler,
                  let selector = dict["selector"] as? String,
                  let text = dict["text"] as? String,
                  let url = dict["url"] as? String,
                  let x = dict["x"] as? Double,
                  let y = dict["y"] as? Double,
                  let w = dict["width"] as? Double,
                  let h = dict["height"] as? Double,
                  let scrollX = dict["scrollX"] as? Double,
                  let scrollY = dict["scrollY"] as? Double,
                  let dpr = dict["devicePixelRatio"] as? Double
            else { return }

            let viewRect = WebSectionView.selectionViewRect(
                pageX: x, pageY: y,
                width: w, height: h,
                scrollX: scrollX, scrollY: scrollY,
                devicePixelRatio: dpr
            )
            handler(selector, viewRect, text, url)
        }

        /// Set status to `.loading` when a provisional navigation begins.
        /// Covers both initial page loads and navigations triggered by the
        /// user typing a new URL in the chrome address bar.
        public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            onStatusChange?(.loading)
        }

        /// Re-apply isolation after each finished navigation (covers SPA
        /// route changes that fire `didFinish` without a full reload), and
        /// set status to `.loaded`.
        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onStatusChange?(.loaded)
            // Report the actually-loaded page so consumers can persist it (a
            // link-click navigation moves the URL without any typed input).
            if let current = webView.url {
                onURLChange?(current)
            }
            reapplyIsolation(in: webView)
            // A full load starts with empty link patterns; hand the page the current ones again.
            if !linkPatterns.isEmpty || interceptAllLinks { pushLinkPatterns(to: webView) }
        }

        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated,
                  onOpenLink != nil || linkRouter != nil,
                  !navigationAction.modifierFlags.contains(.option),
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            // Same-document fragments belong to the document itself. This is
            // particularly important for generated reports and artifacts with
            // tables of contents.
            if Self.isSameDocumentAnchor(url, currentURL: webView.url) {
                decisionHandler(.allow)
                return
            }

            if let onOpenLink {
                onOpenLink(url.absoluteURL)
                decisionHandler(.cancel)
            } else if let linkRouter, linkRouter(url.absoluteURL) {
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        static func isSameDocumentAnchor(_ candidate: URL, currentURL: URL?) -> Bool {
            guard candidate.fragment?.isEmpty == false, let currentURL else { return false }
            var lhs = URLComponents(url: candidate, resolvingAgainstBaseURL: false)
            var rhs = URLComponents(url: currentURL, resolvingAgainstBaseURL: false)
            lhs?.fragment = nil
            rhs?.fragment = nil
            return lhs?.url == rhs?.url
        }

        /// Set status to `.failed` when a committed navigation fails (e.g.
        /// the server closes the connection mid-stream). `didFail` fires after
        /// a response was already received; `didFailProvisionalNavigation`
        /// fires when the request itself could not be made (DNS failure, no
        /// network, SSL error, etc.).
        public func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            onStatusChange?(.failed(description: error.localizedDescription))
        }

        /// Set status to `.failed` when a provisional navigation fails before
        /// a response is received (DNS failure, network unreachable, SSL
        /// error, etc.).
        public func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            onStatusChange?(.failed(description: error.localizedDescription))
        }

        /// Re-apply isolation on same-document navigation (history
        /// pushState/replaceState — how Jira moves between issues).
        public func webView(
            _ webView: WKWebView,
            didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!
        ) {
            reapplyIsolation(in: webView)
        }

        /// Route SSO/login popups (`window.open`) into the same webview so
        /// the auth flow completes inside the widget. Returning nil tells
        /// WebKit not to create a separate popup webview.
        public func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                // `target="_blank"`/`window.open` bypasses the ordinary
                // navigation-policy callback. Content hosts (artifacts) must
                // still dispatch these outbound links through Open Link,
                // while BrowserSurface consumers keep their existing
                // same-webview popup/SSO behavior by leaving `onOpenLink` nil.
                if let onOpenLink, !Self.isSameDocumentAnchor(url, currentURL: webView.url) {
                    onOpenLink(url.absoluteURL)
                } else if onOpenLink == nil, let linkRouter,
                          !Self.isSameDocumentAnchor(url, currentURL: webView.url),
                          linkRouter(url.absoluteURL) {
                    // The host took the link (another widget claims it, or the user chose to
                    // open it elsewhere); nothing to load here.
                } else {
                    webView.load(URLRequest(url: url))
                }
            }
            return nil
        }

        // MARK: - JS dialog delegates (native-web-dialog-parity, subtask .1)

        /// Shared presentation helper: present `alert` as a window-modal sheet
        /// when the webview has a host window, or fall back to app-modal
        /// `runModal()` when `webView.window` is nil (offscreen tile, teardown
        /// race). Calls `completion` **exactly once** with the user's
        /// `ModalResponse` in either path, satisfying AC7 and AC9.
        ///
        /// Reused by the alert, confirm, and prompt delegate methods below, and
        /// by the auth-challenge sheet in subtask .3. Keeping the
        /// sheet-or-modal branching in one place means every caller inherits the
        /// exactly-once guarantee automatically.
        private func presentWebDialog(
            _ alert: NSAlert,
            over webView: WKWebView,
            completion: @escaping (NSApplication.ModalResponse) -> Void
        ) {
            if let window = webView.window {
                alert.beginSheetModal(for: window) { response in
                    completion(response)
                }
            } else {
                // AC9: no-window fallback — still return a real result so the
                // page is never left waiting for a completion handler that never
                // arrives (which would cause a WebKit exception / hung JS).
                let response = alert.runModal()
                completion(response)
            }
        }

        /// AC1: JS `alert(message)` — present a native sheet with a single OK
        /// button and unblock the page by calling the completion handler on
        /// dismissal.
        ///
        /// `messageText` = the originating page host (the "<host> says"
        /// convention real browsers use); `informativeText` = the message from
        /// JS. Completion is called once via `presentWebDialog`, satisfying AC7.
        public func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor @Sendable () -> Void
        ) {
            let host = frame.request.url?.host ?? webView.url?.host ?? "This page"
            let alert = NSAlert()
            alert.messageText = host
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            presentWebDialog(alert, over: webView) { _ in
                completionHandler()
            }
        }

        /// AC2: JS `confirm(message)` — present OK / Cancel and return the
        /// user's boolean choice to the page via the completion handler.
        ///
        /// Returns `true` when the user taps OK (`.alertFirstButtonReturn`) and
        /// `false` on Cancel or sheet dismissal. Completion is called exactly
        /// once (AC7).
        public func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
        ) {
            let host = frame.request.url?.host ?? webView.url?.host ?? "This page"
            let alert = NSAlert()
            alert.messageText = host
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            presentWebDialog(alert, over: webView) { response in
                completionHandler(response == .alertFirstButtonReturn)
            }
        }

        /// AC3: JS `prompt(message, defaultText)` — present an editable text
        /// field pre-filled and selected with `defaultText`; return the entered
        /// string on OK (empty string `""` when the user clears it, not `nil` —
        /// matching browser `prompt` semantics) and `nil` on Cancel.
        ///
        /// The `NSTextField` accessory pattern mirrors `makeAccessoryView` in
        /// `PlayPanelView.swift` (the repo's existing prior art for alert
        /// accessories). Completion is called exactly once (AC7).
        public func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor @Sendable (String?) -> Void
        ) {
            let host = frame.request.url?.host ?? webView.url?.host ?? "This page"
            let alert = NSAlert()
            alert.messageText = host
            alert.informativeText = prompt
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")

            // Editable accessory field — pre-filled with `defaultText` and
            // fully selected so the user can type over without clearing first.
            // 240 pt width matches NSAlert's minimum content column width.
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
            field.stringValue = defaultText ?? ""
            field.selectText(nil)   // select all on sheet open
            alert.accessoryView = field

            presentWebDialog(alert, over: webView) { response in
                if response == .alertFirstButtonReturn {
                    // Return the field's current string value; empty string (not
                    // nil) when the user cleared it — matches browser prompt("…").
                    completionHandler(field.stringValue)
                } else {
                    completionHandler(nil)
                }
            }
        }

        /// AC4: `<input type="file">` — present a native `NSOpenPanel` so the
        /// user can pick files (or directories when
        /// `parameters.allowsDirectories` is set) without leaving the app.
        ///
        /// `WKOpenPanelParameters`' public API on macOS exposes only two
        /// properties: `allowsMultipleSelection` and `allowsDirectories`.
        /// There is no accept-type filter; do not attempt content-type
        /// filtering. Completion is called exactly once on every path
        /// (AC4, AC7, AC9).
        ///
        /// Presentation: window-modal sheet via
        /// `panel.beginSheetModal(for:)` when the webview has a host
        /// window; app-modal `panel.runModal()` as the no-window fallback
        /// (offscreen widget, teardown race) so the page is never left
        /// waiting for a completion handler that never arrives.
        public func webView(
            _ webView: WKWebView,
            runOpenPanelWith parameters: WKOpenPanelParameters,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
        ) {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection

            if let window = webView.window {
                panel.beginSheetModal(for: window) { response in
                    completionHandler(response == .OK ? panel.urls : nil)
                }
            } else {
                // AC9: no-window fallback — still return a real result so
                // the page is never left waiting for a completion handler
                // that never arrives (which would cause a WebKit exception
                // / hung JS).
                let response = panel.runModal()
                completionHandler(response == .OK ? panel.urls : nil)
            }
        }

        /// AC5/AC6: HTTP Basic/Digest authentication challenge — present a
        /// native username + masked-password sheet so the user can
        /// authenticate inline without leaving the widget.
        ///
        /// The switch on `authenticationMethod` is exhaustive-via-default:
        ///
        /// • **Basic / Digest** — show "Sign in to <host>" with a stacked
        ///   `NSTextField` (username) + `NSSecureTextField` (password)
        ///   accessory view. "Sign In" responds with a session-scoped
        ///   `URLCredential` (`.forSession` — nothing written to keychain);
        ///   "Cancel" cancels the challenge. Sheet / runModal follows the
        ///   same window-or-fallback path as all other dialog helpers via
        ///   `presentWebDialog`, satisfying AC7 and AC9.
        ///
        /// • **Every other method** — `NSURLAuthenticationMethodServerTrust`,
        ///   client certificate, NTLM, Negotiate, or any future method — is
        ///   handled with `.performDefaultHandling` (AC6). This is the
        ///   critical TLS-safety branch: implementing this delegate without
        ///   the default case would intercept server-trust validation and
        ///   silently break HTTPS for every page these widgets load.
        ///   `.performDefaultHandling` tells WebKit to behave exactly as it
        ///   would if this method were not implemented at all, preserving
        ///   today's behaviour. Completion is called exactly once on every
        ///   path (AC7).
        public func webView(
            _ webView: WKWebView,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            let method = challenge.protectionSpace.authenticationMethod

            // AC6: pass every non-Basic/Digest challenge straight through so
            // that server-trust (TLS certificate) validation is entirely
            // unchanged. This must be the default branch — scoping it only
            // to explicitly known "other" methods would leave any unrecognised
            // future method unhandled and risk breaking HTTPS.
            guard method == NSURLAuthenticationMethodHTTPBasic ||
                  method == NSURLAuthenticationMethodHTTPDigest else {
                completionHandler(.performDefaultHandling, nil)
                return
            }

            // AC5: Build the Sign In sheet — "Sign in to <host>" messageText
            // with a stacked username + masked-password accessory view.
            let host = challenge.protectionSpace.host
            let alert = NSAlert()
            alert.messageText = "Sign in to \(host)"
            alert.addButton(withTitle: "Sign In")
            alert.addButton(withTitle: "Cancel")

            // Stack NSTextField (username) above NSSecureTextField (password).
            // AppKit coordinate space has y=0 at the bottom, so the password
            // field sits at the bottom (y=0) and the username field is above
            // it with a 6-pt gap (y=28). Width (240 pt) matches the prompt
            // accessory established in subtask .1.
            let userField = NSTextField(frame: NSRect(x: 0, y: 28, width: 240, height: 22))
            userField.placeholderString = "Username"

            let passField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
            passField.placeholderString = "Password"

            let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 54))
            container.addSubview(userField)
            container.addSubview(passField)
            alert.accessoryView = container

            // Reuse the shared sheet-or-runModal helper so the exactly-once
            // completion guarantee (AC7) and the no-window fallback (AC9) are
            // inherited automatically. Translate the single `ModalResponse`
            // into the two-value (disposition, credential?) tuple the auth
            // completion handler expects.
            presentWebDialog(alert, over: webView) { response in
                if response == .alertFirstButtonReturn {
                    // "Sign In": build a session-scoped credential. `.forSession`
                    // means WebKit holds it for the lifetime of the process but
                    // writes nothing to the keychain.
                    completionHandler(
                        .useCredential,
                        URLCredential(
                            user: userField.stringValue,
                            password: passField.stringValue,
                            persistence: .forSession
                        )
                    )
                } else {
                    // "Cancel" or sheet dismissal: abort the challenged request.
                    completionHandler(.cancelAuthenticationChallenge, nil)
                }
            }
        }

        private func reapplyIsolation(in webView: WKWebView) {
            // Best-effort: ignore the result/error. If the target node
            // isn't present yet the script no-ops, and the injected
            // MutationObserver will re-apply once it appears.
            webView.evaluateJavaScript(isolationSource, completionHandler: nil)
        }
    }

    /// Weak forwarding shim for the JS->Swift message handler (subtask
    /// T-005.4). `WKUserContentController.add(_:name:)` retains its handler
    /// STRONGLY; if we registered the Coordinator directly the controller
    /// (owned by the webview) would keep the Coordinator alive for the
    /// webview's whole lifetime and could form a retain cycle. This proxy
    /// is what gets retained instead — it holds the Coordinator `weak`, so
    /// the only strong edge is Coordinator -> proxy (via `messageProxy`),
    /// which breaks cleanly when SwiftUI releases the Coordinator. The
    /// handler is also explicitly removed in `dismantleNSView`.
    @MainActor
    public final class MessageHandlerProxy: NSObject, WKScriptMessageHandler {
        weak var coordinator: Coordinator?

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init()
        }

        public func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            coordinator?.handleMessageBody(message.body)
        }
    }

    /// Weak forwarding shim for the deterministic content-ready JS->Swift
    /// message handler. Same retain-cycle-avoidance shape as
    /// `MessageHandlerProxy`: the controller retains the proxy strongly; the
    /// proxy holds only a weak back-reference to the Coordinator.
    @MainActor
    public final class ContentReadyProxy: NSObject, WKScriptMessageHandler {
        weak var coordinator: Coordinator?

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init()
        }

        public func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            coordinator?.onContentReady?()
        }
    }

    /// The JS injected at document start that posts `handlerName` once the
    /// document has reached `readyState === "complete"` AND two
    /// `requestAnimationFrame`s have elapsed — i.e. the first paint of the
    /// loaded content has actually happened. Idempotent per document (guards
    /// with a `fired` flag), and defensive against a missing handler.
    static func contentReadyScript(handlerName: String) -> String {
        """
        (function () {
          var fired = false;
          function post() {
            if (fired) return; fired = true;
            requestAnimationFrame(function () {
              requestAnimationFrame(function () {
                try {
                  window.webkit.messageHandlers.\(handlerName).postMessage({});
                } catch (e) {}
              });
            });
          }
          if (document.readyState === "complete") { post(); return; }
          window.addEventListener("load", post);
          document.addEventListener("readystatechange", function () {
            if (document.readyState === "complete") post();
          });
        })();
        """
    }

    /// Weak forwarding shim for the text-selection JS->Swift message
    /// handler (AC2 — cozy-nimbus). Same retain-cycle-avoidance pattern
    /// as `MessageHandlerProxy`: `WKUserContentController` retains its
    /// handlers strongly; we register this shim instead of the Coordinator
    /// and hold only a weak back-reference, so the cycle breaks when
    /// SwiftUI releases the Coordinator.
    @MainActor
    public final class SelectionHandlerProxy: NSObject, WKScriptMessageHandler {
        weak var coordinator: Coordinator?

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init()
        }

        public func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            coordinator?.handleSelectionMessageBody(message.body)
        }
    }

    /// Weak forwarding shim for the link-interception JS->Swift message handler. Same retain-cycle
    /// avoidance as `SelectionHandlerProxy`: the content controller retains its handlers strongly, so we
    /// register this shim and hold only a weak back-reference to the Coordinator.
    @MainActor
    final class LinkHandlerProxy: NSObject, WKScriptMessageHandler {
        weak var coordinator: Coordinator?

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init()
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            coordinator?.handleInterceptedLinkBody(message.body, webView: message.webView)
        }
    }

    /// Weak forwarding shim for the element-picker JS->Swift message handler
    /// (lanky-pine.2). Same retain-cycle-avoidance pattern as
    /// `SelectionHandlerProxy`: `WKUserContentController` retains its
    /// handlers strongly; we register this shim instead of the Coordinator
    /// and hold only a weak back-reference, so the cycle breaks when SwiftUI
    /// releases the Coordinator.
    @MainActor
    public final class ElementPickHandlerProxy: NSObject, WKScriptMessageHandler {
        weak var coordinator: Coordinator?

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init()
        }

        public func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            coordinator?.handlePickMessageBody(message.body)
        }
    }

    /// Pure, unit-testable coordinate transform: converts a text selection
    /// rect from CSS-pixel PAGE space (as reported by the injected JS) to
    /// WKWebView VIEW space.
    ///
    /// The JS reports coordinates as:
    ///   `x = rect.left + window.scrollX`
    ///   `y = rect.top  + window.scrollY`
    /// i.e. page-space (NOT viewport-relative). Subtracting `scrollX`/`Y`
    /// converts back to viewport-relative CSS pixels. `devicePixelRatio`
    /// is not applied here because WKWebView already reports layout in CSS
    /// pixels (device-independent units), so no DPR scaling is needed for
    /// the overlay coordinate; the JS passes it for completeness but we
    /// deliberately ignore it in the view-space conversion.
    ///
    /// - Parameters:
    ///   - pageX: Selection rect left edge in page-space CSS pixels.
    ///   - pageY: Selection rect top edge in page-space CSS pixels.
    ///   - width: Selection rect width in CSS pixels.
    ///   - height: Selection rect height in CSS pixels.
    ///   - scrollX: `window.scrollX` at the time of the event.
    ///   - scrollY: `window.scrollY` at the time of the event.
    ///   - devicePixelRatio: `window.devicePixelRatio` (unused; carried
    ///     for API completeness so callers can test the transform fully).
    /// - Returns: The selection rect in WKWebView view-local coordinates
    ///   (CSS pixels, origin at top-left of the visible viewport).
    public static func selectionViewRect(
        pageX: Double,
        pageY: Double,
        width: Double,
        height: Double,
        scrollX: Double,
        scrollY: Double,
        devicePixelRatio: Double
    ) -> CGRect {
        let viewX = pageX - scrollX
        let viewY = pageY - scrollY
        return CGRect(x: viewX, y: viewY, width: width, height: height)
    }

    /// Tear down the JS->Swift message handler when SwiftUI discards the
    /// webview, so the `WKUserContentController` stops strongly retaining
    /// the proxy. Without this the proxy (and through it nothing, since it
    /// only weakly holds the Coordinator) would linger with the controller;
    /// removing it keeps teardown clean and symmetric with `makeNSView`.
    public static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: Self.messageHandlerName)
        coordinator.messageProxy = nil
        // Tear down the content-ready handler symmetrically.
        controller.removeScriptMessageHandler(forName: Self.contentReadyHandlerName)
        coordinator.contentReadyProxy = nil
        // Also tear down the selection message handler symmetrically.
        controller.removeScriptMessageHandler(forName: Self.selectionHandlerName)
        coordinator.selectionProxy = nil
        // Tear down the link-interception handler symmetrically.
        controller.removeScriptMessageHandler(forName: Self.linkHandlerName)
        coordinator.linkProxy = nil
        // Tear down the element-picker message handler symmetrically.
        controller.removeScriptMessageHandler(forName: Self.elementPickHandlerName)
        coordinator.pickProxy = nil
        // Tear down the overscroll scroll-state handler (feat/spec-as-html.11).
        OverscrollInstaller.teardown(from: controller, proxy: coordinator.overscrollProxy)
        coordinator.overscrollProxy = nil
        // Tear down the diagram-expand handler symmetrically.
        controller.removeScriptMessageHandler(forName: DiagramMessageProxy.name)
        coordinator.diagramProxy = nil
        coordinator.diagramExpandHandler = nil
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onOpenLink = onOpenLink
        // Reload only if the spec now points at a different URL, so
        // routine SwiftUI updates don't kick off a reload (which would
        // also drop any in-progress login or SPA state).
        if webView.url != spec.url {
            webView.load(URLRequest(url: spec.url))
        }
    }

    /// Build (or reattach to) the persistent `WKWebsiteDataStore` for a
    /// given key. On macOS 14+ each identifier maps to its own
    /// on-disk store, so distinct integrations stay isolated while a
    /// shared key reuses one logged-in session. The identifier is a
    /// stable UUID derived from the key.
    private static func persistentDataStore(forKey key: String) -> WKWebsiteDataStore {
        WKWebsiteDataStore(forIdentifier: stableIdentifier(forKey: key))
    }

    /// Read the system accent color as a CSS hex string, reliably on macOS 26+.
    ///
    /// `NSColor.controlAccentColor.usingColorSpace(.sRGB)` returns nil on
    /// macOS 26 for dynamic system colors. We use `CGColor.converted(to:intent:options:)`
    /// instead, which works on macOS 26+. Falls back to reading the
    /// `AppleAccentColor` UserDefaults key directly when the CGColor conversion
    /// also fails.
    ///
    /// Key mapping: -1 = multicolor, 1 = red, 2 = orange, 3 = yellow,
    /// 4 = green, 5 = blue (default), 6 = purple, 7 = pink.
    static func systemAccentColorHex() -> String {
        // Theme-first: a custom theme pins an explicit accent hex — use it
        // directly (already sRGB). Only the System palette (`accent: system`)
        // falls through to the macOS controlAccentColor resolution below.
        let isDark = NSApp?.effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let tokens = isDark ? ThemeRuntime.current.spec.dark : ThemeRuntime.current.spec.light
        if case .hex(let h) = tokens.accent { return h }
        let nsColor = NSColor.controlAccentColor
        if let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
           let cgColor = nsColor.cgColor.converted(to: colorSpace, intent: .perceptual, options: nil),
           let comps = cgColor.components, comps.count >= 3 {
            let r = Int((comps[0] * 255).rounded())
            let g = Int((comps[1] * 255).rounded())
            let b = Int((comps[2] * 255).rounded())
            return String(format: "#%02x%02x%02x", r, g, b)
        }
        // Fallback: UserDefaults accent index
        // macOS accent indices: -1=multicolor, 0=graphite, 1=red, 2=orange, 3=yellow, 4=green, 5=blue, 6=purple, 7=pink
        switch UserDefaults.standard.object(forKey: "AppleAccentColor") as? Int {
        case 1: return "#ff3b30"  // red
        case 2: return "#ff9500"  // orange
        case 3: return "#ffcc00"  // yellow
        case 4: return "#34c759"  // green
        case 6: return "#af52de"  // purple
        case 7: return "#ff2d55"  // pink
        default: return "#007aff" // blue (default / graphite / multicolor)
        }
    }

    /// Deterministically map an arbitrary key string to a UUID so the
    /// same `dataStoreKey` always resolves to the same persistent
    /// store across launches. Uses a fixed namespace + an FNV-1a hash
    /// of the key to fill the 16 UUID bytes (RFC-4122 variant/version
    /// bits set), avoiding any dependency on CryptoKit.
    static func stableIdentifier(forKey key: String) -> UUID {
        // Fixed namespace prefix so our identifiers are unlikely to
        // collide with any default/other store UUID.
        var bytes = [UInt8](repeating: 0, count: 16)
        let namespace: [UInt8] = [0x42, 0x57, 0x53, 0x53] // "BWSS"
        for i in 0..<4 { bytes[i] = namespace[i] }

        // FNV-1a 64-bit over the key, spread across the remaining 12
        // bytes by re-seeding so different keys diverge well.
        let keyBytes = Array(key.utf8)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3
        for byte in keyBytes {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        for offset in 0..<12 {
            bytes[4 + offset] = UInt8(truncatingIfNeeded: hash >> (UInt64(offset % 8) * 8))
            if offset % 8 == 7 {
                // Re-mix so the second 8-byte run isn't a repeat of the
                // first when keys are short.
                hash ^= UInt64(offset)
                hash = hash &* prime
            }
        }

        // RFC-4122: version 4 (random) and variant bits.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

// MARK: - Cached live view (LiveWidgetBackends-style, subtask T-005.7 / AC8)

/// A retained bundle of a configured `WKWebView` and the `Coordinator`
/// that serves as its navigation/UI/message delegate.
///
/// `WKWebView` holds its `navigationDelegate`/`uiDelegate` *weakly*, and
/// the JS->Swift `MessageHandlerProxy` only weakly references the
/// Coordinator. So a webview on its own would lose its delegates the
/// moment SwiftUI released the representable's Coordinator. This holder
/// keeps the two together for as long as the holder is retained, which is
/// exactly what a LiveWidgetBackends-style cache wants: store ONE
/// `WebSectionLiveView` per widget identity and the underlying `WKWebView`
/// (with its login session, scroll position, and SPA state) survives tab
/// switches and widget reopen — no reload.
///
/// Build one via ``WebSectionView/makeLiveView(spec:onSignal:)`` and embed
/// it with ``CachedWebSectionView``. Release it (drop the last strong
/// reference) when the widget/session closes; ``teardown()`` detaches the
/// message handler symmetrically with `WebSectionView.dismantleNSView`.
@Observable
@MainActor
public final class WebSectionLiveView {

    /// The configured, already-loading webview. Reused across remounts.
    public let webView: WKWebView

    /// The delegate that owns SPA-navigation re-isolation, SSO popup
    /// routing, and (optionally) the JS->Swift signal sink. Retained here
    /// so it outlives any individual SwiftUI representable instance.
    let coordinator: WebSectionView.Coordinator

    /// Navigation lifecycle status updated by the `Coordinator`'s
    /// `WKNavigationDelegate` callbacks (lanky-pine.3 / AC10, AC11).
    ///
    /// Starts at `.loading` (the webview begins loading its first URL in
    /// `buildWebView`). Transitions:
    ///   - `.loading`  on `didStartProvisionalNavigation`
    ///   - `.loaded`   on `didFinish`
    ///   - `.failed`   on `didFail` / `didFailProvisionalNavigation`
    ///
    /// `public` so `Work42App` targets (BrowserChromeRow, subtasks .5 and
    /// .7) can observe it alongside the webview.
    public var status: WebSectionStatus = .loading

    /// Whether the loaded page has actually painted its content — set true when
    /// the injected readiness script posts `contentReady` (readyState complete +
    /// two rAFs), reset to false when a new full navigation starts
    /// (`didStartProvisionalNavigation` → `.loading`). Drives the loading
    /// overlay so it lifts on real content, not merely on `didFinish`.
    public var hasPaintedContent: Bool = false

    /// KVO token observing `webView.url`. `WKWebView.url` is KVO-compliant and
    /// updates on EVERY navigation — full loads AND same-document `pushState`
    /// navigations (how GitHub/Turbo, Jira, etc. move between pages without a
    /// full reload, which `didFinish` does NOT fire for). This is what makes
    /// `onURLChange` catch in-page link clicks, not just typed URLs.
    /// The token auto-invalidates when this object deallocates (no explicit
    /// deinit — a nonisolated deinit can't touch this @MainActor property).
    private var urlObservation: NSKeyValueObservation?

    init(webView: WKWebView, coordinator: WebSectionView.Coordinator) {
        self.webView = webView
        self.coordinator = coordinator
        // Wire the coordinator's status callback so every nav-delegate event
        // propagates into this observable property. The closure captures
        // `self` weakly to avoid a retain cycle (coordinator → live).
        coordinator.onStatusChange = { [weak self] newStatus in
            self?.status = newStatus
            // A new full navigation invalidates any prior paint — reset so the
            // overlay reappears until the fresh content paints.
            if case .loading = newStatus { self?.hasPaintedContent = false }
        }
        // The injected readiness script reports a real first paint here.
        coordinator.onContentReady = { [weak self] in
            self?.hasPaintedContent = true
        }
        // Observe url so same-document (pushState) navigations report through
        // onURLChange too — `didFinish` alone misses Turbo/PJAX route changes.
        // `change.newValue` (URL, Sendable) avoids touching the @MainActor
        // `webView.url` from this nonisolated KVO closure; hop to main to reach
        // the @MainActor coordinator (KVO fires on main, but stay defensive).
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, change in
            guard let newURL = change.newValue ?? nil else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.coordinator.onURLChange?(newURL)
                }
            }
        }
    }

    /// The text-selection callback (AC2 — cozy-nimbus). Setting this wires
    /// the callback into the `Coordinator` so the cached `WKWebView`
    /// delivers selection events without a teardown/rebuild. Setting to
    /// nil clears the callback (events are discarded). The selection
    /// tracking script is always injected at `buildWebView` time, so this
    /// is purely a handler swap, not a DOM change.
    ///
    /// The closure receives: the selected text, the view-space bounding rect,
    /// and an optional file path extracted from the GitHub diff DOM `data-path`
    /// (non-nil only when the selection is inside a diff file section). AC7:
    /// the diff line / side are recovered Swift-side from the PR patch, not the
    /// DOM, so they are no longer part of this callback.
    public var selectionHandler: ((String, CGRect, [String: String]) -> Void)? {
        get { coordinator.selectionHandler }
        set { coordinator.selectionHandler = newValue }
    }

    /// The element-pick callback (lanky-pine.2 / AC3). Receives the CSS
    /// selector, the view-space bounding rect, the element's normalized text,
    /// and the page URL when JS posts a `capture` payload. Setting this wires
    /// the callback into the `Coordinator` without rebuilding the `WKWebView`.
    /// Setting to nil clears it (events are discarded).
    ///
    /// Parameters: (selector, viewRect, text, pageUrl)
    public var pickHandler: ((String, CGRect, String, String) -> Void)? {
        get { coordinator.pickHandler }
        set { coordinator.pickHandler = newValue }
    }

    /// Callback fired when the picker is stopped by the user (Esc) or by Swift
    /// calling `stopPicker()` / `window.__w42Picker.stop()`. Setting this
    /// wires the callback into the Coordinator without rebuilding the WKWebView.
    public var onPickerStopped: (() -> Void)? {
        get { coordinator.onPickerStopped }
        set { coordinator.onPickerStopped = newValue }
    }

    /// Callback fired on `didFinish` with the page the webview actually landed
    /// on. Lets the browser widget persist the real current page after in-page
    /// link navigation (not just typed URLs). Handler swap only — no rebuild.
    public var onURLChange: ((URL) -> Void)? {
        get { coordinator.onURLChange }
        set { coordinator.onURLChange = newValue }
    }

    /// Intercept outbound user link activations. Nil preserves normal web
    /// navigation, which is the default for BrowserSurface-based widgets.
    public var onOpenLink: ((URL) -> Void)? {
        get { coordinator.onOpenLink }
        set { coordinator.onOpenLink = newValue }
    }

    /// Callback fired when the user deselects a previously-picked element by
    /// clicking it again (toggle-deselect). Setting this wires the callback into
    /// the Coordinator without rebuilding the WKWebView. Setting to nil clears it.
    public var deselectHandler: ((String) -> Void)? {
        get { coordinator.deselectHandler }
        set { coordinator.deselectHandler = newValue }
    }

    /// Arm the element picker in the webview by evaluating
    /// `window.__w42Picker.start()`. No-op if the picker script was not
    /// injected (the JS call is a guarded no-op for null/missing __w42Picker).
    public func startPicker() {
        webView.evaluateJavaScript("window.__w42Picker?.start()", completionHandler: nil)
    }

    /// Disarm the element picker in the webview by evaluating
    /// `window.__w42Picker.stop()`. This also triggers the Esc path in JS
    /// (which posts `{ type: "stop" }` → `onPickerStopped`).
    public func stopPicker() {
        webView.evaluateJavaScript("window.__w42Picker?.stop()", completionHandler: nil)
    }

    /// Reload the current page in the cached webview.
    ///
    /// Re-fetches the loaded URL (`WKWebView.reload()`), keeping the same
    /// data store, delegates, and SPA/login state. The agent canvas widget
    /// calls this when its `content.html` changes on disk: the canvas
    /// server re-composes the themed shell around the latest content on
    /// every request, so a plain reload surfaces the new content live
    /// (spec AC2) without rebuilding the webview. No-op semantics if no
    /// page is loaded yet — `reload()` simply re-requests the last URL.
    public func reload() {
        webView.reload()
    }

    /// Wire (or clear) the link router: asked about each link the user clicks in a browser-style
    /// view; returning true means the host took the link and navigation here is cancelled.
    public func setLinkRouter(_ router: ((URL) -> Bool)?) {
        coordinator.linkRouter = router
    }

    /// The URL patterns other widgets own. A click on a link matching one is caught INSIDE the page (so it
    /// also works for single-page apps that never trigger a navigation) and handed to the link router.
    /// Pass `[]` to stop intercepting. Idempotent: the page is only re-told when the list changes.
    public func setLinkPatterns(_ patterns: [WebLinkPattern]) {
        guard patterns != coordinator.linkPatterns else { return }
        coordinator.linkPatterns = patterns
        coordinator.pushLinkPatterns(to: webView)
    }

    /// Make every web link click (http, https, work42; not fragments in the current document) go to the link
    /// router, whatever it points at, so the host's Open Link decides where it opens. A declined click is
    /// replayed in the page. Option-click always navigates in place. Idempotent.
    public func setInterceptAllLinks(_ on: Bool) {
        guard on != coordinator.interceptAllLinks else { return }
        coordinator.interceptAllLinks = on
        coordinator.pushLinkPatterns(to: webView)
    }

    /// Testing seam: where an intercepted link goes when the router declines it.
    func setInterceptedLinkFallback(_ fallback: ((URL) -> Void)?) {
        coordinator.interceptedLinkFallback = fallback
    }

    /// Load `url` in this view (what "keep it here" does after the router declined or the user
    /// chose to stay).
    public func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    /// Wire (or clear) the native diagram-expand sink. The `w42Diagram` message
    /// handler is always registered at build time; this only sets the callback
    /// the injected diagram bridge's Expand button delivers the diagram SVG to,
    /// so `DiagramOverlayLayer` can present the native dialog without rebuilding
    /// the webview. Pass nil on teardown.
    public func setDiagramExpandHandler(_ handler: ((String) -> Void)?) {
        coordinator.diagramExpandHandler = handler
    }

    /// Wire (or clear) the native Flutter-mockup sink. The `w42FlutterMockup`
    /// handler is always registered at build time; this sets the callback the
    /// page's `<w42-flutter-mockup>` posts `{type,id,app,device}` to, so the
    /// app-side `FlutterMockupController` can spawn the run without rebuilding the
    /// webview. Pass nil on teardown.
    public func setFlutterMockupHandler(_ handler: (([String: Any]) -> Void)?) {
        coordinator.flutterMockupHandler = handler
    }

    /// Clear all website data (cookies, cache, local storage) from the
    /// webview's data store and reload the page.
    ///
    /// Removes every data type tracked by `WKWebsiteDataStore` since the
    /// epoch — effectively a full wipe — then calls `webView.reload()` so
    /// the widget starts fresh and the user can re-authenticate. Intended for
    /// the persistent-store widgets (Jira, GitHub PR) where stale or expired
    /// session state can leave the widget stuck on a login or error page.
    ///
    /// This is a no-op on ephemeral stores (the canvas widget) because they
    /// hold no data across navigations, but calling it there is harmless.
    public func clearData() async {
        let dataStore = webView.configuration.websiteDataStore
        await dataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: Date(timeIntervalSince1970: 0)
        )
        webView.reload()
    }

    // MARK: - Find-in-page (dewy-flint.1)

    /// Perform a find-in-page search for the given query.
    ///
    /// Clears any existing highlights, walks the page's text nodes (top frame
    /// only — cross-origin iframes are not searched), wraps every
    /// case-insensitive match in a yellow `<mark class="w42-find">` and the
    /// first match in an orange `w42-find-active` mark, then scrolls the
    /// active match into view. Persists state in `window.__w42FindState` so
    /// `findNext()` / `findPrevious()` can advance without re-scanning.
    ///
    /// - Parameter query: The text to search for. An empty or blank query
    ///   clears existing highlights and returns `(0, 0)`.
    /// - Returns: `(current, total)` where `current` is the 1-based index of
    ///   the active match (0 when there are no matches) and `total` is the
    ///   total match count.
    public func find(_ query: String) async -> (current: Int, total: Int) {
        let accentHex = WebSectionView.systemAccentColorHex()
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(WebSectionScript.find(query: query, activeColor: accentHex)) { result, _ in
                continuation.resume(returning: Self.decodeFindResult(result))
            }
        }
    }

    /// Advance to the next match, wrapping from the last to the first.
    ///
    /// No-op (returns `(0, 0)`) when no find has been run or there are no
    /// matches on the current page.
    ///
    /// - Returns: `(current, total)` reflecting the newly active match.
    public func findNext() async -> (current: Int, total: Int) {
        let accentHex = WebSectionView.systemAccentColorHex()
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(WebSectionScript.findNext(activeColor: accentHex)) { result, _ in
                continuation.resume(returning: Self.decodeFindResult(result))
            }
        }
    }

    /// Move to the previous match, wrapping from the first to the last.
    ///
    /// No-op (returns `(0, 0)`) when no find has been run or there are no
    /// matches on the current page.
    ///
    /// - Returns: `(current, total)` reflecting the newly active match.
    public func findPrevious() async -> (current: Int, total: Int) {
        let accentHex = WebSectionView.systemAccentColorHex()
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(WebSectionScript.findPrevious(activeColor: accentHex)) { result, _ in
                continuation.resume(returning: Self.decodeFindResult(result))
            }
        }
    }

    /// Remove all match highlights from the page and reset find state.
    ///
    /// Safe to call at any time — a no-op if no find is active. Fire-and-
    /// forget: does not wait for the JS to complete.
    public func clearFind() {
        webView.evaluateJavaScript(WebSectionScript.findClear(), completionHandler: nil)
    }

    /// Decode the `{ current, total }` object returned by the find scripts.
    ///
    /// WKWebView bridges JavaScript numbers as `NSNumber`, so we read via
    /// `NSNumber.intValue` rather than casting directly to `Int`.
    private static func decodeFindResult(_ result: Any?) -> (current: Int, total: Int) {
        guard let dict = result as? [String: Any] else { return (current: 0, total: 0) }
        let current = (dict["current"] as? NSNumber)?.intValue ?? 0
        let total   = (dict["total"]   as? NSNumber)?.intValue ?? 0
        return (current: current, total: total)
    }

    // MARK: - Zoom (dewy-flint.1)

    /// The current zoom level of the webview (1.0 = 100%).
    ///
    /// Reads `WKWebView.pageZoom` directly. The zoom is per-webview (per-tab)
    /// and survives in-tab navigation. `WKWebView.pageZoom` is available on
    /// macOS 14+; this target requires macOS 15 so no availability guard is
    /// needed.
    public var pageZoom: CGFloat {
        webView.pageZoom
    }

    /// Set the zoom level, clamped to the range 50%–300%.
    ///
    /// Values below 0.5 are clamped to 0.5; values above 3.0 are clamped to
    /// 3.0. The zoom is applied immediately and persists for all in-tab
    /// navigations since it lives on the `WKWebView` instance.
    ///
    /// - Parameter zoom: The desired zoom multiplier (1.0 = 100%, 0.5 = 50%,
    ///   3.0 = 300%).
    public func setZoom(_ zoom: CGFloat) {
        webView.pageZoom = min(3.0, max(0.5, zoom))
    }

    /// Increase the zoom level by one 10% step, clamped to 300%.
    public func zoomIn() {
        setZoom(pageZoom + 0.1)
    }

    /// Decrease the zoom level by one 10% step, clamped to 50%.
    public func zoomOut() {
        setZoom(pageZoom - 0.1)
    }

    /// Reset the zoom level to 100%.
    public func resetZoom() {
        setZoom(1.0)
    }

    /// Detach the JS->Swift message handler from the webview's content
    /// controller, mirroring `WebSectionView.dismantleNSView`. Call this
    /// before dropping the holder so the `WKUserContentController` stops
    /// retaining the message proxy. Idempotent.
    public func teardown() {
        WebSectionView.dismantleNSView(webView, coordinator: coordinator)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }
}

extension WebSectionView {

    /// Construct a retained, configured live webview for a spec — the
    /// cacheable unit for the LiveWidgetBackends pattern (subtask T-005.7).
    ///
    /// This builds the SAME webview `makeNSView` would (isolation script,
    /// optional signal seam, persistent data store keyed by
    /// `spec.dataStoreKey`, navigation/UI delegates) but hands back a
    /// `WebSectionLiveView` that retains the Coordinator alongside it, so a
    /// cache can hold the result and reuse the underlying `WKWebView`
    /// across tab switches without reloading the page or dropping the
    /// login session.
    @MainActor
    public static func makeLiveView(
        spec: WebSectionSpec,
        onSignal: ((WebSectionSignal) -> Void)? = nil,
        onOpenLink: ((URL) -> Void)? = nil
    ) -> WebSectionLiveView {
        let coordinator = Coordinator(selector: spec.selector, onSignal: onSignal)
        coordinator.onOpenLink = onOpenLink
        let webView = buildWebView(spec: spec, onSignal: onSignal, coordinator: coordinator)
        return WebSectionLiveView(webView: webView, coordinator: coordinator)
    }
}

/// Embeds an externally-owned, cached `WebSectionLiveView` as a SwiftUI
/// view without taking ownership of its lifecycle.
///
/// Unlike `WebSectionView` (which builds a fresh `WKWebView` per
/// `makeNSView`), this view adopts a `WKWebView` that lives in a
/// LiveWidgetBackends-style cache. SwiftUI may tear this wrapper down and
/// remount it freely (tab switch, layout change); the underlying
/// `_CachedWebViewRepresentable` returns the SAME cached webview each time,
/// so the page is never reloaded and the session/scroll/SPA state is
/// preserved. Cleanup (detaching delegates, dropping the cache entry) is
/// the cache owner's job — see `WebSectionLiveView.teardown()`.
///
/// Overlays (lanky-pine.3 / AC10, AC11):
///   - While `live.status == .loading`: a `ProgressView` spinner is
///     centered over the webview.
///   - While `live.status == .failed(let desc)`: an error view with a
///     heading, the failure description, and a **Retry** button that calls
///     `live.reload()` (which resets status to `.loading` on the next
///     `didStartProvisionalNavigation` callback).
@MainActor
public struct CachedWebSectionView: View {

    /// The retained, configured live webview pulled from the cache.
    public let live: WebSectionLiveView

    public init(live: WebSectionLiveView) {
        self.live = live
    }

    /// This tab's visibility, threaded from the app chassis (`Work42View`). The
    /// overlay stays up while the view is not visible so a page that finishes
    /// loading while hidden is never revealed unpainted (blank); it lifts once
    /// the content has painted AND the view is on screen.
    @Environment(\.widgetIsVisible) private var isVisible

    public var body: some View {
        _CachedWebViewRepresentable(live: live)
            .overlay {
                if case .failed(let description) = live.status {
                    errorOverlay(description: description)
                } else if shouldShowLoadingOverlay {
                    loadingOverlay
                } else {
                    EmptyView()
                }
            }
    }

    /// Keep the loading overlay up until the page has genuinely painted its
    /// content AND this view is visible — so it reads as "ready" exactly when
    /// real content is on screen, never revealing an unpainted (blank) webview.
    /// Bounded fallback: a page that reached `.loaded` (didFinish) but never
    /// posted `contentReady` still lifts the overlay once visible, so a
    /// quiet/edge page is not stuck spinning; requiring visibility means the
    /// hidden→visible repaint nudge has already fired, so this never reveals a
    /// blank surface.
    private var shouldShowLoadingOverlay: Bool {
        if live.hasPaintedContent && isVisible { return false }
        if case .loaded = live.status, isVisible { return false }
        return true
    }

    // MARK: - Loading overlay (AC10)

    @ViewBuilder
    private var loadingOverlay: some View {
        ZStack {
            // Semi-transparent background so the webview (which may be
            // partially rendered) doesn't show through distractingly.
            Color(nsColor: .windowBackgroundColor).opacity(0.85)
            // The 42 brand mark loader (not a generic spinner).
            Loader42()
                .frame(width: 48, height: 48)
        }
    }

    // MARK: - Error overlay (AC11)

    @ViewBuilder
    private func errorOverlay(description: String) -> some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            VStack(spacing: 16) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.secondary)

                Text("Page failed to load")
                    .font(.system(size: 14, weight: .semibold))

                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)

                Button {
                    live.webView.reload()
                    live.status = .loading
                } label: {
                    Text("Retry")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 7)
                        .background(DT.systemAccent, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(24)
        }
    }
}

// MARK: - Private representable

/// The thin `NSViewRepresentable` that adopts the cached `WKWebView`.
/// Kept private so callers always go through `CachedWebSectionView` (which
/// owns the loading/error overlay layer).
@MainActor
private struct _CachedWebViewRepresentable: NSViewRepresentable {
    let live: WebSectionLiveView

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        live.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // The cached webview owns its own state (URL, session, scroll); URL
        // changes are handled by rebuilding the cache entry under a new key,
        // not by reloading in place — so this stays a no-op for that.
        //
        // The one thing it DOES do: when the hosting tab transitions from
        // hidden to visible, nudge a repaint. A cached page can complete its
        // first paint while the tab is at `opacity(0)` with a frozen frame;
        // on re-show the frame often does not change, so WebKit never
        // re-composites and the tab reads blank until an unrelated layout
        // pass. Forcing an in-page reflow (display none→read→restore) makes
        // WebKit repaint immediately, without a tab switch.
        let isVisible = context.environment.widgetIsVisible
        defer { context.coordinator.wasVisible = isVisible }
        guard isVisible, context.coordinator.wasVisible == false else { return }
        nsView.setNeedsDisplay(nsView.bounds)
        nsView.evaluateJavaScript(
            "(function(){var b=document.body;if(!b)return;var d=b.style.display;"
                + "b.style.display='none';void b.offsetHeight;b.style.display=d;})()",
            completionHandler: nil
        )
    }

    @MainActor
    final class Coordinator {
        /// Last visibility seen in `updateNSView`, so the repaint nudge fires
        /// only on the hidden→visible edge. Starts `true` so a webview first
        /// built while already visible does not nudge (it paints normally).
        var wasVisible: Bool = true
    }
}
