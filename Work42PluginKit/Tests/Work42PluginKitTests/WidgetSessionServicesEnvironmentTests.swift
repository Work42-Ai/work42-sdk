// WidgetSessionServicesEnvironmentTests.swift — linear42 s10 (AC34).
//
// `BrowserSurface` owns highlight-to-comment, but only when it has `SessionServices` (the
// composer sink). Widgets used to have to pass `services:` by hand, and most never did. The host
// now injects the widget's services through `EnvironmentValues.widgetSessionServices`, and
// `BrowserSurface` falls back to it: an explicit `services:` still wins.

import Foundation
import SwiftUI
import Testing
@testable import Work42PluginKit

private struct StubComposer: WidgetComposerService {
    nonisolated func insert(text: String) async throws {}
    nonisolated func attach(sourceLabel: String, excerpt: String, body: String) async throws {}
    nonisolated func clearCommentableSelection() async throws {}
}

private struct StubShell: WidgetShellService {
    nonisolated func run(command: String) async throws -> WidgetShellResult {
        WidgetShellResult(stdout: "", stderr: "", exitCode: 0)
    }
}

private struct StubIntents: WidgetIntentsService {
    nonisolated func execute(id: String, params: [String: WidgetJSONValue]) async throws {}
}

private struct StubStorage: WidgetStorageService {
    nonisolated func get(namespace: String, key: String) async throws -> WidgetJSONValue? { nil }
    nonisolated func list(namespace: String) async throws -> [String: WidgetJSONValue] { [:] }
    nonisolated func set(key: String, value: WidgetJSONValue) async throws {}
    nonisolated func delete(key: String) async throws {}
}

private struct StubPill: WidgetPillService {
    nonisolated func present(widgetId: String, sessionId: String) async throws {}
    nonisolated func dismiss(widgetId: String) async throws {}
    nonisolated func isPresented(widgetId: String) async throws -> Bool { false }
}

private func services(_ sessionId: String) -> SessionServices {
    SessionServices(
        composer: StubComposer(), shell: StubShell(), intents: StubIntents(),
        storage: StubStorage(), pill: StubPill(), sessionId: sessionId
    )
}

@Suite("widgetSessionServices environment fallback (AC34)")
@MainActor
struct WidgetSessionServicesEnvironmentTests {

    @Test("the environment value defaults to nil")
    func defaultsToNil() {
        #expect(EnvironmentValues().widgetSessionServices == nil)
    }

    @Test("a value set on the environment reads back")
    func roundTrips() {
        var environment = EnvironmentValues()
        environment.widgetSessionServices = services("env-session")
        #expect(environment.widgetSessionServices?.sessionId == "env-session")
    }

    @Test("without explicit services the surface uses the environment's")
    func fallsBackToEnvironment() {
        let resolved = BrowserSurface.effectiveServices(explicit: nil, environment: services("env"))
        #expect(resolved?.sessionId == "env")
    }

    @Test("explicit services win over the environment")
    func explicitWins() {
        let resolved = BrowserSurface.effectiveServices(explicit: services("explicit"), environment: services("env"))
        #expect(resolved?.sessionId == "explicit")
    }

    @Test("with neither, comments stay disabled")
    func neitherIsNil() {
        #expect(BrowserSurface.effectiveServices(explicit: nil, environment: nil) == nil)
    }
}
