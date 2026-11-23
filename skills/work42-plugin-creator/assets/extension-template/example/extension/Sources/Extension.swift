// An out-of-process Work42 plugin (`runtime: extension` in plugin.yaml). Everything in extension/Sources is compiled into
// one ExtensionKit extension; `work42 plugin build` wraps it in a signed container app.
import SwiftUI
import Work42Extension
import Work42PluginKit

/// `nonisolated` is required: ExtensionKit makes this class off the main actor (the rest of your code stays on it).
@main
nonisolated final class ExampleExtension: Work42PluginExtension {
    required init() {}

    /// One factory per widget id in plugin.yaml. Work42 makes one instance per session.
    @MainActor var widgets: [ExtensionWidgetFactory] {
        [ExtensionWidgetFactory("example-extension") { ExampleWidget() }]
    }
}

final class ExampleWidget: Work42Widget {
    let id = "example-extension"
    let title = "Example"
    let icon = "puzzlepiece.extension"
    let linkIntents: [WidgetLinkIntentSpec] = []

    func makeView(services: SessionServices) -> AnyView {
        AnyView(ExampleView(services: services))
    }
}

struct ExampleView: View {
    let services: SessionServices
    @State private var output = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Running in its own process").font(.headline)
            Button("Run `date` in the session") {
                Task { output = (try? await services.shell.run(command: "date"))?.stdout ?? "failed" }
            }
            Text(output).font(.system(.body, design: .monospaced))
        }
        .padding()
    }
}
