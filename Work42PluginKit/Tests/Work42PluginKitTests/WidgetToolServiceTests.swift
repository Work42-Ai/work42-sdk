// WidgetToolServiceTests.swift — SDK 2.8.0 (ABI 13): `tools` on the session services, the plugin's doorway to
// every work42 tool. The host implements the service; these pin the types and the no-op default.

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

private struct EchoTools: WidgetToolService {
    nonisolated func listTools() async throws -> [WidgetToolInfo] {
        [WidgetToolInfo(server: "work42-session", name: "echo", description: "Echo.", inputSchema: .object([:]))]
    }

    nonisolated func call(server: String, tool: String, arguments: [String: WidgetJSONValue],
                          session: String?) async throws -> WidgetJSONValue {
        .object(["server": .string(server), "tool": .string(tool), "session": session.map(WidgetJSONValue.string) ?? .null,
                 "arguments": .object(arguments)])
    }
}

@Suite("WidgetToolService (SDK 2.8.0)")
struct WidgetToolServiceTests {

    @Test("WidgetToolInfo round-trips through Codable")
    func toolInfoRoundTrips() throws {
        let info = WidgetToolInfo(
            server: "work42-session", name: "storage_set", description: "Set a value.",
            inputSchema: .object(["type": .string("object"), "required": .array([.string("key")])]))
        let decoded = try JSONDecoder().decode(WidgetToolInfo.self, from: JSONEncoder().encode(info))
        #expect(decoded == info)
    }

    @Test("the unavailable default throws a named error with a suggestion, never data")
    func unavailableDefaultFailsLoud() async {
        let service = UnavailableWidgetToolService()
        do {
            _ = try await service.listTools()
            Issue.record("expected an error")
        } catch let error as WidgetServiceError {
            #expect(!error.message.isEmpty)
            #expect(error.suggestion?.isEmpty == false)
        } catch {
            Issue.record("expected WidgetServiceError, got \(error)")
        }
        do {
            _ = try await service.call(server: "work42-session", tool: "storage_get", arguments: [:], session: nil)
            Issue.record("expected an error")
        } catch let error as WidgetServiceError {
            #expect(error.suggestion?.isEmpty == false)
        } catch {
            Issue.record("expected WidgetServiceError, got \(error)")
        }
    }

    @Test("both service bundles default to the unavailable service and carry a supplied one")
    func servicesCarryTools() async throws {
        let defaulted = SessionServices(
            composer: StubComposer(), shell: StubShell(), intents: StubIntents(), storage: StubStorage(), pill: StubPill())
        #expect(defaulted.tools is UnavailableWidgetToolService)

        let session = SessionServices(
            composer: StubComposer(), shell: StubShell(), intents: StubIntents(), storage: StubStorage(), pill: StubPill(),
            tools: EchoTools(), sessionId: "s1")
        let result = try await session.tools.call(
            server: "work42-session", tool: "echo", arguments: ["a": .number(1)], session: "other")
        #expect(result == .object(["server": .string("work42-session"), "tool": .string("echo"), "session": .string("other"),
                                   "arguments": .object(["a": .number(1)])]))

        let background = WidgetBackgroundServices(
            shell: StubShell(), storage: StubStorage(), pill: StubPill(), tools: EchoTools(), sessionId: "s1", taskId: nil)
        #expect(try await background.tools.listTools().map(\.name) == ["echo"])
        let defaultedBackground = WidgetBackgroundServices(
            shell: StubShell(), storage: StubStorage(), pill: StubPill(), sessionId: "s1", taskId: nil)
        #expect(defaultedBackground.tools is UnavailableWidgetToolService)
    }
}
