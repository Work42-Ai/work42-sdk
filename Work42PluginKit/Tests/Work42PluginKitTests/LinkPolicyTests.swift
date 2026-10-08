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
