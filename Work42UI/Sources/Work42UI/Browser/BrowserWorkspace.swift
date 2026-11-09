// BrowserWorkspace.swift — the tab and live-view logic of the Browser widget, once, for every platform (WOR-599).
//
// `BrowserWidgetModel` holds the tabs, the address, back/forward, find and zoom; `WebSectionLiveView` is a page. What joins
// them is this: which live view a tab shows, how a Jira or GitHub PR address gets its preset and its own slot, how a tab's
// first address is pinned so its view is never rebuilt when the person navigates, how a window a page opens becomes a tab, and
// what closing a tab releases. The Mac's `BrowserWidgetView` and the iPad's browser both compose it, each over its own store
// of live views (`WebSectionLiveStore`), so a fix here is a fix on both.

import Observation
import SwiftUI
import WebKit

/// Where a browser keeps its live views: one per cache slot, alive until released. The Mac's `LiveWidgetBackends` is one; a
/// device with no such cache uses `DefaultWebSectionLiveStore`.
@MainActor
public protocol WebSectionLiveStore: AnyObject {
    /// The view in `cacheKey`, built from `spec` on first use and rebuilt when the spec changes (an adopted popup keeps its view).
    func liveView(for spec: WebSectionSpec, cacheKey: String) -> WebSectionLiveView
    /// Stores a popup web view WebKit created as the live view at `cacheKey`, loading nothing.
    func adopt(_ webView: WKWebView, spec: WebSectionSpec, cacheKey: String) -> WebSectionLiveView
    /// Tears down and forgets the view in `cacheKey`.
    func release(cacheKey: String)
}

@MainActor
public final class DefaultWebSectionLiveStore: WebSectionLiveStore {
    private var lives: [String: WebSectionLiveView] = [:]
    private var specs: [String: WebSectionSpec] = [:]
    private var adopted: Set<String> = []

    public init() {}

    public func liveView(for spec: WebSectionSpec, cacheKey: String) -> WebSectionLiveView {
        if let existing = lives[cacheKey], specs[cacheKey] == spec || adopted.contains(cacheKey) { return existing }
        lives[cacheKey]?.teardown()
        let made = WebSectionView.makeLiveView(spec: spec)
        lives[cacheKey] = made
        specs[cacheKey] = spec
        return made
    }

    public func adopt(_ webView: WKWebView, spec: WebSectionSpec, cacheKey: String) -> WebSectionLiveView {
        lives[cacheKey]?.teardown()
        let made = WebSectionView.makeLiveView(adopting: webView, spec: spec)
        lives[cacheKey] = made
        specs[cacheKey] = spec
        adopted.insert(cacheKey)
        return made
    }

    public func release(cacheKey: String) {
        lives[cacheKey]?.teardown()
        lives[cacheKey] = nil
        specs[cacheKey] = nil
        adopted.remove(cacheKey)
    }
}

@MainActor
@Observable
public final class BrowserWorkspace {
    public let model: BrowserWidgetModel
    @ObservationIgnored private let store: any WebSectionLiveStore
    /// A data store key for plain pages, to keep a device's logins apart per Mac; nil is the shared `browser` store.
    @ObservationIgnored private let genericDataStoreKey: String?
    /// A CSS selector a custom widget isolates on its plain pages (a Jira or GitHub address keeps its own preset); nil or empty
    /// shows the whole page.
    @ObservationIgnored private let genericSelector: String?
    /// The URL each tab's web view was first built with. A tab that navigates keeps its view, so the pin does not move.
    public private(set) var pins: [UUID: URL] = [:]

    /// Joins `model` to `store`: wires the new-tab and close-tab callbacks, makes sure there is a tab to type into, and pins
    /// the addresses the tabs already have.
    public init(
        model: BrowserWidgetModel, store: any WebSectionLiveStore, genericDataStoreKey: String? = nil, genericSelector: String? = nil
    ) {
        self.model = model
        self.store = store
        self.genericDataStoreKey = genericDataStoreKey
        self.genericSelector = genericSelector
        model.onNewTab = { [weak model] in _ = model?.openTab(url: nil, title: "New Tab", icon: "globe") }
        model.onTabClosed = { [weak self] id in self?.release(tab: id) }
        model.showInTab = { [weak self] id, url in self?.show(url, inTab: id) }
        if model.tabs.isEmpty {
            _ = model.openTab(url: model.url, title: model.url?.host ?? "New Tab", icon: "globe")
        }
        syncPins()
    }

    public var activeTab: BrowserTab? {
        if let id = model.activeTabId, let tab = model.tabs.first(where: { $0.id == id }) { return tab }
        return model.tabs.first
    }

    /// The address a tab shows: its pin, else its own URL (a tab that already has one must not read as empty before the pin).
    public func shownURL(for tab: BrowserTab) -> URL? { pins[tab.id] ?? tab.url }

    /// The live view of the active tab, if it has a page.
    public var activeLive: WebSectionLiveView? {
        guard let tab = activeTab, let url = shownURL(for: tab) else { return nil }
        return live(for: tab, url: url)
    }

    /// Pins the first URL of any tab that has one, and drops the pins of closed tabs.
    public func syncPins() {
        var next = pins
        for tab in model.tabs where next[tab.id] == nil {
            if let url = tab.url { next[tab.id] = url }
        }
        let alive = Set(model.tabs.map(\.id))
        next = next.filter { alive.contains($0.key) }
        if next != pins { pins = next }
    }

    /// The live view for `tab` at `url`: a Jira or GitHub PR address gets its preset (and its own slot, sharing that app's
    /// login); anything else is a plain page in this tab's slot. Also keeps the tab's address and its popups in step.
    public func live(for tab: BrowserTab, url: URL) -> WebSectionLiveView {
        let intent = URLIntentResolver.classify(url)
        var spec = URLIntentResolver.spec(for: intent, url: url)
        let key: String
        switch intent {
        case .githubPR, .jira:
            key = URLIntentResolver.cacheKey(for: intent, url: url)
        case .generic:
            key = Self.cacheKey(of: tab.id)
            if let genericDataStoreKey { spec.dataStoreKey = genericDataStoreKey }
            if let genericSelector, !genericSelector.isEmpty { spec.selector = genericSelector }
        @unknown default:
            key = Self.cacheKey(of: tab.id)
            if let genericDataStoreKey { spec.dataStoreKey = genericDataStoreKey }
            if let genericSelector, !genericSelector.isEmpty { spec.selector = genericSelector }
        }
        let live = store.liveView(for: spec, cacheKey: key)
        // A page the person clicked to (not typed) is kept on the tab, so a restored tab reopens the real page.
        live.onURLChange = { [weak model] landed in
            guard let model, let current = model.tabs.first(where: { $0.id == tab.id }), current.url != landed else { return }
            // A popup tab opens as "New Tab" at about:blank: it takes its host once it lands.
            model.updateTab(tab.id, title: current.title == "New Tab" ? landed.host : nil, url: landed)
        }
        // A window the page opens becomes a tab next to this one (sign-in popups, target=_blank).
        live.popupHandler = { [weak self] popup in self?.adoptPopup(popup, openedBy: tab) ?? false }
        return live
    }

    /// The cache slot of a plain tab's page.
    public static func cacheKey(of tab: UUID) -> String { "browser:\(tab)" }

    /// Typing an address loads it in the active tab's own view; an empty tab builds its view from it.
    public func navigate(to url: URL) {
        guard let tab = activeTab else { return }
        if pins[tab.id] != nil { activeLive?.load(url) } else { syncPins() }
    }

    /// Another device moved tab `id` to `url`: its page (built if it had none yet) shows it.
    private func show(_ url: URL, inTab id: UUID) {
        guard let tab = model.tabs.first(where: { $0.id == id }), let shown = shownURL(for: tab) else { return }
        live(for: tab, url: pins[id] ?? shown).show(url)
    }

    /// A page in `opener` opened a window: it becomes the tab right after it, backed by the web view WebKit made, so
    /// `window.opener` keeps working. `window.close()` closes the tab and returns to the opener.
    private func adoptPopup(_ popup: PolicyWebView, openedBy opener: BrowserTab) -> Bool {
        let id = UUID()
        // The popup's own request decides what loads; the tab needs a URL to render at all, and the page's real address
        // replaces this one as soon as it lands.
        let blank = URL(string: "about:blank")!
        let spec = URLIntentResolver.spec(for: URLIntentResolver.classify(blank), url: blank)
        let live = store.adopt(popup, spec: spec, cacheKey: Self.cacheKey(of: id))
        live.onClose = { [weak self] in
            // WebKit is inside its own close callback: let it return before the view is torn down.
            DispatchQueue.main.async {
                guard let self else { return }
                self.model.closeTab(id)
                if self.model.tabs.contains(where: { $0.id == opener.id }) { self.model.selectTab(opener.id) }
            }
        }
        model.openTab(id: id, url: blank, title: "New Tab", icon: "globe", after: opener.id)
        return true
    }

    private func release(tab id: UUID) {
        store.release(cacheKey: Self.cacheKey(of: id))
        syncPins()
    }
}
