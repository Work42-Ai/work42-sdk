// WidgetEnvironment.swift — values the host injects into every plugin widget's SwiftUI tree.
//
// `widgetSessionServices` carries the same `SessionServices` the host passes to
// `Work42Widget.makeView(services:)`, so SDK components built into a widget's view (the browser
// base's highlight-to-comment, for one) can reach the session's composer without every widget
// forwarding `services:` by hand. A component's explicit parameter always wins over this value.

import Foundation
import SwiftUI

public struct WidgetSessionServicesKey: EnvironmentKey {
    public static let defaultValue: SessionServices? = nil
}

public extension EnvironmentValues {
    /// The session services of the widget this view belongs to. Nil outside a host-rendered
    /// widget (previews, tests).
    var widgetSessionServices: SessionServices? {
        get { self[WidgetSessionServicesKey.self] }
        set { self[WidgetSessionServicesKey.self] = newValue }
    }
}

// MARK: - Link routing

/// How a link clicked inside a browser widget is offered to the host before it navigates in
/// place. `route(url, keepHere)` returns true when the host took the link (it may ask the user
/// where to open it and call `keepHere` to load it in the source view after all), false to
/// navigate in place. Installed by the host around every plugin widget; `BrowserSurface` wires
/// it to each of its web views.
public struct WidgetLinkRouter: Sendable {
    public let route: @MainActor @Sendable (_ url: URL, _ keepHere: @escaping @MainActor @Sendable () -> Void) -> Bool

    public init(route: @escaping @MainActor @Sendable (_ url: URL, _ keepHere: @escaping @MainActor @Sendable () -> Void) -> Bool) {
        self.route = route
    }
}

public struct WidgetLinkRouterKey: EnvironmentKey {
    public static let defaultValue: WidgetLinkRouter? = nil
}

public extension EnvironmentValues {
    /// The host's link router for this widget. Nil outside a host-rendered widget.
    var widgetLinkRouter: WidgetLinkRouter? {
        get { self[WidgetLinkRouterKey.self] }
        set { self[WidgetLinkRouterKey.self] = newValue }
    }
}
