// The compat fixture widget (WOR-856). Frozen per SDK release by scripts/freeze-compat-fixture.sh and never rebuilt
// afterwards: Work42CompatibilityLoadTests loads each frozen build with the CURRENT app, so every 3.x host has to keep
// running what every earlier 3.x SDK produced.
//
// It touches each part of the surface a plugin widget uses: a SwiftUI view reading `services.storage`, one declared
// intent that writes through `services`, and a background agent. Keep it to API that exists in the SDK version being
// frozen; a newer service goes behind a runtime check so the same source freezes cleanly at every version.

import SwiftUI
import Work42PluginKit

final class CompatWidget: Work42Widget, Work42WidgetBackground {
    let id = "compat-fixture"
    let title = "Compat fixture"
    let icon = "checkmark.seal"
    let linkIntents: [WidgetLinkIntentSpec] = []

    /// Storage key the intent writes and the test reads back.
    static let intentMarkerKey = "intent-ran"

    /// Storage key the `mark-files` intent (frozen from SDK 3.3.0 on) writes once its file and command calls have run.
    static let filesMarkerKey = "files-ran"

    var intents: [WidgetIntentSpec] {
        [
            WidgetIntentSpec(
                name: "mark",
                title: "Mark compat fixture",
                icon: "checkmark",
                isConfirmed: nil,
                performWithServices: { services in
                    try await services.storage.set(key: CompatWidget.intentMarkerKey, value: .string("yes"))
                }),
            // SDK 3.3.0: a written and removed session file, and a started command that is stopped again. A fixture
            // frozen before 3.3.0 has no such intent, so the load test only runs it for versions that declare it.
            WidgetIntentSpec(
                name: "mark-files",
                title: "Mark compat fixture files",
                icon: "doc",
                isConfirmed: nil,
                performWithServices: { services in
                    try await services.files.write("compat-fixture.txt", data: Data("yes".utf8))
                    let process = try await services.shell.start(command: "true")
                    await process.stop()
                    try await services.files.remove("compat-fixture.txt")
                    try await services.storage.set(key: CompatWidget.filesMarkerKey, value: .string("yes"))
                }),
        ]
    }

    func makeView(services: SessionServices) -> AnyView {
        AnyView(CompatFixtureView(services: services))
    }

    func makeBackgroundAgent() -> any WidgetBackgroundAgent {
        CompatAgent()
    }
}

private struct CompatFixtureView: View {
    let services: SessionServices
    @State private var marker = "loading"

    var body: some View {
        Text("compat fixture: \(marker)")
            .padding(DT.s16)
            .task {
                let value = try? await services.storage.get(namespace: "compat-fixture", key: CompatWidget.intentMarkerKey)
                marker = value == nil ? "unset" : "set"
            }
    }
}

final class CompatAgent: WidgetBackgroundAgent {
    private var task: Task<Void, Never>?
    let headerLabels: [WidgetHeaderLabel] = []

    func start(services: WidgetBackgroundServices) {
        task = Task {
            try? await services.storage.set(key: "agent-started", value: .string("yes"))
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

@_cdecl("work42_widget_sdk_version")
public func work42_widget_sdk_version() -> Int32 { Work42SDKCompatibility.versionProbeValue }

@_cdecl("work42_widget_main")
public func work42_widget_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated { result = WidgetEntryPoint.register(CompatWidget()) }
    return result
}
