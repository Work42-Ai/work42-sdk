// WidgetEnvironment.swift — values the host injects into every plugin widget's SwiftUI tree.
//
// `widgetSessionServices` carries the same `SessionServices` the host passes to
// `Work42Widget.makeView(services:)`, so SDK components built into a widget's view (the browser
// base's highlight-to-comment, for one) can reach the session's composer without every widget
// forwarding `services:` by hand. A component's explicit parameter always wins over this value.

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
