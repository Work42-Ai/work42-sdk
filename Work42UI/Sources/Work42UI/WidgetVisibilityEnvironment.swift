import SwiftUI

/// Whether the widget subtree hosting this view belongs to the currently
/// visible/active tab.
///
/// Set by the app's tab chassis (`Work42View`) per tab — driven by the app's
/// own `isActive` state, NOT AppKit visibility (an inactive tab renders at
/// `opacity(0)` with a frozen frame, which AppKit does not treat as hidden).
/// Browser widgets read it to (a) nudge a repaint when they become visible
/// after a page painted while hidden, and (b) keep the loading overlay up until
/// the content has painted AND the view is actually visible.
///
/// Propagates through the SwiftUI environment, so it reaches the deeply-nested
/// web view without threading a parameter through every intermediate closure.
/// Defaults to `true` so any view rendered outside the chassis (previews,
/// standalone hosting) behaves as visible.
public struct WidgetIsVisibleKey: EnvironmentKey {
    public static let defaultValue: Bool = true
}

public extension EnvironmentValues {
    var widgetIsVisible: Bool {
        get { self[WidgetIsVisibleKey.self] }
        set { self[WidgetIsVisibleKey.self] = newValue }
    }
}
