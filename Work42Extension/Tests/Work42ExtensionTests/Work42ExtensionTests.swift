// Work42ExtensionTests.swift — the out-of-process plugin runtime over an in-memory channel (SDK 3.2.0).
//
// A fake host stands in for Work42: it decodes every `ExtensionCall` the extension's proxies send, records it, and answers.
// No XPC and no ExtensionKit: the wire, the proxies, request ids, interruption and the runtime's dispatch are plain Swift.

import Foundation
import SwiftUI
import Testing
import Work42Extension
import Work42PluginKit

// MARK: - Fake host

/// Answers calls from an extension the way Work42 would, and records them.
nonisolated final class FakeHost: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ExtensionCall] = []
    /// When false, every call is dropped as if the extension's connection to Work42 had been lost.
    var connected = true
    var answer: @Sendable (ExtensionCall) -> ExtensionReply = { _ in ExtensionReply(payload: Data("{}".utf8)) }

    var calls: [ExtensionCall] { lock.lock(); defer { lock.unlock() }; return recorded }

    private(set) var channel: ExtensionChannel!

    init() {
        channel = ExtensionChannel(transport: ClosureExtensionTransport { [unowned self] data, reply in
            guard self.connected else { reply(nil); return }
            guard let call = try? ExtensionJSON.decode(ExtensionCall.self, from: data) else { reply(nil); return }
            self.lock.lock(); self.recorded.append(call); self.lock.unlock()
            reply(try? ExtensionJSON.encode(self.answer(call)))
        })
    }
}

// MARK: - Test widgets

@MainActor
final class CountingWidget: Work42Widget {
    let id = "counter"
    let title = "Counter"
    let icon = "number"
    let linkIntents: [WidgetLinkIntentSpec] = []
    var activations = 0
    var deactivations = 0
    var lastServices: SessionServices?

    var intents: [WidgetIntentSpec] {
        [WidgetIntentSpec(name: "run", title: "Run", icon: "play", isConfirmed: nil) { services in
            _ = try await services.shell.run(command: "echo hi")
        }]
    }

    func activate(services: SessionServices) { activations += 1; lastServices = services }
    func deactivate() { deactivations += 1 }
    func makeView(services: SessionServices) -> AnyView { AnyView(EmptyView()) }
}

@MainActor
final class LinkWidget: Work42Widget {
    let id = "links"
    let title = "Links"
    let icon = "link"
    var opened: [URL] = []
    var linkIntents: [WidgetLinkIntentSpec] {
        [WidgetLinkIntentSpec(matchers: [.regex("^https://example\\.com/")]) { [weak self] url in self?.opened.append(url) }]
    }
    func makeView(services: SessionServices) -> AnyView { AnyView(EmptyView()) }
}

nonisolated final class RecordingHooks: Work42SessionHooks, @unchecked Sendable {
    var created: [String] = []
    func onCreate(_ context: SessionCreateContext) async throws {
        created.append(context.sessionId)
        try await context.storage.set(key: "seeded", value: .bool(true))
    }
}

// MARK: - Wire

@Suite("ExtensionCall wire")
struct ExtensionWireTests {

    @Test("non-idempotent calls carry a request id; reads do not")
    func requestIds() throws {
        let run = try ExtensionCall.make(service: "shell", method: "run", sessionId: "s", widgetId: "w",
                                         payload: ExtensionPayload.Command(command: "ls"))
        let read = try ExtensionCall.make(service: "storage", method: "get", sessionId: "s", widgetId: "w",
                                          payload: ExtensionPayload.NamespacedKey(namespace: "n", key: "k"))
        #expect(run.requestId != nil)
        #expect(read.requestId == nil)
        for name in ["shell.run", "intents.execute", "tools.call", "extension.hook", "extension.performIntent"] {
            #expect(ExtensionCall.nonIdempotentMethods.contains(name))
        }
    }

    @Test("a call round-trips through JSON unchanged, stamped with this SDK's version")
    func roundTrip() throws {
        let call = try ExtensionCall.make(service: "tools", method: "call", sessionId: "s1", widgetId: "w1",
                                          payload: ExtensionPayload.ToolCall(server: "work42-session", tool: "storage_get",
                                                                             arguments: ["key": .string("plan/spec")], session: nil))
        let decoded = try ExtensionJSON.decode(ExtensionCall.self, from: try ExtensionJSON.encode(call))
        #expect(decoded == call)
        #expect(decoded.sdkVersion == Work42SDKCompatibility.version)
    }

    @Test("the extension point is qualified by the host bundle id")
    func pointIdentifier() {
        #expect(Work42ExtensionPoint.identifier == "com.work42.app.plugin")
    }
}

// MARK: - Proxies

@Suite("Service proxies over the channel", .serialized)
@MainActor
struct ExtensionProxyTests {

    @Test("shell.run carries the session, the widget and a request id, and returns the host's result")
    func shellRun() async throws {
        let host = FakeHost()
        host.answer = { _ in try! .success(WidgetShellResult(stdout: "ok\n", stderr: "", exitCode: 0)) }
        let services = ExtensionServices.session(channel: host.channel, sessionId: "S1", widgetId: "W1", worktreePath: "/tmp")
        let result = try await services.shell.run(command: "echo ok")
        #expect(result.stdout == "ok\n")
        let call = try #require(host.calls.first)
        #expect(call.name == "shell.run")
        #expect(call.sessionId == "S1")
        #expect(call.widgetId == "W1")
        #expect(call.requestId != nil)
        #expect(try ExtensionJSON.decode(ExtensionPayload.Command.self, from: call.payload).command == "echo ok")
    }

    @Test("storage reads return the host's value and send no request id")
    func storageGet() async throws {
        let host = FakeHost()
        host.answer = { _ in try! .success(ExtensionPayload.OptionalValue(value: .string("v"))) }
        let services = ExtensionServices.session(channel: host.channel, sessionId: "S1", widgetId: "W1", worktreePath: nil)
        #expect(try await services.storage.get(namespace: "plan", key: "spec") == .string("v"))
        #expect(host.calls.first?.requestId == nil)
    }

    @Test("an error the host throws reaches the widget unchanged")
    func hostError() async throws {
        let host = FakeHost()
        host.answer = { _ in .failure(WidgetServiceError(message: "intent 'x' is not registered", suggestion: "check ids")) }
        let services = ExtensionServices.session(channel: host.channel, sessionId: "S1", widgetId: "W1", worktreePath: nil)
        await #expect(throws: WidgetServiceError(message: "intent 'x' is not registered", suggestion: "check ids")) {
            try await services.intents.execute(id: "x", params: [:])
        }
    }

    @Test("a lost connection throws 'interrupted' and nothing is resent")
    func interrupted() async throws {
        let host = FakeHost()
        host.connected = false
        let services = ExtensionServices.session(channel: host.channel, sessionId: "S1", widgetId: "W1", worktreePath: nil)
        await #expect(throws: WidgetServiceError.hostInterrupted) {
            _ = try await services.shell.run(command: "make deploy")
        }
        host.connected = true
        #expect(host.calls.isEmpty)
        #expect(WidgetServiceError.extensionInterrupted.message == "interrupted: the extension stopped")
        #expect(WidgetServiceError.extensionInterrupted.suggestion == "retry the action")
    }

    @Test("a refused file path never leaves the process")
    func filePathRefused() async throws {
        let host = FakeHost()
        let services = ExtensionServices.session(channel: host.channel, sessionId: "S1", widgetId: "W1", worktreePath: nil)
        await #expect(throws: (any Error).self) { _ = try await services.files.read("../secrets") }
        #expect(host.calls.isEmpty)
    }

    @Test("a stream gets the items the host pushes, then ends when the host finishes it")
    func streams() async throws {
        let host = FakeHost()
        let channel: ExtensionChannel = host.channel
        host.answer = { call in
            // The host learns the stream id from the call and pushes two items, then finishes.
            if let sub = try? ExtensionJSON.decode(ExtensionSubscription<ExtensionPayload.Path>.self, from: call.payload) {
                channel.deliver(ExtensionStreamEvent(streamId: sub.streamId, item: Data("{}".utf8)))
                channel.deliver(ExtensionStreamEvent(streamId: sub.streamId, item: Data("{}".utf8)))
                channel.deliver(ExtensionStreamEvent(streamId: sub.streamId, finished: true))
            }
            return ExtensionReply(payload: Data("{}".utf8))
        }
        let services = ExtensionServices.session(channel: channel, sessionId: "S1", widgetId: "W1", worktreePath: nil)
        var count = 0
        for await _ in services.files.watch("meeting.json") { count += 1 }
        #expect(count == 2)
        #expect(host.calls.first?.name == "files.watch")
        #expect(channel.openStreamCount == 0)
    }

    @Test("closing the channel ends every open stream")
    func closeEndsStreams() async throws {
        let host = FakeHost()
        let services = ExtensionServices.session(channel: host.channel, sessionId: "S1", widgetId: "W1", worktreePath: nil)
        let stream = services.files.watch("notes")
        host.channel.close()
        var count = 0
        for await _ in stream { count += 1 }
        #expect(count == 0)
    }
}

// MARK: - Runtime

@Suite("Work42ExtensionRuntime dispatch", .serialized)
@MainActor
struct ExtensionRuntimeTests {

    private func runtime(_ host: FakeHost, widget: CountingWidget, hooks: RecordingHooks? = nil) -> Work42ExtensionRuntime {
        let runtime = Work42ExtensionRuntime(widgets: [ExtensionWidgetFactory("counter") { widget }], sessionHooks: hooks)
        runtime.connect(host.channel)
        return runtime
    }

    @Test("handshake reports the SDK version, each widget's metadata and the hooks, without activating anything")
    func handshake() async throws {
        let widget = CountingWidget()
        let runtime = runtime(FakeHost(), widget: widget, hooks: RecordingHooks())
        let reply = await runtime.handle(ExtensionCall(service: "extension", method: "handshake"))
        let handshake = try ExtensionJSON.decode(ExtensionPayload.Handshake.self, from: try #require(reply.payload))
        #expect(handshake.sdkVersion == Work42SDKCompatibility.version)
        #expect(handshake.hasSessionHooks)
        let counter = try #require(handshake.widgets.first)
        #expect(handshake.widgets.count == 1)
        #expect(counter.id == "counter" && counter.title == "Counter" && counter.icon == "number")
        #expect(counter.intents == [ExtensionIntentDescription(name: "run", title: "Run", icon: "play")])
        #expect(!counter.hasBackgroundAgent && !counter.isBrowserBacked)
        #expect(widget.activations == 0 && runtime.activeInstanceCount == 0)
    }

    @Test("openLink runs the widget's link intent with that index")
    func openLink() async throws {
        let widget = LinkWidget()
        let host = FakeHost()
        let runtime = Work42ExtensionRuntime(widgets: [ExtensionWidgetFactory("links") { widget }], sessionHooks: nil)
        runtime.connect(host.channel)
        let url = try #require(URL(string: "https://example.com/a"))
        let call = try ExtensionCall.make(service: "extension", method: "openLink", sessionId: "s1", widgetId: "links",
                                          payload: ExtensionPayload.OpenLink(index: 0, url: url, worktreePath: nil))
        #expect(await runtime.handle(call).error == nil)
        #expect(widget.opened == [url])
        let bad = try ExtensionCall.make(service: "extension", method: "openLink", sessionId: "s1", widgetId: "links",
                                         payload: ExtensionPayload.OpenLink(index: 3, url: url, worktreePath: nil))
        #expect(await runtime.handle(bad).error?.message.contains("no link intent 3") == true)
    }

    @Test("performIntent activates the widget once per session and runs the intent with proxy services")
    func performIntent() async throws {
        let host = FakeHost()
        host.answer = { _ in try! .success(WidgetShellResult(stdout: "", stderr: "", exitCode: 0)) }
        let widget = CountingWidget()
        let runtime = runtime(host, widget: widget)
        let call = try ExtensionCall.make(service: "extension", method: "performIntent", sessionId: "S1", widgetId: "counter",
                                          payload: ExtensionPayload.PerformIntent(name: "run", params: [:], worktreePath: "/w"))
        #expect(call.requestId != nil)
        #expect(await runtime.handle(call).error == nil)
        #expect(await runtime.handle(call).error == nil)
        #expect(widget.activations == 1)
        #expect(widget.lastServices?.worktreePath == "/w")
        #expect(host.calls.map(\.name).filter { $0 != "widget.state" } == ["shell.run", "shell.run"])
        #expect(host.calls.allSatisfy { $0.sessionId == "S1" && $0.widgetId == "counter" })
    }

    @Test("an unknown intent is a named error, not a crash")
    func unknownIntent() async throws {
        let runtime = runtime(FakeHost(), widget: CountingWidget())
        let call = try ExtensionCall.make(service: "extension", method: "performIntent", sessionId: "S1", widgetId: "counter",
                                          payload: ExtensionPayload.PerformIntent(name: "nope", params: [:], worktreePath: nil))
        let error = try #require(await runtime.handle(call).error)
        #expect(error.message.contains("has no intent 'nope'"))
    }

    @Test("releaseSession deactivates that session's widgets")
    func release() async throws {
        let host = FakeHost()
        host.answer = { _ in try! .success(WidgetShellResult(stdout: "", stderr: "", exitCode: 0)) }
        let widget = CountingWidget()
        let runtime = runtime(host, widget: widget)
        _ = try runtime.instance(widgetId: "counter", sessionId: "S1", worktreePath: nil)
        #expect(runtime.activeInstanceCount == 1)
        _ = await runtime.handle(ExtensionCall(service: "extension", method: "releaseSession", sessionId: "S1"))
        #expect(runtime.activeInstanceCount == 0)
        #expect(widget.deactivations == 1)
    }

    @Test("the onCreate hook runs with proxy storage that reaches the host")
    func hook() async throws {
        let host = FakeHost()
        let hooks = RecordingHooks()
        let runtime = runtime(host, widget: CountingWidget(), hooks: hooks)
        let call = try ExtensionCall.make(service: "extension", method: "hook", sessionId: "S9", widgetId: nil,
                                          payload: ExtensionPayload.Hook(event: "onCreate", name: "New", worktreePath: "/w", params: [:]))
        #expect(await runtime.handle(call).error == nil)
        #expect(hooks.created == ["S9"])
        #expect(host.calls.map(\.name).filter { $0 != "widget.state" } == ["storage.set"])
        #expect(host.calls.first?.sessionId == "S9")
    }

    @Test("a method this SDK does not know comes back as a named 'unsupported' error")
    func unsupported() async throws {
        let runtime = runtime(FakeHost(), widget: CountingWidget())
        let error = try #require(await runtime.handle(ExtensionCall(sdkVersion: "3.9.0", service: "extension", method: "teleport")).error)
        #expect(error.message.contains("extension.teleport is not supported"))
        #expect(error.message.contains("3.9.0"))
    }

    @Test("an extension that lost its connection fails calls with 'interrupted' and stops its widgets")
    func disconnect() async throws {
        let host = FakeHost()
        let widget = CountingWidget()
        let runtime = runtime(host, widget: widget)
        let (_, services) = try runtime.instance(widgetId: "counter", sessionId: "S1", worktreePath: nil)
        runtime.disconnect()
        #expect(widget.deactivations == 1)
        await #expect(throws: WidgetServiceError.hostInterrupted) { _ = try await services.shell.run(command: "ls") }
    }
}
