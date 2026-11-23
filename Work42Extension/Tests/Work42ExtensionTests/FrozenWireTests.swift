// FrozenWireTests.swift — the extension half of the compat fixture (SDK 3.2.0, WOR-862).
//
// The in-process half of `Fixtures/compat/<version>/` is native code a host loads. The extension half is the wire: an
// extension built against an older SDK keeps sending the calls it sent then, and keeps receiving the calls its host sent
// then. `Fixtures/compat/<version>/extension/` freezes both, as that release's code encoded them:
//
//   extension-calls.json  every call the proxies send to the host (one per `SessionServices` member method and stream)
//   host-calls.json       every call a host sends an extension, each with the reply that release's runtime gave
//   scene-calls.json      the call a host sends on a widget scene's connection (answered by the scene, so no reply)
//
// Freeze a release once, right after the version bump (never regenerate a frozen directory):
//
//   WORK42_FREEZE_WIRE=1 swift test --filter FrozenWire
//
// The replay test below runs every frozen version against this runtime; WOR-863 replays extension-calls.json against
// the host.

import Foundation
import Testing
import Work42Extension
import Work42PluginKit

private let compatRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/compat")

/// One host request and the reply the runtime of the frozen release gave it.
nonisolated struct FrozenExchange: Codable {
    var call: ExtensionCall
    var reply: ExtensionReply
}

/// A fake host that answers the service calls a host request triggers the way Work42 does, so the replies the
/// runtime gives are the ones it gives in production (`counter.run` runs `shell.run`, which returns a shell result).
private func answeringHost() -> FakeHost {
    let host = FakeHost()
    host.answer = { call in
        if call.name == "shell.run" {
            return (try? .success(WidgetShellResult(stdout: "hi\n", stderr: "", exitCode: 0)))
                ?? ExtensionReply(error: WidgetServiceError(message: "encode", suggestion: nil))
        }
        return ExtensionReply(payload: Data("{}".utf8))
    }
    return host
}

/// The scene's first call. The scene endpoint answers it, not the runtime, so it is frozen without a reply.
private func sceneCalls() throws -> [ExtensionCall] {
    let context = try ExtensionJSON.encode(ExtensionPayload.SessionContext(worktreePath: "/tmp/frozen"))
    return [ExtensionCall(service: "scene", method: "attach", sessionId: "s-frozen", widgetId: "counter", payload: context)]
}

/// The host calls a release sends, against a runtime with a `counter` widget and session hooks.
@MainActor
private func hostCalls() throws -> [ExtensionCall] {
    let session = "s-frozen", widget = "counter"
    func call(_ service: String, _ method: String, sessionId: String? = session, widgetId: String? = widget,
              _ payload: some Encodable) throws -> ExtensionCall {
        try ExtensionCall.make(service: service, method: method, sessionId: sessionId, widgetId: widgetId, payload: payload)
    }
    return [
        try call("extension", "handshake", sessionId: nil, widgetId: nil, ExtensionEmpty()),
        try call("extension", "performIntent",
                 ExtensionPayload.PerformIntent(name: "run", params: ["n": .number(1)], worktreePath: "/tmp/frozen")),
        try call("extension", "openLink",
                 ExtensionPayload.OpenLink(index: 0, url: URL(string: "https://example.com/a")!, worktreePath: "/tmp/frozen")),
        try call("extension", "resolveStartURL", sessionId: nil, ExtensionEmpty()),
        try call("extension", "backgroundStart", ExtensionPayload.BackgroundStart(taskId: "t-frozen")),
        try call("extension", "backgroundStop", ExtensionEmpty()),
        try call("extension", "hook", widgetId: nil,
                 ExtensionPayload.Hook(event: "onCreate", name: "frozen", worktreePath: "/tmp/frozen", params: [:])),
        try call("extension", "releaseSession", widgetId: nil, ExtensionEmpty()),
    ]
}

/// Drives every proxy once, so the fake host records each call shape the release sends.
@MainActor
private func driveEveryProxy(_ host: FakeHost) async {
    let services = ExtensionServices.session(channel: host.channel, sessionId: "s-frozen", widgetId: "counter",
                                             worktreePath: "/tmp/frozen")
    let scope = ExtensionServiceScope(channel: host.channel, sessionId: "s-frozen", widgetId: "counter")
    let background = ExtensionServices.background(channel: host.channel, sessionId: "s-frozen", widgetId: "counter",
                                                  taskId: "t-frozen")
    // Replies are `{}`, so typed results fail to decode after the call is recorded; only the request matters here.
    try? await services.composer.insert(text: "hi")
    try? await services.composer.attach(sourceLabel: "a.swift", excerpt: "let a", body: "let a = 1")
    try? await services.composer.presentCommentableSelection(sourceLabel: "a.swift", excerpt: "let a")
    try? await services.composer.clearCommentableSelection()
    _ = try? await services.shell.run(command: "echo frozen")
    try? await services.intents.execute(id: "counter.run", params: ["n": .number(1)])
    _ = try? await services.storage.get(namespace: "todos", key: "items")
    _ = try? await services.storage.list(namespace: "todos")
    try? await services.storage.set(key: "todos/items", value: .array([.string("a")]))
    try? await services.storage.delete(key: "todos/items")
    _ = try? await services.storage.person(key: "todos/seen")
    try? await services.storage.setPerson(key: "todos/seen", value: .bool(true))
    try? await services.storage.deletePerson(key: "todos/seen")
    _ = try? await services.storage.people(key: "todos/seen")
    try? await services.pill.present(widgetId: "counter", sessionId: "s-frozen")
    try? await services.pill.dismiss(widgetId: "counter")
    _ = try? await services.pill.isPresented(widgetId: "counter")
    _ = try? await services.tools.listTools()
    _ = try? await services.tools.call(server: "work42-session", tool: "storage_get", arguments: ["key": .string("a/b")],
                                       session: nil)
    _ = try? await services.files.read("README.md")
    _ = try? await services.files.list("docs")
    _ = await ExtensionAccountProxy(scope: scope).currentUser()
    _ = try? await services.collaboration.members()
    try? await services.collaboration.report(nil)
    await background.activity.ping()
    let browser = ExtensionBrowserTabsProxy(scope: scope)
    let tab = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
    try? await browser.selectTab(tab)
    try? await browser.updateTab(tab, title: "Docs", url: URL(string: "https://example.com"), icon: "globe")
    try? await browser.setTabs([])
    // Streams: subscribing sends the call; dropping the stream sends `stream.cancel`.
    var streams: [Any] = [
        services.files.watch("docs"),
        services.collaboration.cursors(),
        ExtensionStreamProxy(scope: scope).subscribe(session: "s-frozen", widget: "counter", stream: "events"),
        browser.tabs,
        browser.events,
    ]
    try? await Task.sleep(for: .milliseconds(200))
    streams.removeAll()
    try? await Task.sleep(for: .milliseconds(200))
}

@Suite("Frozen wire (compat fixture)", .serialized)
@MainActor
struct FrozenWireTests {

    @Test("freeze this release's wire (only with WORK42_FREEZE_WIRE=1)",
          .enabled(if: ProcessInfo.processInfo.environment["WORK42_FREEZE_WIRE"] == "1"))
    func freeze() async throws {
        let out = compatRoot.appendingPathComponent("\(Work42SDKCompatibility.version)/extension")
        #expect(!FileManager.default.fileExists(atPath: out.path), "a frozen fixture is never rebuilt")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let proxyHost = FakeHost()
        await driveEveryProxy(proxyHost)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(proxyHost.calls).write(to: out.appendingPathComponent("extension-calls.json"))

        let host = answeringHost()
        let runtime = Work42ExtensionRuntime(widgets: [ExtensionWidgetFactory("counter") { CountingWidget() }],
                                             sessionHooks: RecordingHooks())
        runtime.connect(host.channel)
        var exchanges: [FrozenExchange] = []
        for call in try hostCalls() {
            exchanges.append(FrozenExchange(call: call, reply: await runtime.handle(call)))
        }
        try encoder.encode(exchanges).write(to: out.appendingPathComponent("host-calls.json"))
        try encoder.encode(try sceneCalls()).write(to: out.appendingPathComponent("scene-calls.json"))
    }

    /// Every frozen release with an extension half.
    private static var frozenVersions: [URL] {
        let versions = (try? FileManager.default.contentsOfDirectory(at: compatRoot, includingPropertiesForKeys: nil)) ?? []
        return versions.map { $0.appendingPathComponent("extension") }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("host-calls.json").path) }
    }

    @Test("at least one release has a frozen extension wire")
    func fixturesExist() {
        #expect(!Self.frozenVersions.isEmpty, "expected Fixtures/compat/<version>/extension/ next to this package")
    }

    @Test("every frozen host call is still understood: none is unsupported or unreadable")
    func frozenHostCallsReplay() async throws {
        for dir in Self.frozenVersions {
            let exchanges = try JSONDecoder().decode([FrozenExchange].self,
                                                     from: Data(contentsOf: dir.appendingPathComponent("host-calls.json")))
            let host = answeringHost()
            let runtime = Work42ExtensionRuntime(widgets: [ExtensionWidgetFactory("counter") { CountingWidget() }],
                                                 sessionHooks: RecordingHooks())
            runtime.connect(host.channel)
            for exchange in exchanges {
                let reply = await runtime.handle(exchange.call)
                let message = reply.error?.message ?? ""
                #expect(!message.contains("not supported") && !message.contains("could not be read"),
                        "\(dir.path): \(exchange.call.name) → \(message)")
                // A call the frozen runtime answered must still succeed, and vice versa.
                #expect((reply.error == nil) == (exchange.reply.error == nil), "\(dir.path): \(exchange.call.name)")
            }
        }
    }

    @Test("every frozen extension call still decodes, and each non-idempotent one carries a request id")
    func frozenExtensionCallsDecode() throws {
        for dir in Self.frozenVersions {
            let calls = try JSONDecoder().decode([ExtensionCall].self,
                                                 from: Data(contentsOf: dir.appendingPathComponent("extension-calls.json")))
            #expect(!calls.isEmpty)
            for call in calls {
                #expect((call.requestId != nil) == ExtensionCall.nonIdempotentMethods.contains(call.name),
                        "\(dir.path): \(call.name)")
            }
            let scene = try JSONDecoder().decode([ExtensionCall].self,
                                                 from: Data(contentsOf: dir.appendingPathComponent("scene-calls.json")))
            for call in scene {
                _ = try ExtensionJSON.decode(ExtensionPayload.SessionContext.self, from: call.payload)
            }
        }
    }
}
