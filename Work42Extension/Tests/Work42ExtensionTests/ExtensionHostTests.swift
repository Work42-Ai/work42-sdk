// ExtensionHostTests.swift — Work42's end of the wire against the real extension runtime, over memory (WOR-863).
//
// `Pair` is one connection: an `ExtensionHostLink` (what Work42 runs) and a `Work42ExtensionRuntime` (what the extension
// runs), joined by closures instead of XPC. `crash()` is what a killed extension process looks like from Work42: every
// pending and later reply is lost, and the link is told the connection is gone.

import Foundation
import SwiftUI
import Testing
import Work42Extension
import Work42PluginKit

// MARK: - Host-side fakes

/// The host's shell: counts every command it runs, and can hold one until released (a command in flight during a crash).
nonisolated final class CountingShell: WidgetShellService, @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String] = []
    private var gate: CheckedContinuation<Void, Never>?
    var holdNext = false
    var started: (@Sendable () -> Void)?

    var ran: [String] { lock.withLock { commands } }

    func run(command: String) async throws -> WidgetShellResult {
        let hold = lock.withLock { () -> Bool in
            commands.append(command)
            defer { holdNext = false }
            return holdNext
        }
        started?()
        if hold { await withCheckedContinuation { continuation in lock.withLock { gate = continuation } } }
        return WidgetShellResult(stdout: "ran \(command)\n", stderr: "", exitCode: 0)
    }

    func release() { lock.withLock { let pending = gate; gate = nil; return pending }?.resume() }
}

nonisolated final class MemoryStore: WidgetStorageService, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: WidgetJSONValue] = [:]
    func get(namespace: String, key: String) async throws -> WidgetJSONValue? { lock.withLock { values["\(namespace)/\(key)"] } }
    func list(namespace: String) async throws -> [String: WidgetJSONValue] { lock.withLock { values } }
    func set(key: String, value: WidgetJSONValue) async throws { lock.withLock { values[key] = value } }
    func delete(key: String) async throws { _ = lock.withLock { values.removeValue(forKey: key) } }
    func person(key: String) async throws -> WidgetJSONValue? { lock.withLock { values["me/\(key)"] } }
    func setPerson(key: String, value: WidgetJSONValue) async throws { lock.withLock { values["me/\(key)"] = value } }
    func deletePerson(key: String) async throws { _ = lock.withLock { values.removeValue(forKey: "me/\(key)") } }
    func people(key: String) async throws -> [String: WidgetJSONValue] { [:] }
    func value(_ key: String) -> WidgetJSONValue? { lock.withLock { values[key] } }
}

nonisolated struct NullComposer: WidgetComposerService {
    func insert(text: String) async throws {}
    func attach(sourceLabel: String, excerpt: String, body: String) async throws {}
}

nonisolated struct NullIntents: WidgetIntentsService {
    func execute(id: String, params: [String: WidgetJSONValue]) async throws {}
}

nonisolated struct NullPill: WidgetPillService {
    func present(widgetId: String, sessionId: String) async throws {}
    func dismiss(widgetId: String) async throws {}
    func isPresented(widgetId: String) async throws -> Bool { false }
}

nonisolated func hostServices(shell: CountingShell, storage: MemoryStore, sessionId: String) -> SessionServices {
    SessionServices(composer: NullComposer(), shell: shell, intents: NullIntents(), storage: storage, pill: NullPill(),
                    sessionId: sessionId, worktreePath: "/tmp/\(sessionId)")
}

// MARK: - One connection over memory

@MainActor
final class Pair {
    let link: ExtensionHostLink
    let runtime: Work42ExtensionRuntime
    private let state = CrashState()

    /// One reply, delivered at most once: by its answer, or by a crash, whichever comes first.
    nonisolated final class PendingReply: @unchecked Sendable {
        private let lock = NSLock()
        private var reply: (@Sendable (Data?) -> Void)?
        init(_ reply: @escaping @Sendable (Data?) -> Void) { self.reply = reply }
        func send(_ data: Data?) { lock.withLock { let pending = reply; reply = nil; return pending }?(data) }
    }

    nonisolated final class CrashState: @unchecked Sendable {
        private let lock = NSLock()
        private var crashed = false
        private var pending: [PendingReply] = []
        /// Keeps `reply` so a crash can fail it; nil when already crashed (then it fails now).
        func hold(_ reply: @escaping @Sendable (Data?) -> Void) -> PendingReply? {
            lock.withLock {
                guard !crashed else { return nil }
                let held = PendingReply(reply)
                pending.append(held)
                return held
            }
        }
        func crash() -> [PendingReply] { lock.withLock { crashed = true; defer { pending.removeAll() }; return pending } }
        var isCrashed: Bool { lock.withLock { crashed } }
    }

    init(widgets: [ExtensionWidgetFactory], hooks: (any Work42SessionHooks)? = nil,
         sessionTypes: [ExtensionSessionTypeFactory] = [], deadline: Duration = ExtensionHostLink.uiDeadline) {
        let state = self.state
        let runtime = Work42ExtensionRuntime(widgets: widgets, sessionHooks: hooks, sessionTypes: sessionTypes)
        self.runtime = runtime
        // Host -> extension.
        let toExtension = ClosureExtensionTransport { data, reply in
            guard let held = state.hold(reply) else { reply(nil); return }
            Task { @MainActor in
                let answer = await runtime.handle(encoded: data)
                if !state.isCrashed { held.send(answer) }
            }
        }
        let link = ExtensionHostLink(transport: toExtension, deadline: deadline)
        self.link = link
        // Extension -> host.
        let extensionChannel = ExtensionChannel(transport: ClosureExtensionTransport { data, reply in
            guard let held = state.hold(reply) else { reply(nil); return }
            Task { @MainActor in
                let answer = await link.handleIncoming(data)
                if !state.isCrashed { held.send(answer) }
            }
        })
        link.server.push = { event in extensionChannel.deliver(event) }
        runtime.connect(extensionChannel)
    }

    /// The extension process dies: no reply arrives any more, on either side.
    func crash() {
        for reply in state.crash() { reply.send(nil) }
        link.connectionLost()
        runtime.disconnect()
    }
}

/// A widget whose intent runs one shell command through its services.
@MainActor
final class ShellWidget: Work42Widget {
    let id = "todos"
    let title = "Todos"
    let icon = "checklist"
    let linkIntents: [WidgetLinkIntentSpec] = []
    var intents: [WidgetIntentSpec] {
        [WidgetIntentSpec(name: "sync", title: "Sync", icon: "arrow.clockwise", isConfirmed: nil) { services in
            _ = try await services.shell.run(command: "git pull")
            try await services.storage.set(key: "todos/synced", value: .bool(true))
        }]
    }
    func makeView(services: SessionServices) -> AnyView { AnyView(EmptyView()) }
}

nonisolated final class ShellHooks: Work42SessionHooks, @unchecked Sendable {
    func onCreate(_ context: SessionCreateContext) async throws {
        _ = try await context.shell.run(command: "make setup")
    }
}

private func performIntent(_ name: String, session: String, widget: String = "todos") throws -> ExtensionCall {
    try ExtensionCall.make(service: "extension", method: "performIntent", sessionId: session, widgetId: widget,
                           payload: ExtensionPayload.PerformIntent(name: name, params: [:], worktreePath: "/tmp/\(session)"))
}

// MARK: - Tests

@Suite("Work42 host end of the wire", .serialized)
@MainActor
struct ExtensionHostTests {

    @Test("an intent runs in the extension and its service calls run on the host's services for that session")
    func intentRoundTrip() async throws {
        let pair = Pair(widgets: [ExtensionWidgetFactory("todos") { ShellWidget() }])
        let shell = CountingShell(), store = MemoryStore()
        pair.link.server.attach(hostServices(shell: shell, storage: store, sessionId: "s1"), widgetId: "todos", sessionId: "s1")

        _ = try await pair.link.send(try performIntent("sync", session: "s1"), kind: .ui)

        #expect(shell.ran == ["git pull"])
        #expect(store.value("todos/synced") == .bool(true))
        // Both requests that must not run twice were recorded, and both finished.
        let recorded = pair.link.ledger.entries(forSession: "s1")
        #expect(Set(recorded.map(\.name)) == ["extension.performIntent", "shell.run"])
        #expect(recorded.allSatisfy { $0.status == .done })
    }

    @Test("a call for a session the host has no services for is refused by name")
    func unknownScope() async throws {
        let pair = Pair(widgets: [ExtensionWidgetFactory("todos") { ShellWidget() }])
        let error = await #expect(throws: WidgetServiceError.self) {
            _ = try await pair.link.send(try performIntent("sync", session: "nobody"), kind: .ui)
        }
        #expect(error?.message.contains("shell.run is only available") == true)
    }

    @Test("a crash mid shell.run: the command ran exactly once, the caller is told 'interrupted', nothing is re-sent")
    func crashMidShellRun() async throws {
        let pair = Pair(widgets: [ExtensionWidgetFactory("todos") { ShellWidget() }])
        let shell = CountingShell(), store = MemoryStore()
        pair.link.server.attach(hostServices(shell: shell, storage: store, sessionId: "s1"), widgetId: "todos", sessionId: "s1")
        shell.holdNext = true
        let started = AsyncStream<Void>.makeStream()
        shell.started = { started.continuation.yield() }

        let intent = try performIntent("sync", session: "s1")
        let result = Task { @MainActor in try await pair.link.send(intent, kind: .work) }
        for await _ in started.stream { break }   // the host is running the command
        pair.crash()
        shell.release()

        let error = await #expect(throws: WidgetServiceError.self) { _ = try await result.value }
        #expect(error == .extensionInterrupted)
        #expect(error?.message == "interrupted: the extension stopped" && error?.suggestion == "retry the action")
        #expect(shell.ran == ["git pull"])
        #expect(store.value("todos/synced") == nil)   // the intent never got past the command
        #expect(pair.link.ledger.entries(forSession: "s1").allSatisfy { $0.status == .interrupted })
        #expect(pair.link.ledger.inFlightCount == 0)

        // A restart is a new connection; the interrupted request is not sent again, so the command still ran once.
        let restarted = Pair(widgets: [ExtensionWidgetFactory("todos") { ShellWidget() }])
        restarted.link.server.attach(hostServices(shell: shell, storage: store, sessionId: "s1"), widgetId: "todos",
                                     sessionId: "s1")
        try await Task.sleep(for: .milliseconds(50))
        #expect(shell.ran == ["git pull"])
    }

    @Test("a request id that reaches the host twice runs once")
    func duplicateRequestRunsOnce() async throws {
        let pair = Pair(widgets: [])
        let shell = CountingShell()
        pair.link.server.attach(hostServices(shell: shell, storage: MemoryStore(), sessionId: "s1"), widgetId: "todos",
                                sessionId: "s1")
        let call = try ExtensionCall.make(service: "shell", method: "run", sessionId: "s1", widgetId: "todos",
                                          payload: ExtensionPayload.Command(command: "deploy"))
        #expect(await pair.link.server.handle(call).error == nil)
        let again = await pair.link.server.handle(call)
        #expect(again.error?.message.contains("never run twice") == true)
        #expect(shell.ran == ["deploy"])
    }

    @Test("a hook runs with the session's create context, and a crash during it reports 'interrupted'")
    func hookThroughTheLink() async throws {
        let pair = Pair(widgets: [], hooks: ShellHooks())
        let shell = CountingShell()
        pair.link.server.attachCreateContext(SessionCreateContext(
            sessionId: "s2", name: "New", worktreePath: "/tmp/s2", params: [:], storage: MemoryStore(), shell: shell))
        let hook = try ExtensionCall.make(service: "extension", method: "hook", sessionId: "s2", widgetId: nil,
                                          payload: ExtensionPayload.Hook(event: "onCreate", name: "New",
                                                                         worktreePath: "/tmp/s2", params: [:]))
        _ = try await pair.link.send(hook, kind: .work)
        #expect(shell.ran == ["make setup"])
        pair.link.server.detachCreateContext(sessionId: "s2")
    }

    @Test("a UI request with no reply by the deadline reports a hang; stopping the process interrupts it")
    func hangIsDetected() async throws {
        let pair = Pair(widgets: [ExtensionWidgetFactory("todos") { ShellWidget() }], deadline: .milliseconds(100))
        let shell = CountingShell()
        shell.holdNext = true   // the extension's intent never gets its reply: it looks hung from the host
        pair.link.server.attach(hostServices(shell: shell, storage: MemoryStore(), sessionId: "s1"), widgetId: "todos",
                                sessionId: "s1")
        var hung: [String] = []
        pair.link.onHang = { call in hung.append(call.name); pair.crash() }

        let error = await #expect(throws: WidgetServiceError.self) {
            _ = try await pair.link.send(try performIntent("sync", session: "s1"), kind: .ui)
        }
        #expect(error == .extensionInterrupted)
        #expect(hung == ["extension.performIntent"])
        shell.release()
    }

    @Test("streams the extension opens get the host's items and stop when the connection is lost")
    func streamsCrossAndStop() async throws {
        let pair = Pair(widgets: [])
        let shell = CountingShell()
        let (cursors, continuation) = AsyncStream<[WidgetCursor]>.makeStream()
        let collaboration = StreamingCollaboration(source: cursors)
        pair.link.server.attach(SessionServices(composer: NullComposer(), shell: shell, intents: NullIntents(),
                                                storage: MemoryStore(), pill: NullPill(), sessionId: "s1",
                                                collaboration: collaboration),
                                widgetId: "todos", sessionId: "s1")
        let extensionSide = ExtensionServices.session(channel: try #require(pair.runtime.channel), sessionId: "s1",
                                                      widgetId: "todos", worktreePath: nil)
        var iterator = extensionSide.collaboration.cursors().makeAsyncIterator()
        try await Task.sleep(for: .milliseconds(50))
        #expect(pair.link.server.openStreamCount == 1)
        continuation.yield([])
        let first = await iterator.next()
        #expect(first?.isEmpty == true)
        pair.crash()
        #expect(pair.link.server.openStreamCount == 0)
        let end = await iterator.next()
        #expect(end == nil)
    }

    @Test("every frozen extension call has a host handler")
    func everyFrozenCallIsHandled() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/compat")
        let versions = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for file in versions.map({ $0.appendingPathComponent("extension/extension-calls.json") })
        where FileManager.default.fileExists(atPath: file.path) {
            let calls = try JSONDecoder().decode([ExtensionCall].self, from: Data(contentsOf: file))
            let server = ExtensionHostServer(ledger: ExtensionRequestLedger())
            for call in calls {
                let message = await server.handle(call).error?.message ?? ""
                #expect(!message.contains("not supported"), "\(file.path): \(call.name)")
            }
        }
    }
}

nonisolated struct StreamingCollaboration: WidgetCollaborationService {
    let source: AsyncStream<[WidgetCursor]>
    func members() async throws -> [WidgetCollaborator] { [.solo] }
    func cursors() -> AsyncStream<[WidgetCursor]> { source }
    func report(_ cursor: WidgetCursorReport?) async throws {}
}
