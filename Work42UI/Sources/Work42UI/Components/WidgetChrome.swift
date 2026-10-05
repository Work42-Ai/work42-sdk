// WidgetChrome.swift - Per-widget chrome configuration and move-target descriptor.
//
// Moved to Work42UI (browser-widgets-not-extending-from-browser.1) so that
// BrowserWidgetChrome.swift can live in the framework and both the session panel
// and the Home surface keep compiling via `import Work42UI` with no import churn.
//
// Work42App/Common/Widgets/WidgetGrid.swift previously defined these types and
// retains all the widget-card views (WidgetCard, FloatingWidgetCard, etc.) that
// compose WidgetChrome — those view types are app-side and stay in Work42App.

import SwiftUI

// MARK: - WidgetMoveOptions

/// Describes the targets a widget can be moved to via the per-widget `…` menu.
/// Carried by `WidgetCard` and used to build the move submenu in the card's
/// header. Nil means the widget can't be moved — the menu button isn't rendered.
public struct WidgetMoveOptions {
    /// Destinations the widget can be moved INTO, in display order. The current
    /// surface is excluded by the caller, so each entry is a valid target.
    public let targets: [Target]
    /// Move the widget to the destination at the given index.
    public let onMoveTo: (Int) -> Void
    /// Create a new destination containing this widget and switch to it.
    public let onMoveToNewTab: () -> Void

    public init(targets: [Target], onMoveTo: @escaping (Int) -> Void, onMoveToNewTab: @escaping () -> Void) {
        self.targets = targets
        self.onMoveTo = onMoveTo
        self.onMoveToNewTab = onMoveToNewTab
    }

    public struct Target: Hashable {
        public let tabIndex: Int
        public let name: String

        public init(tabIndex: Int, name: String) {
            self.tabIndex = tabIndex
            self.name = name
        }
    }
}

// MARK: - WidgetChrome

/// The chrome a single widget wears: its header title + glyph, whether it can be
/// closed (and how), arbitrary trailing header `actions`, and the move/rearrange
/// menu. Built by `WidgetGridConfig.chrome` for each widget id.
public struct WidgetChrome<Actions: View> {
    public let title: String
    /// Retained for back-compat with callers that still pass a glyph; the
    /// design-system header is text-only, so it is currently unused (kept so
    /// re-introducing per-widget glyphs is a one-line `Card` change).
    public let systemImage: String
    public let minWidth: CGFloat
    public let minHeight: CGFloat
    public let contentPadding: CGFloat
    public let canClose: Bool
    public let onClose: () -> Void
    /// Optional "move this widget to…" menu. When non-nil a `⋮` button appears
    /// in the header before the close X.
    public let moveOptions: WidgetMoveOptions?
    /// Extra trailing header controls, placed before the move menu + close X.
    @ViewBuilder public let actions: () -> Actions
    /// When non-nil, replaces the title+icon block in the card header. The
    /// builder RECEIVES the trailing widget controls (`actions` + move menu +
    /// close X) as a ready-to-place `AnyView`, so the header decides where they
    /// sit — letting a multi-row header (e.g. BrowserChromeRow, with a tab bar
    /// below) pin the controls to its TOP row while a full-width second row
    /// spans edge to edge. Set only via the `headerContent:` overload.
    public let headerContent: ((AnyView) -> AnyView)?
    /// When true, `WidgetCard` renders the header as a floating overlay that
    /// slides down on hover (Theme B — floating browser header, AC9–AC13).
    /// When false (default), the header stacks above the content as usual
    /// (AC14 — non-floating widgets are unaffected).
    public let floatingHeader: Bool
    /// AC11 seam — optional external reveal signal for the floating header.
    /// Bind to `BrowserWidgetModel.urlFieldFocused` (or any Bool source) in
    /// subtask .5; the header stays revealed while true, regardless of hover.
    /// Generic (`Binding<Bool>?`) — `WidgetGrid` never imports browser types.
    /// Leave nil for non-floating widgets (the default).
    public let externalReveal: Binding<Bool>?
    /// When non-nil and true, a `floatingHeader` widget is **docked** instead of
    /// floating: the header stacks above the content (reserving its own space,
    /// always visible) so the content behind it stays fully accessible. When
    /// false, the header floats (overlay + top-hover reveal + auto-hide).
    /// Toggled by the pin button in `BrowserChromeRow`. Ignored when
    /// `floatingHeader` is false.
    public let pinned: Binding<Bool>?
    /// Loading / failed / idle state for this widget's content area.
    /// `.idle` (the default) renders nothing extra — existing call sites are
    /// unaffected (AC9). `.loading` shows a centred `LoadingIndicator` via the
    /// S1 anti-flash gate; `.failed` shows the message + an optional Retry button.
    /// The overlay sits ABOVE content (content stays mounted, not replaced).
    public let loadingState: WidgetLoadingState

    public init(
        title: String,
        systemImage: String = "square",
        minWidth: CGFloat = 0,
        minHeight: CGFloat = 0,
        contentPadding: CGFloat = 16,   // DT.s16 value
        canClose: Bool = false,
        onClose: @escaping () -> Void = {},
        moveOptions: WidgetMoveOptions? = nil,
        floatingHeader: Bool = false,
        externalReveal: Binding<Bool>? = nil,
        pinned: Binding<Bool>? = nil,
        loadingState: WidgetLoadingState = .idle,
        @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
    ) {
        self.title = title
        self.systemImage = systemImage
        self.minWidth = minWidth
        self.minHeight = minHeight
        self.contentPadding = contentPadding
        self.canClose = canClose
        self.onClose = onClose
        self.moveOptions = moveOptions
        self.actions = actions
        self.headerContent = nil
        self.floatingHeader = floatingHeader
        self.externalReveal = externalReveal
        self.pinned = pinned
        self.loadingState = loadingState
    }

    /// Overload: `headerContent` replaces the title+icon block in the card
    /// header. The builder RECEIVES the trailing controls (`actions` + move menu
    /// + close X) and places them itself — so the header owns their position.
    /// `title` and `systemImage` are still required so the ghost overlay
    /// can label the placeholder card during column resize drags.
    public init<HC: View>(
        title: String,
        systemImage: String = "square",
        minWidth: CGFloat = 0,
        minHeight: CGFloat = 0,
        contentPadding: CGFloat = 16,
        headerContent: @escaping (_ trailingControls: AnyView) -> HC,
        canClose: Bool = false,
        onClose: @escaping () -> Void = {},
        moveOptions: WidgetMoveOptions? = nil,
        floatingHeader: Bool = false,
        externalReveal: Binding<Bool>? = nil,
        pinned: Binding<Bool>? = nil,
        loadingState: WidgetLoadingState = .idle,
        @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
    ) {
        self.title = title
        self.systemImage = systemImage
        self.minWidth = minWidth
        self.minHeight = minHeight
        self.contentPadding = contentPadding
        self.canClose = canClose
        self.onClose = onClose
        self.moveOptions = moveOptions
        self.actions = actions
        self.headerContent = { trailing in AnyView(headerContent(trailing)) }
        self.floatingHeader = floatingHeader
        self.externalReveal = externalReveal
        self.pinned = pinned
        self.loadingState = loadingState
    }
}
