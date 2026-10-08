// LinkPolicyTests.swift — linear42 s24 (AC36, AC59, AC61, AC62).
//
// Real `WKWebView`s built by `Work42WebView.make`, loading `loadHTMLString` pages, against a fake
// `WebLinkHost.handler`. Lives beside the PluginKit tests because Work42UI has no test target of its own.

import AppKit
import Foundation
import Testing
import WebKit
@testable import Work42UI

@MainActor
private final class Loader: NSObject, WKNavigationDelegate {
    var continuation: CheckedContinuation<Void, Never>?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }
}

/// One interactive web view with a recording handler registered as the host.
@MainActor
private final class Rig {
    let webView: PolicyWebView
    private let loader = Loader()
    var requests: [WebLinkRequest] = []
    var outcome: WebLinkOutcome = .keptInPlace
    var owned: Set<String> = []

    init(source: String? = "issue") {
        webView = Work42WebView.make(role: .interactive(source: source)) as! PolicyWebView
        webView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        webView.navigationDelegate = loader
        WebLinkHost.handler = WebLinkHandler(
            open: { [unowned self] request, completion in
                self.requests.append(request)
                completion(self.outcome)
            },
            ownsElsewhere: { [unowned self] url, _ in self.owned.contains(url.host ?? "") }
        )
    }

    deinit { MainActor.assumeIsolated { WebLinkHost.handler = nil } }

    func load(_ html: String, base: String = "https://x.test/start") async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            loader.continuation = continuation
            webView.loadHTMLString(html, baseURL: URL(string: base))
        }
    }

    @discardableResult
    func run(_ js: String) async -> Any? {
        try? await webView.evaluateJavaScript(js)
    }

    /// Polls until `condition` holds (the page and the native side talk asynchronously).
    func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<60 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await condition()
    }
}

@Suite("Work42WebView link policy", .serialized)
@MainActor
struct LinkPolicyTests {

    @Test("a click on a link offers it to the host with its page and source, then replays when kept in place")
    func clickIsRoutedAndReplayed() async {
        let rig = Rig()
        await rig.load("""
        <a id="a" href="https://x.test/a">go</a>
        <script>
          window.pageSawClick = false;
          document.getElementById('a').addEventListener('click', function(e) { window.pageSawClick = true; e.preventDefault(); });
        </script>
        """)
        await rig.run("document.getElementById('a').click()")
        #expect(await rig.eventually { rig.requests.count == 1 })
        let request = rig.requests.first
        #expect(request?.kind == .click)
        #expect(request?.url.absoluteString == "https://x.test/a")
        #expect(request?.source == "issue")
        #expect(request?.pageURL?.absoluteString.hasPrefix("https://x.test/") == true)
        // kept in place -> the click is replayed, so the page's own handler finally runs
        #expect(await rig.eventually { (await rig.run("window.pageSawClick") as? Bool) == true })
    }

    @Test("a taken click is not replayed")
    func takenClickIsNotReplayed() async {
        let rig = Rig()
        rig.outcome = .taken
        await rig.load("""
        <a id="a" href="https://x.test/a">go</a>
        <script>window.pageSawClick = false; document.getElementById('a').addEventListener('click', function(e) { window.pageSawClick = true; e.preventDefault(); });</script>
        """)
        await rig.run("document.getElementById('a').click()")
        #expect(await rig.eventually { rig.requests.count == 1 })
        try? await Task.sleep(for: .milliseconds(300))
        #expect((await rig.run("window.pageSawClick") as? Bool) == false)
    }

    @Test("a click with an option key held routes like a plain click")
    func modifierClickRoutes() async {
        let rig = Rig()
        await rig.load(#"<a id="a" href="https://x.test/a">go</a>"#)
        await rig.run("document.getElementById('a').dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true, altKey: true}))")
        #expect(await rig.eventually { rig.requests.count == 1 })
        #expect(rig.requests.first?.kind == .click)
    }

    @Test("mailto links and same-document fragments are not routed")
    func nonRoutableLinks() async {
        let rig = Rig()
        await rig.load("""
        <a id="m" href="mailto:a@x.test">mail</a>
        <a id="f" href="#section">frag</a>
        <script>
          document.getElementById('m').addEventListener('click', function(e) { e.preventDefault(); });
          window.fragClicks = 0;
          document.getElementById('f').addEventListener('click', function() { window.fragClicks++; });
        </script>
        """)
        await rig.run("document.getElementById('m').click(); document.getElementById('f').click();")
        #expect(await rig.eventually { (await rig.run("window.fragClicks") as? Int) == 1 })
        #expect(rig.requests.isEmpty)
    }

    @Test("pushState to a new path right after a click is offered, and reverted when the host takes it")
    func routeChangeTaken() async {
        let rig = Rig()
        rig.outcome = .taken
        await rig.load("""
        <div id="d">row</div>
        <script>document.getElementById('d').addEventListener('click', function() { history.pushState({}, '', '/other/spec'); });</script>
        """, base: "https://x.test/issues/1")
        await rig.run("document.getElementById('d').click()")
        #expect(await rig.eventually { rig.requests.count == 1 })
        #expect(rig.requests.first?.kind == .routeChange)
        #expect(rig.requests.first?.url.path == "/other/spec")
        #expect(await rig.eventually { (await rig.run("location.pathname") as? String) == "/issues/1" })
    }

    @Test("a route change the host leaves in place stays")
    func routeChangeKept() async {
        let rig = Rig()
        rig.outcome = .keptInPlace
        await rig.load("""
        <div id="d">row</div>
        <script>document.getElementById('d').addEventListener('click', function() { history.pushState({}, '', '/other'); });</script>
        """, base: "https://x.test/issues/1")
        await rig.run("document.getElementById('d').click()")
        #expect(await rig.eventually { rig.requests.count == 1 })
        try? await Task.sleep(for: .milliseconds(300))
        #expect((await rig.run("location.pathname") as? String) == "/other")
    }

    @Test("pushState with no gesture, and a query-only change after a click, offer nothing")
    func routeChangeNeedsAGestureAndAPath() async {
        let rig = Rig()
        await rig.load("""
        <div id="d">row</div>
        <script>document.getElementById('d').addEventListener('click', function() { history.pushState({}, '', '?tab=2'); });</script>
        """, base: "https://x.test/issues/1")
        await rig.run("history.pushState({}, '', '/no-gesture')")
        await rig.run("document.getElementById('d').click()")
        try? await Task.sleep(for: .milliseconds(400))
        #expect(rig.requests.isEmpty)
    }

    @Test("a popup owned elsewhere is routed and not created")
    func ownedPopupIsRouted() async {
        let rig = Rig()
        rig.owned = ["owned.test"]
        await rig.load("<div>page</div>")
        await rig.run("window.open('https://owned.test/x')")
        #expect(await rig.eventually { rig.requests.count == 1 })
        #expect(rig.requests.first?.kind == .popup)
        #expect(rig.requests.first?.url.host == "owned.test")
    }

    @Test("an unowned popup is a real attached window with window.opener")
    func unownedPopupKeepsItsOpener() async {
        let rig = Rig()
        await rig.load("<div>page</div>")
        let before = NSApp.windows.count
        await rig.run("window.popup = window.open('about:blank'); window.popup.document.title = 'Sign in';")
        #expect(await rig.eventually { NSApp.windows.count > before })
        #expect(rig.requests.isEmpty)
        #expect((await rig.run("window.popup && !window.popup.closed") as? Bool) == true)
        #expect((await rig.run("window.popup.opener === window") as? Bool) == true)
        await rig.run("window.popup.close()")
    }

    @Test("an offscreen web view has no link handler and a plain type")
    func offscreenIsPlain() async {
        let view = Work42WebView.make(role: .offscreen)
        #expect(!(view is PolicyWebView))
        #expect(view.configuration.userContentController.userScripts.isEmpty)
    }

    @Test("the caller's delegates still receive what the policy does not handle")
    func delegatesAreForwarded() async {
        let rig = Rig()
        await rig.load("<div>page</div>")   // Loader.didFinish is only reachable through the proxy
        #expect(rig.webView.navigationDelegate != nil)
        #expect(rig.webView.url != nil)
    }
}

// MARK: - A released caller (WOR-70)

/// A caller that implements every delegate method the proxy fronts and records what reached it.
@MainActor
private final class FullCaller: NSObject, WKNavigationDelegate, WKUIDelegate {
    var calls: [String] = []
    var challengeDisposition: URLSession.AuthChallengeDisposition = .cancelAuthenticationChallenge
    var alertAnswer = true
    var promptAnswer: String? = "from caller"

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { calls.append("didStart") }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { calls.append("didCommit") }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { calls.append("didFinish") }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { calls.append("didFail") }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        calls.append("didFailProvisional")
    }
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        calls.append("redirect")
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { calls.append("terminate") }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        calls.append("challenge")
        completionHandler(challengeDisposition, nil)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        calls.append("confirm")
        completionHandler(alertAnswer)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        calls.append("prompt")
        completionHandler(promptAnswer)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable () -> Void
    ) {
        calls.append("alert")
        completionHandler()
    }
}

private final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

@Suite("LinkPolicyProxy with a released caller", .serialized)
@MainActor
struct LinkPolicyReleasedCallerTests {

    private func makeChallenge() -> URLAuthenticationChallenge {
        let space = URLProtectionSpace(
            host: "auth.test", port: 443, protocol: "https", realm: "r", authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        return URLAuthenticationChallenge(
            protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
            failureResponse: nil, error: nil, sender: ChallengeSender()
        )
    }

    /// A web view whose caller has been assigned and then released.
    private func webViewWithReleasedCaller() -> PolicyWebView {
        let view = Work42WebView.make(role: .interactive(source: "issue")) as! PolicyWebView
        weak var weakCaller: FullCaller?
        do {
            let caller = FullCaller()
            weakCaller = caller
            view.navigationDelegate = caller
            view.uiDelegate = caller
        }
        precondition(weakCaller == nil, "the caller must be released for this test to mean anything")
        return view
    }

    @Test("an authentication challenge falls back to default handling")
    func challengeFallsBack() async {
        let view = webViewWithReleasedCaller()
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<URLSession.AuthChallengeDisposition, Never>) in
            view.policy.webView(view, didReceive: makeChallenge()) { disposition, _ in continuation.resume(returning: disposition) }
        }
        #expect(result == .performDefaultHandling)
    }

    @Test("every navigation notification is a no-op")
    func notificationsAreNoOps() {
        let view = webViewWithReleasedCaller()
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        view.policy.webView(view, didStartProvisionalNavigation: nil)
        view.policy.webView(view, didCommit: nil)
        view.policy.webView(view, didFinish: nil)
        view.policy.webView(view, didFail: nil, withError: error)
        view.policy.webView(view, didFailProvisionalNavigation: nil, withError: error)
        view.policy.webView(view, didReceiveServerRedirectForProvisionalNavigation: nil)
        view.policy.webViewWebContentProcessDidTerminate(view)
    }

    @Test("JavaScript alert, confirm and prompt complete with the cancel answers")
    func panelsCancel() async {
        let view = webViewWithReleasedCaller()
        view.loadHTMLString("<div>page</div>", baseURL: URL(string: "https://x.test/start"))
        let alerted = await view.evaluateAsyncResult("alert('hi'); return 'alerted'")
        let confirmed = await view.evaluateAsyncResult("return String(confirm('sure'))")
        let prompted = await view.evaluateAsyncResult("return String(prompt('name', 'x'))")
        #expect(alerted == "alerted")
        #expect(confirmed == "false")
        #expect(prompted == "null")
    }

    @Test("every selector the proxy promised while the caller was alive is still answered after it is released")
    func promisesOutliveTheCaller() {
        // WebKit caches `respondsToSelector:` when the delegate is assigned. The crash was a cached "yes" that a
        // released caller could no longer honour, so a promise made with a live caller must hold without it.
        let selectors = [
            "webView:didStartProvisionalNavigation:",
            "webView:didCommitNavigation:",
            "webView:didFinishNavigation:",
            "webView:didFailNavigation:withError:",
            "webView:didFailProvisionalNavigation:withError:",
            "webView:didReceiveServerRedirectForProvisionalNavigation:",
            "webViewWebContentProcessDidTerminate:",
            "webView:didReceiveAuthenticationChallenge:completionHandler:",
            "webView:decidePolicyForNavigationResponse:decisionHandler:",
            "webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:",
            "webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:",
            "webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:",
            "webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:",
        ].map { NSSelectorFromString($0) }

        let view = Work42WebView.make(role: .interactive(source: "issue")) as! PolicyWebView
        weak var weakCaller: FullCaller?
        var promised: [Selector] = []
        do {
            let caller = FullCaller()
            weakCaller = caller
            view.navigationDelegate = caller
            view.uiDelegate = caller
            promised = selectors.filter { view.policy.responds(to: $0) }
        }
        #expect(weakCaller == nil)
        #expect(!promised.isEmpty)
        for selector in promised {
            #expect(view.policy.responds(to: selector), "\(selector) was promised, then dropped with its caller")
        }
    }

    @Test("a live caller still receives every message with its own answer")
    func liveCallerIsForwarded() async {
        let view = Work42WebView.make(role: .interactive(source: "issue")) as! PolicyWebView
        let caller = FullCaller()
        view.navigationDelegate = caller
        view.uiDelegate = caller

        let disposition = await withCheckedContinuation { (continuation: CheckedContinuation<URLSession.AuthChallengeDisposition, Never>) in
            view.policy.webView(view, didReceive: makeChallenge()) { disposition, _ in continuation.resume(returning: disposition) }
        }
        #expect(disposition == .cancelAuthenticationChallenge)

        view.policy.webView(view, didStartProvisionalNavigation: nil)
        view.policy.webView(view, didFinish: nil)
        view.policy.webViewWebContentProcessDidTerminate(view)
        #expect(caller.calls == ["challenge", "didStart", "didFinish", "terminate"])
    }
}

private extension WKWebView {
    /// Runs `body` as an async JavaScript function once the page has loaded and returns its string result.
    @MainActor
    func evaluateAsyncResult(_ body: String) async -> String? {
        for _ in 0..<100 where isLoading || url == nil { try? await Task.sleep(for: .milliseconds(50)) }
        return try? await callAsyncJavaScript(body, contentWorld: .page) as? String
    }
}
