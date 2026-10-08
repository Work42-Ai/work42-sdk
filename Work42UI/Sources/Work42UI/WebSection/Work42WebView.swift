// Work42WebView.swift — the one constructor for every web view, and the link policy it installs (linear42 s24).
//
// Every `WKWebView` Work42 shows is built by `Work42WebView.make`. An interactive one is a `PolicyWebView`:
// it hands every clicked link, every route change a click causes, and every popup to the host's single
// `WebLinkHost.handler` (the Open Link intent), so no surface can exist without link routing. An offscreen one
// (snapshot renderers, diagram canvases) is a plain `WKWebView` that never shows a link to anyone.
//
// What the policy sees:
//   * click        — a click on an `<a href>` (caught in the page, capture phase, before the app's handlers) or a
//                    `.linkActivated` navigation the page script missed (the context menu's Open Link).
//   * routeChange  — a single-page app's `pushState`/`replaceState` to a new path within a second of a click or
//                    Enter. A safety net for apps like Linear that navigate from non-link elements. The host can
//                    take it (the page is reverted) or leave it in place.
//   * popup        — `window.open` / `target=_blank`. Owned elsewhere: routed. Unowned: a real popup attached to
//                    the opener, so sign-in windows keep their `window.opener`.
// Everything else (redirects, form posts, reloads, back/forward, subframes) is left alone.

import AppKit
import Foundation
import SwiftUI
import WebKit

// MARK: - Public types

public enum WebLinkKind: Sendable {
    case click
    case routeChange
    case popup
}

/// A link the web view offers the host.
public struct WebLinkRequest {
    public let url: URL
    /// The widget the web view belongs to (`PolicyWebView.linkSource`), nil for surfaces that are no widget.
    public let source: String?
    /// The page the link was found on.
    public let pageURL: URL?
    public let kind: WebLinkKind
    public weak var window: NSWindow?

    public init(url: URL, source: String?, pageURL: URL?, kind: WebLinkKind, window: NSWindow?) {
        self.url = url
        self.source = source
        self.pageURL = pageURL
        self.kind = kind
        self.window = window
    }
}

public enum WebLinkOutcome: Sendable {
    /// The host opened the link somewhere else.
    case taken
    /// The host declined: the web view carries on in place.
    case keptInPlace
}

/// How the host decides links. Registered once, at launch (`WebLinkHost.handler`).
public struct WebLinkHandler {
    /// Decide a link. Call `completion` exactly once, possibly later (the host may ask the user to pick).
    public var open: (WebLinkRequest, @escaping @MainActor (WebLinkOutcome) -> Void) -> Void
    /// Whether a widget other than `source` owns `url` (decides whether a popup is routed or stays attached).
    public var ownsElsewhere: (_ url: URL, _ source: String?) -> Bool

    public init(
        open: @escaping (WebLinkRequest, @escaping @MainActor (WebLinkOutcome) -> Void) -> Void,
        ownsElsewhere: @escaping (_ url: URL, _ source: String?) -> Bool
    ) {
        self.open = open
        self.ownsElsewhere = ownsElsewhere
    }
}

public enum WebLinkHost {
    /// Nil until the host registers one; a web view with no handler leaves every link in place.
    public static var handler: WebLinkHandler?
}

public enum WebViewRole: Sendable {
    case interactive(source: String?)
    case offscreen
}

public enum Work42WebView {
    /// The only way to create a web view in Work42. `configuration` carries the caller's scripts and handlers.
    public static func make(
        configuration: WKWebViewConfiguration = WKWebViewConfiguration(),
        role: WebViewRole,
        frame: CGRect = .zero
    ) -> WKWebView {
        switch role {
        case .offscreen:
            return WKWebView(frame: frame, configuration: configuration)
        case .interactive:
            return make(PolicyWebView.self, configuration: configuration, role: role, frame: frame)
        }
    }

    /// Builds one of the SDK's own `PolicyWebView` subclasses (overscroll passthrough, the markdown renderer's
    /// scroll forwarding). An `.offscreen` role leaves the subclass without a link policy.
    static func make<T: PolicyWebView>(
        _ type: T.Type,
        configuration: WKWebViewConfiguration = WKWebViewConfiguration(),
        role: WebViewRole,
        frame: CGRect = .zero
    ) -> T {
        let view = type.init(frame: frame, configuration: configuration)
        view.install(role)
        return view
    }
}

extension EnvironmentValues {
    /// The widget id the surrounding view belongs to; an embedded web view passes it as its link source.
    @Entry public var work42LinkSource: String?
}

// MARK: - PolicyWebView

/// An interactive web view whose navigation and UI delegates are fronted by the link policy. Subclass it for
/// a view that needs its own behaviour and build it with `Work42WebView.make(_:configuration:role:)`.
public class PolicyWebView: WKWebView {
    public var linkSource: String?

    private let policy = LinkPolicyProxy()
    private var policyActive = false
    private weak var callerNavigation: (any WKNavigationDelegate)?
    private weak var callerUI: (any WKUIDelegate)?

    public required override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("PolicyWebView is built by Work42WebView.make") }

    /// Offers a link the page could not route itself (a `path:line` reference, a relative href in a page with no
    /// base URL) to the host's Open Link. A view with no policy ignores it.
    func offerLink(_ url: URL) {
        guard policyActive else { return }
        policy.offer(url, kind: .click) { _ in }
    }

    /// Turns the link policy on for an interactive role. Offscreen leaves the view as a plain web view.
    func install(_ role: WebViewRole) {
        guard case .interactive(let source) = role, !policyActive else { return }
        linkSource = source
        policy.webView = self
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(
            source: WebSectionScript.linkPolicy(handlerName: LinkPolicyProxy.handlerName),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        controller.add(LinkMessageRelay(policy), name: LinkPolicyProxy.handlerName)
        policyActive = true
        callerNavigation = super.navigationDelegate
        callerUI = super.uiDelegate
        policy.callerNavigation = callerNavigation
        policy.callerUI = callerUI
        super.navigationDelegate = policy
        super.uiDelegate = policy
    }

    public override var navigationDelegate: (any WKNavigationDelegate)? {
        get { policyActive ? callerNavigation : super.navigationDelegate }
        set {
            guard policyActive else { super.navigationDelegate = newValue; return }
            callerNavigation = newValue
            policy.callerNavigation = newValue
            super.navigationDelegate = policy
        }
    }

    public override var uiDelegate: (any WKUIDelegate)? {
        get { policyActive ? callerUI : super.uiDelegate }
        set {
            guard policyActive else { super.uiDelegate = newValue; return }
            callerUI = newValue
            policy.callerUI = newValue
            super.uiDelegate = policy
        }
    }
}

/// Keeps the script message handler from retaining the policy (and through it the web view).
private final class LinkMessageRelay: NSObject, WKScriptMessageHandler {
    private weak var policy: LinkPolicyProxy?
    init(_ policy: LinkPolicyProxy) { self.policy = policy }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        policy?.handle(message.body)
    }
}

// MARK: - The policy

final class LinkPolicyProxy: NSObject, WKNavigationDelegate, WKUIDelegate {
    static let handlerName = "w42Link"
    private static let schemes: Set<String> = ["http", "https", "work42", "file"]

    weak var webView: PolicyWebView?
    // Read by the Objective-C forwarding hooks below, which the runtime calls on the thread WebKit uses (main).
    nonisolated(unsafe) weak var callerNavigation: (any WKNavigationDelegate)?
    nonisolated(unsafe) weak var callerUI: (any WKUIDelegate)?

    /// A link the host kept in place is let through once: its replayed click (or load) must not be asked again.
    private var allowedOnce: [String: Date] = [:]

    // MARK: Forwarding

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector)
            || (callerNavigation?.responds(to: aSelector) ?? false)
            || (callerUI?.responds(to: aSelector) ?? false)
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let callerNavigation, callerNavigation.responds(to: aSelector) { return callerNavigation }
        if let callerUI, callerUI.responds(to: aSelector) { return callerUI }
        return super.forwardingTarget(for: aSelector)
    }

    // MARK: Messages from the page

    func handle(_ body: Any) {
        guard let webView,
              let dict = body as? [String: Any],
              let kindName = dict["kind"] as? String,
              let urlString = dict["url"] as? String,
              let url = URL(string: urlString)
        else { return }

        switch kindName {
        case "click":
            offer(url, kind: .click) { [weak self, weak webView] outcome in
                guard outcome == .keptInPlace, let self, let webView else { return }
                self.allowOnce(url)
                webView.evaluateJavaScript("window.__w42Links && window.__w42Links.replay()", completionHandler: nil)
            }
        case "routeChange":
            let replaced = dict["replaced"] as? Bool ?? false
            let previous = dict["previous"] as? String ?? ""
            offer(url, kind: .routeChange) { [weak webView] outcome in
                guard outcome == .taken, let webView else { return }
                let js = "window.__w42Links && window.__w42Links.revert(\(replaced), \(WebSectionScript.jsStringLiteral(previous)))"
                webView.evaluateJavaScript(js, completionHandler: nil)
            }
        default:
            break
        }
    }

    /// Ask the host; no handler means the link stays where it is.
    func offer(_ url: URL, kind: WebLinkKind, completion: @escaping @MainActor (WebLinkOutcome) -> Void) {
        guard let webView, let handler = WebLinkHost.handler else {
            completion(.keptInPlace)
            return
        }
        handler.open(
            WebLinkRequest(url: url, source: webView.linkSource, pageURL: webView.url, kind: kind, window: webView.window),
            completion
        )
    }

    private func allowOnce(_ url: URL) {
        allowedOnce = allowedOnce.filter { $0.value > Date() }
        allowedOnce[url.absoluteString] = Date().addingTimeInterval(3)
    }

    private func consumeAllowance(_ url: URL) -> Bool {
        guard let until = allowedOnce.removeValue(forKey: url.absoluteString) else { return false }
        return until > Date()
    }

    // MARK: Navigation

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        if navigationAction.navigationType == .linkActivated,
           navigationAction.targetFrame?.isMainFrame == true,
           let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(), Self.schemes.contains(scheme),
           !isSameDocumentFragment(url, of: webView.url),
           !consumeAllowance(url) {
            decisionHandler(.cancel, preferences)
            offer(url, kind: .click) { [weak webView] outcome in
                guard outcome == .keptInPlace, let webView else { return }
                webView.load(URLRequest(url: url))
            }
            return
        }
        if let caller = callerNavigation,
           caller.responds(to: Selector(("webView:decidePolicyForNavigationAction:preferences:decisionHandler:"))) {
            caller.webView?(webView, decidePolicyFor: navigationAction, preferences: preferences, decisionHandler: decisionHandler)
        } else if let caller = callerNavigation,
                  caller.responds(to: Selector(("webView:decidePolicyForNavigationAction:decisionHandler:"))) {
            caller.webView?(webView, decidePolicyFor: navigationAction) { policy in decisionHandler(policy, preferences) }
        } else {
            decisionHandler(.allow, preferences)
        }
    }

    private func isSameDocumentFragment(_ url: URL, of current: URL?) -> Bool {
        guard url.fragment != nil, let current else { return false }
        return url.absoluteString.components(separatedBy: "#")[0] == current.absoluteString.components(separatedBy: "#")[0]
    }

    // MARK: Popups

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let opener = webView as? PolicyWebView else { return nil }
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           scheme == "work42" || scheme == "file" || (WebLinkHost.handler?.ownsElsewhere(url, opener.linkSource) ?? false) {
            offer(url, kind: .popup) { _ in }
            return nil
        }
        // A popup shares its opener's content controller; give it its own so the policy handler is added once.
        configuration.userContentController = WKUserContentController()
        let popup = Work42WebView.make(configuration: configuration, role: .interactive(source: opener.linkSource))
        PopupPanel.show(popup, over: opener.window)
        return popup
    }
}

// MARK: - Popup window

/// The window an unowned popup lives in. Retained until the page closes it or the user does.
private final class PopupPanel: NSObject, WKUIDelegate, NSWindowDelegate {
    private static var open: Set<PopupPanel> = []

    private let panel: NSPanel
    private let webView: WKWebView
    private var titleObservation: NSKeyValueObservation?

    private init(webView: WKWebView) {
        self.webView = webView
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.isReleasedWhenClosed = false
        panel.contentView = webView
        panel.delegate = self
        webView.uiDelegate = self
        titleObservation = webView.observe(\.title, options: [.initial, .new]) { [weak self] view, _ in
            MainActor.assumeIsolated { self?.panel.title = view.title ?? "" }
        }
    }

    static func show(_ webView: WKWebView, over parent: NSWindow?) {
        let popup = PopupPanel(webView: webView)
        open.insert(popup)
        parent?.addChildWindow(popup.panel, ordered: .above)
        popup.panel.center()
        popup.panel.makeKeyAndOrderFront(nil)
    }

    func webViewDidClose(_ webView: WKWebView) {
        panel.close()
    }

    func windowWillClose(_ notification: Notification) {
        titleObservation = nil
        panel.parent?.removeChildWindow(panel)
        PopupPanel.open.remove(self)
    }
}
