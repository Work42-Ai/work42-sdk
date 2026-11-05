// WebSectionSchemeTests.swift — which navigations name an app instead of a page (WOR-601).
//
// Linear's page hands a document to its desktop app with a `linear://` link and retries with `?noRedirect=1`; on iOS a web view
// fails each attempt as "unsupported URL". The web layer cancels app-launch schemes there, so the tab keeps its page.

import Foundation
import Testing

@testable import Work42UI

@Suite("App-launch schemes")
struct WebSectionSchemeTests {

    @Test("a page's own schemes are not app launches")
    func webSchemes() {
        for address in [
            "https://linear.app/work42/document/x", "http://127.0.0.1:3000/", "about:blank", "blob:https://x.test/1",
            "data:text/html,hi", "file:///tmp/a.html", "javascript:void(0)", "work42://open", "w42-artifact://s/a/",
            "HTTPS://LINEAR.APP/",
        ] {
            #expect(!WebSectionView.Coordinator.isAppLaunchScheme(URL(string: address)!), "\(address)")
        }
    }

    @Test("a custom app scheme is an app launch, whatever its case")
    func appSchemes() {
        for address in ["linear://work42/document/x", "slack://open", "zoommtg://zoom.us/join", "mailto:a@b.test", "tel:123", "LINEAR://x"] {
            #expect(WebSectionView.Coordinator.isAppLaunchScheme(URL(string: address)!), "\(address)")
        }
    }

    @Test("an address with no scheme is not one")
    func noScheme() {
        #expect(!WebSectionView.Coordinator.isAppLaunchScheme(URL(string: "/relative/path")!))
    }
}
