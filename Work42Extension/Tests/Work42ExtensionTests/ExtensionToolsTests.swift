// ExtensionToolsTests.swift — MCP tools a widget or a session type declares, over the wire (SDK 3.5.0, WOR-894).
//
// A tool is described in the handshake, called with `extension.callTool`, can report progress and be cancelled, and answers
// with a result or its own failure. A tool that changes data is never repeated after a crash. Driven through `Pair`: the real
// host link against the real extension runtime, joined by memory.

import Foundation
import SwiftUI
import Testing
import Work42Extension
import Work42PluginKit

/// What the test tools did, and a hook that says when a long one started.
nonisolated final class ToolLog: @unchecked Sendable {
    private let lock = NSLock()
    private var notes: [String] = []
    var started: (@Sendable () -> Void)?
    var all: [String] { lock.withLock { notes } }
    func note(_ text: String) { lock.withLock { notes.append(text) } }
}

@MainActor
final class ToolsWidget: Work42Widget, Work42WidgetMCPs {
    let id = "mail"
    let title = "Mail"
    let icon = "envelope"
    let linkIntents: [WidgetLinkIntentSpec] = []
    var intents: [WidgetIntentSpec] { [] }
    let log: ToolLog

    init(log: ToolLog) { self.log = log }

    func makeView(services: SessionServices) -> AnyView { AnyView(EmptyView()) }

    var mcpTools: [PluginMCPTools] {
        let log = self.log
        return [PluginMCPTools(id: "mail") {
            PluginTool(id: "search", description: "Search the mail.",
                       input: .object(["query": .string("What to search for"), "limit": .integer("At most this many").optional])) { args, context in
                let query = try args.string("query")
                let limit = try args.optionalInt("limit") ?? 20
                _ = try await context.services.shell.run(command: "search \(query)")
                log.note("search \(query) \(limit)")
                return try .structured(["query": query, "limit": String(limit), "widget": context.widgetId ?? "none"])
            }
            PluginTool(id: "fail", description: "Always fails.") { _, _ in
                throw PluginToolFailure(code: "not_found", message: "no such message", suggestion: "search first")
            }
            PluginTool(id: "denied", description: "A permission refusal.") { _, _ in
                throw PluginPermissionError.denied(.microphone, message: "Mail42 is not allowed to use the microphone.")
            }
            PluginTool(id: "progress", description: "Reports progress.") { _, context in
                await context.reportProgress("halfway", fraction: 0.5)
                return .text("done")
            }
            PluginTool(id: "slow", description: "Waits.") { _, _ in
                log.started?()
                try await Task.sleep(for: .seconds(30))
                return .text("late")
            }
            PluginTool(id: "send", description: "Sends.", changesData: true) { _, _ in
                log.note("send")
                log.started?()
                try await Task.sleep(for: .seconds(30))
                return .text("sent")
            }
        }]
    }
}

/// A widget with no tools, to show it adds nothing to the handshake.
@MainActor
final class PlainWidget: Work42Widget {
    let id = "plain"
    let title = "Plain"
    let icon = "circle"
    let linkIntents: [WidgetLinkIntentSpec] = []
    var intents: [WidgetIntentSpec] { [] }
    func makeView(services: SessionServices) -> AnyView { AnyView(EmptyView()) }
}

@MainActor
final class EventSessionType: Work42SessionTypeMCPs {
    var mcpTools: [PluginMCPTools] {[
        PluginMCPTools(id: "calendar") {
            PluginTool(id: "get_event", description: "This session's event.") { _, context in
                .text("widget=\(context.widgetId ?? "none") session=\(context.sessionId)")
            }
        },
    ]}
}

@MainActor
private func toolsPair(_ log: ToolLog = ToolLog(), shell: CountingShell = CountingShell()) -> Pair {
    let pair = Pair(widgets: [ExtensionWidgetFactory("mail") { ToolsWidget(log: log) }, ExtensionWidgetFactory("plain") { PlainWidget() }],
                    sessionTypes: [ExtensionSessionTypeFactory("event") { EventSessionType() }])
    pair.link.server.attach(hostServices(shell: shell, storage: MemoryStore(), sessionId: "s1"), widgetId: "mail", sessionId: "s1")
    return pair
}

@MainActor
private func call(_ pair: Pair, owner: String = ExtensionPayload.CallTool.widgetOwner, ownerId: String = "mail", mcp: String = "mail",
                  tool: String, arguments: [String: WidgetJSONValue] = [:], changesData: Bool = false,
                  invocation: String = UUID().uuidString) async throws -> ExtensionPayload.ToolOutcome {
    let payload = ExtensionPayload.CallTool(owner: owner, ownerId: ownerId, mcp: mcp, tool: tool, arguments: arguments,
                                            invocationId: invocation, chatId: "chat-1")
    let request = try ExtensionCall.callTool(payload, sessionId: "s1",
                                             widgetId: owner == ExtensionPayload.CallTool.widgetOwner ? ownerId : nil,
                                             changesData: changesData)
    return try ExtensionJSON.decode(ExtensionPayload.ToolOutcome.self, from: try await pair.link.send(request, kind: .work))
}

@Suite("MCP tools over the wire", .serialized)
@MainActor
struct ExtensionToolsTests {

    // MARK: The handshake

    @Test("the handshake lists each widget's and session type's tools with their schemas, and a widget with none adds nothing")
    func handshakeListsTools() async throws {
        let pair = toolsPair()
        let reply = await pair.runtime.handle(ExtensionCall(service: "extension", method: "handshake"))
        let handshake = try ExtensionJSON.decode(ExtensionPayload.Handshake.self, from: try #require(reply.payload))

        let mail = try #require(handshake.widgets.first { $0.id == "mail" })
        let mcp = try #require(mail.mcps?.first)
        #expect(mcp.id == "mail" && mcp.tools.map(\.id) == ["search", "fail", "denied", "progress", "slow", "send"])
        let search = try #require(mcp.tools.first)
        #expect(search.description == "Search the mail." && !search.changesData)
        #expect(search.inputSchema.type == "object" && search.inputSchema.required == ["query"])
        #expect(search.inputSchema.properties["limit"]?.type == "integer")
        #expect(mcp.tools.first { $0.id == "send" }?.changesData == true)

        let event = try #require(handshake.sessionTypes?.first)
        #expect(event.id == "event" && event.mcps.first?.id == "calendar" && event.mcps.first?.tools.first?.id == "get_event")

        #expect(handshake.widgets.first { $0.id == "plain" }?.mcps == nil)
        let plain = try ExtensionJSON.encode(try #require(handshake.widgets.first { $0.id == "plain" }))
        #expect(!String(decoding: plain, as: UTF8.self).contains("\"mcps\""), "absent on the wire when empty")
    }

    @Test("an extension with no session types answers a handshake without the key, and a 3.4 handshake still decodes")
    func handshakeStaysCompatible() async throws {
        let runtime = Work42ExtensionRuntime(widgets: [ExtensionWidgetFactory("plain") { PlainWidget() }], sessionHooks: nil)
        let reply = await runtime.handle(ExtensionCall(service: "extension", method: "handshake"))
        #expect(!String(decoding: try #require(reply.payload), as: UTF8.self).contains("sessionTypes"))

        let old = #"{"sdkVersion":"3.4.0","widgets":[],"hasSessionHooks":false}"#
        let handshake = try ExtensionJSON.decode(ExtensionPayload.Handshake.self, from: Data(old.utf8))
        #expect(handshake.sessionTypes == nil && handshake.widgets.isEmpty)
    }

    // MARK: Calling

    @Test("a tool runs in the extension, uses the host's services for its session, and answers with text and structured JSON")
    func callRunsTheTool() async throws {
        let log = ToolLog(), shell = CountingShell()
        let outcome = try await call(toolsPair(log, shell: shell), tool: "search",
                                     arguments: ["query": .string("alex"), "limit": .number(5)])
        #expect(outcome.failure == nil)
        let result = try #require(outcome.result)
        #expect(result.structured == .object(["query": .string("alex"), "limit": .string("5"), "widget": .string("mail")]))
        #expect(result.content.first?.text.contains("alex") == true)
        #expect(shell.ran == ["search alex"], "the tool's service call ran on the host, for this session")
        #expect(log.all == ["search alex 5"])
    }

    @Test("an optional argument can be left out")
    func optionalArgument() async throws {
        let log = ToolLog()
        _ = try await call(toolsPair(log), tool: "search", arguments: ["query": .string("x")])
        #expect(log.all == ["search x 20"])
    }

    @Test("a session type's tool runs with no widget, for the session")
    func sessionTypeTool() async throws {
        let outcome = try await call(toolsPair(), owner: ExtensionPayload.CallTool.sessionTypeOwner, ownerId: "event",
                                     mcp: "calendar", tool: "get_event")
        #expect(outcome.result?.content.first?.text == "widget=none session=s1")
    }

    // MARK: Failures

    @Test("a tool's own failure comes back as a failure with its code, message and suggestion, not a transport error")
    func toolFailure() async throws {
        let outcome = try await call(toolsPair(), tool: "fail")
        #expect(outcome.result == nil)
        #expect(outcome.failure == PluginToolFailure(code: "not_found", message: "no such message", suggestion: "search first"))
    }

    @Test("a permission refusal inside a tool is a failure with a permission code and a pointer to Settings")
    func permissionFailure() async throws {
        let failure = try #require(try await call(toolsPair(), tool: "denied").failure)
        #expect(failure.code == "permission_denied" && failure.message.contains("microphone"))
        #expect(failure.suggestion?.contains("Permissions") == true)
    }

    @Test("an unknown tool or MCP is a named failure")
    func unknownTool() async throws {
        let pair = toolsPair()
        #expect(try await call(pair, tool: "nope").failure?.code == "no_such_tool")
        #expect(try await call(pair, mcp: "other", tool: "search").failure?.code == "no_such_tool")
    }

    @Test("arguments that do not fit the schema are refused before the handler runs")
    func invalidArguments() async throws {
        let log = ToolLog()
        let pair = toolsPair(log)
        let missing = try await call(pair, tool: "search")
        #expect(missing.failure?.code == "invalid_arguments" && missing.failure?.message == "'query' is required")
        let wrongType = try await call(pair, tool: "search", arguments: ["query": .number(3)])
        #expect(wrongType.failure?.message == "'query' must be a string")
        let extra = try await call(pair, tool: "search", arguments: ["query": .string("a"), "surprise": .bool(true)])
        #expect(extra.failure?.message == "'surprise' is not an argument of this tool")
        let fractional = try await call(pair, tool: "search", arguments: ["query": .string("a"), "limit": .number(2.5)])
        #expect(fractional.failure?.message == "'limit' must be a whole number")
        #expect(log.all.isEmpty, "no handler ran")
    }

    @Test("a call that cannot be routed (no such widget or session type, a wrong owner) is a transport error")
    func unroutable() async throws {
        let pair = toolsPair()
        await #expect(throws: WidgetServiceError.self) { _ = try await call(pair, ownerId: "nope", tool: "search") }
        await #expect(throws: WidgetServiceError.self) {
            _ = try await call(pair, owner: ExtensionPayload.CallTool.sessionTypeOwner, ownerId: "nope", mcp: "calendar", tool: "get_event")
        }
        await #expect(throws: WidgetServiceError.self) { _ = try await call(pair, owner: "planet", tool: "search") }
    }

    // MARK: Progress and cancellation

    @Test("progress reaches the host with the call's invocation id and session")
    func progress() async throws {
        let pair = toolsPair()
        var seen: [(ExtensionPayload.ToolProgress, String?)] = []
        pair.link.server.toolProgress = { progress, session in seen.append((progress, session)) }
        let outcome = try await call(pair, tool: "progress", invocation: "inv-7")
        #expect(outcome.result?.content.first?.text == "done")
        #expect(seen.count == 1 && seen[0].0 == ExtensionPayload.ToolProgress(invocationId: "inv-7", message: "halfway", fraction: 0.5))
        #expect(seen[0].1 == "s1")
    }

    @Test("progress with no listener is accepted and dropped")
    func progressWithoutListener() async throws {
        #expect(try await call(toolsPair(), tool: "progress").result != nil)
    }

    @Test("cancelTool stops a running call, which answers 'cancelled'")
    func cancel() async throws {
        let log = ToolLog()
        let started = AsyncStream<Void>.makeStream()
        log.started = { started.continuation.yield() }
        let pair = toolsPair(log)
        let running = Task { @MainActor in try await call(pair, tool: "slow", invocation: "inv-slow") }
        for await _ in started.stream { break }
        let cancel = try ExtensionCall.make(service: "extension", method: "cancelTool", sessionId: "s1", widgetId: "mail",
                                            payload: ExtensionPayload.CancelTool(invocationId: "inv-slow"))
        _ = try await pair.link.send(cancel, kind: .work)
        #expect(try await running.value.failure == .cancelled)
    }

    // MARK: Tools that change data

    @Test("a call to a tool that changes data carries a request id, and any other does not")
    func requestIds() throws {
        let payload = ExtensionPayload.CallTool(owner: "widget", ownerId: "mail", mcp: "mail", tool: "send", invocationId: "i")
        #expect(try ExtensionCall.callTool(payload, sessionId: "s1", widgetId: "mail", changesData: true).requestId != nil)
        #expect(try ExtensionCall.callTool(payload, sessionId: "s1", widgetId: "mail", changesData: false).requestId == nil)
        #expect(try ExtensionCall.callTool(payload, sessionId: "s1", widgetId: "mail", changesData: true).name == "extension.callTool")
    }

    @Test("a crash mid-call: a tool that changes data ran once, the caller is told it was interrupted, and nothing is re-sent")
    func crashMidChangingCall() async throws {
        let log = ToolLog()
        let started = AsyncStream<Void>.makeStream()
        log.started = { started.continuation.yield() }
        let pair = toolsPair(log)
        let running = Task { @MainActor in try await call(pair, tool: "send", changesData: true) }
        for await _ in started.stream { break }
        pair.crash()

        let error = await #expect(throws: WidgetServiceError.self) { _ = try await running.value }
        #expect(error == .extensionInterrupted)
        #expect(log.all == ["send"])
        let entry = try #require(pair.link.ledger.entries(forSession: "s1").first { $0.name == "extension.callTool" })
        #expect(entry.status == .interrupted)
        #expect(pair.link.ledger.inFlightCount == 0)

        // A restart is a new connection; the interrupted call is not sent again.
        let restarted = toolsPair(log)
        try await Task.sleep(for: .milliseconds(50))
        #expect(log.all == ["send"])
        _ = restarted
        #expect(PluginToolFailure.outcomeUnknown.code == "outcome_unknown")
    }
}

// MARK: - Frozen wire

@Suite("MCP tool wire is frozen")
struct ExtensionToolsWireTests {

    @Test("the messages decode from the JSON a 3.5.0 side writes, and write the same keys back")
    func frozenMessages() throws {
        let call = #"{"owner":"widget","ownerId":"mail","mcp":"mail","tool":"search","arguments":{"query":"alex","limit":5},"invocationId":"i-1","chatId":"c-1","worktreePath":"/w"}"#
        let decoded = try ExtensionJSON.decode(ExtensionPayload.CallTool.self, from: Data(call.utf8))
        #expect(decoded == ExtensionPayload.CallTool(owner: "widget", ownerId: "mail", mcp: "mail", tool: "search",
                                                      arguments: ["query": .string("alex"), "limit": .number(5)], invocationId: "i-1",
                                                      chatId: "c-1", worktreePath: "/w"))
        let keys = Set(try #require(JSONSerialization.jsonObject(with: try ExtensionJSON.encode(decoded)) as? [String: Any]).keys)
        #expect(keys == ["owner", "ownerId", "mcp", "tool", "arguments", "invocationId", "chatId", "worktreePath"])

        let result = #"{"result":{"content":[{"type":"text","text":"ok"}],"structured":{"n":1}}}"#
        let ok = try ExtensionJSON.decode(ExtensionPayload.ToolOutcome.self, from: Data(result.utf8))
        #expect(ok.result?.content.first?.text == "ok" && ok.result?.structured == .object(["n": .number(1)]) && ok.failure == nil)

        let failure = #"{"failure":{"code":"not_found","message":"no such message","suggestion":"search first"}}"#
        let bad = try ExtensionJSON.decode(ExtensionPayload.ToolOutcome.self, from: Data(failure.utf8))
        #expect(bad.failure == PluginToolFailure(code: "not_found", message: "no such message", suggestion: "search first") && bad.result == nil)

        let progress = try ExtensionJSON.decode(ExtensionPayload.ToolProgress.self,
                                                from: Data(#"{"invocationId":"i-1","message":"half","fraction":0.5}"#.utf8))
        #expect(progress == ExtensionPayload.ToolProgress(invocationId: "i-1", message: "half", fraction: 0.5))
        #expect(try ExtensionJSON.decode(ExtensionPayload.CancelTool.self, from: Data(#"{"invocationId":"i-1"}"#.utf8)).invocationId == "i-1")
    }

    @Test("an optional field absent on the wire stays absent")
    func optionalsStayAbsent() throws {
        let bare = ExtensionPayload.CallTool(owner: "session-type", ownerId: "event", mcp: "calendar", tool: "get_event", invocationId: "i")
        let json = String(decoding: try ExtensionJSON.encode(bare), as: UTF8.self)
        #expect(!json.contains("chatId") && !json.contains("worktreePath"))
        let progress = String(decoding: try ExtensionJSON.encode(ExtensionPayload.ToolProgress(invocationId: "i", message: "m")), as: UTF8.self)
        #expect(!progress.contains("fraction"))
    }
}
