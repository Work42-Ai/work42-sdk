// ExtensionServiceProxies.swift — `SessionServices` inside an extension process (SDK 3.2.0).
//
// A widget running out of process gets the same `SessionServices` it gets in process; each member is a proxy that sends the
// call to Work42 over the extension's channel, carrying the session and widget the host assigned. `platform` is the one
// exception: opening a link and copying text happen on this Mac either way, so it stays local.
//
// Wire names: `<service>.<method>`, with the payload structs below. The host implements the same names (WOR-863).

import Foundation
import Work42PluginKit

/// Where a proxy sends its calls: the channel plus the session and widget it acts for.
nonisolated public struct ExtensionServiceScope: Sendable {
    public let channel: ExtensionChannel
    public let sessionId: String?
    public let widgetId: String?

    public init(channel: ExtensionChannel, sessionId: String?, widgetId: String?) {
        self.channel = channel
        self.sessionId = sessionId
        self.widgetId = widgetId
    }

    func call<Payload: Encodable, Result: Decodable>(_ service: String, _ method: String, _ payload: Payload,
                                                     as type: Result.Type) async throws -> Result {
        try await channel.call(service, method, sessionId: sessionId, widgetId: widgetId, payload: payload, as: type)
    }

    func call<Payload: Encodable>(_ service: String, _ method: String, _ payload: Payload) async throws {
        try await channel.call(service, method, sessionId: sessionId, widgetId: widgetId, payload: payload)
    }

    func subscribe<Arguments: Codable & Sendable>(_ service: String, _ method: String,
                                                  _ arguments: Arguments) -> AsyncStream<Data> {
        channel.subscribe(service, method, sessionId: sessionId, widgetId: widgetId, arguments: arguments)
    }
}

/// Decodes each item of `raw` as `Item`, dropping (and ending on) an item that does not decode.
nonisolated func decodedStream<Item: Decodable & Sendable>(_ raw: AsyncStream<Data>, as type: Item.Type) -> AsyncStream<Item> {
    AsyncStream { continuation in
        let task = Task {
            for await data in raw {
                guard let item = try? ExtensionJSON.decode(type, from: data) else { break }
                continuation.yield(item)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

// MARK: - Payloads

/// The argument and result shapes of the proxied calls. Public so the host decodes exactly what the extension encodes.
public enum ExtensionPayload {
    nonisolated public struct Text: Codable, Sendable { public var text: String; public init(text: String) { self.text = text } }
    nonisolated public struct Attach: Codable, Sendable {
        public var sourceLabel: String, excerpt: String, body: String
        public init(sourceLabel: String, excerpt: String, body: String) {
            self.sourceLabel = sourceLabel; self.excerpt = excerpt; self.body = body
        }
    }
    nonisolated public struct Selection: Codable, Sendable {
        public var sourceLabel: String, excerpt: String
        public init(sourceLabel: String, excerpt: String) { self.sourceLabel = sourceLabel; self.excerpt = excerpt }
    }
    nonisolated public struct Command: Codable, Sendable { public var command: String; public init(command: String) { self.command = command } }
    nonisolated public struct Intent: Codable, Sendable {
        public var id: String, params: [String: WidgetJSONValue]
        public init(id: String, params: [String: WidgetJSONValue]) { self.id = id; self.params = params }
    }
    nonisolated public struct NamespacedKey: Codable, Sendable {
        public var namespace: String, key: String
        public init(namespace: String, key: String) { self.namespace = namespace; self.key = key }
    }
    nonisolated public struct Namespace: Codable, Sendable { public var namespace: String; public init(namespace: String) { self.namespace = namespace } }
    nonisolated public struct Key: Codable, Sendable { public var key: String; public init(key: String) { self.key = key } }
    nonisolated public struct KeyValue: Codable, Sendable {
        public var key: String, value: WidgetJSONValue
        public init(key: String, value: WidgetJSONValue) { self.key = key; self.value = value }
    }
    nonisolated public struct OptionalValue: Codable, Sendable { public var value: WidgetJSONValue?; public init(value: WidgetJSONValue?) { self.value = value } }
    nonisolated public struct Pill: Codable, Sendable {
        public var widgetId: String, sessionId: String?
        public init(widgetId: String, sessionId: String?) { self.widgetId = widgetId; self.sessionId = sessionId }
    }
    nonisolated public struct Flag: Codable, Sendable { public var value: Bool; public init(value: Bool) { self.value = value } }
    nonisolated public struct ToolCall: Codable, Sendable {
        public var server: String, tool: String, arguments: [String: WidgetJSONValue], session: String?
        public init(server: String, tool: String, arguments: [String: WidgetJSONValue], session: String?) {
            self.server = server; self.tool = tool; self.arguments = arguments; self.session = session
        }
    }
    nonisolated public struct Path: Codable, Sendable { public var path: String; public init(path: String) { self.path = path } }
    nonisolated public struct Bytes: Codable, Sendable { public var data: Data; public init(data: Data) { self.data = data } }
    nonisolated public struct AccountUser: Codable, Sendable {
        public var displayName: String?, email: String?, photoURL: URL?
        public init(displayName: String?, email: String?, photoURL: URL?) {
            self.displayName = displayName; self.email = email; self.photoURL = photoURL
        }
    }
    nonisolated public struct OptionalAccountUser: Codable, Sendable { public var user: AccountUser?; public init(user: AccountUser?) { self.user = user } }
    nonisolated public struct CursorReport: Codable, Sendable { public var cursor: WidgetCursorReport?; public init(cursor: WidgetCursorReport?) { self.cursor = cursor } }
    public struct Tabs: Codable, Sendable { public var tabs: [BrowserTab]; public init(tabs: [BrowserTab]) { self.tabs = tabs } }
    nonisolated public struct TabId: Codable, Sendable { public var id: UUID; public init(id: UUID) { self.id = id } }
    nonisolated public struct TabUpdate: Codable, Sendable {
        public var id: UUID, title: String?, url: URL?, icon: String?
        public init(id: UUID, title: String?, url: URL?, icon: String?) { self.id = id; self.title = title; self.url = url; self.icon = icon }
    }
    nonisolated public struct HostStream: Codable, Sendable {
        public var session: String, widget: String, stream: String
        public init(session: String, widget: String, stream: String) { self.session = session; self.widget = widget; self.stream = stream }
    }
}

// MARK: - Proxies

nonisolated public struct ExtensionComposerProxy: WidgetComposerService {
    let scope: ExtensionServiceScope
    public init(scope: ExtensionServiceScope) { self.scope = scope }
    public func insert(text: String) async throws { try await scope.call("composer", "insert", ExtensionPayload.Text(text: text)) }
    public func attach(sourceLabel: String, excerpt: String, body: String) async throws {
        try await scope.call("composer", "attach", ExtensionPayload.Attach(sourceLabel: sourceLabel, excerpt: excerpt, body: body))
    }
    public func presentCommentableSelection(sourceLabel: String, excerpt: String) async throws {
        try await scope.call("composer", "presentCommentableSelection", ExtensionPayload.Selection(sourceLabel: sourceLabel, excerpt: excerpt))
    }
    public func clearCommentableSelection() async throws { try await scope.call("composer", "clearCommentableSelection", ExtensionEmpty()) }
}

nonisolated public struct ExtensionShellProxy: WidgetShellService {
    let scope: ExtensionServiceScope
    public init(scope: ExtensionServiceScope) { self.scope = scope }
    public func run(command: String) async throws -> WidgetShellResult {
        try await scope.call("shell", "run", ExtensionPayload.Command(command: command), as: WidgetShellResult.self)
    }
}

nonisolated public struct ExtensionIntentsProxy: WidgetIntentsService {
    let scope: ExtensionServiceScope
    public init(scope: ExtensionServiceScope) { self.scope = scope }
    public func execute(id: String, params: [String: WidgetJSONValue]) async throws {
        try await scope.call("intents", "execute", ExtensionPayload.Intent(id: id, params: params))
    }
}

nonisolated public struct ExtensionStorageProxy: WidgetStorageService {
    let scope: ExtensionServiceScope
    public init(scope: ExtensionServiceScope) { self.scope = scope }
    public func get(namespace: String, key: String) async throws -> WidgetJSONValue? {
        try await scope.call("storage", "get", ExtensionPayload.NamespacedKey(namespace: namespace, key: key),
                             as: ExtensionPayload.OptionalValue.self).value
    }
    public func list(namespace: String) async throws -> [String: WidgetJSONValue] {
        try await scope.call("storage", "list", ExtensionPayload.Namespace(namespace: namespace), as: [String: WidgetJSONValue].self)
    }
    public func set(key: String, value: WidgetJSONValue) async throws {
        try await scope.call("storage", "set", ExtensionPayload.KeyValue(key: key, value: value))
    }
    public func delete(key: String) async throws { try await scope.call("storage", "delete", ExtensionPayload.Key(key: key)) }
    public func person(key: String) async throws -> WidgetJSONValue? {
        try await scope.call("storage", "person", ExtensionPayload.Key(key: key), as: ExtensionPayload.OptionalValue.self).value
    }
    public func setPerson(key: String, value: WidgetJSONValue) async throws {
        try await scope.call("storage", "setPerson", ExtensionPayload.KeyValue(key: key, value: value))
    }
    public func deletePerson(key: String) async throws { try await scope.call("storage", "deletePerson", ExtensionPayload.Key(key: key)) }
    public func people(key: String) async throws -> [String: WidgetJSONValue] {
        try await scope.call("storage", "people", ExtensionPayload.Key(key: key), as: [String: WidgetJSONValue].self)
    }
}

nonisolated public struct ExtensionPillProxy: WidgetPillService {
    let scope: ExtensionServiceScope
    public init(scope: ExtensionServiceScope) { self.scope = scope }
    public func present(widgetId: String, sessionId: String) async throws {
        try await scope.call("pill", "present", ExtensionPayload.Pill(widgetId: widgetId, sessionId: sessionId))
    }
    public func dismiss(widgetId: String) async throws {
        try await scope.call("pill", "dismiss", ExtensionPayload.Pill(widgetId: widgetId, sessionId: nil))
    }
    public func isPresented(widgetId: String) async throws -> Bool {
        try await scope.call("pill", "isPresented", ExtensionPayload.Pill(widgetId: widgetId, sessionId: nil),
                             as: ExtensionPayload.Flag.self).value
    }
}

nonisolated public struct ExtensionToolProxy: WidgetToolService {
    let scope: ExtensionServiceScope
    public init(scope: ExtensionServiceScope) { self.scope = scope }
    public func listTools() async throws -> [WidgetToolInfo] {
        try await scope.call("tools", "listTools", ExtensionEmpty(), as: [WidgetToolInfo].self)
    }
    public func call(server: String, tool: String, arguments: [String: WidgetJSONValue],
                     session: String?) async throws -> WidgetJSONValue {
        try await scope.call("tools", "call", ExtensionPayload.ToolCall(server: server, tool: tool, arguments: arguments, session: session),
                             as: WidgetJSONValue.self)
    }
}

nonisolated public struct ExtensionFileProxy: WidgetFileService {
    let scope: ExtensionServiceScope
    public init(scope: ExtensionServiceScope) { self.scope = scope }
    public func read(_ relativePath: String) async throws -> Data {
        try WidgetFilePath.validate(relativePath)
        return try await scope.call("files", "read", ExtensionPayload.Path(path: relativePath), as: ExtensionPayload.Bytes.self).data
    }
    public func list(_ relativeDir: String) async throws -> [WidgetFileEntry] {
        try WidgetFilePath.validate(relativeDir)
        return try await scope.call("files", "list", ExtensionPayload.Path(path: relativeDir), as: [WidgetFileEntry].self)
    }
    public func watch(_ relativePath: String) -> AsyncStream<Void> {
        // A refused path finishes at once, as it does in process.
        guard (try? WidgetFilePath.validate(relativePath)) != nil else { return AsyncStream { $0.finish() } }
        let raw = scope.subscribe("files", "watch", ExtensionPayload.Path(path: relativePath))
        return AsyncStream { continuation in
            let task = Task {
                for await _ in raw { continuation.yield(()) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

nonisolated public struct ExtensionAccountProxy: WidgetAccountService {
    let scope: ExtensionServiceScope
    public init(scope: ExtensionServiceScope) { self.scope = scope }
    public func currentUser() async -> WidgetAccountUser? {
        guard let user = try? await scope.call("account", "currentUser", ExtensionEmpty(),
                                               as: ExtensionPayload.OptionalAccountUser.self).user else { return nil }
        return WidgetAccountUser(displayName: user.displayName, email: user.email, photoURL: user.photoURL)
    }
}

nonisolated public struct ExtensionCollaborationProxy: WidgetCollaborationService {
    let scope: ExtensionServiceScope
    public init(scope: ExtensionServiceScope) { self.scope = scope }
    public func members() async throws -> [WidgetCollaborator] {
        try await scope.call("collaboration", "members", ExtensionEmpty(), as: [WidgetCollaborator].self)
    }
    public func cursors() -> AsyncStream<[WidgetCursor]> {
        decodedStream(scope.subscribe("collaboration", "cursors", ExtensionEmpty()), as: [WidgetCursor].self)
    }
    public func report(_ cursor: WidgetCursorReport?) async throws {
        try await scope.call("collaboration", "report", ExtensionPayload.CursorReport(cursor: cursor))
    }
}

nonisolated public struct ExtensionActivityProxy: WidgetSessionActivityService {
    let scope: ExtensionServiceScope
    public init(scope: ExtensionServiceScope) { self.scope = scope }
    public func ping() async { try? await scope.call("activity", "ping", ExtensionEmpty()) }
}

nonisolated public struct ExtensionStreamProxy: WidgetStreamService {
    let scope: ExtensionServiceScope
    public init(scope: ExtensionServiceScope) { self.scope = scope }
    public func subscribe(session: String, widget: String, stream: String) -> AsyncStream<Data> {
        decodedStream(scope.subscribe("streams", "subscribe", ExtensionPayload.HostStream(session: session, widget: widget, stream: stream)),
                      as: ExtensionPayload.Bytes.self).map(\.data).asAsyncStream()
    }
}

nonisolated public struct ExtensionBrowserTabsProxy: BrowserTabsService {
    let scope: ExtensionServiceScope
    public init(scope: ExtensionServiceScope) { self.scope = scope }
    public func setTabs(_ tabs: [BrowserTab]) async throws {
        // `BrowserTab`'s Codable conformance is main-actor isolated, so the call is encoded there.
        let scope = self.scope
        let call = try await MainActor.run {
            try ExtensionCall.make(service: "browser", method: "setTabs", sessionId: scope.sessionId,
                                   widgetId: scope.widgetId, payload: ExtensionPayload.Tabs(tabs: tabs))
        }
        _ = try await scope.channel.sendRaw(call)
    }
    public func selectTab(_ id: UUID) async throws {
        try await scope.call("browser", "selectTab", ExtensionPayload.TabId(id: id))
    }
    public func updateTab(_ id: UUID, title: String?, url: URL?, icon: String?) async throws {
        try await scope.call("browser", "updateTab", ExtensionPayload.TabUpdate(id: id, title: title, url: url, icon: icon))
    }
    public var tabs: AsyncStream<BrowserTabsState> {
        let raw = scope.subscribe("browser", "tabs", ExtensionEmpty())
        return AsyncStream { continuation in
            let task = Task { @MainActor in
                for await data in raw {
                    guard let state = try? ExtensionJSON.decode(BrowserTabsState.self, from: data) else { break }
                    continuation.yield(state)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    public var events: AsyncStream<BrowserEvent> {
        let raw = scope.subscribe("browser", "events", ExtensionEmpty())
        return AsyncStream { continuation in
            let task = Task { @MainActor in
                for await data in raw {
                    guard let event = try? ExtensionJSON.decode(BrowserEvent.self, from: data) else { break }
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension AsyncSequence where Self: Sendable, Element: Sendable {
    /// Re-wraps any async sequence as an `AsyncStream`, so a mapped stream keeps the protocol's return type.
    nonisolated func asAsyncStream() -> AsyncStream<Element> {
        AsyncStream { continuation in
            let task = Task {
                do { for try await element in self { continuation.yield(element) } } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Assembled services

/// The service bundles an extension hands its widgets, every member a proxy (except `platform`).
public enum ExtensionServices {

    /// What a widget gets in a scene, an intent or its lifecycle: the session's `SessionServices`.
    nonisolated public static func session(channel: ExtensionChannel, sessionId: String?, widgetId: String?, worktreePath: String?,
                               actor: WidgetCollaborator = .solo) -> SessionServices {
        let scope = ExtensionServiceScope(channel: channel, sessionId: sessionId, widgetId: widgetId)
        return SessionServices(
            composer: ExtensionComposerProxy(scope: scope),
            shell: ExtensionShellProxy(scope: scope),
            intents: ExtensionIntentsProxy(scope: scope),
            storage: ExtensionStorageProxy(scope: scope),
            pill: ExtensionPillProxy(scope: scope),
            tools: ExtensionToolProxy(scope: scope),
            files: ExtensionFileProxy(scope: scope),
            platform: SystemWidgetPlatformService(),
            sessionId: sessionId,
            worktreePath: worktreePath,
            actor: actor,
            collaboration: ExtensionCollaborationProxy(scope: scope))
    }

    /// What a background agent gets.
    nonisolated public static func background(channel: ExtensionChannel, sessionId: String, widgetId: String,
                                  taskId: String?) -> WidgetBackgroundServices {
        let scope = ExtensionServiceScope(channel: channel, sessionId: sessionId, widgetId: widgetId)
        return WidgetBackgroundServices(
            shell: ExtensionShellProxy(scope: scope),
            storage: ExtensionStorageProxy(scope: scope),
            pill: ExtensionPillProxy(scope: scope),
            activity: ExtensionActivityProxy(scope: scope),
            tools: ExtensionToolProxy(scope: scope),
            files: ExtensionFileProxy(scope: scope),
            sessionId: sessionId,
            taskId: taskId)
    }

    /// What a session hook gets.
    nonisolated public static func createContext(channel: ExtensionChannel, sessionId: String, name: String, worktreePath: String,
                                     params: [String: WidgetJSONValue]) -> SessionCreateContext {
        let scope = ExtensionServiceScope(channel: channel, sessionId: sessionId, widgetId: nil)
        return SessionCreateContext(
            sessionId: sessionId, name: name, worktreePath: worktreePath, params: params,
            storage: ExtensionStorageProxy(scope: scope),
            shell: ExtensionShellProxy(scope: scope),
            tools: ExtensionToolProxy(scope: scope))
    }

    /// Points the SDK's process-wide registries (account, host streams, browser tabs) at proxies on `channel`, so the
    /// computed `SessionServices` members a widget reads (`account`, `stream(_:widget:)`, `browser`) reach Work42 too.
    @MainActor
    public static func installRegistries(channel: ExtensionChannel) {
        WidgetAccountRegistry.service = ExtensionAccountProxy(scope: ExtensionServiceScope(channel: channel, sessionId: nil, widgetId: nil))
        WidgetStreamRegistry.service = ExtensionStreamProxy(scope: ExtensionServiceScope(channel: channel, sessionId: nil, widgetId: nil))
        // Every `SessionServices` an extension builds is for one widget in one session, and its proxies carry both, so the
        // browser service is scoped by reading them back. Services the extension did not build get no browser.
        BrowserTabsRegistry.resolve = { services in
            guard let scope = (services.shell as? ExtensionShellProxy)?.scope, scope.widgetId != nil else { return nil }
            return ExtensionBrowserTabsProxy(scope: scope)
        }
    }
}
