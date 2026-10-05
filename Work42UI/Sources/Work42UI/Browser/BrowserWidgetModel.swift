// BrowserWidgetModel.swift - Shared @Observable model for all embedded-browser
// widgets (Browser, Jira, GitHub PR, Canvas).
//
// Moved from Work42App/Browser/ to Work42UI
// (browser-widgets-not-extending-from-browser.1) so that BrowserSurface and
// other SDK-side code can compose the same model that the built-in widgets use,
// eliminating the parallel chrome/model implementation in Work42PluginKit.
//
// One instance per widget, stored in LiveWidgetBackends keyed by the widget's
// dataStoreKey. Centralises URL/navigation/tab state so that BrowserChromeRow
// (the shared header) binds against one type regardless of which specific
// widget is rendered.
//
// Multi-tab model (humble-harbor.6):
// The model now holds an ordered list of `BrowserTab` values. Widgets that
// never call `openTab` keep the single-implicit-tab behaviour —
// `showsTabBar` returns false when tabs.count <= 1, so the tab bar stays
// hidden and the chrome looks exactly as before. Subtask .7 (GitHub PR widget)
// calls these APIs to expose one tab per attached PR.
//
// Picker state (lanky-pine.5):
// `isPicking` / `openPicker()` / `closePicker()` are the canonical
// element-highlight affordance. The BrowserHighlightLayer (lanky-pine.6)
// observes `isPicking` to inject/remove the picker overlay from the WKWebView.
// BrowserChromeRow renders the viewfinder toggle button that calls these.
//
// Selector API (backward-compat stubs):
// The CSS selector-isolation UI has been removed (humble-harbor.6). The
// properties and methods below are kept as no-ops so call sites in
// SessionDetailPanel that have not yet been updated (subtask .7) continue to
// compile. Preset selectors flow through WebSectionSpec.selector untouched —
// they were never driven by these properties in the factory methods.

import Combine
import Foundation
import Observation
import WebKit
import SwiftUI

// MARK: - BrowserTab

/// A single tab in the multi-tab browser model.
/// Each tab has a stable identity (UUID), a URL, a display title, and an
/// optional SF Symbol icon name. Subtask .7 (GitHub PR widget) populates
/// these when building one tab per attached PR. `Codable` so the generic
/// Browser widget's tabs can be persisted to disk (`BrowserTabsStore`) and
/// restored across app launches — Jira/PR/Canvas never persist (their URL
/// is re-derived from task/PR/canvas-server state on every launch anyway).
public struct BrowserTab: Identifiable, Equatable, Hashable, Codable {
    public let id: UUID
    public var url: URL?
    public var title: String
    /// Optional SF Symbol name to display as the tab's favicon/icon.
    public var icon: String?

    public init(id: UUID = UUID(), url: URL? = nil, title: String, icon: String? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.icon = icon
    }
}

// MARK: - BrowserWidgetModel

/// Shared state for any embedded-browser widget (Browser, Jira, GitHub PR, Canvas).
/// One instance per widget, stored in LiveWidgetBackends keyed by the widget's dataStoreKey.
///
/// Dual-observation model (humble-harbor.10 fix):
/// The class is both `@Observable` (so `@Bindable` call sites and `@Observable`-tracked
/// closures still work) AND `ObservableObject` (so `@ObservedObject` call sites — in
/// particular `BrowserChromeRow`, which lives inside an `AnyView`-erased header and cannot
/// rely solely on `@Observable` tracking — reliably re-render when tab state changes).
/// `objectWillChange.send()` is called manually in every mutation that affects the tab bar.
@Observable
@MainActor
public final class BrowserWidgetModel: ObservableObject {

    // MARK: - Configuration (set at init, may be updated)

    /// Whether the user can type a new URL in the capsule. False for Canvas (loopback URL is fixed).
    public let canEditURL: Bool

    /// Kept for call-site compatibility. The preset selector UI has been
    /// removed (humble-harbor.6); this value is no longer applied via the
    /// toggle. Preset selectors for GitHub and Jira come from
    /// WebSectionSpec.selector in the WebAppCatalog factories.
    public let presetSelector: String

    // MARK: - URL state (single-URL, mirrors the active tab or the widget URL)

    public var url: URL?
    public var urlDraft: String = ""

    // MARK: - Navigation state (back/forward)

    public var canGoBack: Bool = false
    public var canGoForward: Bool = false

    // MARK: - Selector state (backward-compat stubs — UI removed in humble-harbor.6)
    //
    // These properties and methods are kept as no-ops so SessionDetailPanel
    // and other callers that have not yet been updated (subtask .7) continue to
    // compile. The selector-isolation button and BrowserSelectorRow are no
    // longer rendered by BrowserChromeRow.

    /// Always false — the selector UI has been removed. Kept for compat.
    public var isSelecting: Bool = false
    /// Unused — kept for compat.
    public var selectorDraft: String = ""
    /// Always empty — the selector UI has been removed. Kept for compat.
    public var activeSelector: String = ""

    // MARK: - Picker state (lanky-pine.5 / AC1)

    /// Whether element-picker mode is armed for this tile. Set by `openPicker()`
    /// / `closePicker()`. The BrowserHighlightLayer (lanky-pine.6) observes this
    /// to inject/remove the picker overlay from the WKWebView.
    public var isPicking: Bool = false

    // MARK: - Multi-tab model (humble-harbor.6)

    /// Ordered list of tabs. Empty when the widget uses the single-URL path
    /// (all existing Browser/Jira/Canvas/GitHub consumers that have not yet
    /// called `openTab` stay on the single-URL path and the tab bar remains hidden).
    public private(set) var tabs: [BrowserTab] = []

    /// The ID of the currently-selected tab, or nil when `tabs` is empty.
    public private(set) var activeTabId: UUID?

    /// Called when the `+` (new tab) button is pressed. Subtask .7 wires this
    /// to the PR paste-URL flow. The closure is set by the widget host; the
    /// model itself only stores it.
    public var onNewTab: (() -> Void)?

    /// Called AFTER a tab is removed via `closeTab(_:)`, with the closed tab's
    /// id. The GitHub PR widget sets this to call `TaskRepository.removePR` so
    /// tapping × on a tab detaches the PR from the task. Other widgets leave
    /// this nil (no-op).
    public var onTabClosed: ((UUID) -> Void)?

    /// The closure the view sets so find/zoom operations can reach the current
    /// tab's live view without the model holding a strong reference to the
    /// view layer. Set by BrowserWidgetView / BrowserActiveTab on `.onAppear`
    /// (and re-set on tab switch), mirroring the `onNewTab` / `onTabClosed`
    /// closure pattern. Every find/zoom method resolves the current live view
    /// by calling `activeLiveView?()`.
    public var activeLiveView: (() -> WebSectionLiveView?)?

    /// True when the tab bar should be shown (more than one tab exists).
    /// Single-tab or no-tab widgets keep the bar hidden — the chrome looks as
    /// it does today.
    public var showsTabBar: Bool { tabs.count > 1 }

    // MARK: - Find state (dewy-flint.2)

    /// Whether the find bar is currently open.
    public var isFinding: Bool = false

    /// The text the user has entered in the find bar.
    public var findQuery: String = ""

    /// The 1-based index of the currently active match (0 when there are no
    /// matches or no find is in progress).
    public var findCurrent: Int = 0

    /// The total number of matches for the current query (0 when no find is
    /// active or the query matched nothing).
    public var findTotal: Int = 0

    // MARK: - Zoom state (dewy-flint.2)

    /// The active tab's zoom level expressed as a percentage (50–300).
    /// The live webview is the source of truth; this is updated after every
    /// zoom operation and on tab switch via `syncZoom(from:)`. Starts at 100
    /// (new tabs default to 100% zoom).
    public var zoomPercent: Int = 100

    // MARK: - Combine (KVO bindings to WKWebView)

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Disk persistence (browser tabs survive app quit/relaunch)

    /// When set, every tab-list mutation is written to `BrowserTabsStore`
    /// under this key, and the initial `tabs`/`activeTabId` are restored
    /// from it at init — so quitting and relaunching the app reloads
    /// whatever page(s) were open. Only the generic "browser" widget kind
    /// sets this (`LiveWidgetBackends.browserWidgetModel(persistTabs: true)`);
    /// Jira/PR/Canvas never do, since their URL is re-derived from task/PR/
    /// canvas-server state on every launch rather than user-typed.
    private let persistenceKey: String?

    // MARK: - Init

    public init(
        canEditURL: Bool = true,
        presetSelector: String = "",
        initialURL: URL? = nil,
        persistenceKey: String? = nil
    ) {
        self.canEditURL = canEditURL
        self.presetSelector = presetSelector
        self.persistenceKey = persistenceKey
        if let persistenceKey, let restored = BrowserTabsStore.load(forKey: persistenceKey) {
            self.tabs = restored.tabs
            self.activeTabId = restored.activeTabId
            let active = restored.tabs.first { $0.id == restored.activeTabId }
            self.url = active?.url ?? restored.tabs.first?.url
            self.urlDraft = self.url?.absoluteString ?? ""
        } else {
            self.url = initialURL
            self.urlDraft = initialURL?.absoluteString ?? ""
        }
    }

    /// Writes the current `tabs`/`activeTabId` to disk. No-op when
    /// `persistenceKey` is nil. Called at the end of every method that
    /// mutates the tab list or selection.
    private func persistTabsIfNeeded() {
        guard let persistenceKey else { return }
        BrowserTabsStore.save(tabs: tabs, activeTabId: activeTabId, forKey: persistenceKey)
    }

    // MARK: - Single-URL Actions

    /// Called when the user submits the URL capsule field.
    public func navigateToDraft() {
        var raw = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        if !raw.contains("://") { raw = "https://" + raw }
        guard let resolved = URL(string: raw) else { return }
        url = resolved
        urlDraft = resolved.absoluteString
        // Reflect the navigation onto the active tab so an empty tab pins its
        // spec URL (and its webview builds) and the tab title tracks the page.
        // For a tab that already has a webview, the host's `onNavigate` loads the
        // URL in place; updating `tabs[].url` here is harmless (the per-tab spec
        // URL is pinned once and not rebuilt).
        if let activeTabId, tabs.contains(where: { $0.id == activeTabId }) {
            updateTab(activeTabId, title: resolved.host ?? resolved.absoluteString, url: resolved)
        }
        // Disarm the picker when navigating to a new URL (lanky-pine.5).
        isPicking = false
        // Clear find so highlights never carry into a new page (AC6).
        closeFind()
    }

    /// Called when the user sets a URL programmatically (e.g. Jira assigns a ticket).
    public func setURL(_ newURL: URL?) {
        url = newURL
        urlDraft = newURL?.absoluteString ?? ""
        // Disarm the picker on programmatic URL change (lanky-pine.5).
        isPicking = false
        // Clear find so highlights never carry into a new page (AC6).
        closeFind()
    }

    // MARK: - Picker API (lanky-pine.5 / AC1)

    /// Arms element-picker mode for this tile (lanky-pine.5 / AC1).
    /// The BrowserHighlightLayer observes `isPicking` and injects the
    /// picker overlay into the WKWebView.
    public func openPicker() {
        isPicking = true
    }

    /// Disarms element-picker mode for this tile (lanky-pine.5 / AC6).
    /// The BrowserHighlightLayer observes `isPicking` and removes the
    /// picker overlay from the WKWebView.
    public func closePicker() {
        isPicking = false
    }

    // MARK: - Selector stubs (backward-compat, UI removed in humble-harbor.6)

    /// No-op. Kept for call-site compatibility; the selector UI has been removed.
    public func openSelector() {}

    /// No-op. Kept for call-site compatibility; the selector UI has been removed.
    public func closeSelector() {}

    /// No-op. Kept for call-site compatibility; the selector UI has been removed.
    public func applySelector() {}

    // MARK: - Multi-tab Operations

    /// Opens a new tab with the given parameters and makes it active.
    ///
    /// If a tab with the same `id` already exists it is selected without
    /// creating a duplicate — this makes the operation idempotent when called
    /// from the GitHub PR widget's `task_prs` refresh path.
    ///
    /// - Returns: the new or existing tab's id.
    @discardableResult
    public func openTab(id: UUID = UUID(), url: URL? = nil, title: String, icon: String? = nil) -> UUID {
        if let existingIndex = tabs.firstIndex(where: { $0.id == id }) {
            selectTab(tabs[existingIndex].id)
            return tabs[existingIndex].id
        }
        let tab = BrowserTab(id: id, url: url, title: title, icon: icon)
        tabs.append(tab)
        activeTabId = tab.id
        // The new tab becomes active: mirror its URL into the capsule — an empty
        // tab CLEARS the capsule so it feels like a fresh browser (no carryover
        // from the previously-active tab).
        self.url = tab.url
        self.urlDraft = tab.url?.absoluteString ?? ""
        isPicking = false
        // Notify ObservableObject observers.
        objectWillChange.send()
        persistTabsIfNeeded()
        return tab.id
    }

    /// Selects the tab with the given id. No-op if the id is not found.
    public func selectTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        // Clear find from the current tab's page before switching (AC6).
        closeFind()
        activeTabId = id
        // Mirror the selected tab's URL into the URL capsule — CLEARING it when
        // the tab has no URL yet (empty tab), so switching to an empty tab shows
        // a blank address bar rather than the previous tab's URL.
        url = tab.url
        urlDraft = tab.url?.absoluteString ?? ""
        isPicking = false
        // Notify ObservableObject observers (e.g. BrowserChromeRow via @ObservedObject).
        objectWillChange.send()
        persistTabsIfNeeded()
    }

    /// Closes the tab with the given id. If the closed tab was active, the
    /// adjacent tab is selected (preferring the previous tab; falling back to
    /// the next). When the last tab is closed, `tabs` becomes empty and
    /// `activeTabId` becomes nil.
    ///
    /// After updating the tab list, calls `onTabClosed?(id)` so the host widget
    /// (e.g. the GitHub PR widget) can remove the corresponding DB row.
    public func closeTab(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        // Clear find state before removing the tab (AC6).
        closeFind()
        let wasActive = activeTabId == id
        tabs.remove(at: idx)
        if wasActive {
            if tabs.isEmpty {
                activeTabId = nil
            } else {
                let newIdx = max(0, idx - 1)
                activeTabId = tabs[newIdx].id
            }
        }
        // Notify ObservableObject observers before the DB-removal callback.
        objectWillChange.send()
        persistTabsIfNeeded()
        onTabClosed?(id)
    }

    /// Updates the title and/or URL of an existing tab. No-op if the id is not found.
    public func updateTab(_ id: UUID, title: String? = nil, url: URL? = nil, icon: String? = nil) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        if let title { tabs[idx].title = title }
        if let url   { tabs[idx].url = url }
        if let icon  { tabs[idx].icon = icon }
        // Notify ObservableObject observers.
        objectWillChange.send()
        persistTabsIfNeeded()
    }

    /// Give the active tab a URL only when it is still the Browser start page.
    ///
    /// An empty Browser tab is intentionally rendered as native SwiftUI, so it
    /// has no `WKWebView` for Flow42 to record. Agent recording can call this
    /// with `about:blank` to materialize a real web surface without replacing
    /// any page the user already opened. Normal Browser opening remains an
    /// empty start page until a recording is explicitly started.
    @discardableResult
    public func materializeEmptyActiveTab(at fallbackURL: URL) -> UUID? {
        if let activeTabId,
           let tab = tabs.first(where: { $0.id == activeTabId }) {
            guard tab.url == nil else { return activeTabId }
            url = fallbackURL
            urlDraft = fallbackURL.absoluteString
            updateTab(activeTabId, title: "New Tab", url: fallbackURL)
            return activeTabId
        }

        guard tabs.isEmpty else { return nil }
        return openTab(url: fallbackURL, title: "New Tab", icon: "globe")
    }

    /// Replaces the full tab list. Used by the GitHub PR widget (subtask .7)
    /// to sync the tab collection from `task_prs` in one shot. Preserves
    /// `activeTabId` when it appears in the new list; otherwise selects the
    /// first tab.
    public func replaceTabs(_ newTabs: [BrowserTab]) {
        tabs = newTabs
        if let current = activeTabId, tabs.contains(where: { $0.id == current }) {
            // keep current selection
        } else {
            activeTabId = tabs.first?.id
        }
        // Notify ObservableObject observers (e.g. BrowserChromeRow via @ObservedObject)
        // so the tab bar re-renders reliably even through AnyView-erased chrome headers.
        objectWillChange.send()
        persistTabsIfNeeded()
    }

    // MARK: - WebSectionSpec helper

    /// The WebSectionSpec for the current state (url).
    /// The selector is always empty here — preset selectors come from the
    /// WebAppCatalog factory (WebSectionSpec.selector in githubPR / jiraIssue),
    /// not from this model.
    public func spec(dataStoreKey: String) -> WebSectionSpec? {
        guard let url else { return nil }
        return WebSectionSpec(
            url: url,
            selector: "",
            dataStoreKey: dataStoreKey,
            title: nil
        )
    }

    // MARK: - WKWebView Binding

    /// Binds the model's navigation state and URL capsule to a live `WKWebView`
    /// using Combine KVO publishers. Call this once when the webview is first
    /// available (e.g. from `.onAppear` in the widget content). Safe to call
    /// multiple times — cancels previous subscriptions before re-subscribing.
    ///
    /// - `canGoBack` / `canGoForward` mirror the webview's state so the chrome
    ///   back/forward buttons reflect the current navigation stack.
    /// - `urlDraft` is updated to the webview's URL on every navigation so the
    ///   URL capsule tracks the page the webview is showing (handles SPA route
    ///   changes and redirects — the capsule reflects the ACTUAL loaded URL, not
    ///   just the one the user typed).
    public func bind(to webView: WKWebView) {
        // Cancel any previous subscriptions (safe to call multiple times).
        cancellables.removeAll()

        webView.publisher(for: \.canGoBack)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] val in self?.canGoBack = val }
            .store(in: &cancellables)

        webView.publisher(for: \.canGoForward)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] val in self?.canGoForward = val }
            .store(in: &cancellables)

        webView.publisher(for: \.url)
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .sink { [weak self] url in self?.urlDraft = url.absoluteString }
            .store(in: &cancellables)
    }

    // MARK: - Find API (dewy-flint.2)

    /// Open the find bar. Sets `isFinding` to true so `BrowserWidgetView`
    /// overlays `BrowserFindBar` and focuses its text field.
    public func openFind() {
        isFinding = true
        // Notify ObservableObject observers (BrowserChromeRow, etc.).
        objectWillChange.send()
    }

    /// Close the find bar. Clears all find state and removes page highlights
    /// by calling `clearFind()` on the active tab's live view.
    ///
    /// Called internally by `setURL(_:)`, `navigateToDraft()`, `selectTab(_:)`,
    /// and `closeTab(_:)` so find state never carries across pages or tabs (AC6).
    public func closeFind() {
        isFinding = false
        findQuery = ""
        findCurrent = 0
        findTotal = 0
        activeLiveView?()?.clearFind()
        // Notify ObservableObject observers.
        objectWillChange.send()
    }

    /// Run the current `findQuery` against the active tab's live view and store
    /// the resulting match counts in `findCurrent` / `findTotal`.
    ///
    /// No-op (counts remain 0) when `activeLiveView` is not set or returns nil.
    public func runFind() async {
        guard let live = activeLiveView?() else { return }
        let result = await live.find(findQuery)
        findCurrent = result.current
        findTotal = result.total
        // Notify ObservableObject observers.
        objectWillChange.send()
    }

    /// Advance to the next match in the active tab and update
    /// `findCurrent` / `findTotal`.
    ///
    /// No-op (counts remain unchanged) when `activeLiveView` is not set or
    /// returns nil, or when no find is active on the page.
    public func findNext() async {
        guard let live = activeLiveView?() else { return }
        let result = await live.findNext()
        findCurrent = result.current
        findTotal = result.total
        // Notify ObservableObject observers.
        objectWillChange.send()
    }

    /// Move to the previous match in the active tab and update
    /// `findCurrent` / `findTotal`.
    ///
    /// No-op (counts remain unchanged) when `activeLiveView` is not set or
    /// returns nil, or when no find is active on the page.
    public func findPrevious() async {
        guard let live = activeLiveView?() else { return }
        let result = await live.findPrevious()
        findCurrent = result.current
        findTotal = result.total
        // Notify ObservableObject observers.
        objectWillChange.send()
    }

    // MARK: - Zoom API (dewy-flint.2)

    /// Increase the zoom level by one 10% step (clamped to 300%) and update
    /// `zoomPercent` from the live view's actual `pageZoom`.
    ///
    /// No-op when `activeLiveView` is not set or returns nil.
    public func zoomIn() {
        guard let live = activeLiveView?() else { return }
        live.zoomIn()
        zoomPercent = Int((live.pageZoom * 100).rounded())
        // Notify ObservableObject observers (BrowserChromeRow zoom pill).
        objectWillChange.send()
    }

    /// Decrease the zoom level by one 10% step (clamped to 50%) and update
    /// `zoomPercent` from the live view's actual `pageZoom`.
    ///
    /// No-op when `activeLiveView` is not set or returns nil.
    public func zoomOut() {
        guard let live = activeLiveView?() else { return }
        live.zoomOut()
        zoomPercent = Int((live.pageZoom * 100).rounded())
        // Notify ObservableObject observers.
        objectWillChange.send()
    }

    /// Reset the zoom level to 100% and set `zoomPercent` to 100.
    ///
    /// Safe to call when `activeLiveView` is nil — `zoomPercent` is still reset
    /// to 100 so the chrome pill hides even if no live view is reachable.
    public func resetZoom() {
        activeLiveView?()?.resetZoom()
        zoomPercent = 100
        // Notify ObservableObject observers.
        objectWillChange.send()
    }

    /// Sync `zoomPercent` from a specific `WKWebView`'s `pageZoom`.
    ///
    /// Called by the view on tab switch so the chrome zoom pill immediately
    /// reflects the newly-active tab's zoom level — `pageZoom` is per-webview,
    /// so the model must be updated after every active-tab change.
    public func syncZoom(from webView: WKWebView) {
        zoomPercent = Int((webView.pageZoom * 100).rounded())
        // Notify ObservableObject observers.
        objectWillChange.send()
    }

    // MARK: - URL Field Focus (feat/tiles-and-dev-improvement .5 / AC11)

    // MARK: - URL Focus (dewy-flint.4)

    /// Bumped by `focusURL()` so BrowserChromeRow can observe the change
    /// and move first-responder to the URL TextField, selecting all its
    /// contents (⌘L / AC12). The nonce pattern mirrors `filesFocusNonce`
    /// in SessionDetailPanel.
    public var urlFocusNonce: Int = 0

    /// Request focus for the URL capsule. Increments `urlFocusNonce` so
    /// BrowserChromeRow's observer fires and moves first responder to the
    /// TextField. No-op when `canEditURL` is false (Canvas — AC12).
    public func focusURL() {
        guard canEditURL else { return }
        urlFocusNonce += 1
        // Notify ObservableObject observers (BrowserChromeRow).
        objectWillChange.send()
    }
}

// MARK: - BrowserTabsStore

/// On-disk persistence for one `BrowserWidgetModel`'s tab list, keyed by the
/// SAME string key the model is cached under in `LiveWidgetBackends`
/// (`"browser:<Work42Tab id>"` — a widget-instance identity that's stable
/// across app launches because `Work42Tab.id` is itself persisted by
/// HomeLayoutStore / the session's own tab-layout UserDefaults key). This is
/// what makes "quit and relaunch reloads the page that was open" a SPREAD
/// behavior — every Browser widget on every Work42View consumer (Home tabs,
/// session tabs) gets it for free from the one shared `BrowserWidgetModel`
/// implementation, with no surface-specific persistence code.
public enum BrowserTabsStore {

    private struct Snapshot: Codable {
        var tabs: [BrowserTab]
        var activeTabId: UUID?
    }

    private static func defaultsKey(for key: String) -> String {
        "work42.browserTabs.\(key)"
    }

    /// The canonical persistence key for the `.browser` widget owned by the
    /// Work42View tab with `tabId` — matches the `"browser:<tabId>"` scheme
    /// used by SessionDetailPanel/HomeView when they build the browser model.
    /// Exposed so tab-template capture/restore can snapshot and re-seed the
    /// browser state for a specific tab.
    public static func tabKey(forTabId tabId: UUID) -> String {
        "browser:\(tabId.uuidString)"
    }

    /// Persists the given tab list + active selection under `key`.
    public static func save(tabs: [BrowserTab], activeTabId: UUID?, forKey key: String) {
        let snapshot = Snapshot(tabs: tabs, activeTabId: activeTabId)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey(for: key))
    }

    /// Restores the tab list + active selection saved under `key`, or nil if
    /// nothing was ever saved (a widget instance's first launch).
    public static func load(forKey key: String) -> (tabs: [BrowserTab], activeTabId: UUID?)? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey(for: key)),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return nil }
        return (snapshot.tabs, snapshot.activeTabId)
    }
}
