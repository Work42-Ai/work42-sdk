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
    /// Widget ids that own a link clicked in them (the right-click item is offered for these).
    var ownedHere: Set<String> = []
    var widgetTitle: String? = "Issue"

    init(source: String? = "issue") {
        webView = Work42WebView.make(role: .interactive(source: source)) as! PolicyWebView
        webView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        webView.navigationDelegate = loader
        Rig.installed = ObjectIdentifier(self)
        WebLinkHost.handler = WebLinkHandler(
            open: { [unowned self] request, completion in
                self.requests.append(request)
                completion(self.outcome)
            },
            ownsElsewhere: { [unowned self] url, _ in self.owned.contains(url.host ?? "") },
            ownsHere: { [unowned self] url, source in
                guard let source else { return false }
                return self.ownedHere.contains(source) && url.host == "x.test"
            },
            title: { [unowned self] _ in self.widgetTitle }
        )
    }

    /// The rig whose handler is installed. A rig that is released late must not clear a newer rig's handler.
    nonisolated(unsafe) private static var installed: ObjectIdentifier?

    deinit {
        let me = ObjectIdentifier(self)
        MainActor.assumeIsolated {
            guard Rig.installed == me else { return }
            Rig.installed = nil
            WebLinkHost.handler = nil
        }
    }

    func load(_ html: String, base: String = "https://x.test/start") async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            loader.continuation = continuation
            webView.loadHTMLString(html, baseURL: URL(string: base))
        }
    }

    func loadFile(_ url: URL) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            loader.continuation = continuation
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
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

/// Stands in for a tab host: adopts every popup it is handed and counts the ones the page closes.
@MainActor
private final class PopupSink {
    var popups: [PolicyWebView] = []
    var closed = 0

    func adopt(_ popup: PolicyWebView) -> Bool {
        popups.append(popup)
        popup.onClose = { [unowned self] in closed += 1 }
        return true
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

    @Test("history moves (Back/Forward buttons and swipes) are never offered to the host as links")
    func historyBypassesRouting() async throws {
        let rig = Rig()
        rig.owned = [""]   // even a URL another widget owns must not be rerouted by a history move
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("w42-link-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var pages: [URL] = []
        for name in ["a.html", "b.html", "c.html"] {
            let url = directory.appendingPathComponent(name)
            try Data("<html><body>\(name)</body></html>".utf8).write(to: url)
            pages.append(url)
            await rig.loadFile(url)
        }
        #expect(rig.webView.canGoBack)

        // Each history move settles (the page is committed and idle) before the next one starts.
        func settle() async {
            _ = await rig.eventually { !rig.webView.isLoading }
            try? await Task.sleep(for: .milliseconds(250))
        }
        rig.webView.goBack()
        #expect(await rig.eventually { rig.webView.url?.lastPathComponent == "b.html" })
        await settle()
        rig.webView.goBack()
        #expect(await rig.eventually { rig.webView.url?.lastPathComponent == "a.html" })
        await settle()
        rig.webView.goForward()
        #expect(await rig.eventually { rig.webView.url?.lastPathComponent == "b.html" })
        await settle()
        await rig.run("history.forward()")
        #expect(await rig.eventually { rig.webView.url?.lastPathComponent == "c.html" })

        try? await Task.sleep(for: .milliseconds(300))
        #expect(rig.requests.isEmpty)
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

    @Test("an unowned popup is handed to popupHandler and keeps window.opener; no window is created")
    func unownedPopupKeepsItsOpener() async {
        let rig = Rig()
        let sink = PopupSink()
        rig.webView.popupHandler = sink.adopt
        await rig.load("<div>page</div>")
        let before = NSApp.windows.count
        await rig.run("window.popup = window.open('about:blank'); 1")
        #expect(await rig.eventually { sink.popups.count == 1 })
        #expect(NSApp.windows.count == before)
        #expect(rig.requests.isEmpty)
        #expect((await rig.run("window.popup && !window.popup.closed") as? Bool) == true)
        #expect((await rig.run("window.popup.opener === window") as? Bool) == true)
        #expect(sink.popups.first?.linkSource == "issue")
        await rig.run("window.popup.close()")
        #expect(await rig.eventually { sink.closed == 1 })
    }

    @Test("with no popupHandler an http popup is offered to the host as a popup and not created")
    func httpPopupWithoutHostIsOffered() async {
        let rig = Rig()
        await rig.load("<div>page</div>")
        let before = NSApp.windows.count
        await rig.run("window.popup = window.open('https://other.test/p'); 1")
        #expect(await rig.eventually { rig.requests.count == 1 })
        #expect(rig.requests.first?.kind == .popup)
        #expect(rig.requests.first?.url.absoluteString == "https://other.test/p")
        #expect((await rig.run("window.popup === null") as? Bool) == true)
        #expect(NSApp.windows.count == before)
    }

    @Test("with no popupHandler a blank popup is refused")
    func blankPopupWithoutHostIsRefused() async {
        let rig = Rig()
        await rig.load("<div>page</div>")
        let before = NSApp.windows.count
        await rig.run("window.popup = window.open('about:blank'); 1")
        try? await Task.sleep(for: .milliseconds(400))
        #expect((await rig.run("window.popup === null") as? Bool) == true)
        #expect(rig.requests.isEmpty)
        #expect(NSApp.windows.count == before)
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

    // MARK: Right-click: Open in New Tab in <widget> (WOR-147)

    private static let openInNewWindow = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLinkInNewWindow")

    /// A menu like the one WebKit builds for a link: Open Link, Open Link in New Window, Copy Link.
    private func linkMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Link", action: nil, keyEquivalent: ""))
        let newWindow = NSMenuItem(title: "Open Link in New Window", action: nil, keyEquivalent: "")
        newWindow.identifier = Self.openInNewWindow
        menu.addItem(newWindow)
        menu.addItem(NSMenuItem(title: "Copy Link", action: nil, keyEquivalent: ""))
        return menu
    }

    private func rightClick(_ rig: Rig, _ id: String) async {
        await rig.run("document.getElementById('\(id)').dispatchEvent(new MouseEvent('contextmenu', {bubbles: true, cancelable: true}))")
    }

    @Test("right-clicking an owned link retitles WebKit's new-window item and puts it first")
    func menuGetsOpenInNewTab() async {
        let rig = Rig()
        rig.ownedHere = ["issue"]
        await rig.load(#"<a id="a" href="https://x.test/a">go</a>"#)
        await rightClick(rig, "a")
        #expect(await rig.eventually { rig.webView.policy.lastContextLink?.absoluteString == "https://x.test/a" })

        let menu = linkMenu()
        rig.webView.policy.customizeMenu(menu, source: rig.webView.linkSource)

        #expect(menu.items.first?.title == "Open in New Tab in Issue")
        #expect(menu.items.first?.identifier == Self.openInNewWindow)
        #expect(menu.items[1].isSeparatorItem)
        #expect(menu.items.dropFirst(2).map(\.title).contains("Open Link"))
        #expect(menu.items.filter { $0.identifier == Self.openInNewWindow }.count == 1)
    }

    @Test("the menu is left alone when the link is not owned here, has no title, or was not right-clicked")
    func menuUnchanged() async {
        let rig = Rig()
        await rig.load(#"<a id="a" href="https://x.test/a">go</a><p id="p">text</p><a id="o" href="https://other.test/o">o</a>"#)

        // Nothing right-clicked yet.
        var menu = linkMenu()
        rig.webView.policy.customizeMenu(menu, source: "issue")
        #expect(menu.items.map(\.title) == ["Open Link", "Open Link in New Window", "Copy Link"])

        // Right-clicked, but the widget does not own the link.
        await rightClick(rig, "a")
        #expect(await rig.eventually { rig.webView.policy.lastContextLink != nil })
        menu = linkMenu()
        rig.webView.policy.customizeMenu(menu, source: "issue")
        #expect(menu.items.map(\.title) == ["Open Link", "Open Link in New Window", "Copy Link"])

        // Owned, but the widget has no title.
        rig.ownedHere = ["issue"]
        rig.widgetTitle = nil
        menu = linkMenu()
        rig.webView.policy.customizeMenu(menu, source: "issue")
        #expect(menu.items.map(\.title) == ["Open Link", "Open Link in New Window", "Copy Link"])

        // Owned and titled, but the link is on another host (not owned), and a non-link clears it.
        rig.widgetTitle = "Issue"
        await rightClick(rig, "o")
        #expect(await rig.eventually { rig.webView.policy.lastContextLink?.host == "other.test" })
        menu = linkMenu()
        rig.webView.policy.customizeMenu(menu, source: "issue")
        #expect(menu.items.first?.title == "Open Link")
        await rightClick(rig, "p")
        #expect(await rig.eventually { rig.webView.policy.lastContextLink == nil })
    }

    @Test("choosing the item opens the link as a separate tab: offered as a popup, no popup window")
    func armedPopupIsRouted() async {
        let rig = Rig()
        rig.ownedHere = ["issue"]
        await rig.load(#"<a id="a" href="https://x.test/a">go</a>"#)
        await rightClick(rig, "a")
        #expect(await rig.eventually { rig.webView.policy.lastContextLink != nil })
        rig.webView.policy.customizeMenu(linkMenu(), source: "issue")
        #expect(rig.webView.policy.openSeparatelyLink?.absoluteString == "https://x.test/a")

        let before = NSApp.windows.count
        await rig.run("window.open('https://x.test/a')")
        #expect(await rig.eventually { rig.requests.count == 1 })
        #expect(rig.requests.first?.kind == .popup)
        #expect(rig.requests.first?.url.absoluteString == "https://x.test/a")
        #expect(NSApp.windows.count == before)
        #expect(rig.webView.policy.openSeparatelyLink == nil)   // one-shot
    }

    @Test("an armed item does not swallow an unrelated popup")
    func armedPopupOnlyForThatLink() async {
        let rig = Rig()
        let sink = PopupSink()
        rig.webView.popupHandler = sink.adopt
        rig.ownedHere = ["issue"]
        await rig.load(#"<a id="a" href="https://x.test/a">go</a>"#)
        await rightClick(rig, "a")
        #expect(await rig.eventually { rig.webView.policy.lastContextLink != nil })
        rig.webView.policy.customizeMenu(linkMenu(), source: "issue")

        await rig.run("window.popup = window.open('about:blank'); 1")   // a sign-in popup, not the chosen link
        #expect(await rig.eventually { sink.popups.count == 1 })
        #expect(rig.requests.isEmpty)
        await rig.run("window.popup.close()")
    }

    @Test("willOpenMenu applies the same customization to the real view")
    func willOpenMenuCustomizes() async {
        let rig = Rig()
        rig.ownedHere = ["issue"]
        await rig.load(#"<a id="a" href="https://x.test/a">go</a>"#)
        await rightClick(rig, "a")
        #expect(await rig.eventually { rig.webView.policy.lastContextLink != nil })
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let menu = linkMenu()
        rig.webView.willOpenMenu(menu, with: event)
        #expect(menu.items.first?.title == "Open in New Tab in Issue")
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
