// ShellAuthorizationTests.swift — Work42 can gate `shell.run` and `shell.start` per link (SDK 3.5.0, WOR-893).
//
// `ExtensionHostServer.authorizeShell` runs before a command starts. When it throws, the command never runs and the caller gets
// the error; when it is unset a command runs as it did before, so an older host or a test double is unaffected.

import Foundation
import Testing
import Work42PluginKit

@testable import Work42Extension

@Suite("Shell authorization", .serialized)
@MainActor
struct ShellAuthorizationTests {

    private func pair(_ shell: CountingShell) -> Pair {
        let pair = Pair(widgets: [ExtensionWidgetFactory("todos") { ShellWidget() }])
        pair.link.server.attach(hostServices(shell: shell, storage: MemoryStore(), sessionId: "s1"), widgetId: "todos", sessionId: "s1")
        return pair
    }

    @Test("with no gate a command runs as before")
    func ungated() async throws {
        let shell = CountingShell()
        _ = try await pair(shell).link.send(try performIntentCall("sync", session: "s1"), kind: .ui)
        #expect(shell.ran == ["git pull"])
    }

    @Test("a gate that allows lets the command run, and sees the call's session and widget")
    func allowed() async throws {
        let shell = CountingShell()
        let pair = pair(shell)
        var seen: [(String?, String?, String)] = []
        pair.link.server.authorizeShell = { call in seen.append((call.sessionId, call.widgetId, call.name)) }
        _ = try await pair.link.send(try performIntentCall("sync", session: "s1"), kind: .ui)
        #expect(shell.ran == ["git pull"])
        #expect(seen.count == 1 && seen.first?.0 == "s1" && seen.first?.1 == "todos" && seen.first?.2 == "shell.run")
    }

    @Test("a gate that throws stops the command, and the caller gets the gate's error")
    func refused() async throws {
        let shell = CountingShell()
        let pair = pair(shell)
        pair.link.server.authorizeShell = { _ in
            throw WidgetServiceError(message: PluginPermissionError.deniedPrefix + "run-commands: not allowed to run commands")
        }
        let error = await #expect(throws: WidgetServiceError.self) {
            _ = try await pair.link.send(try performIntentCall("sync", session: "s1"), kind: .ui)
        }
        #expect(error?.message.contains("run-commands") == true)
        #expect(shell.ran.isEmpty, "the command never ran")
    }
}

private func performIntentCall(_ name: String, session: String) throws -> ExtensionCall {
    try ExtensionCall.make(service: "extension", method: "performIntent", sessionId: session, widgetId: "todos",
                           payload: ExtensionPayload.PerformIntent(name: name, params: [:], worktreePath: "/tmp/\(session)"))
}
