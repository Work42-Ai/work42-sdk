// WidgetInstances.swift — which instances a widget has, and what each is called (WOR-798).
//
// A widget built on `BrowserSurface` is a browser with a preset: like the Browser it is each person's own, on each of their devices,
// with their tabs and sign-ins. So unless it says otherwise, the host treats it as personal, and each instance has its own id
// (`WidgetInstanceID`). Every other widget is what it declares (shared unless it says so).

import Foundation
import Work42UI

@MainActor
extension Work42Widget {
    /// How the host treats this widget with more than one collaborator: what it declares, except that a browser-backed widget that
    /// declares nothing is personal (each person has their own, agents act in it with their permission).
    public var hostCollaboration: WidgetCollaboration {
        if collaboration == .default, self is any Work42BrowserBacked { return .personal(agentControl: .withPermission) }
        return collaboration
    }
}

extension WidgetCollaboration {
    /// Whether each person has their own instance on each device.
    public var isPersonal: Bool {
        if case .personal = self { return true }
        return false
    }
}

extension InstanceKey {
    /// The id an agent and a person use for this instance: the widget's own for a shared or hosted widget, with `owner` (whose it is,
    /// on what device) for one device's instance of a personal widget.
    public func runtimeID(owner: WidgetInstanceID.Owner?) -> String {
        WidgetInstanceID.runtimeID(kindID: widgetID, owner: deviceID == nil ? nil : owner)
    }
}
