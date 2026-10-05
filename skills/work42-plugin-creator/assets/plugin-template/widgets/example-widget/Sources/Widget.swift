import SwiftUI
import Work42PluginKit

final class ExampleWidget: Work42Widget {
    let id = "example-widget"
    let title = "Example"
    let icon = "sparkles"
    let linkIntents: [WidgetLinkIntentSpec] = []

    func makeView(services: SessionServices) -> AnyView {
        AnyView(Text("Hello from example-plugin").padding(DT.s16))
    }
}

@_cdecl("work42_widget_sdk_version")
public func work42_widget_sdk_version() -> Int32 { WidgetSDK.abiVersion }

@_cdecl("work42_widget_main")
public func work42_widget_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated { result = WidgetEntryPoint.register(ExampleWidget()) }
    return result
}
