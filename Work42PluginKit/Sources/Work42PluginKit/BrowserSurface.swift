// BrowserSurface.swift — the SDK's browser base component, rebuilt on the
// shared Work42UI browser base (browser-widgets-not-extending-from-browser.2,
// AC2 + AC4) and extended with the widget-facing hook API (.3, AC3 + AC5).
//
// Previously this file contained a parallel chrome implementation
// (`BrowserSurfaceChromeRow`) and a minimal model that duplicated the app's
// `BrowserWidgetModel`. That parallel code is now deleted; `BrowserSurface`
// composes the shared base directly — the same `BrowserWidgetModel` +
// `BrowserChromeRow` + `BrowserFindBar` (+ `BrowserTabBar` when >1 tab) over
// `CachedWebSectionView` that the app's `BrowserActiveTab` uses.
//
// ## Key design points
//
//   - `BrowserSurfaceCache` holds two caches side-by-side:
//       * Model cache:    `cacheKey → BrowserWidgetModel`
//       * Live-view cache:`"<cacheKey>:<tabID>" → WebSectionLiveView`
//     `teardown(key: cacheKey)` releases both the model and all per-tab
//     live views whose key starts with `"<cacheKey>:"`.
//
//   - `BrowserSurfaceState` keeps only the provider-resolution phase states
//     (`resolving` / `failed(message)` / `ready`) and the `retryNonce` for
//     the Retry button.  The `urlDraft` field is gone — `BrowserWidgetModel`
//     owns the URL state now.  The non-generic `@Observable` class held via
//     `@State` avoids the Swift 6.3 release-inliner crash and dead-click
//     classes documented in the repo.
//
//   - `BrowserSurface` exposes the model's hook API two ways (.3):
//
//       (a) `configure: ((BrowserWidgetModel) -> Void)?` — an optional
//           closure on init. Invoked EXACTLY ONCE with the surface's model
//           when it becomes live:
//             • On new model creation: right after model seeding in
//               `resolveIfNeeded()`.
//             • On cache-hit, first mount of a new `BrowserSurface` value:
//               on the first `.task` execution for this view instance.
//           "Once" is guarded by `BrowserSurfaceState.configureInvoked`
//           which persists within a view mount but resets on true
//           unmount+remount (new `BrowserSurface` value, new `@State`).
//           This means a full widget-deactivate+reactivate cycle calls
//           configure again on the cache-hit path — intentional, since the
//           widget may need to re-wire its intent closures.
//
//           Use configure to: wire `model.onNewTab` / `model.onTabClosed`,
//           stash the model reference for use in intents, etc.
//
//       (b) `BrowserSurface.model(forKey:)` — a public static accessor
//           backed by `BrowserSurfaceCache.shared`. Returns nil when the
//           surface has not yet resolved. Use from a widget's declared
//           intent `perform` closure to drive `openTab` / `closeTab` /
//           `setURL` / find / zoom from outside the view.
//
//   - Default hook wiring (set before `configure:` runs, overrideable):
//       • `model.onNewTab`: opens an empty tab (`openTab(title:"New Tab")`).
//       • `model.onTabClosed`: composed — cache-release fires FIRST, then
//         whatever `configure` placed on `model.onTabClosed`. This guarantees
//         the per-tab live-view slot is always freed regardless of what the
//         widget's configure closure does.
//
//   - `BrowserSurfaceReady` always renders the chrome row when a tab is
//     active. When the active tab has no URL yet (empty tab, opened via
//     `model.openTab(url: nil, ...)`), it renders a "New Tab" placeholder
//     instead of the webview. Typing a URL in the capsule and pressing
//     Return calls `model.navigateToDraft()` (wired in `BrowserChromeRow`),
//     which calls `model.updateTab(activeTabId, url:)` — pinning the URL
//     onto the tab — and triggers a re-render that builds the live view.
//
//   - `BrowserSurfaceReady` holds `@ObservedObject var model` so
//     tab-count changes reliably re-render through AnyView-erased widget
//     boundaries (same dual @Observable+ObservableObject pattern the app uses).
//
//   - The provider-resolution short-circuit (AC4): a cache hit on the model
//     immediately renders `BrowserSurfaceReady` without re-running the provider
//     or flashing the spinner — identical to the old live-view cache-hit path.
//
// ## Tab bar
//
//   The tab bar is rendered by `BrowserChromeRow` (via `BrowserTabBar`) when
//   `model.showsTabBar` is true (tabs.count > 1). This comes free from the
//   shared base — no extra code in BrowserSurface.
//
// ## SDK version (AC5)
//
//   Adding the `configure:` parameter to `BrowserSurface.init` changes the
//   init's mangled Swift symbol from
//   `BrowserSurface.init(spec:cacheKey:)` to
//   `BrowserSurface.init(spec:cacheKey:configure:)`. A widget dylib built
//   against SDK v2 references the OLD mangled symbol; `dlopen(RTLD_NOW)` on
//   the new framework will fail with "symbol not found", which the loader
//   catches and surfaces as a fail-loud error card (never a crash). The ABI
//   version is bumped from 2 to 3 in Work42PluginKit.swift so `widget.yaml`
//   staleness detection and the version-mismatch card name the correct target
//   version.
//
// The public `BrowserSurfaceSpec` API (source .url/.provider, selector,
// dataStoreKey, title, icon) is unchanged.
//
// The `BrowserSurfaceChromeRow` struct and the `urlDraft` property of
// `BrowserSurfaceState` are deleted in the .2 commit.
//
// ## Usage example (.3 hook API)
//
// ```swift
// func makeView(services: SessionServices) -> AnyView {
//     AnyView(BrowserSurface(
//         spec: BrowserSurfaceSpec(
//             url: jiraURL,
//             selector: "[data-vc=\"issue-body-container\"]",
//             dataStoreKey: "jira",
//             title: "Jira"
//         ),
//         cacheKey: id,
//         configure: { model in
//             // Wire onNewTab to open Jira's "New Issue" URL.
//             model.onNewTab = { [weak model] in
//                 model?.openTab(url: newIssueURL, title: "New Issue")
//             }
//             // Stash model for intents.
//             self.browserModel = model
//         }
//     ))
// }
//
// // In a declared intent:
// func perform() async throws -> some IntentResult {
//     BrowserSurface.model(forKey: id)?.openTab(url: url, title: "…")
//     return .result()
// }
// ```

import Observation
import SwiftUI
import Work42UI

// MARK: - BrowserSurfaceSpec

/// Spec-shaped input for one browser surface. Mirrors `WebSectionSpec`'s
/// vocabulary (url / selector / dataStoreKey / title — see
/// docs/web-section.md) but allows the URL to be *produced by widget
/// code* asynchronously, because an agent-built widget often has to
/// compute its target (e.g. read a ticket id via `services.shell`) before
/// it can browse there.
public struct BrowserSurfaceSpec {

    /// Where the page URL comes from.
    public enum Source {
        /// A static URL, known at spec-construction time.
        case url(URL)
        /// Widget-supplied async producer. Runs ONCE per surface identity
        /// (the resolved model is cached under `cacheKey`); a thrown
        /// error renders a fail-loud error card with Retry — never a
        /// silent blank surface.
        case provider(@Sendable () async throws -> URL)
    }

    public var source: Source

    /// Optional CSS selector to isolate and pin to fill the surface;
    /// empty string = show the whole page. Same semantics as
    /// `WebSectionSpec.selector` (auth-gated selectors like GitHub's
    /// `.logged-in .application-main` work unchanged).
    public var selector: String

    /// Identity of the persistent login store
    /// (`WebSectionSpec.dataStoreKey`): authenticate once per key, survive
    /// restarts; distinct keys isolate distinct web apps.
    public var dataStoreKey: String

    /// Human-facing label shown in the chrome row.
    public var title: String?

    /// SF Symbol for the chrome row's leading icon.
    public var icon: String

    public init(
        source: Source,
        selector: String = "",
        dataStoreKey: String,
        title: String? = nil,
        icon: String = "globe"
    ) {
        self.source = source
        self.selector = selector
        self.dataStoreKey = dataStoreKey
        self.title = title
        self.icon = icon
    }

    /// Convenience for the static-URL case.
    public init(
        url: URL,
        selector: String = "",
        dataStoreKey: String,
        title: String? = nil,
        icon: String = "globe"
    ) {
        self.init(
            source: .url(url),
            selector: selector,
            dataStoreKey: dataStoreKey,
            title: title,
            icon: icon
        )
    }
}

// MARK: - BrowserSurfaceCache

/// Process-wide cache of `BrowserWidgetModel` instances and their per-tab
/// `WebSectionLiveView` slots, keyed by surface identity (the widget's
/// `cacheKey`).
///
/// Two caches side-by-side:
///   * **Model cache**: `cacheKey → BrowserWidgetModel`
///   * **Live-view cache**: `"<cacheKey>:<tabID>" → WebSectionLiveView`
///
/// Ownership: entries live until explicitly torn down. A widget releases
/// its entry in `deactivate()` via `teardown(key:)`; the loader may call
/// `teardownAll(withPrefix:)` when a session closes.
///
/// `teardown(key: cacheKey)` releases the model for that surface AND all
/// live views whose key starts with `"<cacheKey>:"`.
///
/// ## @Observable (AC7)
///
/// `BrowserSurfaceCache` is `@Observable` so host-side SwiftUI views that read
/// `existingModel(forKey:)` inside their `body` (or from closures called
/// during `body`) establish an observation dependency on `models`. When a
/// `BrowserSurface` resolves its URL and inserts its model into the cache,
/// that observation fires — re-rendering the host's chrome closure so it can
/// switch from the generic title header to the browser chrome header without
/// polling. This is the "model appeared" re-render mechanism for AC7.
@Observable
@MainActor
public final class BrowserSurfaceCache {

    public static let shared = BrowserSurfaceCache()

    // MARK: - Storage

    /// Model cache: surface cacheKey → BrowserWidgetModel.
    private var models: [String: BrowserWidgetModel] = [:]

    /// Live-view cache: "<cacheKey>:<tabID>" → WebSectionLiveView.
    /// Callers pass the full per-tab key when building or retrieving a live view.
    private var liveViews: [String: WebSectionLiveView] = [:]

    private init() {}

    // MARK: - Session scope

    /// Set by the host around a widget instance's `activate`/`deactivate`, so a widget's own
    /// `teardown(key: id)` reaches the entries of ITS session only. Nil everywhere else.
    public var scope: String?

    /// The cache key a surface in `scope` uses for `key` (`"<scope>/<key>"`; unchanged when `scope` is nil).
    public static func scopedKey(_ key: String, scope: String?) -> String {
        scope.map { "\($0)/\(key)" } ?? key
    }

    // MARK: - Internal model cache

    /// Return the cached model for `key`, or nil when none was built yet.
    /// Used by `BrowserSurface` to short-circuit provider re-resolution on
    /// remounts (AC4: a cache hit never re-runs the provider).
    ///
    /// Also exposed via `BrowserSurface.model(forKey:)` for widget-intent
    /// code that drives tabs/URL/find/zoom outside the view.
    func existingModel(forKey key: String) -> BrowserWidgetModel? {
        models[key]
    }

    /// Return the cached model for `key`, creating one via `building` on first use.
    func model(forKey key: String, building: () -> BrowserWidgetModel) -> BrowserWidgetModel {
        if let m = models[key] { return m }
        let m = building()
        models[key] = m
        return m
    }

    // MARK: - Live-view cache (public)

    /// The cached live view for `key`, or nil when none was built yet.
    ///
    /// With the per-tab key scheme (`"<cacheKey>:<tabID>"`), pass the full
    /// per-tab key. Passing a bare `cacheKey` returns nil after the migration
    /// to per-tab keys — use `existingModel(forKey:)` to check surface resolution.
    public func existing(forKey key: String) -> WebSectionLiveView? {
        liveViews[key]
    }

    /// Return the cached live view for `key`, building (and caching) one from
    /// `spec` on first use. With the per-tab key scheme, pass the full
    /// `"<cacheKey>:<tabID>"` key.
    public func liveView(forKey key: String, building spec: WebSectionSpec) -> WebSectionLiveView {
        if let live = liveViews[key] { return live }
        let live = WebSectionView.makeLiveView(spec: spec)
        liveViews[key] = live
        return live
    }

    /// Release the single live view stored at `key` (full per-tab key:
    /// `"<cacheKey>:<tabID>"`). Used by the composed `onTabClosed` handler to
    /// free a closed tab's cached webview slot without tearing down the whole
    /// surface.
    ///
    /// No-op when no live view exists for `key`.
    func releaseLiveView(forKey key: String) {
        liveViews[key]?.teardown()
        liveViews.removeValue(forKey: key)
    }

    // MARK: - Teardown

    /// Tear down and drop the cached model and ALL per-tab live views for the
    /// surface identified by `key` (the widget's `cacheKey`). Live views are
    /// keyed `"<key>:<tabID>"` — all entries whose key starts with `"<key>:"` are
    /// torn down.
    ///
    /// Call from the widget's `deactivate()` — a cached `WKWebView` is a
    /// heavyweight resource and "done means inert".
    public func teardown(key rawKey: String) {
        let key = Self.scopedKey(rawKey, scope: scope)
        // Release the model for this surface.
        models.removeValue(forKey: key)
        // Release all per-tab live views: keys are "<key>:<tabID>".
        let tabPrefix = "\(key):"
        let liveKeysToRemove = liveViews.keys.filter { $0.hasPrefix(tabPrefix) }
        for liveKey in liveKeysToRemove {
            liveViews[liveKey]?.teardown()
            liveViews.removeValue(forKey: liveKey)
        }
    }

    /// Tear down every cached surface whose `cacheKey` starts with `prefix`
    /// (empty prefix = everything). For host-side cleanup when a session closes.
    public func teardownAll(withPrefix prefix: String = "") {
        // Collect surface keys (model keys) that match the prefix.
        let surfaceKeys = models.keys.filter { prefix.isEmpty || $0.hasPrefix(prefix) }
        for key in surfaceKeys {
            teardown(key: key)
        }
        // Also clean up orphaned live views (surface built a live view but no model
        // was registered — should not happen in normal use, but handled defensively).
        // Live view key format: "<surfaceKey>:<tabID>".
        let orphanLiveKeys = liveViews.keys.filter { liveKey in
            guard !prefix.isEmpty else { return true }
            guard let colonIdx = liveKey.firstIndex(of: ":") else { return false }
            return String(liveKey[..<colonIdx]).hasPrefix(prefix)
        }
        for liveKey in orphanLiveKeys {
            liveViews[liveKey]?.teardown()
            liveViews.removeValue(forKey: liveKey)
        }
    }
}

// MARK: - Scope reader

/// Reads `widgetCacheScope` from the environment and hands it to `build`.
private struct BrowserSurfaceScopeReader<Content: View>: View {
    @Environment(\.widgetCacheScope) private var scope
    let build: (String?) -> Content

    init(@ViewBuilder build: @escaping (String?) -> Content) { self.build = build }

    var body: some View { build(scope) }
}

// MARK: - BrowserSurfaceState

/// Per-mount observable state for a `BrowserSurface`: the async URL-provider
/// resolution phase and the configure-once guard.
///
/// A non-generic `@Observable` class held via `@State` — the repo's safe
/// pattern:
///   - A generic `@StateObject` class is the documented Swift 6.3 release-
///     inliner crash class.
///   - Per-frame `@State` writes from escaping callbacks are the documented
///     dead-click class.
///
/// Intentionally minimal: only the resolution phase, the retry nonce, and
/// the `configureInvoked` flag live here. `BrowserWidgetModel` owns the URL
/// draft, tab list, find/zoom state, and all other browser state.
@Observable
@MainActor
final class BrowserSurfaceState {

    enum Resolution {
        /// The URL provider hasn't finished yet.
        case resolving
        /// The provider threw; fail loud with the message.
        case failed(String)
        /// The surface has its URL and the model is live.
        case ready
    }

    var resolution: Resolution = .resolving

    /// Bumped to re-run a failed provider resolution (Retry button).
    var retryNonce = 0

    /// Guards the `configure:` closure — set to true after the first
    /// `wireHooks` call for this view mount. Resets to false when the
    /// `BrowserSurface` value is truly unmounted (new `@State` instance),
    /// so a full widget-deactivate+reactivate cycle re-calls configure on
    /// the cache-hit path.
    var configureInvoked = false
}

// MARK: - BrowserSurface

/// The browser base component for custom widgets. Compose it from a widget's
/// `makeView` with a `BrowserSurfaceSpec`, the widget's `id` as `cacheKey`,
/// and an optional `configure:` closure for hook wiring.
///
/// ## Hook API (AC3)
///
/// The hook API *is* the public `BrowserWidgetModel` surface — every method
/// (`openTab`, `closeTab`, `selectTab`, `updateTab`, `replaceTabs`, `setURL`,
/// `navigateToDraft`, `openFind`, `closeFind`, `zoomIn`, `zoomOut`,
/// `resetZoom`) and every callback (`onNewTab`, `onTabClosed`) is already
/// public on the model. Two access paths reach the model from widget code:
///
///   (a) `configure: ((BrowserWidgetModel) -> Void)?` — an optional closure
///       on init, called ONCE when the model becomes live. Use to wire
///       `onNewTab` / `onTabClosed`, stash the model for intents, etc.
///
///   (b) `BrowserSurface.model(forKey:)` — a static accessor backed by
///       `BrowserSurfaceCache.shared`. Returns nil before resolution. Use
///       from a widget's declared intent `perform` closure to drive tabs,
///       URL, find, or zoom from outside the view.
///
/// ## Empty-tab support
///
/// `model.openTab(url: nil, title:)` opens a tab with no URL. The chrome row
/// is always rendered when any tab is active; an empty tab renders a "New
/// Tab" placeholder body instead of a webview. Typing a URL in the capsule
/// pins it onto the active tab (`navigateToDraft` → `updateTab`) and the
/// next re-render builds the live webview from the tab's URL.
///
/// ## Default hook wiring
///
/// Before `configure:` runs, the surface sets these defaults on the model:
///   - `onNewTab`: opens an empty tab (overrideable by `configure`).
///   - `onTabClosed`: composed — cache-release fires FIRST (freeing the
///     closed tab's live-view slot), then whatever `configure` placed on
///     `model.onTabClosed`. See `wireHooks(on:cacheKey:configure:)`.
///
/// ## Tab bar
///
/// The tab bar appears when `model.tabs.count > 1` and hides at ≤1 — this
/// comes free from `BrowserChromeRow` → `BrowserTabBar` (same behaviour as
/// the built-in browser widget).
public struct BrowserSurface: View {

    public let spec: BrowserSurfaceSpec

    /// Identity of the cached model and live views (`BrowserSurfaceCache`) —
    /// pass the widget's `id`. Two surfaces sharing a key share one model and
    /// one set of per-tab webviews.
    public let cacheKey: String

    /// Called ONCE with the surface's `BrowserWidgetModel` when it becomes
    /// live. Wire callbacks, stash the model for intents, etc. The surface
    /// sets default `onNewTab` and composed `onTabClosed` BEFORE calling this
    /// closure, so `configure` can override either.
    ///
    /// Nil (the default) is equivalent to no-op configure — the two-arg call
    /// `BrowserSurface(spec:cacheKey:)` preserves the existing call signature.
    public let configure: ((BrowserWidgetModel) -> Void)?

    /// The session services. When present, the surface owns highlight-to-comment
    /// for EVERY tab: selecting text shows the floating "＋" bubble + composer and
    /// publishes the selection for dictate-to-comment — no per-widget wiring.
    /// Nil (previews / tests / hosts that don't pass services) disables the
    /// comment pipeline but keeps every other behaviour identical.
    ///
    /// When nil, the surface falls back to `EnvironmentValues.widgetSessionServices`, which
    /// the host sets around every plugin widget — so highlight-to-comment works for any
    /// browser widget without it passing `services:`. An explicit value always wins.
    ///
    /// The environment is read inside the internal `BrowserSurfaceReady`, NOT here: this struct is
    /// embedded by value in every widget, so any new stored property (an `@Environment` wrapper
    /// stores its value inline) changes its size and crashes widgets built against another SDK.
    /// `PublicLayoutStabilityTests` pins that size.
    public let services: SessionServices?

    /// Optional plugin hook that enriches a raw selection into a useful source
    /// label / excerpt (e.g. GitHub → "PR #42 · File.swift:L12–L18") right
    /// before the comment reaches the composer. Applies identically to the
    /// typed and dictated paths. Nil → the SDK's plain page-title / host label.
    public let selectionResolver: WebSelectionResolver?

    @State private var state = BrowserSurfaceState()

    public init(
        spec: BrowserSurfaceSpec,
        cacheKey: String,
        services: SessionServices? = nil,
        selectionResolver: WebSelectionResolver? = nil,
        configure: ((BrowserWidgetModel) -> Void)? = nil
    ) {
        self.spec = spec
        self.cacheKey = cacheKey
        self.services = services
        self.selectionResolver = selectionResolver
        self.configure = configure
    }

    /// The services the comment pipeline uses: the explicit parameter, else the environment's.
    static func effectiveServices(explicit: SessionServices?, environment: SessionServices?) -> SessionServices? {
        explicit ?? environment
    }

    public var body: some View {
        // The scope is read in a nested view: a stored `@Environment` here would change this struct's size.
        BrowserSurfaceScopeReader { scope in
            let key = BrowserSurfaceCache.scopedKey(cacheKey, scope: scope)
            content(cacheKey: key)
                .task(id: state.retryNonce) {
                    await resolveIfNeeded(cacheKey: key)
                }
        }
    }

    @ViewBuilder
    private func content(cacheKey: String) -> some View {
        // A cached model means this surface already resolved once — render it
        // immediately. Remounts must never re-run the provider or flash a
        // spinner (AC4: cache hit short-circuits resolution).
        if let model = BrowserSurfaceCache.shared.existingModel(forKey: cacheKey) {
            BrowserSurfaceReady(
                model: model, cacheKey: cacheKey, spec: spec,
                services: services,
                selectionResolver: selectionResolver
            )
        } else {
            switch state.resolution {
            case .resolving:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                errorCard(message: message)
            case .ready:
                // `.ready` with no cached model can't happen in normal use
                // (resolution populates the cache before flipping state) —
                // render the spinner rather than trap.
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Public hook accessor

    /// Return the cached `BrowserWidgetModel` for the surface with the given
    /// `cacheKey`, or nil when none is live yet.
    ///
    /// Use from a widget's declared intent `perform` closure to drive
    /// `openTab` / `closeTab` / `setURL` / find / zoom programmatically,
    /// outside the view:
    ///
    /// ```swift
    /// func perform() async throws -> some IntentResult {
    ///     BrowserSurface.model(forKey: myWidgetId)?.openTab(url: url, title: "…")
    ///     return .result()
    /// }
    /// ```
    ///
    /// Returns nil before the surface has resolved its URL (provider still
    /// running or not yet mounted). The cache is populated in
    /// `resolveIfNeeded()` before the state flips to `.ready`.
    public static func model(forKey cacheKey: String) -> BrowserWidgetModel? {
        BrowserSurfaceCache.shared.existingModel(forKey: cacheKey)
    }

    /// The model of the surface with `cacheKey` in `scope` (a session id, or `"home"`): what a host asks for
    /// when one widget is shown in several sessions.
    public static func model(forKey cacheKey: String, scope: String?) -> BrowserWidgetModel? {
        BrowserSurfaceCache.shared.existingModel(forKey: BrowserSurfaceCache.scopedKey(cacheKey, scope: scope))
    }

    // MARK: - Resolution

    /// Resolve the spec's URL source, build the `BrowserWidgetModel`, and seed
    /// its first tab. Runs once per surface identity: a model cache hit
    /// short-circuits, so remounts and tab switches never re-run a provider.
    ///
    /// On NEW model creation: seeds the first tab, then calls `wireHooks` once.
    /// On CACHE HIT (model already exists, new BrowserSurface value mounting):
    /// calls `wireHooks` once on the first `.task` execution; subsequent
    /// `.task` executions (re-renders) are guarded by `state.configureInvoked`.
    private func resolveIfNeeded(cacheKey: String) async {
        // Cache hit: already resolved. Call wireHooks on first mount only,
        // then flip to ready.
        if let model = BrowserSurfaceCache.shared.existingModel(forKey: cacheKey) {
            if !state.configureInvoked {
                state.configureInvoked = true
                BrowserSurface.wireHooks(on: model, cacheKey: cacheKey, configure: configure)
            }
            state.resolution = .ready
            return
        }
        state.resolution = .resolving

        let url: URL
        switch spec.source {
        case .url(let staticURL):
            url = staticURL
        case .provider(let provider):
            do {
                url = try await provider()
            } catch {
                // Fail loud (AC4 / repo's fail-loud rule): the widget's URL
                // producer failing must render as an error card, never a
                // silent blank webview.
                state.resolution = .failed(error.localizedDescription)
                return
            }
        }

        // Build (or retrieve) the model and seed its first tab.
        let model = BrowserSurfaceCache.shared.model(forKey: cacheKey) {
            BrowserWidgetModel(
                canEditURL: true,
                presetSelector: spec.selector,
                initialURL: url
            )
        }
        // Only seed the tab if the model is fresh (empty tab list).
        // A repeated call (e.g. retry after a partial failure) must not
        // open a duplicate tab if the model was already partially built.
        if model.tabs.isEmpty {
            _ = model.openTab(
                url: url,
                title: spec.title ?? url.host ?? url.absoluteString,
                icon: spec.icon
            )
        }

        // Wire default + widget-supplied hooks. Called exactly once per model
        // creation — the configureInvoked guard is set here so any subsequent
        // cache-hit path (e.g. a retry loop) doesn't re-call wireHooks.
        state.configureInvoked = true
        BrowserSurface.wireHooks(on: model, cacheKey: cacheKey, configure: configure)
        state.resolution = .ready
    }

    // MARK: - Hook wiring

    /// Wire the default `onNewTab` / `onTabClosed` hooks onto `model`, call the
    /// widget's `configure:` closure (if provided), then compose the
    /// cache-release into `onTabClosed`.
    ///
    /// ## Wiring sequence
    ///
    ///   1. Set `model.onNewTab` to the default (open an empty tab). The widget's
    ///      `configure:` closure can override this by assigning its own closure.
    ///   2. Call `configure?(model)` — the widget wires its callbacks and may
    ///      stash the model reference.
    ///   3. Compose `model.onTabClosed`:
    ///        - Cache-release (`BrowserSurfaceCache` drops `"<cacheKey>:<tabID>"`).
    ///        - Widget-set handler (whatever `configure` placed on `onTabClosed`).
    ///      The cache-release always runs FIRST, ensuring the live-view slot is
    ///      freed regardless of what the widget's handler does.
    ///
    /// `internal` (not `private`) so `Work42PluginKitTests` can call it directly
    /// via `@testable import Work42PluginKit` and verify hook behaviour without
    /// requiring a running SwiftUI view.
    static func wireHooks(
        on model: BrowserWidgetModel,
        cacheKey: String,
        configure: ((BrowserWidgetModel) -> Void)?
    ) {
        // 1. Default: + button opens an empty tab.
        //    configure can override this by assigning its own model.onNewTab.
        model.onNewTab = { [weak model] in
            guard let model else { return }
            _ = model.openTab(title: "New Tab", icon: "globe")
        }

        // 2. Call the widget's configure closure. It may:
        //    - Override model.onNewTab
        //    - Set model.onTabClosed
        //    - Stash the model reference for use in intents
        configure?(model)

        // 3. Compose onTabClosed: save whatever configure set, then replace
        //    with a closure that releases the live view FIRST, then calls the
        //    widget's handler (if any).
        //
        //    This is safe even when configure did NOT set onTabClosed (nil is
        //    captured and the composed closure becomes a cache-release-only handler).
        //    It is also safe when configure set onTabClosed to be the same default
        //    we set above — the cache-release runs once since the composed closure
        //    replaces the previous one.
        let widgetTabClosed = model.onTabClosed
        model.onTabClosed = { tabID in
            // Cache-release first: free the closed tab's live-view slot.
            BrowserSurfaceCache.shared.releaseLiveView(forKey: "\(cacheKey):\(tabID)")
            // Then call the widget's handler (may be nil → no-op).
            widgetTabClosed?(tabID)
        }
    }

    // MARK: - Fail-loud error card

    /// Fail-loud error state for a throwing URL provider, with Retry.
    private func errorCard(message: String) -> some View {
        VStack(spacing: DT.s12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.secondary)
            Text("\(spec.title ?? "Browser") failed to resolve its URL")
                .font(.system(size: DT.f13, weight: .semibold))
            Text(message)
                .font(.system(size: DT.f12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Button("Retry") {
                state.retryNonce += 1
            }
        }
        .padding(DT.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - BrowserSurfaceReady

/// Renders the resolved browser surface: the shared `BrowserChromeRow` (with
/// `BrowserTabBar` when >1 tab) above the content area, with the
/// `BrowserFindBar` overlay when `model.isFinding` is true.
///
/// ## Always-visible chrome (when not host-owned)
///
/// The chrome row is rendered whenever `activeTab` is non-nil (i.e. any time
/// the surface is live and has at least one tab), UNLESS `browserChromeHostOwned`
/// is `true` in the environment. When the host owns the chrome (AC7 header
/// routing), `BrowserSurfaceReady` skips its own `BrowserChromeRow` + `Divider`
/// so exactly one chrome row renders (the host's header). The find-bar overlay
/// and empty-tab placeholder always render in the body regardless.
///
/// When `browserChromeHostOwned` is `false` (the default), the chrome row is
/// always-visible: when the active tab has no URL yet (an empty tab), an
/// `emptyTabPlaceholder` is shown instead of a webview. This lets widgets open
/// empty tabs via `model.openTab(url: nil, ...)` and show the full chrome UI
/// (address bar, + button, back/forward) from the first moment.
///
/// ## First navigation in an empty tab
///
/// Typing a URL in the capsule and pressing Return calls
/// `model.navigateToDraft()` (wired in `BrowserChromeRow.onSubmit`). That
/// method calls `model.updateTab(activeTabId, url:)`, pinning the URL onto
/// the tab. The `@ObservedObject` subscription on `model` triggers a
/// re-render; on the next render `activeTab.url` is non-nil, `liveView(for:url:)`
/// builds and caches the live view, and `CachedWebSectionView` renders it.
/// The `onNavigate` callback in the chrome row calls
/// `live?.webView.load(URLRequest(url:))` — which is a no-op for an empty tab
/// (live is nil at that moment) since the initial page load happens through the
/// live view's `WebSectionView.buildWebView(spec:)` on construction.
///
/// ## Model wiring
///
/// `@ObservedObject var model` ensures tab-count changes reliably trigger
/// re-renders through AnyView-erased widget boundaries (the dual
/// @Observable+ObservableObject pattern with `objectWillChange.send()`).
///
/// `bind(to:)` + `syncZoom(from:)` + `activeLiveView` closure are wired
/// on `.onAppear` and re-wired on `.onChange(of: model.activeTabId)` so
/// every tab switch correctly rebinds to the new tab's `WKWebView`. Empty
/// tabs (no URL) are skipped — there is no live view to bind to.
///
/// Per-tab live views are keyed `"<cacheKey>:<tabID>"` in `BrowserSurfaceCache`.
@MainActor
private struct BrowserSurfaceReady: View {

    @ObservedObject var model: BrowserWidgetModel
    let cacheKey: String
    let spec: BrowserSurfaceSpec

    /// Session services, forwarded from `BrowserSurface`. When present, the web
    /// content area gets the generic highlight-to-comment layer.
    var services: SessionServices?

    /// The host-injected services, used when `services` is nil (see `BrowserSurface.services`).
    @Environment(\.widgetSessionServices) private var environmentServices

    /// Plugin selection resolver, forwarded from `BrowserSurface`.
    var selectionResolver: WebSelectionResolver?

    /// The host's link router (see `WidgetLinkRouter`): links clicked in the page are offered to
    /// the host before they navigate in place.
    @Environment(\.widgetLinkRouter) private var linkRouter

    /// When `true`, the host's widget-chrome engine owns and renders the browser
    /// chrome row in the widget header (AC7). Skip the in-body chrome row +
    /// divider here to avoid a double header. The find-bar overlay and
    /// empty-tab placeholder still render in the body.
    @Environment(\.browserChromeHostOwned) private var chromeHostOwned

    // MARK: - Active tab

    /// The currently-selected tab, or the first tab when `activeTabId` is nil.
    private var activeTab: BrowserTab? {
        if let id = model.activeTabId {
            return model.tabs.first(where: { $0.id == id })
        }
        return model.tabs.first
    }

    // MARK: - Live-view helpers

    /// The per-tab live-view cache key: "<cacheKey>:<tabID>".
    private func tabLiveKey(for tabID: UUID) -> String {
        "\(cacheKey):\(tabID)"
    }

    /// Return (or build) the `WebSectionLiveView` for `tab` at `url`.
    /// The live view is keyed `"<cacheKey>:<tab.id>"` in `BrowserSurfaceCache`
    /// so it survives SwiftUI remounts and tab switches without reloading.
    private func liveView(for tab: BrowserTab, url: URL) -> WebSectionLiveView {
        let sectionSpec = WebSectionSpec(
            url: url,
            selector: spec.selector,
            dataStoreKey: spec.dataStoreKey,
            title: spec.title
        )
        let live = BrowserSurfaceCache.shared.liveView(
            forKey: tabLiveKey(for: tab.id),
            building: sectionSpec
        )
        installLinkRouter(on: live)
        return live
    }

    /// Offer every link clicked in `live` to the host's router (Open Link decides where it opens);
    /// "keep here" loads the URL in this view.
    private func installLinkRouter(on live: WebSectionLiveView) {
        guard let router = linkRouter else {
            live.setLinkRouter(nil)
            live.setInterceptAllLinks(false)
            return
        }
        live.setLinkRouter { [weak live] url in
            router.route(url) { live?.load(url) }
        }
        live.setInterceptAllLinks(true)
    }

    // MARK: - Body

    var body: some View {
        if let tab = activeTab {
            // Resolve the live view when the tab has a URL; nil for empty tabs.
            let live: WebSectionLiveView? = tab.url.map { liveView(for: tab, url: $0) }
            VStack(spacing: 0) {
                // Shared chrome row — rendered when the surface is live and
                // the host does NOT own the chrome header (AC7).
                //
                // When `chromeHostOwned == true`, the app's widget-chrome engine
                // renders an equivalent `BrowserChromeRow` in the widget's header
                // area via `makeWebWidgetChrome`. Skipping the in-body row here
                // prevents a double header (the bug this subtask fixes).
                //
                // When `chromeHostOwned == false` (the default — standalone
                // `BrowserSurface`, previews, or a host not yet routing the chrome
                // to its header), the row renders as before.
                //
                // `@ObservedObject` on `model` ensures the tab bar below the URL
                // capsule re-renders on tab changes. `live?.status` is read here
                // for `@Observable` tracking so the loading spinner updates when
                // navigation status changes.
                if !chromeHostOwned {
                    BrowserChromeRow(
                        icon: spec.icon,
                        label: spec.title ?? "Browser",
                        model: model,
                        onRefresh: {
                            live?.reload()
                        },
                        onGoBack: {
                            live?.webView.goBack()
                        },
                        onGoForward: {
                            live?.webView.goForward()
                        },
                        onNavigate: { navURL in
                            // When a live view exists, load the URL in the webview.
                            // For an empty tab (live == nil): navigateToDraft() already
                            // called updateTab(activeTabId, url:) from the chrome row's
                            // onSubmit, pinning the URL onto the tab. The @ObservedObject
                            // subscription triggers a re-render; the next body evaluation
                            // finds tab.url non-nil and builds the live view automatically.
                            live?.webView.load(URLRequest(url: navURL))
                        },
                        webStatus: live?.status ?? .loaded
                    )
                    Divider()
                }
                if let live {
                    // Web content area: the cached live webview.
                    CachedWebSectionView(live: live)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // Generic highlight-to-comment: select text → "＋" bubble +
                        // composer, and dictate-to-comment, for EVERY browser widget.
                        // Applied only when the host passed services (the composer
                        // sink). Keyed to the live view so it re-wires per tab.
                        .modifier(BrowserSelectionCommentLayer(
                            live: live,
                            composer: BrowserSurface.effectiveServices(explicit: services, environment: environmentServices)?.composer,
                            resolver: selectionResolver,
                            pageURL: { [weak live] in live?.webView.url },
                            pageTitle: { [weak live] in live?.webView.title },
                            fallbackLabel: spec.title
                        ))
                        // Find bar overlay (dewy-flint): shown top-trailing when isFinding.
                        // Renders regardless of chromeHostOwned — the find bar is body
                        // content, not part of the chrome row.
                        .overlay(alignment: .topTrailing) {
                            if model.isFinding {
                                BrowserFindBar(model: model)
                                    .padding(DT.s8)
                            }
                        }
                } else {
                    // Empty-tab placeholder: the active tab has no URL yet.
                    // Typing in the address bar and pressing Return will pin a
                    // URL onto the tab and build its live webview on the next render.
                    // Renders regardless of chromeHostOwned — the placeholder is
                    // body content, not chrome.
                    emptyTabPlaceholder
                }
            }
            // Stable id so SwiftUI knows which content to remount on tab switch.
            .id("surface:\(tab.id)")
            .onAppear {
                // Wire the model to the live view (if any). Empty tabs have no
                // live view yet; wiring happens on the next render after the URL
                // is pinned via navigateToDraft().
                if let live {
                    wireModel(to: live, tab: tab)
                }
            }
            // Re-wire to the new active tab's live view on every tab switch.
            .onChange(of: model.activeTabId) { _, _ in
                guard let newTab = activeTab, let newURL = newTab.url else { return }
                let newLive = liveView(for: newTab, url: newURL)
                wireModel(to: newLive, tab: newTab)
            }
        } else {
            // No tabs at all: transitional state before resolveIfNeeded seeds
            // the first tab. Show a spinner until the model is seeded.
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Empty-tab placeholder

    /// Shown in the content area when the active tab has no URL yet.
    /// Mirrors the built-in browser's "New Tab / Enter a URL in the address
    /// bar above" empty-state pattern — SDK-side, no app types required.
    private var emptyTabPlaceholder: some View {
        VStack(spacing: DT.s12) {
            Image(systemName: "globe")
                .font(.system(size: 32, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("New Tab")
                .font(.system(size: DT.f15, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Enter a URL in the address bar above")
                .font(.system(size: DT.f13))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Model wiring

    /// Wire the shared model to `live` for `tab`:
    ///   - `bind(to:)` sets up Combine KVO to mirror canGoBack/canGoForward/urlDraft.
    ///   - `syncZoom(from:)` reads the tab's pageZoom into `model.zoomPercent`.
    ///   - `activeLiveView` closure lets model find/zoom methods reach the current webview.
    ///   - `onURLChange` tracks in-page navigation onto the tab's URL record.
    ///
    /// Called on `.onAppear` (initial) and on `.onChange(of: model.activeTabId)`
    /// (tab switch) — mirroring `BrowserActiveTab`'s wiring pattern.
    private func wireModel(to live: WebSectionLiveView, tab: BrowserTab) {
        model.bind(to: live.webView)
        model.syncZoom(from: live.webView)
        model.activeLiveView = { [weak live] in live }
        // Track in-page navigation (link clicks, SPA pushState) onto the tab's
        // URL so a remount or tab-template restore reopens the actual visited page.
        live.onURLChange = { [weak model] landed in
            guard let model,
                  model.tabs.first(where: { $0.id == tab.id })?.url != landed
            else { return }
            model.updateTab(tab.id, url: landed)
        }
    }
}
