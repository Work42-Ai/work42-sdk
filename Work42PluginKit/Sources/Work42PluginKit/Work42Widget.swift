// Work42Widget.swift — the widget protocol (feat/custom-widgets.1, AC2).
//
// A custom widget is a class conforming to `Work42Widget`, exported from
// its dylib through the `work42_widget_main` entry point (see
// `Work42PluginKit.swift`). The protocol carries everything the app needs
// to register the widget in the `+ Widget` menu and render it in the
// grid: a stable identity, display metadata, layout availability, minimum
// sizes, an EXPLICIT lifecycle, and a SwiftUI view factory that receives
// the session's services.
//
// Lifecycle discipline: nothing a widget owns may assume app-lifetime.
// `activate(services:)` fires when the widget becomes live in a session
// (open in a tab); `deactivate()` fires when it is closed/torn down and
// must release everything (observers, timers, cached webviews via
// `BrowserSurfaceCache.teardown`). Hot-reload swaps rely on `deactivate()`
// actually cleaning up — a leaked timer from a stale widget version keeps
// firing in-process.
//
// Render-path discipline (the documented AttributeGraph freeze class): a
// widget's `makeView` body must NEVER spawn a synchronous subprocess or
// perform blocking waits — that severs the widget grid's update edges and
// freezes visible tiles. The async `SessionServices.shell` exists
// precisely so widget code never needs `Process`.

import SwiftUI

// MARK: - WidgetLayout

// The `WidgetLayout` surface-allow-list enum was deleted in data-driven-
// session-surfaces s7: every widget is now available on every surface, curated
// only by each surface's `disabled_widget_kind_ids` deny-list. A widget that
// cannot function on a given surface is responsible for its own visible failure
// state, not for declaring where it may appear.

// MARK: - WidgetMinSize

/// Minimum content size (in points) the widget needs to render usefully.
/// The tile engine refuses splits that would shrink a widget below its
/// minimum, so declare honest values. `.zero` (the default) means "no
/// minimum" — the widget can be squeezed arbitrarily.
nonisolated public struct WidgetMinSize: Codable, Sendable, Equatable {

    /// Minimum width in points. 0 = unconstrained.
    public var width: Double

    /// Minimum height in points. 0 = unconstrained.
    public var height: Double

    public init(width: Double = 0, height: Double = 0) {
        self.width = width
        self.height = height
    }

    /// No minimum in either dimension.
    public static let zero = WidgetMinSize()
}

// MARK: - WidgetIntentPlacement

/// Where a widget's intent is invokable from. `.palette` (always implied)
/// makes it reachable via ⌘⇧P / `services.intents.execute`. `.actionArea`
/// ADDITIONALLY promotes it to a visible button in the tab-bar row beside
/// `+ Add Widget`, shown while this widget is open in the active tab — the
/// SAME intent either way, never a second behavior surface ("all the
/// buttons in the end should be just intents").
public enum WidgetIntentPlacement: Sendable, Hashable {
    case palette
    case actionArea
}

/// How an `.actionArea`-promoted intent renders as a button. Ignored
/// unless the intent's `placement` contains `.actionArea`.
public enum WidgetIntentActionAreaStyle: Sendable {
    /// Icon + text label in a capsule (the default; e.g. "Approve Plan").
    case labeled
    /// Icon only — compact chevron-style controls (e.g. Previous/Next).
    case icon
    /// Text-only pill, no icon (e.g. the calendar "Today" jump).
    case pill
    /// A menu button whose choices are read live when the menu opens. Selecting
    /// a choice invokes the same widget-owned intent handler path as every
    /// other action-area control.
    case menu(
        options: @MainActor @Sendable () -> [WidgetIntentMenuOption],
        onSelect: @MainActor @Sendable (String) async throws -> Void
    )
}

/// One live choice in a widget-declared action-area menu.
nonisolated public struct WidgetIntentMenuOption: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let icon: String?
    public let isSelected: Bool

    public init(id: String, title: String, icon: String? = nil, isSelected: Bool = false) {
        self.id = id
        self.title = title
        self.icon = icon
        self.isSelected = isSelected
    }
}

// MARK: - WidgetHeaderLabel

/// The tint role for a widget-contributed header label. Roles, not raw
/// colors: the host maps each role onto the DT token palette so labels
/// match the session chips in both light and dark mode.
public enum WidgetHeaderLabelTint: Sendable, Hashable {
    /// Muted secondary look — the default, matches informational chips.
    case neutral
    /// Positive/green (e.g. CI passing, approved review).
    case success
    /// Attention/amber (e.g. CI pending, changes requested).
    case warning
    /// Failure/red (e.g. CI failing).
    case failure
    /// The app accent color (e.g. an identity chip like a Jira key).
    case accent
}

/// One label a widget contributes to the SESSION HEADER's metadata strip
/// while the widget is open in the active tab. Widget labels render AFTER
/// the session-provided labels (task status pills, …), in
/// the same chip language (`.sessionChip()`), and disappear when the
/// widget closes. Vendor knowledge lives in the widget: the github widget
/// contributes CI status / reviewers, the jira widget its issue key — the
/// host never learns what they mean.
///
/// Labels are read live from `Work42Widget.headerLabels` during the host's
/// render pass: an `@Observable` widget that mutates its backing storage
/// re-renders the strip automatically (same pattern as `isEnabled`).
public struct WidgetHeaderLabel: Sendable, Hashable {

    /// The label text (short — it renders as a chip).
    public let text: String

    /// Optional SF Symbol shown before the text.
    public let systemIcon: String?

    /// Optional remote image rendered (circle-clipped) before the text —
    /// e.g. a GitHub avatar. Wins over `systemIcon` once loaded; while
    /// loading (or on failure) the host falls back to `systemIcon`.
    public let iconURL: URL?

    /// Tint role mapped by the host onto DT colors. Default `.neutral`.
    public let tint: WidgetHeaderLabelTint

    /// Optional URL opened on click (e.g. the CI run, a reviewer profile).
    /// nil → the label is inert.
    public let url: URL?

    /// Optional raw image bytes (e.g. a PNG brand mark — GitHub / Jira) rendered
    /// as the LEADING icon, rounded-rect (not circle-clipped like `iconURL`), so
    /// a widget can lead its chip with an unambiguous brand logo instead of a
    /// generic SF Symbol. Wins over `iconURL` and `systemIcon` when present. A
    /// widget typically embeds a small PNG and decodes it via
    /// `Data(base64Encoded:)`. Self-contained (no network, unlike `iconURL`).
    public let iconImageData: Data?

    /// Optional brand color as a `#RRGGBB` hex string. When set, the host fills
    /// the chip SOLID with this color (contrasting text/icon) instead of the
    /// semantic `tint` color — so a chip reads as its brand (GitHub dark, Jira
    /// blue). A monochrome `iconImageData` mark is tinted to the contrasting
    /// foreground so it stays legible on the brand fill.
    public let brandColorHex: String?

    /// Optional grouping marker. Consecutive labels (in contribution order) that
    /// share a non-nil `groupId` are rendered by the host as ONE segmented
    /// capsule — a single visual pill split into per-label segments (leading and
    /// trailing corners rounded on the group's first/last segment, hairline
    /// separators between). Each segment keeps its OWN fill, icon, and `url`/hit
    /// area, so an item pill (e.g. a PR) can open its identity segment to the PR
    /// and its status segment to the checks page. `nil` (the default) → the label
    /// renders as a standalone chip exactly as before. Typically the item's
    /// stable id (a PR/issue URL).
    public let groupId: String?

    /// Original init — preserved verbatim so dylibs built against the
    /// iconURL-less SDK keep linking (same discipline as WidgetIntentSpec's
    /// isEnabled addition).
    public init(
        text: String,
        systemIcon: String? = nil,
        tint: WidgetHeaderLabelTint = .neutral,
        url: URL? = nil
    ) {
        self.text = text
        self.systemIcon = systemIcon
        self.iconURL = nil
        self.tint = tint
        self.url = url
        self.iconImageData = nil
        self.brandColorHex = nil
        self.groupId = nil
    }

    public init(
        text: String,
        systemIcon: String? = nil,
        iconURL: URL?,
        tint: WidgetHeaderLabelTint = .neutral,
        url: URL? = nil
    ) {
        self.text = text
        self.systemIcon = systemIcon
        self.iconURL = iconURL
        self.tint = tint
        self.url = url
        self.iconImageData = nil
        self.brandColorHex = nil
        self.groupId = nil
    }

    /// Full init including a leading brand image (`iconImageData`) and optional
    /// `brandColorHex`. Added after the two above; those keep their exact
    /// signatures so already-built dylibs keep linking.
    public init(
        text: String,
        systemIcon: String? = nil,
        iconURL: URL? = nil,
        iconImageData: Data?,
        brandColorHex: String? = nil,
        tint: WidgetHeaderLabelTint = .neutral,
        url: URL? = nil
    ) {
        self.text = text
        self.systemIcon = systemIcon
        self.iconURL = iconURL
        self.tint = tint
        self.url = url
        self.iconImageData = iconImageData
        self.brandColorHex = brandColorHex
        self.groupId = nil
    }

    /// Full init + `groupId` (segmented grouping). Added after the three above
    /// with `groupId` required (no default) so its signature is distinct and
    /// already-built dylibs keep linking against the older inits. Widgets that
    /// emit per-item segmented pills use this one.
    public init(
        text: String,
        systemIcon: String? = nil,
        iconURL: URL? = nil,
        iconImageData: Data? = nil,
        brandColorHex: String? = nil,
        tint: WidgetHeaderLabelTint = .neutral,
        url: URL? = nil,
        groupId: String?
    ) {
        self.text = text
        self.systemIcon = systemIcon
        self.iconURL = iconURL
        self.tint = tint
        self.url = url
        self.iconImageData = iconImageData
        self.brandColorHex = brandColorHex
        self.groupId = groupId
    }
}

// MARK: - WidgetIntentSpec

/// One custom intent a widget contributes to the command palette. The
/// loader namespaces it (`widget.<slug>.<name>`), registers it into the
/// palette's runtime intent store while the widget is loaded, and removes
/// it on unload/reload. The COMMON widget intents (Focus/Add) are provided
/// by the system for every widget — never declared here; a widget declares
/// only its SPECIFIC intents.
///
/// Metadata is data; `perform` is a handler closure. In the later
/// out-of-process phase the metadata crosses XPC as-is and the handler
/// becomes a host-side proxy that routes the call back — declaring intents
/// stays source-compatible.
public struct WidgetIntentSpec: Sendable {

    /// The intent's name — the LAST component of its hierarchical id
    /// (loader prepends `widget.<slug>.`). Lowercase, stable.
    public let name: String

    /// Title shown in the palette row (e.g. "Refresh Deploy Status").
    public let title: String

    /// SF Symbol for the palette row.
    public let icon: String

    /// Optional bundled image bytes for the palette row and action-area button.
    /// When present and decodable, the host renders this image instead of the
    /// SF Symbol; `icon` remains the fail-soft fallback.
    public let iconImageData: Data?

    /// Optional `#RRGGBB` brand colour for the action-area button. A valid value
    /// produces a solid brand fill with a contrast-correct foreground. Nil or an
    /// invalid value keeps the host's existing semantic tint styling.
    public let brandColorHex: String?

    /// Extra fuzzy-match aliases.
    public let keywords: [String]

    /// Where this intent is invokable from. Defaults to palette-only; add
    /// `.actionArea` to also promote it to a tab-bar button (SDK v2).
    public let placement: Set<WidgetIntentPlacement>

    /// Action-area button presentation (SDK v2). Ignored unless
    /// `placement` contains `.actionArea`.
    public let actionAreaStyle: WidgetIntentActionAreaStyle

    /// Optional live-state enablement check for the action-area button (SDK
    /// v4). When non-nil, called on the main actor each time the button
    /// renders; the button is enabled when the closure returns `true` and
    /// dimmed-but-visible when it returns `false`. `nil` (the default) keeps
    /// the button always enabled. Ignored unless `placement` contains
    /// `.actionArea`. The closure is evaluated at render time — not captured
    /// once at registration — so it reflects live state such as the current
    /// browser URL.
    public let isEnabled: (@MainActor () -> Bool)?

    /// Optional live confirmed-state check for the action-area button. A
    /// confirmed control remains visible and tappable even when `isEnabled`
    /// returns false, and the host renders the same control with its filled
    /// success treatment. Nil keeps the existing presentation.
    public let isConfirmed: (@MainActor () -> Bool)?

    /// Optional live label override for the action-area button, queried fresh
    /// on each render (mirrors `isEnabled`/`isConfirmed`) — for an intent whose
    /// visible text tracks session state (e.g. "Approve Plan" → "Plan
    /// approved"). Nil keeps the static `title`.
    public let actionAreaTitle: (@MainActor () -> String)?

    /// Opts the action-area button into a periodic re-render every N seconds
    /// (e.g. a recording timer ticking in `actionAreaTitle` with no other
    /// state change to trigger a redraw). Nil (the default) renders on-demand
    /// only, like every other intent.
    public let livePeriodicTick: TimeInterval?

    /// Service-aware behavior used by built-in widgets and available to plugin
    /// widgets through the same SDK type. The host resolves the active
    /// session's `SessionServices` only when the intent is invoked.
    public let performWithServices: (@MainActor (SessionServices) async throws -> Void)?

    /// Optional reversal handler for a `isConfirmed` control. When set, tapping
    /// the button while confirmed shows the host's native confirmation dialog
    /// instead of re-running `performWithServices`; on confirm, this runs.
    /// Nil (the default) makes a confirmed button inert to taps.
    public let onConfirmedTap: (@MainActor (SessionServices) async throws -> Void)?

    /// The behavior. Runs on the main actor; failures are reported to the
    /// caller (palette or `services.intents.execute`), never swallowed.
    public let perform: @MainActor () async throws -> Void

    /// Designated initialiser — source-compatible with all prior SDK
    /// versions. `isEnabled` defaults to `nil` (always enabled). The
    /// mangled symbol of this overload is unchanged from SDK v3, so dylibs
    /// built against any prior SDK version continue to link without a
    /// version-mismatch error.
    public init(
        name: String,
        title: String,
        icon: String,
        keywords: [String] = [],
        placement: Set<WidgetIntentPlacement> = [.palette],
        actionAreaStyle: WidgetIntentActionAreaStyle = .labeled,
        perform: @escaping @MainActor () async throws -> Void
    ) {
        self.name = name
        self.title = title
        self.icon = icon
        self.iconImageData = nil
        self.brandColorHex = nil
        self.keywords = keywords
        self.placement = placement
        self.actionAreaStyle = actionAreaStyle
        self.isEnabled = nil
        self.isConfirmed = nil
        self.actionAreaTitle = nil
        self.livePeriodicTick = nil
        self.performWithServices = nil
        self.onConfirmedTap = nil
        self.perform = perform
    }

    /// Use this overload when the action-area button's availability depends
    /// on live state. Pass a closure that reads the current state and returns
    /// `false` to dim the button. The label is `isEnabled:` so call sites
    /// are unambiguous — the compiler picks the 7-parameter overload above
    /// when `isEnabled:` is absent.
    public init(
        name: String,
        title: String,
        icon: String,
        brandColorHex: String? = nil,
        keywords: [String] = [],
        placement: Set<WidgetIntentPlacement> = [.palette],
        actionAreaStyle: WidgetIntentActionAreaStyle = .labeled,
        isEnabled: (@MainActor () -> Bool)?,
        actionAreaTitle: (@MainActor () -> String)? = nil,
        livePeriodicTick: TimeInterval? = nil,
        perform: @escaping @MainActor () async throws -> Void
    ) {
        self.name = name
        self.title = title
        self.icon = icon
        self.iconImageData = nil
        self.brandColorHex = brandColorHex
        self.keywords = keywords
        self.placement = placement
        self.actionAreaStyle = actionAreaStyle
        self.isEnabled = isEnabled
        self.isConfirmed = nil
        self.actionAreaTitle = actionAreaTitle
        self.livePeriodicTick = livePeriodicTick
        self.performWithServices = nil
        self.onConfirmedTap = nil
        self.perform = perform
    }

    /// SDK v6 branded-intent initializer. `iconImageData` is deliberately a
    /// required argument so this overload remains distinct from the preserved
    /// pre-v6 initializers above.
    public init(
        name: String,
        title: String,
        icon: String,
        iconImageData: Data?,
        brandColorHex: String? = nil,
        keywords: [String] = [],
        placement: Set<WidgetIntentPlacement> = [.palette],
        actionAreaStyle: WidgetIntentActionAreaStyle = .labeled,
        isEnabled: (@MainActor () -> Bool)? = nil,
        perform: @escaping @MainActor () async throws -> Void
    ) {
        self.name = name
        self.title = title
        self.icon = icon
        self.iconImageData = iconImageData
        self.brandColorHex = brandColorHex
        self.keywords = keywords
        self.placement = placement
        self.actionAreaStyle = actionAreaStyle
        self.isEnabled = isEnabled
        self.isConfirmed = nil
        self.actionAreaTitle = nil
        self.livePeriodicTick = nil
        self.performWithServices = nil
        self.onConfirmedTap = nil
        self.perform = perform
    }

    /// SDK v7 service-aware initializer. The active session service bundle is
    /// resolved by the host at invocation time, so a process-wide catalog never
    /// captures stale session state.
    public init(
        name: String,
        title: String,
        icon: String,
        iconImageData: Data? = nil,
        brandColorHex: String? = nil,
        keywords: [String] = [],
        placement: Set<WidgetIntentPlacement> = [.palette],
        actionAreaStyle: WidgetIntentActionAreaStyle = .labeled,
        isEnabled: (@MainActor () -> Bool)? = nil,
        isConfirmed: (@MainActor () -> Bool)?,
        actionAreaTitle: (@MainActor () -> String)? = nil,
        onConfirmedTap: (@MainActor (SessionServices) async throws -> Void)? = nil,
        performWithServices: @escaping @MainActor (SessionServices) async throws -> Void
    ) {
        self.name = name
        self.title = title
        self.icon = icon
        self.iconImageData = iconImageData
        self.brandColorHex = brandColorHex
        self.keywords = keywords
        self.placement = placement
        self.actionAreaStyle = actionAreaStyle
        self.isEnabled = isEnabled
        self.isConfirmed = isConfirmed
        self.actionAreaTitle = actionAreaTitle
        self.livePeriodicTick = nil
        self.performWithServices = performWithServices
        self.onConfirmedTap = onConfirmedTap
        self.perform = {}
    }
}

// MARK: - WidgetLinkIntentSpec

/// One way a widget can claim a canonical URL passed to Work42's global
/// `Open Link` intent. Matching is host-owned: regex declarations outrank
/// scheme declarations, which outrank the wildcard fallback.
public enum WidgetLinkMatcher: Sendable, Hashable {
    /// A regular expression evaluated against `URL.absoluteString`.
    case regex(String)
    /// A URL scheme, compared case-insensitively (for example `file`).
    case scheme(String)
    /// The least-specific fallback. The built-in Browser uses this matcher.
    case wildcard
}

/// A widget-owned link handler. The host chooses the best eligible widget,
/// reveals it, then invokes `perform` with only the canonical URL.
public struct WidgetLinkIntentSpec: Sendable {
    public let matchers: [WidgetLinkMatcher]
    public let perform: @MainActor @Sendable (URL) async throws -> Void

    public init(
        matchers: [WidgetLinkMatcher],
        perform: @escaping @MainActor @Sendable (URL) async throws -> Void
    ) {
        self.matchers = matchers
        self.perform = perform
    }
}

// MARK: - Work42Widget

/// One custom widget. Conform with a class (reference semantics — the
/// loader holds the single instance across activations), export it via
/// `work42_widget_main`, and the app takes it from there: `+ Widget` menu
/// registration under "My Widgets" (kindId `widget:<id>`), saved-layout
/// round-trips, and grid rendering through the same per-widget observation
/// path as built-ins.
///
/// `@MainActor` because the factory produces SwiftUI views and the
/// lifecycle callbacks fire from UI code. Widget packages compile with
/// main-actor default isolation (the scaffold template sets
/// `.defaultIsolation(MainActor.self)`, matching the app), so conformances
/// need no extra annotation.
@MainActor
public protocol Work42Widget: AnyObject {

    /// Stable identity — the widget's slug (`WidgetSDK.isValidSlug`).
    /// Becomes the catalog kindId `widget:<id>` and the persistence key in
    /// saved tab layouts; changing it orphans existing layouts.
    var id: String { get }

    /// Human-facing title shown in the `+ Widget` menu and widget chrome.
    var title: String { get }

    /// SF Symbol name for the menu row and chrome icon. Used as the fallback
    /// whenever `iconImageData` is nil or cannot be decoded.
    var icon: String { get }

    /// Optional bundled image bytes for the widget's menu/tile and chrome icon.
    /// SDK v6 hosts prefer this image and fail soft to `icon`.
    var iconImageData: Data? { get }

    // `enabledLayouts` was removed in data-driven-session-surfaces s7 — every
    // widget is available on every surface; per-surface curation is the host's
    // `disabled_widget_kind_ids` deny-list, not a widget-declared allow-list.

    /// Minimum useful content size. Defaults to `.zero` (no minimum).
    var minSize: WidgetMinSize { get }

    /// The widget's SPECIFIC palette intents (see `WidgetIntentSpec` — the
    /// common Focus/Add intents are system-provided, never declared).
    /// Defaults to none.
    var intents: [WidgetIntentSpec] { get }

    /// The canonical URLs this widget can open. This declaration is required:
    /// widgets that do not handle links explicitly return `[]`.
    var linkIntents: [WidgetLinkIntentSpec] { get }

    /// The storage namespace this widget writes to via
    /// `SessionServices.storage.set`/`.delete` (task42-plugin-conversion,
    /// s3). `nil` (the default) means "my own slug" — the existing behavior.
    /// A widget declares a DIFFERENT namespace when it must write into a
    /// shared address other widgets/gates also read (e.g. a `spec` widget
    /// writing `plan/approved_at` alongside a `subtasks` widget writing
    /// `plan/subtasks`, both under namespace `plan`).
    var storageNamespace: String? { get }

    /// The widget became live in a session (opened in a tab, or restored
    /// with a saved layout). Acquire resources here — never earlier: the
    /// instance existing does NOT mean the widget is on screen.
    /// Default: no-op.
    func activate(services: SessionServices)

    /// The widget was closed / its session tore down / a hot-reload is
    /// swapping in a newer version. Release EVERYTHING acquired in
    /// `activate` (observers, timers, `BrowserSurfaceCache` entries).
    /// Nothing may assume app-lifetime. Default: no-op.
    func deactivate()

    /// Produce the widget's SwiftUI view. Called when the widget mounts in
    /// the grid; `services` is the same session-scoped instance passed to
    /// `activate`. Return the view type-erased — the boundary is
    /// existential by design so the ABI never depends on a concrete view
    /// type.
    func makeView(services: SessionServices) -> AnyView
}

// MARK: - Work42WidgetHeaderLabels

/// Opt-in protocol for widgets that contribute labels to the session
/// header's metadata strip (see `WidgetHeaderLabel`). A SEPARATE protocol —
/// not a `Work42Widget` requirement — following the
/// `Work42BrowserWidgetOptions` pattern so the addition is ABI-safe for
/// dylibs compiled before it existed (the host discovers support via a
/// conditional cast; non-conforming widgets simply contribute nothing).
public protocol Work42WidgetHeaderLabels: AnyObject {

    /// Labels contributed while this widget is open in the active tab.
    /// Read live during the host's render pass — mutate backing
    /// `@Observable` state to update the strip.
    var headerLabels: [WidgetHeaderLabel] { get }
}

// MARK: - Work42WidgetCustomHeader

/// Optional native-header surface for a custom widget.
///
/// This is deliberately separate from `Work42Widget`: the host discovers it
/// with a conditional cast, so widgets compiled against older SDKs keep their
/// existing generic header and ABI. Work42 still owns and appends the widget's
/// move and close controls after this view.
@MainActor
public protocol Work42WidgetCustomHeader: Work42Widget {

    /// A live SwiftUI header view. Return a child view that observes the
    /// widget's state when the header must update as navigation changes.
    func makeHeaderView() -> AnyView

    /// Padding applied around the widget's content below the native header.
    var contentPadding: Double { get }
}

extension Work42Widget {

    /// Default keeps every SF-Symbol-only widget source-compatible with SDK v6.
    public var iconImageData: Data? { nil }

    /// Default: no minimum size.
    public var minSize: WidgetMinSize { .zero }

    /// Default: no widget-specific intents.
    public var intents: [WidgetIntentSpec] { [] }

    /// Default: write to my own slug (unchanged behavior for every widget
    /// compiled before this member existed).
    public var storageNamespace: String? { nil }

    /// Default lifecycle: nothing to acquire.
    public func activate(services: SessionServices) {}

    /// Default lifecycle: nothing to release.
    public func deactivate() {}
}

// MARK: - Work42BrowserWidgetOptions

/// Optional opt-out protocol for browser-based custom widgets that prefer the
/// generic title header over the browser chrome row.
///
/// ## Default behaviour (no conformance required)
///
/// By default, any custom widget whose `BrowserSurface` resolves with a model
/// keyed by the widget's `id` gets the full browser chrome row AS its widget
/// header — the same `makeWebWidgetChrome` path the built-in Browser, Jira,
/// and GitHub PR widgets use. No declaration is required to gain this treatment:
/// existing widgets (compiled against any prior SDK version) acquire the browser
/// header automatically when the app is updated.
///
/// ## Opting out
///
/// Conform to `Work42BrowserWidgetOptions` AND return `true` from
/// `prefersDefaultWidgetHeader` to keep the generic title-bar header instead:
///
/// ```swift
/// final class MyWidget: Work42Widget, Work42BrowserWidgetOptions {
///     var prefersDefaultWidgetHeader: Bool { true }
///     // ... rest of Work42Widget ...
/// }
/// ```
///
/// A widget that does NOT need to opt out must NOT conform to this protocol
/// (or may conform with `prefersDefaultWidgetHeader` returning `false`, which
/// is identical to not conforming at all).
///
/// ## ABI safety — no version bump required
///
/// This is a SEPARATE, OPTIONAL protocol rather than a new requirement on
/// `Work42Widget`. The host checks conformance via `as? any Work42BrowserWidgetOptions`
/// before calling `prefersDefaultWidgetHeader`. For an old dylib that does not
/// declare conformance, the cast safely returns `nil` and the host uses the
/// default behaviour (browser chrome header). No Protocol Witness Table slot
/// is added to `Work42Widget`, so `WidgetSDK.abiVersion` stays at 3 — old
/// dylibs load without a version-mismatch error and gain the browser header
/// automatically, which is the intended behavior.
@MainActor
public protocol Work42BrowserWidgetOptions: Work42Widget {

    /// Return `true` to use the standard generic title header instead of the
    /// browser chrome header for this widget. Return `false` (or omit this
    /// protocol entirely) for the default browser-chrome treatment.
    var prefersDefaultWidgetHeader: Bool { get }
}
