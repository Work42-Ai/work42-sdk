// WidgetStreamServiceTests.swift — SDK 2.16.0 (ABI 17): the host's pushed streams, as a widget reads them. The host registers
// the service (an iPad subscribes through the paired Mac); these pin the empty default and how `SessionServices.stream` finds it.

import Foundation
import Testing
@testable import Work42PluginKit

private struct StubComposer: WidgetComposerService {
    nonisolated func insert(text: String) async throws {}
    nonisolated func attach(sourceLabel: String, excerpt: String, body: String) async throws {}
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

/// Answers every subscription with the three values it was asked about, so a test sees which session, widget and stream came through.
private struct EchoStreams: WidgetStreamService {
    nonisolated func subscribe(session: String, widget: String, stream: String) -> AsyncStream<Data> {
        AsyncStream { continuation in
            for part in [session, widget, stream] { continuation.yield(Data(part.utf8)) }
            continuation.finish()
        }
    }
}

private func services(sessionId: String?) -> SessionServices {
    SessionServices(
        composer: StubComposer(), shell: StubShell(), intents: StubIntents(), storage: StubStorage(), pill: StubPill(),
        sessionId: sessionId)
}

@MainActor
@Suite("Widget streams", .serialized)
struct WidgetStreamServiceTests {

    private func collect(_ stream: AsyncStream<Data>) async -> [String] {
        var out: [String] = []
        for await data in stream { out.append(String(decoding: data, as: UTF8.self)) }
        return out
    }

    @Test("the no-op service finishes at once, so a widget keeps to its own source")
    func noopFinishes() async {
        let stream = NoopWidgetStreamService().subscribe(session: "s", widget: "w", stream: "x")
        #expect(await collect(stream).isEmpty)
    }

    @Test("a host with no registered service gives an empty stream")
    func unregisteredIsEmpty() async {
        WidgetStreamRegistry.service = nil
        #expect(await collect(services(sessionId: "s1").stream("transcript", widget: "widget:recording")).isEmpty)
    }

    @Test("the registered service gets this session, the widget and the stream")
    func registeredServiceIsAsked() async {
        WidgetStreamRegistry.service = EchoStreams()
        defer { WidgetStreamRegistry.service = nil }
        let seen = await collect(services(sessionId: "s1").stream("transcript", widget: "widget:recording"))
        #expect(seen == ["s1", "widget:recording", "transcript"])
    }

    @Test("a session-less surface (Home) has no stream even when a service is registered")
    func sessionLessIsEmpty() async {
        WidgetStreamRegistry.service = EchoStreams()
        defer { WidgetStreamRegistry.service = nil }
        #expect(await collect(services(sessionId: nil).stream("transcript", widget: "widget:recording")).isEmpty)
    }
}
