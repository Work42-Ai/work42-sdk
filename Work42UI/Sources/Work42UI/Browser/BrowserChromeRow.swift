// BrowserChromeRow.swift - The browser navigation header shared by all
// embedded-web widgets (Browser, Jira, GitHub PR, Canvas).
//
// Moved from Work42App/Browser/ to Work42UI
// (browser-widgets-not-extending-from-browser.1).
//
// Rendered INSIDE WidgetChrome's header area — it replaces the default title
// area. The close button is provided by WidgetChrome, not here.
//
// Layout (feat/ui-improvements-over-browser.1):
//   Row:  [icon+label] | [‹] [↺] [›] [[+] ── URL capsule ──] [⌖ picker] [accessory?] [zoom?] [loading?]
//   Below (when tabs > 1): BrowserTabBar (hidden when model.showsTabBar is false)
//
// Navigation button group:
//   ‹ (back), ↺ (refresh), › (forward)
//
// URL capsule:
//   + (new-tab, calls model.onNewTab), URL field (no search icon)
//
// Trailing button group:
//   ⌖ (lanky-pine viewfinder/picker toggle — the canonical highlight affordance)
//   optional per-widget accessory (Preview's Record control)
//   zoom percentage (when zoom is not 100%)
//   spinner (while webStatus == .loading)
//
// Removed (humble-harbor.6):
//   - CSS selector-isolation button (rectangle.dashed) — gone
//   - clear-cache trailingActions — not rendered (trailingActions param kept for compat)
//
// Removed by rebase reconciliation:
//   - onHighlight callback button — superseded by lanky-pine's isPicking viewfinder
//     toggle; callers that previously used onHighlight should wire BrowserHighlightLayer
//     instead (SessionDetailPanel.prWidgetContent already does this on main).
//
// BrowserSelectorRow: retained as an empty-view stub so any remaining call
// sites continue to compile. It renders nothing.

import AppKit
import SwiftUI
// WebSectionStatus is declared in Work42UI (WebSectionView.swift, lanky-pine.3)

// MARK: - BrowserBookmarkControl

/// The app-supplied "add this page to Bookmarks" (★) control for the browser
/// chrome (feat/home-labels .5). Bookmark storage is app-side, so the app host
/// builds this value; Work42UI's `BrowserChromeRow` only renders the star and
/// presents the supplied add popover. `isBookmarked` drives the filled star;
/// `removeCurrent` runs when the star is tapped while already bookmarked;
/// `popover` supplies the add-bookmark form shown when tapped on a new page.
@MainActor
public struct BrowserBookmarkControl {
    public let isBookmarked: Bool
    public let removeCurrent: (() -> Void)?
    public let popover: (() -> AnyView)?

    public init(
        isBookmarked: Bool,
        removeCurrent: (() -> Void)? = nil,
        popover: (() -> AnyView)? = nil
    ) {
        self.isBookmarked = isBookmarked
        self.removeCurrent = removeCurrent
        self.popover = popover
    }
}

// MARK: - BrowserChromeRow

/// The compact browser navigation row:
///   [icon+label] | [‹] [↺] [›] [[+] ── URL capsule ──] [⌖ picker] [accessory?] [zoom?] [spinner?]
/// Rendered inside WidgetChrome's header area. BrowserTabBar appears below when
/// the model has more than one tab.
///
/// Uses `@ObservedObject` (not `@Bindable`) so that tab-count changes reliably
/// trigger a re-render even when this view is hosted inside an `AnyView`-erased
/// header (`WidgetChrome.headerContent`). `BrowserWidgetModel` conforms to both
/// `@Observable` and `ObservableObject`; tab mutations call `objectWillChange.send()`
/// so `@ObservedObject` observers are always notified. `$model.urlDraft` bindings
/// work via `@ObservedObject`'s dynamic-member-lookup projected value.
@MainActor
public struct BrowserChromeRow: View {

    /// Shared outer height for the three Liquid Glass control groups.
    private static let controlGroupHeight: CGFloat = 40

    public let icon: String          // SF Symbol name for the widget type (e.g. "globe", "ticket")
    public let iconImageData: Data?  // Bundled brand mark; `icon` remains the fallback.
    public let label: String         // Widget name shown left of the nav (e.g. "Browser", "Jira")
    @ObservedObject public var model: BrowserWidgetModel
    public let onRefresh: () -> Void

    /// Called when the user taps the back chevron. Disabled when model.canGoBack is false.
    public var onGoBack: () -> Void = {}
    /// Called when the user taps the forward chevron. Disabled when model.canGoForward is false.
    public var onGoForward: () -> Void = {}
    /// Called after the user submits the URL capsule field and the model resolves a URL.
    public var onNavigate: ((URL) -> Void)? = nil

    /// Accepted for backward-compat with any remaining call sites. Not rendered
    /// in the trimmed button set.
    public var trailingActions: AnyView = AnyView(EmptyView())

    /// Optional per-widget control rendered inside the trailing glass pill,
    /// immediately after the element picker (e.g. Preview's Record button).
    public var pillAccessory: AnyView = AnyView(EmptyView())

    /// Optional tint for the entire trailing pill. Preview supplies red while
    /// recording; other browser widgets leave the shared pill neutral.
    public var pillTint: Color? = nil

    /// The widget's own controls (move menu ⋯ + close ✕), handed down by
    /// WidgetChrome. Rendered at the right end of the chrome (TOP) row so they
    /// align with the top of the header — which lets the tab bar below span the
    /// FULL width of the header instead of leaving a gap for these controls.
    public var trailingControls: AnyView = AnyView(EmptyView())

    /// Navigation lifecycle status published by `WebSectionLiveView.status` (lanky-pine.3 / AC10).
    /// Drives the compact loading affordance in the chrome row.
    public var webStatus: WebSectionStatus = .loaded

    /// Optional "add this page to Bookmarks" (★) control rendered at the TRAILING
    /// edge of the URL capsule (feat/home-labels .5). Nil = no star (e.g. no page
    /// loaded, or no project). The app-side host builds it since bookmark storage
    /// is app-side; Work42UI only renders the star + presents the supplied popover.
    public var bookmarkControl: BrowserBookmarkControl? = nil

    /// Drives the add-bookmark popover shown when the ★ is tapped on a not-yet-
    /// bookmarked page.
    @State private var showBookmarkPopover = false

    /// Drives keyboard focus into the URL TextField when `model.urlFocusNonce`
    /// is incremented (via `model.focusURL()` / ⌘L intent — dewy-flint.5 / AC12).
    /// Boolean because the URL capsule has exactly one focusable field.
    /// macOS `NSTextField` selects all text automatically on `becomeFirstResponder`,
    /// so setting this to true both focuses and selects the current URL contents.
    @FocusState private var isURLFieldFocused: Bool

    public init(
        icon: String,
        iconImageData: Data? = nil,
        label: String,
        model: BrowserWidgetModel,
        onRefresh: @escaping () -> Void,
        onGoBack: @escaping () -> Void = {},
        onGoForward: @escaping () -> Void = {},
        onNavigate: ((URL) -> Void)? = nil,
        trailingActions: AnyView = AnyView(EmptyView()),
        pillAccessory: AnyView = AnyView(EmptyView()),
        pillTint: Color? = nil,
        trailingControls: AnyView = AnyView(EmptyView()),
        webStatus: WebSectionStatus = .loaded,
        bookmarkControl: BrowserBookmarkControl? = nil
    ) {
        self.icon = icon
        self.iconImageData = iconImageData
        self.label = label
        self.model = model
        self.onRefresh = onRefresh
        self.onGoBack = onGoBack
        self.onGoForward = onGoForward
        self.onNavigate = onNavigate
        self.trailingActions = trailingActions
        self.pillAccessory = pillAccessory
        self.pillTint = pillTint
        self.trailingControls = trailingControls
        self.webStatus = webStatus
        self.bookmarkControl = bookmarkControl
    }

    public var body: some View {
        VStack(spacing: 0) {
            chromeRow
            if model.showsTabBar {
                BrowserTabBar(
                    tabs: model.tabs,
                    activeTabId: model.activeTabId,
                    onSelect: { id in model.selectTab(id) },
                    onClose:  { id in model.closeTab(id) }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.82), value: model.showsTabBar)
    }

    // MARK: - Chrome row

    private var chromeRow: some View {
        HStack(spacing: DT.s8) {
            // Widget label (icon + name) — compact left anchor
            HStack(spacing: 4) {
                if let data = iconImageData, let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 11, height: 11)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                Text(label)
                    .font(.system(size: DT.f12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.trailing, 4)
            .overlay(alignment: .trailing) {
                Rectangle().fill(.primary.opacity(0.07)).frame(width: 1)
                    .offset(x: 4)
            }

            // Back + Refresh + Forward grouped pill (refresh sits between the
            // two chevrons).
            Toolbar {
                Button(action: onGoBack) {
                    ZStack {
                        Color.clear
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(model.canGoBack ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    }
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.canGoBack)
                .help("Back")

                // Refresh — between back and forward.
                Button(action: onRefresh) {
                    ZStack {
                        Color.clear
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AnyShapeStyle(.primary))
                    }
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Refresh")

                Button(action: onGoForward) {
                    ZStack {
                        Color.clear
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(model.canGoForward ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    }
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.canGoForward)
                .help("Forward")
            }
            .frame(height: Self.controlGroupHeight)

            // URL capsule — dominant flex element. The + new-tab control lives
            // at the capsule's leading edge (there is no search icon).
            HStack(spacing: DT.s8) {
                Button {
                    model.onNewTab?()
                } label: {
                    ZStack {
                        Color.clear
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AnyShapeStyle(.primary))
                    }
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New tab")
                if model.canEditURL {
                    TextField("Search or enter website name", text: $model.urlDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: DT.f13))
                        .frame(maxHeight: .infinity)
                        // Wire @FocusState so model.focusURL() / ⌘L can move
                        // first-responder here (dewy-flint.5 / AC12).
                        .focused($isURLFieldFocused)
                        .onSubmit {
                            model.navigateToDraft()
                            if let url = model.url {
                                onNavigate?(url)
                            }
                        }
                        // Observe urlFocusNonce: each increment means the ⌘L
                        // intent fired. Flip focus on; macOS NSTextField
                        // automatically selects all text on becomeFirstResponder
                        // (same behavior as clicking the URL bar in Safari).
                        // `model.focusURL()` already no-ops when canEditURL is
                        // false (Canvas — AC12), so no extra guard is needed here.
                        .onChange(of: model.urlFocusNonce) { _, _ in
                            isURLFieldFocused = true
                        }
                } else {
                    Text(model.urlDraft)
                        .font(.system(size: DT.f13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                // ★ Add-current-page control at the capsule's TRAILING edge
                // (Safari-style; the + new-tab is at the leading edge). Filled
                // when the current page is already bookmarked — tapping then
                // removes it; otherwise tapping opens the app-supplied add popover.
                if let bc = bookmarkControl {
                    Button {
                        if bc.isBookmarked {
                            bc.removeCurrent?()
                        } else {
                            showBookmarkPopover = true
                        }
                    } label: {
                        ZStack {
                            Color.clear
                            Image(systemName: bc.isBookmarked ? "star.fill" : "star")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(bc.isBookmarked
                                    ? AnyShapeStyle(DT.systemAccent) : AnyShapeStyle(.tertiary))
                        }
                        .frame(width: 28, height: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(bc.isBookmarked
                        ? "Remove this page from Bookmarks"
                        : "Add this page to Bookmarks")
                    .popover(isPresented: $showBookmarkPopover, arrowEdge: .bottom) {
                        if let content = bc.popover { content() }
                    }
                }
            }
            .padding(.horizontal, DT.s12)
            .frame(height: Self.controlGroupHeight)
            .frame(maxWidth: .infinity)
            .glassCapsuleSurface()
            .contentShape(Capsule())
            .onTapGesture {
                if model.canEditURL { isURLFieldFocused = true }
            }

            // Trailing controls: picker | accessory? | zoom? | loading?
            // (+ new-tab moved into the URL capsule; refresh moved into the nav pill.)
            Toolbar(tint: pillTint) {
                // Element picker toggle (lanky-pine.5 / AC1). Arms/disarms the
                // element-picker overlay in the WKWebView, wired by BrowserHighlightLayer.
                // accentColor when active, tertiary when inactive.
                // This is the canonical highlight affordance — replaces the old
                // onHighlight callback button from humble-harbor.6.
                Button {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
                        if model.isPicking { model.closePicker() } else { model.openPicker() }
                    }
                } label: {
                    ZStack {
                        Color.clear
                        Image(systemName: "viewfinder")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(model.isPicking ? AnyShapeStyle(DT.systemAccent) : AnyShapeStyle(.tertiary))
                    }
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Highlight element for the agent")

                pillAccessory

                // Zoom-percentage pill (dewy-flint.3 / AC9): shown only when the
                // active tab's zoom is not 100%. Clicking resets zoom to 100%.
                if model.zoomPercent != 100 {
                    Button(action: { model.resetZoom() }) {
                        Text("\(model.zoomPercent)%")
                            .font(.system(size: DT.f11, weight: .medium).monospacedDigit())
                            .foregroundStyle(AnyShapeStyle(.primary))
                            .padding(.horizontal, DT.s4)
                    }
                    .buttonStyle(.plain)
                    .help("Reset zoom")
                }

                // Loading affordance (lanky-pine.5 / AC10). A compact spinner shown
                // while `webStatus == .loading`.
                if webStatus == .loading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.55)
                        .frame(width: 20, height: 20)
                        .frame(width: 26, height: 26)
                }
            }
            .frame(height: Self.controlGroupHeight)

            // Widget controls (⋯ move menu + ✕ close) handed down by
            // WidgetChrome, pinned to this top row.
            trailingControls
        }
        .padding(.horizontal, DT.s8)
        .frame(height: Self.controlGroupHeight)
    }
}

// MARK: - BrowserSelectorRow (compat stub — renders nothing)
//
// The selector-isolation UI has been removed (humble-harbor.6). This struct is
// kept as an empty-view stub so any remaining call sites continue to compile
// without modification. Rendering this view produces no visible output.

public struct BrowserSelectorRow: View {
    // Keep the ObservedObject init param for call-site compat.
    @ObservedObject public var model: BrowserWidgetModel

    public init(model: BrowserWidgetModel) {
        self.model = model
    }

    public var body: some View {
        EmptyView()
    }
}
