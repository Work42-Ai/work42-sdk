// ExtensionHost.swift — Work42's end of the wire to one extension process (SDK 3.2.0, host side).
//
// `ExtensionHostLink` is one connection: it sends Work42's requests (`extension.*`, recorded in the ledger, UI requests
// bounded by a deadline) and answers the extension's calls through `ExtensionHostServer`, which runs each one against the
// services Work42 built for that widget in that session: the same `SessionServices`, `WidgetBackgroundServices` and
// `SessionCreateContext` an in-process plugin is handed. Like the rest of the wire it is plain Swift; the app connects it to
// ExtensionKit's XPC connection, tests to an in-memory transport.

import Foundation
import Work42PluginKit

// MARK: - Server: the extension's calls

@MainActor
public final class ExtensionHostServer {

    private struct Scope: Hashable { let sessionId: String; let widgetId: String }

    public let ledger: ExtensionRequestLedger
    /// Sends a stream item (or a stream's end) to the extension.
    public var push: (@MainActor (ExtensionStreamEvent) -> Void)?

    private var sessionServices: [Scope: SessionServices] = [:]
    private var backgroundServices: [Scope: WidgetBackgroundServices] = [:]
    private var createContexts: [String: SessionCreateContext] = [:]
    private var streams: [UUID: Task<Void, Never>] = [:]

    public init(ledger: ExtensionRequestLedger) {
        self.ledger = ledger
    }

    // MARK: Which services answer

    /// The services widget `widgetId` was activated with in `sessionId`: what its scene, intents and link intents use.
    public func attach(_ services: SessionServices, widgetId: String, sessionId: String) {
        sessionServices[Scope(sessionId: sessionId, widgetId: widgetId)] = services
    }

    public func detach(widgetId: String, sessionId: String) {
        sessionServices.removeValue(forKey: Scope(sessionId: sessionId, widgetId: widgetId))
    }

    /// The services widget `widgetId`'s background agent was started with in `sessionId`.
    public func attachBackground(_ services: WidgetBackgroundServices, widgetId: String, sessionId: String) {
        backgroundServices[Scope(sessionId: sessionId, widgetId: widgetId)] = services
    }

    public func detachBackground(widgetId: String, sessionId: String) {
        backgroundServices.removeValue(forKey: Scope(sessionId: sessionId, widgetId: widgetId))
    }

    /// The context a session hook runs with, for the length of the hook.
    public func attachCreateContext(_ context: SessionCreateContext) {
        createContexts[context.sessionId] = context
    }

    public func detachCreateContext(sessionId: String) {
        createContexts.removeValue(forKey: sessionId)
    }

    /// The connection is gone: every stream the extension had open stops.
    public func stopStreams() {
        for task in streams.values { task.cancel() }
        streams.removeAll()
    }

    public var openStreamCount: Int { streams.count }

    // MARK: Answering

    public func handle(encoded: Data) async -> Data {
        let reply: ExtensionReply
        do {
            reply = await handle(try ExtensionJSON.decode(ExtensionCall.self, from: encoded))
        } catch {
            reply = .failure(error)
        }
        return (try? ExtensionJSON.encode(reply)) ?? Data("{}".utf8)
    }

    public func handle(_ call: ExtensionCall) async -> ExtensionReply {
        let tracked = ExtensionCall.nonIdempotentMethods.contains(call.name)
        if tracked {
            guard call.requestId != nil else {
                return .failure(WidgetServiceError(message: "\(call.name) needs a requestId",
                                                   suggestion: "send it through the SDK's service proxies"))
            }
            // A request id seen before already ran (or was interrupted while running): never run it a second time.
            guard ledger.begin(call) else {
                return .failure(WidgetServiceError(
                    message: "\(call.name) request \(call.requestId?.uuidString ?? "") was already received; it is never run twice",
                    suggestion: "send a new request to run it again"))
            }
        }
        defer { if tracked, let id = call.requestId { ledger.finish(id) } }
        do {
            return try await dispatch(call)
        } catch {
            return .failure(error)
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func dispatch(_ call: ExtensionCall) async throws -> ExtensionReply {
        func args<T: Decodable>(_ type: T.Type) throws -> T { try ExtensionJSON.decode(type, from: call.payload) }
        let empty = try ExtensionReply.success(ExtensionEmpty())

        switch call.name {
        // composer
        case "composer.insert":
            try await session(call).composer.insert(text: try args(ExtensionPayload.Text.self).text)
            return empty
        case "composer.attach":
            let a = try args(ExtensionPayload.Attach.self)
            try await session(call).composer.attach(sourceLabel: a.sourceLabel, excerpt: a.excerpt, body: a.body)
            return empty
        case "composer.presentCommentableSelection":
            let a = try args(ExtensionPayload.Selection.self)
            try await session(call).composer.presentCommentableSelection(sourceLabel: a.sourceLabel, excerpt: a.excerpt)
            return empty
        case "composer.clearCommentableSelection":
            try await session(call).composer.clearCommentableSelection()
            return empty

        // shell, intents
        case "shell.run":
            return try .success(try await shell(call).run(command: try args(ExtensionPayload.Command.self).command))
        case "intents.execute":
            let a = try args(ExtensionPayload.Intent.self)
            try await session(call).intents.execute(id: a.id, params: a.params)
            return empty

        // storage
        case "storage.get":
            let a = try args(ExtensionPayload.NamespacedKey.self)
            return try .success(ExtensionPayload.OptionalValue(value: try await storage(call).get(namespace: a.namespace, key: a.key)))
        case "storage.list":
            return try .success(try await storage(call).list(namespace: try args(ExtensionPayload.Namespace.self).namespace))
        case "storage.set":
            let a = try args(ExtensionPayload.KeyValue.self)
            try await storage(call).set(key: a.key, value: a.value)
            return empty
        case "storage.delete":
            try await storage(call).delete(key: try args(ExtensionPayload.Key.self).key)
            return empty
        case "storage.person":
            let key = try args(ExtensionPayload.Key.self).key
            return try .success(ExtensionPayload.OptionalValue(value: try await storage(call).person(key: key)))
        case "storage.setPerson":
            let a = try args(ExtensionPayload.KeyValue.self)
            try await storage(call).setPerson(key: a.key, value: a.value)
            return empty
        case "storage.deletePerson":
            try await storage(call).deletePerson(key: try args(ExtensionPayload.Key.self).key)
            return empty
        case "storage.people":
            return try .success(try await storage(call).people(key: try args(ExtensionPayload.Key.self).key))

        // pill
        case "pill.present":
            let a = try args(ExtensionPayload.Pill.self)
            try await pill(call).present(widgetId: a.widgetId, sessionId: a.sessionId ?? call.sessionId ?? "")
            return empty
        case "pill.dismiss":
            try await pill(call).dismiss(widgetId: try args(ExtensionPayload.Pill.self).widgetId)
            return empty
        case "pill.isPresented":
            let a = try args(ExtensionPayload.Pill.self)
            return try .success(ExtensionPayload.Flag(value: try await pill(call).isPresented(widgetId: a.widgetId)))

        // tools
        case "tools.listTools":
            return try .success(try await tools(call).listTools())
        case "tools.call":
            let a = try args(ExtensionPayload.ToolCall.self)
            return try .success(try await tools(call).call(server: a.server, tool: a.tool, arguments: a.arguments,
                                                           session: a.session))

        // files
        case "files.read":
            let path = try args(ExtensionPayload.Path.self).path
            try WidgetFilePath.validate(path)
            return try .success(ExtensionPayload.Bytes(data: try await files(call).read(path)))
        case "files.list":
            let path = try args(ExtensionPayload.Path.self).path
            try WidgetFilePath.validate(path)
            return try .success(try await files(call).list(path))
        case "files.watch":
            let sub = try args(ExtensionSubscription<ExtensionPayload.Path>.self)
            try WidgetFilePath.validate(sub.arguments.path)
            let source = try files(call).watch(sub.arguments.path)
            open(sub.streamId) { yield in for await _ in source { yield(try? ExtensionJSON.encode(ExtensionEmpty())) } }
            return empty

        // account, collaboration, activity
        case "account.currentUser":
            let user = await WidgetAccountRegistry.service?.currentUser()
            return try .success(ExtensionPayload.OptionalAccountUser(user: user.map {
                ExtensionPayload.AccountUser(displayName: $0.displayName, email: $0.email, photoURL: $0.photoURL)
            }))
        case "collaboration.members":
            return try .success(try await session(call).collaboration.members())
        case "collaboration.report":
            try await session(call).collaboration.report(try args(ExtensionPayload.CursorReport.self).cursor)
            return empty
        case "collaboration.cursors":
            let sub = try args(ExtensionSubscription<ExtensionEmpty>.self)
            let source = try session(call).collaboration.cursors()
            open(sub.streamId) { yield in for await cursors in source { yield(try? ExtensionJSON.encode(cursors)) } }
            return empty
        case "activity.ping":
            guard let background = background(call) else { throw unavailable(call, "a background agent") }
            await background.activity.ping()
            return empty

        // host streams
        case "streams.subscribe":
            let sub = try args(ExtensionSubscription<ExtensionPayload.HostStream>.self)
            guard let service = WidgetStreamRegistry.service else {
                throw WidgetServiceError(message: "host streams are not available here", suggestion: nil)
            }
            let source = service.subscribe(session: sub.arguments.session, widget: sub.arguments.widget,
                                           stream: sub.arguments.stream)
            open(sub.streamId) { yield in
                for await data in source { yield(try? ExtensionJSON.encode(ExtensionPayload.Bytes(data: data))) }
            }
            return empty

        // browser
        case "browser.setTabs":
            try await session(call).browser.setTabs(try args(ExtensionPayload.Tabs.self).tabs)
            return empty
        case "browser.selectTab":
            try await session(call).browser.selectTab(try args(ExtensionPayload.TabId.self).id)
            return empty
        case "browser.updateTab":
            let a = try args(ExtensionPayload.TabUpdate.self)
            try await session(call).browser.updateTab(a.id, title: a.title, url: a.url, icon: a.icon)
            return empty
        case "browser.tabs":
            let sub = try args(ExtensionSubscription<ExtensionEmpty>.self)
            let source = try session(call).browser.tabs
            open(sub.streamId) { yield in for await state in source { yield(try? ExtensionJSON.encode(state)) } }
            return empty
        case "browser.events":
            let sub = try args(ExtensionSubscription<ExtensionEmpty>.self)
            let source = try session(call).browser.events
            open(sub.streamId) { yield in for await event in source { yield(try? ExtensionJSON.encode(event)) } }
            return empty

        case "stream.cancel":
            let sub = try args(ExtensionSubscription<ExtensionEmpty>.self)
            streams.removeValue(forKey: sub.streamId)?.cancel()
            return empty

        default:
            return .failure(WidgetServiceError.unsupported(call))
        }
    }

    // MARK: Streams

    /// Runs `body` as stream `streamId`, pushing what it yields, then the stream's end.
    private func open(_ streamId: UUID,
                      _ body: @escaping @MainActor (_ yield: @MainActor (Data?) -> Void) async -> Void) {
        streams[streamId]?.cancel()
        streams[streamId] = Task { [weak self] in
            await body { item in
                guard let item, !Task.isCancelled else { return }
                self?.push?(ExtensionStreamEvent(streamId: streamId, item: item))
            }
            guard let self, !Task.isCancelled else { return }
            self.streams.removeValue(forKey: streamId)
            self.push?(ExtensionStreamEvent(streamId: streamId, finished: true))
        }
    }

    // MARK: Service lookup

    private func scope(_ call: ExtensionCall) -> Scope? {
        guard let sessionId = call.sessionId, let widgetId = call.widgetId else { return nil }
        return Scope(sessionId: sessionId, widgetId: widgetId)
    }

    private func background(_ call: ExtensionCall) -> WidgetBackgroundServices? {
        scope(call).flatMap { backgroundServices[$0] }
    }

    private func session(_ call: ExtensionCall) throws -> SessionServices {
        guard let scope = scope(call), let services = sessionServices[scope] else {
            throw unavailable(call, "a widget shown in a session")
        }
        return services
    }

    private func shell(_ call: ExtensionCall) throws -> any WidgetShellService {
        if let scope = scope(call) {
            if let services = sessionServices[scope] { return services.shell }
            if let services = backgroundServices[scope] { return services.shell }
        }
        if let sessionId = call.sessionId, let context = createContexts[sessionId] { return context.shell }
        throw unavailable(call, "a widget, a background agent or a session hook")
    }

    private func storage(_ call: ExtensionCall) throws -> any WidgetStorageService {
        if let scope = scope(call) {
            if let services = sessionServices[scope] { return services.storage }
            if let services = backgroundServices[scope] { return services.storage }
        }
        if let sessionId = call.sessionId, let context = createContexts[sessionId] { return context.storage }
        throw unavailable(call, "a widget, a background agent or a session hook")
    }

    private func tools(_ call: ExtensionCall) throws -> any WidgetToolService {
        if let scope = scope(call) {
            if let services = sessionServices[scope] { return services.tools }
            if let services = backgroundServices[scope] { return services.tools }
        }
        if let sessionId = call.sessionId, let context = createContexts[sessionId] { return context.tools }
        throw unavailable(call, "a widget, a background agent or a session hook")
    }

    private func pill(_ call: ExtensionCall) throws -> any WidgetPillService {
        if let scope = scope(call) {
            if let services = sessionServices[scope] { return services.pill }
            if let services = backgroundServices[scope] { return services.pill }
        }
        throw unavailable(call, "a widget or a background agent")
    }

    private func files(_ call: ExtensionCall) throws -> any WidgetFileService {
        if let scope = scope(call) {
            if let services = sessionServices[scope] { return services.files }
            if let services = backgroundServices[scope] { return services.files }
        }
        throw unavailable(call, "a widget or a background agent")
    }

    private func unavailable(_ call: ExtensionCall, _ needs: String) -> WidgetServiceError {
        let who = [call.widgetId.map { "widget '\($0)'" }, call.sessionId.map { "session \($0)" }]
            .compactMap { $0 }.joined(separator: " in ")
        return WidgetServiceError(
            message: "\(call.name) is only available to \(needs); \(who.isEmpty ? "this call" : who) has none right now",
            suggestion: "call it from the widget's view, an intent, its background agent or a session hook")
    }
}

// MARK: - Link: one connection

/// What a host request needs: no deadline (hooks, background work), or a reply within `uiDeadline` (what a person is
/// waiting on: a scene, an intent, a link).
nonisolated public enum ExtensionRequestKind: Sendable {
    case ui
    case work
}

@MainActor
public final class ExtensionHostLink {

    /// How long a UI request may go unanswered before the extension counts as hung (WOR-863: 10 s).
    nonisolated public static let uiDeadline: Duration = .seconds(10)

    public let channel: ExtensionChannel
    public let server: ExtensionHostServer
    public var ledger: ExtensionRequestLedger { server.ledger }
    /// The extension did not answer a UI request in time. The owner stops the process, which interrupts the request.
    public var onHang: (@MainActor (ExtensionCall) -> Void)?
    public private(set) var isConnected = true
    private let deadline: Duration

    public init(transport: any ExtensionTransport, ledger: ExtensionRequestLedger = ExtensionRequestLedger(),
                deadline: Duration = ExtensionHostLink.uiDeadline) {
        self.channel = ExtensionChannel(transport: transport, interruption: .extensionInterrupted)
        self.server = ExtensionHostServer(ledger: ledger)
        self.deadline = deadline
    }

    /// Sends `call`, recording it when it must not run twice. A UI request with no reply by the deadline reports a hang;
    /// the caller then gets `extensionInterrupted` once the owner stops the process.
    public func send(_ call: ExtensionCall, kind: ExtensionRequestKind) async throws -> Data {
        let tracked = ledger.begin(call)
        defer { if tracked, let id = call.requestId, ledger.entry(id)?.status == .sent { ledger.finish(id) } }
        guard kind == .ui else { return try await channel.sendRaw(call) }
        let watchdog = Task { [weak self, deadline] in
            try? await Task.sleep(for: deadline)
            guard !Task.isCancelled, let self, self.isConnected else { return }
            self.onHang?(call)
        }
        defer { watchdog.cancel() }
        return try await channel.sendRaw(call)
    }

    public func send<Result: Decodable>(_ call: ExtensionCall, kind: ExtensionRequestKind,
                                        as type: Result.Type) async throws -> Result {
        try ExtensionJSON.decode(type, from: try await send(call, kind: kind))
    }

    /// An encoded call from the extension, answered by the server.
    public func handleIncoming(_ encoded: Data) async -> Data {
        await server.handle(encoded: encoded)
    }

    /// The process stopped or the connection broke: waiting calls throw `extensionInterrupted`, in-flight requests are
    /// marked interrupted (never re-sent), and the extension's streams stop. Returns the interrupted requests.
    @discardableResult
    public func connectionLost() -> [ExtensionRequestLedger.Entry] {
        guard isConnected else { return [] }
        isConnected = false
        channel.close()
        server.stopStreams()
        return ledger.interruptInFlight()
    }
}
