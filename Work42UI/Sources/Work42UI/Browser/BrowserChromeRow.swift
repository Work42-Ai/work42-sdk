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

import Combine
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import SwiftUI
// WebSectionStatus is declared in Work42UI (WebSectionView.swift, lanky-pine.3)

private struct AddressWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
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
    private static var controlGroupHeight: CGFloat { TileMetrics.controlHeight }

    public let icon: String          // SF Symbol name for the widget type (e.g. "globe", "ticket")
    public let iconImageData: Data?  // Bundled brand mark; `icon` remains the fallback.
    public let label: String         // Widget name shown left of the nav (e.g. "Browser", "Jira")
    @ObservedObject public var model: BrowserWidgetModel
    public let onRefresh: () -> Void

    /// Called when the user taps the back chevron. Disabled when model.canGoBack is false.
    public var onGoBack: () -> Void = {}
    /// Called when the user taps the forward chevron. Disabled when model.canGoForward is false.
    public var onGoForward: () -> Void = {}
    /// Called when the user taps Stop (shown in place of Refresh while a page is loading).
    public var onStop: () -> Void = {}
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

    private var isLoading: Bool {
        if case .loading = webStatus { return true }
        return false
    }

    /// Drives keyboard focus into the URL TextField when `model.urlFocusNonce`
    /// is incremented (via `model.focusURL()` / ⌘L intent — dewy-flint.5 / AC12).
    /// Boolean because the URL capsule has exactly one focusable field.
    /// macOS `NSTextField` selects all text automatically on `becomeFirstResponder`,
    /// so setting this to true both focuses and selects the current URL contents.
    @FocusState private var isURLFieldFocused: Bool

    /// The tile's controls pill, when the tile offers it to this header to place (see `TileHeaderControls`).
    @Environment(\.tileHeaderControls) private var hostedControls

    /// The address capsule's width: the widget's name before the address needs room, so it drops to the mark alone below
    /// `namePrefixMinWidth` (WOR-807).
    @State private var addressWidth: CGFloat = .infinity
    static var namePrefixMinWidth: CGFloat { 280 }

    /// Whether the capsule has room for the name as well as the mark.
    static func showsName(addressWidth: CGFloat) -> Bool { addressWidth >= namePrefixMinWidth }

    /// The widget's mark in the slot a favicon would take, then its name as a muted prefix and a "·" before the address
    /// ("Browser · example.com"). Short of space only the mark stays.
    @ViewBuilder
    private var identityPrefix: some View {
        HStack(spacing: DT.s4) {
            identityMark
            if Self.showsName(addressWidth: addressWidth) {
                Text(label)
                    .font(.system(size: DT.f13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                Text("·")
                    .font(.system(size: DT.f13))
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var identityMark: some View {
        if let image = iconImageData.flatMap(Self.platformImage) {
            image.resizable().scaledToFit().frame(width: 14, height: 14)
        } else {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
        }
    }

    private static func platformImage(_ data: Data) -> Image? {
        #if canImport(AppKit)
        NSImage(data: data).map { Image(nsImage: $0) }
        #else
        UIImage(data: data).map { Image(uiImage: $0) }
        #endif
    }

    public init(
        icon: String,
        iconImageData: Data? = nil,
        label: String,
        model: BrowserWidgetModel,
        onRefresh: @escaping () -> Void,
        onGoBack: @escaping () -> Void = {},
        onGoForward: @escaping () -> Void = {},
        onStop: @escaping () -> Void = {},
        onNavigate: ((URL) -> Void)? = nil,
        trailingActions: AnyView = AnyView(EmptyView()),
        pillAccessory: AnyView = AnyView(EmptyView()),
        pillTint: Color? = nil,
        trailingControls: AnyView = AnyView(EmptyView()),
        webStatus: WebSectionStatus = .loaded
    ) {
        self.icon = icon
        self.iconImageData = iconImageData
        self.label = label
        self.model = model
        self.onRefresh = onRefresh
        self.onGoBack = onGoBack
        self.onGoForward = onGoForward
        self.onStop = onStop
        self.onNavigate = onNavigate
        self.trailingActions = trailingActions
        self.pillAccessory = pillAccessory
        self.pillTint = pillTint
        self.trailingControls = trailingControls
        self.webStatus = webStatus
    }

    public var body: some View {
        VStack(spacing: 0) {
            chromeRow
            if model.showsTabBar {
                BrowserTabBar(
                    tabs: model.tabs,
                    activeTabId: model.activeTabId,
                    viewers: model.tabViewers,
                    onSelect: { id in model.selectTab(id) },
                    onClose:  { id in model.closeTab(id) }
                )
                // Someone else's tabs: shown, never switched or closed from here.
                .disabled(model.isReadOnly)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.82), value: model.showsTabBar)
        // Says the controls pill is drawn in the first row, so the tile does not draw its own beside this header.
        .preference(key: TileHeaderHostsControlsKey.self, value: hostedControls != nil)
    }

    // MARK: - Chrome row

    private var chromeRow: some View {
        HStack(spacing: DT.s8) {
            // Back + Refresh + Forward grouped pill (refresh sits between the
            // two chevrons).
            TileControlGroup {
                Button(action: onGoBack) {
                    ZStack {
                        Color.clear
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(model.canGoBack ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    }
                    .frame(width: TileMetrics.controlButtonWidth, height: Self.controlGroupHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.canGoBack)
                .help("Back")
                .accessibilityLabel("Back")

                // Refresh — between back and forward — becomes Stop while a page is loading.
                Button(action: isLoading ? onStop : onRefresh) {
                    ZStack {
                        Color.clear
                        Image(systemName: isLoading ? "xmark" : "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AnyShapeStyle(.primary))
                    }
                    .frame(width: TileMetrics.controlButtonWidth, height: Self.controlGroupHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isLoading ? "Stop" : "Refresh")
                .accessibilityLabel(isLoading ? "Stop loading" : "Refresh")

                Button(action: onGoForward) {
                    ZStack {
                        Color.clear
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(model.canGoForward ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    }
                    .frame(width: TileMetrics.controlButtonWidth, height: Self.controlGroupHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.canGoForward)
                .help("Forward")
                .accessibilityLabel("Forward")
            }
            .disabled(model.isReadOnly)
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
                    .frame(width: Self.controlGroupHeight, height: Self.controlGroupHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New tab")
                .disabled(model.isReadOnly)
                identityPrefix
                if model.isReadOnly {
                    // Someone else's address: it can be selected and copied, not edited.
                    Text(model.urlDraft)
                        .font(.system(size: DT.f13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if model.canEditURL {
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
                        // Leaving the field without submitting shows the page's address again.
                        .onChange(of: isURLFieldFocused) { _, focused in
                            if !focused { model.revertUnsubmittedDraft() }
                        }
                } else {
                    Text(model.urlDraft)
                        .font(.system(size: DT.f13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

            }
            .padding(.horizontal, DT.s12)
            .frame(height: Self.controlGroupHeight)
            .frame(maxWidth: .infinity)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: AddressWidthKey.self, value: proxy.size.width)
                }
            )
            .onPreferenceChange(AddressWidthKey.self) { addressWidth = $0 }
            .tileControlSurface()
            .contentShape(Capsule())
            .onTapGesture {
                if model.canEditURL, !model.isReadOnly { isURLFieldFocused = true }
            }

            // Trailing controls: zoom? | loading? — only while there is something to show, so no empty pill sits in the row.
            // (+ new-tab moved into the URL capsule; refresh moved into the nav pill; the element picker is gone and Record is
            // a segment of the tile's pill, WOR-807.)
            if model.zoomPercent != 100 || webStatus == .loading {
            TileControlGroup(tint: pillTint) {
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

                // Loading affordance (lanky-pine.5 / AC10). The compact glass logo loader
                // shown while `webStatus == .loading`.
                if webStatus == .loading {
                    LoadingIndicator(size: .small)
                }
            }
            .disabled(model.isReadOnly)
            .frame(height: Self.controlGroupHeight)
            }

            // Widget controls (⋯ move menu + ✕ close) handed down by
            // WidgetChrome, pinned to this top row. A tile that offers its controls pill (`tileHeaderControls`) gets it here, so the
            // tab bar below runs the tile's full width instead of stopping short of the pill (N3).
            if let hostedControls {
                hostedControls
            } else {
                trailingControls
            }
        }
        .padding(.horizontal, TileMetrics.chromeRowInset)
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
