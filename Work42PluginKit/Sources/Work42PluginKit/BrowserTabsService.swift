// BrowserTabsService.swift — how a browser-based widget drives its own tabs (SDK 3.1.0, WOR-858).
//
// A browser widget declares its surface once (`BrowserSurfaceDeclaration(spec:cacheKey:)`) and reaches its tabs through
// `services.browser`. The service is bound to the calling widget: every call acts on that widget's own browser in that
// widget's own session, and nothing takes a widget id, so a widget cannot read or change another widget's tabs.
//
// The shape is deliberately XPC-friendly (async calls, Codable values, streams), so moving plugins out of process later is
// a transport swap and not a rewrite.

import Foundation
import Work42UI

/// A widget's tabs and the one in front, as the host holds them.
///
/// Main-actor-isolated like `BrowserTab` (the module's default), and so `Sendable`: read it from your widget's own code.
public struct BrowserTabsState: Codable, Sendable, Equatable {
    public var tabs: [BrowserTab]
    public var activeTabId: UUID?

    public init(tabs: [BrowserTab] = [], activeTabId: UUID? = nil) {
        self.tabs = tabs
        self.activeTabId = activeTabId
    }
}

/// Something the person did in the widget's tab bar that the widget decides how to answer.
public enum BrowserEvent: Codable, Sendable, Equatable {
    /// The "+" button was pressed. Answer it with `setTabs` (add a tab and keep the others).
    case newTabRequested
    /// A tab's "×" was pressed and the tab is gone. Forget anything you kept for it.
    case tabClosed(UUID)
}

/// Drives the calling widget's tabs. Reach it as `services.browser`; it is already scoped to this widget.
///
/// ```swift
/// let browser = services.browser
/// try await browser.setTabs([BrowserTab(url: issueURL, title: "PROJ-1")])   // show these tabs
/// try await browser.selectTab(tabID)                                         // bring one to the front
/// for await event in browser.events {                                        // answer + and ×
///     switch event {
///     case .newTabRequested: try await browser.setTabs(tabs + [BrowserTab(title: "New Tab")])
///     case .tabClosed(let id): tabs.removeAll { $0.id == id }
///     @unknown default: break   // a later 3.x release may add events
///     }
/// }
/// ```
///
/// Do not use `configure:` or `BrowserWidgetModel` for this; they are deprecated.
nonisolated public protocol BrowserTabsService: Sendable {

    /// Replace the widget's tabs with `tabs`. A tab whose `id` is already open keeps its page (and its history); a new `id`
    /// opens a tab; an `id` that is no longer listed closes. Selection stays where it was when that tab remains.
    func setTabs(_ tabs: [BrowserTab]) async throws

    /// Bring tab `id` to the front. Throws when no such tab is open.
    func selectTab(_ id: UUID) async throws

    /// Change a tab's title, address or icon. A nil argument leaves that field as it is. Throws when no such tab is open.
    func updateTab(_ id: UUID, title: String?, url: URL?, icon: String?) async throws

    /// The widget's tabs now, then again after every change (including the person's own: opening, closing, navigating).
    var tabs: AsyncStream<BrowserTabsState> { get }

    /// What the person asked for in the tab bar. See `BrowserEvent`.
    var events: AsyncStream<BrowserEvent> { get }
}

/// What the host sets at launch so `services.browser` finds the browser of the widget a `SessionServices` belongs to. Plugins
/// never touch this.
@MainActor
public enum BrowserTabsRegistry {
    public static var resolve: (@MainActor (SessionServices) -> (any BrowserTabsService)?)?

    /// Called each time a browser surface has finished wiring a model's own hooks (when the model is built, and again when a view
    /// mounts on a model that already exists), with the model and the key it is cached under (`"<session>/<widget id>"`). It runs
    /// after the surface's default `onNewTab` / `onTabClosed`, so a host that answers a widget's events through `services.browser`
    /// installs its listeners here and they are never overwritten by the defaults. Plugins never touch this.
    public static var attach: (@MainActor (_ model: BrowserWidgetModel, _ scopedKey: String) -> Void)?
}

/// The service a host with no browser support (or no widget binding) hands out: every call throws a named remedy.
nonisolated public struct UnavailableBrowserTabsService: BrowserTabsService {
    public init() {}

    private var error: WidgetServiceError {
        WidgetServiceError(
            message: "services.browser is not available here.",
            suggestion: "Run inside Work42 3.1 or later, from a widget the app has mounted in a session.")
    }

    public func setTabs(_ tabs: [BrowserTab]) async throws { throw error }
    public func selectTab(_ id: UUID) async throws { throw error }
    public func updateTab(_ id: UUID, title: String?, url: URL?, icon: String?) async throws { throw error }

    public var tabs: AsyncStream<BrowserTabsState> { AsyncStream { $0.finish() } }
    public var events: AsyncStream<BrowserEvent> { AsyncStream { $0.finish() } }
}

extension SessionServices {

    /// The calling widget's tabs (SDK 3.1.0). Already scoped to this widget in this session: it takes no widget id.
    ///
    /// ```swift
    /// try await services.browser.setTabs(tabs)          // show these tabs
    /// try await services.browser.selectTab(tabs[0].id)  // bring one to the front
    /// for await event in services.browser.events {      // answer + and ×
    ///     if case .newTabRequested = event { /* add a tab with setTabs */ }
    /// }
    /// ```
    ///
    /// On a host that cannot provide it, every call throws a `WidgetServiceError` saying to run inside Work42 3.1 or later.
    /// It is computed, so `SessionServices`' layout is unchanged.
    @MainActor
    public var browser: any BrowserTabsService {
        BrowserTabsRegistry.resolve?(self) ?? UnavailableBrowserTabsService()
    }
}
