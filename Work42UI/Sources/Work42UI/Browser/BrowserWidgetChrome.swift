// BrowserWidgetChrome.swift — the SINGLE source of truth for a web widget's
// chrome (Browser / Jira / GitHub PR / Canvas, and the Home-surface browser).
//
// Moved from Work42App/Browser/ to Work42UI
// (browser-widgets-not-extending-from-browser.1) so both the session panel and
// the Home surface share one implementation that can also be consumed by SDK
// code in future subtasks.
//
// The `LiveWidgetBackends` dependency has been replaced by explicit closure
// parameters (injection seam) so this file has no app-side dependencies and
// builds in Work42UI standalone:
//   - `onRefresh`    → caller wraps `backends.cachedWebSectionView(key)?.reload()`
//   - `onGoBack`     → caller wraps `backends.cachedWebSectionView(key)?.webView.goBack()`
//   - `onGoForward`  → caller wraps `backends.cachedWebSectionView(key)?.webView.goForward()`
//   - `onNavigate`   → caller wraps `backends.cachedWebSectionView(key)?.webView.load(...)`
//
// Both `SessionDetailPanel.webWidgetChrome` and `HomeView`'s widget-grid config
// call `makeWebWidgetChrome(...)` so the two can NEVER drift: the always-docked
// header, BrowserChromeRow wiring, and nav callbacks are defined here exactly
// once.

import SwiftUI

/// Builds the fully-wired `WidgetChrome` for a web (WKWebView-backed) widget.
///
/// Everything that must be identical between the session panel and the Home
/// surface lives here: the `BrowserChromeRow` is always stacked above the
/// WebView, visible, and reserves its own layout space.
///
/// Call-site-specific bits are injected as parameters:
/// - `onRefresh` / `onGoBack` / `onGoForward` / `onNavigate` — navigation
///   callbacks that the caller builds using its local `LiveWidgetBackends`
///   instance and cache-key scheme (injection seam for the app-side type).
/// - `canClose` / `onClose` / `moveOptions` — engine chrome the host owns.
/// - `headerAccessory` — an optional control (e.g. the Preview tile's Record
///   button) rendered inside the trailing glass pill after the picker. Defaults
///   to nothing, so Browser/Jira/PR/Artifacts are unchanged.
/// - `headerAccessoryPillTint` — optional tint for that whole shared pill.
@MainActor
public func makeWebWidgetChrome(
    icon: String,
    iconImageData: Data? = nil,
    label: String,
    model: BrowserWidgetModel,
    onRefresh: @escaping () -> Void,
    onGoBack: @escaping () -> Void = {},
    onGoForward: @escaping () -> Void = {},
    onNavigate: ((URL) -> Void)? = nil,
    minWidth: CGFloat = 0,
    minHeight: CGFloat = 0,
    canClose: Bool,
    onClose: @escaping () -> Void,
    moveOptions: WidgetMoveOptions?,
    headerAccessory: AnyView = AnyView(EmptyView()),
    headerAccessoryPillTint: Color? = nil,
    bookmarkControl: BrowserBookmarkControl? = nil
) -> WidgetChrome<AnyView> {
    WidgetChrome(
        title: label,
        systemImage: icon,
        minWidth: minWidth,
        minHeight: minHeight,
        contentPadding: 0,
        headerContent: { trailing in
            BrowserChromeRow(
                icon: icon,
                iconImageData: iconImageData,
                label: label,
                model: model,
                onRefresh: onRefresh,
                onGoBack: onGoBack,
                onGoForward: onGoForward,
                onNavigate: onNavigate,
                // The optional per-widget accessory (Preview's Record button)
                // joins the shared trailing glass pill after the picker.
                pillAccessory: headerAccessory,
                pillTint: headerAccessoryPillTint,
                // Engine-owned move/close controls remain bare after the pill.
                trailingControls: trailing,
                // ★ add-current-page control at the URL capsule's trailing edge.
                bookmarkControl: bookmarkControl
            )
        },
        canClose: canClose,
        onClose: onClose,
        moveOptions: moveOptions,
        // Browser chrome is permanently docked: the standard custom-header path
        // stacks it above the WebView and reserves layout space.
        floatingHeader: false,
        actions: { AnyView(EmptyView()) }
    )
}
