// AccountScopedStoresTests.swift — a device that keeps one account's web data apart from another's (WOR-753).
//
// The pieces: a workspace that moves every page's data store into a scope (`@<scope>`), a sign-in import that writes only into the
// stores it is told, a reload that follows the same list, and a tab list kept in a suite of the caller's choosing. Each one must also
// behave exactly as before when it is not asked for (the Mac app and plugins do not ask).

import Foundation
import Testing
import WebKit

@testable import Work42UI

/// A live-view store that records every spec it is asked for, and builds the view from an ephemeral copy so nothing touches disk.
@MainActor
private final class RecordingLiveStore: WebSectionLiveStore {
    private(set) var specs: [WebSectionSpec] = []
    private var lives: [String: WebSectionLiveView] = [:]

    func liveView(for spec: WebSectionSpec, cacheKey: String) -> WebSectionLiveView {
        specs.append(spec)
        if let existing = lives[cacheKey] { return existing }
        var inert = spec
        inert.ephemeral = true
        let made = WebSectionView.makeLiveView(spec: inert)
        lives[cacheKey] = made
        return made
    }

    func adopt(_ webView: WKWebView, spec: WebSectionSpec, cacheKey: String) -> WebSectionLiveView {
        specs.append(spec)
        var inert = spec
        inert.ephemeral = true
        let made = WebSectionView.makeLiveView(adopting: webView, spec: inert)
        lives[cacheKey] = made
        return made
    }

    func release(cacheKey: String) {
        lives[cacheKey]?.teardown()
        lives[cacheKey] = nil
    }
}

/// Collects the `userInfo` list of a cookie-import notification. The observer runs on the posting thread, so the box is only
/// touched there.
private final class ImportNotes: @unchecked Sendable {
    var posted = 0
    var keys: [String]?
}

@MainActor
@Suite("Account-scoped web stores")
struct AccountScopedStoresTests {

    private static let githubPR = "https://github.com/work42-ai/work42/pull/1"
    private static let jiraIssue = "https://acme.atlassian.net/browse/WOR-1"
    private static let plainPage = "https://example.com/page"

    /// The spec the workspace asks its store for when it shows `url`.
    private func spec(for url: String, genericKey: String? = nil, scope: String? = nil) throws -> WebSectionSpec {
        let store = RecordingLiveStore()
        let workspace = BrowserWorkspace(
            model: BrowserWidgetModel(initialURL: URL(string: url)), store: store, genericDataStoreKey: genericKey,
            dataStoreScope: scope)
        _ = workspace.activeLive
        return try #require(store.specs.last, "the workspace never asked its store for a page")
    }

    // MARK: Key naming

    @Test("a key inside a scope is `<key>@<scope>`, and two scopes never share one")
    func scopedKeys() {
        #expect(BrowserWorkspace.scoped("browser", scope: "u1") == "browser@u1")
        #expect(BrowserWorkspace.scoped("browser", scope: "u1") != BrowserWorkspace.scoped("browser", scope: "u2"))
        #expect(BrowserWorkspace.scoped("browser", scope: "u1") != BrowserWorkspace.scoped("github", scope: "u1"))
    }

    // MARK: Workspace

    @Test("with no scope every page keeps the key it has today")
    func unscopedKeysAreUnchanged() throws {
        #expect(try spec(for: Self.plainPage).dataStoreKey == WebAppCatalog.browserDataStoreKey)
        #expect(try spec(for: Self.plainPage, genericKey: "browser-mac1").dataStoreKey == "browser-mac1")
        #expect(try spec(for: Self.githubPR).dataStoreKey == WebAppCatalog.browserDataStoreKey)
        #expect(try spec(for: Self.jiraIssue).dataStoreKey == WebAppCatalog.browserDataStoreKey)
    }

    @Test("with a scope a plain page, a GitHub PR and a Jira issue all land in that scope's store")
    func scopedKeysForEveryKindOfPage() throws {
        let plain = try spec(for: Self.plainPage, scope: "u1")
        let pr = try spec(for: Self.githubPR, scope: "u1")
        let jira = try spec(for: Self.jiraIssue, scope: "u1")
        #expect(plain.dataStoreKey == "browser@u1")
        #expect(pr.dataStoreKey == "browser@u1")
        #expect(jira.dataStoreKey == "browser@u1")
        #expect(pr.selector == WebAppCatalog.githubPR(url: pr.url).selector, "scoping must not change the preset itself")
    }

    @Test("a generic key given to the workspace is scoped too, keeping its own name before the scope")
    func genericKeyIsScoped() throws {
        #expect(try spec(for: Self.plainPage, genericKey: "browser-mac1", scope: "u1").dataStoreKey == "browser-mac1@u1")
    }

    @Test("two accounts never end up with the same store for the same page")
    func twoScopesTwoStores() throws {
        for url in [Self.plainPage, Self.githubPR, Self.jiraIssue] {
            #expect(try spec(for: url, scope: "u1").dataStoreKey != spec(for: url, scope: "u2").dataStoreKey)
        }
    }

    // MARK: Reload follows the list

    @Test("an import aimed at stores reaches only the views in them; an import with no list reaches every persistent view")
    func importReach() {
        #expect(WebSectionLiveView.importReaches(viewKey: "browser@u1", storeKeys: ["browser@u1", "github@u1"]))
        #expect(!WebSectionLiveView.importReaches(viewKey: "browser@u2", storeKeys: ["browser@u1"]))
        #expect(!WebSectionLiveView.importReaches(viewKey: nil, storeKeys: ["browser@u1"]), "an ephemeral view holds no imported cookie")
        #expect(WebSectionLiveView.importReaches(viewKey: "browser@u2", storeKeys: nil))
        #expect(WebSectionLiveView.importReaches(viewKey: nil, storeKeys: nil))
    }

    @Test("a live view reports the key of its store, and an ephemeral one reports none")
    func liveViewKnowsItsStore() {
        let persistent = WebSectionView.makeLiveView(
            spec: WebSectionSpec(url: URL(string: Self.plainPage)!, selector: "", dataStoreKey: "wor753.view.\(UUID())"))
        #expect(persistent.dataStoreKey?.hasPrefix("wor753.view.") == true)
        persistent.teardown()
        let ephemeral = WebSectionView.makeLiveView(
            spec: WebSectionSpec(url: URL(string: Self.plainPage)!, selector: "", dataStoreKey: "x", ephemeral: true))
        #expect(ephemeral.dataStoreKey == nil)
        ephemeral.teardown()
    }

    // MARK: Cookie import

    @Test("an import into named stores writes those stores and no other, and says which")
    func installOnlyIntoNamedStores() async throws {
        let a = "wor753.a.\(UUID())", b = "wor753.b.\(UUID())", other = "wor753.other.\(UUID())"
        // A real domain: WebKit's store refuses a cookie for a reserved one such as `example.test`.
        let cookie = SignInCookie(
            name: "wor753", value: "1", domain: "example.com", path: "/",
            expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970)
        let notes = ImportNotes()
        let observer = NotificationCenter.default.addObserver(forName: .work42BrowserCookiesImported, object: nil, queue: nil) { note in
            notes.posted += 1
            notes.keys = note.userInfo?[Notification.work42DataStoreKeysUserInfoKey] as? [String]
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let written = await SignInCookieStore.install(SignInCookieExport(cookies: [cookie]), onlyInto: [a, b])

        #expect(written == 1)
        func cookies(in key: String) async -> [HTTPCookie] {
            await WKWebsiteDataStore(forIdentifier: WebSectionView.stableIdentifier(forKey: key)).httpCookieStore.allCookies()
        }
        #expect(await cookies(in: a).contains { $0.name == "wor753" })
        #expect(await cookies(in: b).contains { $0.name == "wor753" })
        #expect(await cookies(in: other).isEmpty, "a store that was not named must stay as it was")
        #expect(notes.posted == 1 && notes.keys == [a, b])

        for key in [a, b, other] {
            try? await WKWebsiteDataStore.remove(forIdentifier: WebSectionView.stableIdentifier(forKey: key))
        }
    }

    @Test("an import with nothing to write, or nowhere to write it, does nothing and posts nothing")
    func installOnlyIntoNothing() async {
        let notes = ImportNotes()
        let observer = NotificationCenter.default.addObserver(forName: .work42BrowserCookiesImported, object: nil, queue: nil) { _ in
            notes.posted += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let cookie = SignInCookie(name: "n", value: "v", domain: "example.test", path: "/")

        #expect(await SignInCookieStore.install(SignInCookieExport(cookies: []), onlyInto: ["wor753.never"]) == 0)
        #expect(await SignInCookieStore.install(SignInCookieExport(cookies: [cookie]), onlyInto: []) == 0)
        #expect(notes.posted == 0)
    }

    // MARK: Tabs

    @Test("a tab list kept in a suite stays in it, comes back from it, and leaves the app's defaults alone")
    func tabsLiveInTheSuiteGiven() {
        let suiteName = "wor753.tabs.\(UUID())"
        let otherName = "wor753.tabs.other.\(UUID())"
        let suite = UserDefaults(suiteName: suiteName)!
        let other = UserDefaults(suiteName: otherName)!
        defer {
            suite.removePersistentDomain(forName: suiteName)
            other.removePersistentDomain(forName: otherName)
        }
        let key = "ipad-browser.wor753-\(UUID())"

        let model = BrowserWidgetModel(persistenceKey: key, defaults: suite)
        let id = model.openTab(url: URL(string: Self.plainPage), title: "Page")

        #expect(UserDefaults.standard.data(forKey: "work42.browserTabs.\(key)") == nil, "the standard defaults must not be written")
        #expect(BrowserWidgetModel(persistenceKey: key, defaults: suite).tabs.map(\.id) == [id])
        #expect(BrowserWidgetModel(persistenceKey: key, defaults: other).tabs.isEmpty, "another suite must not see these tabs")
    }

    @Test("with no suite given the tab list is still kept in the standard defaults")
    func tabsDefaultToStandard() {
        let key = "wor753-default-\(UUID())"
        defer { UserDefaults.standard.removeObject(forKey: "work42.browserTabs.\(key)") }
        let tab = BrowserTab(url: URL(string: Self.plainPage), title: "Page")

        BrowserTabsStore.save(tabs: [tab], activeTabId: tab.id, forKey: key)

        #expect(UserDefaults.standard.data(forKey: "work42.browserTabs.\(key)") != nil)
        #expect(BrowserTabsStore.load(forKey: key)?.tabs == [tab])
    }
}
