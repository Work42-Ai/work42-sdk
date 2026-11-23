// ExtensionRuntime.swift — what an extension does with the host's requests (SDK 3.2.0).
//
// One runtime per extension process. It keeps one widget instance per (widget, session), activated with proxy services the
// first time the host needs it, and answers the `extension.*` and `scene.*` calls. It is plain Swift on the main actor, so
// it is tested without ExtensionKit; `Work42PluginExtension` connects it to the real XPC connection.

import Foundation
import Work42PluginKit

/// How an extension makes one of its widgets. The runtime makes a fresh instance per session, as the in-process loader does.
public struct ExtensionWidgetFactory: Sendable {
    public let id: String
    public let make: @MainActor @Sendable () -> any Work42Widget

    public init(_ id: String, make: @escaping @MainActor @Sendable () -> any Work42Widget) {
        self.id = id
        self.make = make
    }
}

extension ExtensionPayload {
    /// `extension.handshake` reply: who this extension is.
    nonisolated public struct Handshake: Codable, Sendable, Equatable {
        public var sdkVersion: String, widgets: [String], hasSessionHooks: Bool
        public init(sdkVersion: String, widgets: [String], hasSessionHooks: Bool) {
            self.sdkVersion = sdkVersion; self.widgets = widgets; self.hasSessionHooks = hasSessionHooks
        }
    }
    /// The session context the host sends with any call that may activate a widget.
    nonisolated public struct SessionContext: Codable, Sendable {
        public var worktreePath: String?
        public init(worktreePath: String?) { self.worktreePath = worktreePath }
    }
    /// `extension.performIntent` arguments: the intent's last name component and its parameters.
    nonisolated public struct PerformIntent: Codable, Sendable {
        public var name: String, params: [String: WidgetJSONValue], worktreePath: String?
        public init(name: String, params: [String: WidgetJSONValue], worktreePath: String?) {
            self.name = name; self.params = params; self.worktreePath = worktreePath
        }
    }
    /// `extension.resolveStartURL` reply: what the host needs to draw a browser-backed widget's browser itself.
    nonisolated public struct BrowserStart: Codable, Sendable, Equatable {
        public var url: URL, selector: String, dataStoreKey: String, title: String?, icon: String, cacheKey: String
        public init(url: URL, selector: String, dataStoreKey: String, title: String?, icon: String, cacheKey: String) {
            self.url = url; self.selector = selector; self.dataStoreKey = dataStoreKey; self.title = title
            self.icon = icon; self.cacheKey = cacheKey
        }
    }
    nonisolated public struct OptionalBrowserStart: Codable, Sendable, Equatable {
        public var start: BrowserStart?
        public init(start: BrowserStart?) { self.start = start }
    }
    /// `extension.backgroundStart` arguments.
    nonisolated public struct BackgroundStart: Codable, Sendable {
        public var taskId: String?
        public init(taskId: String?) { self.taskId = taskId }
    }
    /// `extension.hook` arguments. `event` is `onCreate` today.
    nonisolated public struct Hook: Codable, Sendable {
        public var event: String, name: String, worktreePath: String, params: [String: WidgetJSONValue]
        public init(event: String, name: String, worktreePath: String, params: [String: WidgetJSONValue]) {
            self.event = event; self.name = name; self.worktreePath = worktreePath; self.params = params
        }
    }
}

@MainActor
public final class Work42ExtensionRuntime {

    private struct InstanceKey: Hashable { let widgetId: String; let sessionId: String }

    public let factories: [ExtensionWidgetFactory]
    public let sessionHooks: (any Work42SessionHooks)?
    public private(set) var channel: ExtensionChannel?

    private var instances: [InstanceKey: (widget: any Work42Widget, services: SessionServices)] = [:]
    private var agents: [InstanceKey: any WidgetBackgroundAgent] = [:]

    public init(widgets: [ExtensionWidgetFactory], sessionHooks: (any Work42SessionHooks)?) {
        self.factories = widgets
        self.sessionHooks = sessionHooks
    }

    /// Attaches the runtime to its connection to Work42 and points the SDK registries at it.
    public func connect(_ channel: ExtensionChannel) {
        self.channel = channel
        ExtensionServices.installRegistries(channel: channel)
    }

    /// The connection to Work42 is gone: background agents stop and widgets deactivate. Work42 restarts the extension and
    /// starts over; nothing here is resent.
    public func disconnect() {
        channel?.close()
        for agent in agents.values { agent.stop() }
        agents.removeAll()
        for instance in instances.values { instance.widget.deactivate() }
        instances.removeAll()
    }

    /// Answers one encoded call from the host with one encoded reply.
    public func handle(encoded: Data) async -> Data {
        let reply: ExtensionReply
        do {
            reply = await handle(try ExtensionJSON.decode(ExtensionCall.self, from: encoded))
        } catch {
            reply = .failure(error)
        }
        return (try? ExtensionJSON.encode(reply)) ?? Data("{}".utf8)
    }

    /// Answers one call from the host.
    public func handle(_ call: ExtensionCall) async -> ExtensionReply {
        do {
            switch call.name {
            case "extension.handshake":
                return try .success(ExtensionPayload.Handshake(
                    sdkVersion: Work42SDKCompatibility.version, widgets: factories.map(\.id),
                    hasSessionHooks: sessionHooks != nil))
            case "extension.performIntent":
                let args = try ExtensionJSON.decode(ExtensionPayload.PerformIntent.self, from: call.payload)
                try await performIntent(call, args)
                return try .success(ExtensionEmpty())
            case "extension.resolveStartURL":
                return try .success(ExtensionPayload.OptionalBrowserStart(start: try await resolveStartURL(call)))
            case "extension.backgroundStart":
                let args = try ExtensionJSON.decode(ExtensionPayload.BackgroundStart.self, from: call.payload)
                try backgroundStart(call, taskId: args.taskId)
                return try .success(ExtensionEmpty())
            case "extension.backgroundStop":
                let key = try instanceKey(call)
                agents.removeValue(forKey: key)?.stop()
                return try .success(ExtensionEmpty())
            case "extension.hook":
                let args = try ExtensionJSON.decode(ExtensionPayload.Hook.self, from: call.payload)
                try await runHook(call, args)
                return try .success(ExtensionEmpty())
            case "extension.releaseSession":
                releaseSession(try required(call.sessionId, "sessionId", call))
                return try .success(ExtensionEmpty())
            default:
                return .failure(WidgetServiceError.unsupported(call))
            }
        } catch {
            return .failure(error)
        }
    }

    /// The widget instance for `widgetId` in `sessionId` with its services, made and activated on first use.
    public func instance(widgetId: String, sessionId: String,
                         worktreePath: String?) throws -> (widget: any Work42Widget, services: SessionServices) {
        let key = InstanceKey(widgetId: widgetId, sessionId: sessionId)
        if let existing = instances[key] { return existing }
        guard let channel else {
            throw WidgetServiceError(message: "the extension is not connected to Work42", suggestion: "retry the action")
        }
        guard let factory = factories.first(where: { $0.id == widgetId }) else {
            throw WidgetServiceError(
                message: "this extension has no widget '\(widgetId)'",
                suggestion: "check the widget ids the extension returns from `widgets` against plugin.yaml")
        }
        let widget = factory.make()
        let services = ExtensionServices.session(channel: channel, sessionId: sessionId, widgetId: widgetId,
                                                 worktreePath: worktreePath)
        widget.activate(services: services)
        instances[key] = (widget, services)
        return (widget, services)
    }

    /// Deactivates every widget of `sessionId` and stops its background agents.
    public func releaseSession(_ sessionId: String) {
        for key in instances.keys where key.sessionId == sessionId {
            instances.removeValue(forKey: key)?.widget.deactivate()
        }
        for key in agents.keys where key.sessionId == sessionId {
            agents.removeValue(forKey: key)?.stop()
        }
    }

    public var activeInstanceCount: Int { instances.count }
    public var runningAgentCount: Int { agents.count }

    // MARK: Requests

    private func performIntent(_ call: ExtensionCall, _ args: ExtensionPayload.PerformIntent) async throws {
        let key = try instanceKey(call)
        let (widget, services) = try instance(widgetId: key.widgetId, sessionId: key.sessionId, worktreePath: args.worktreePath)
        guard let spec = widget.intents.first(where: { $0.name == args.name }) else {
            throw WidgetServiceError(
                message: "widget '\(key.widgetId)' has no intent '\(args.name)'",
                suggestion: "use one of: \(widget.intents.map(\.name).joined(separator: ", "))")
        }
        if let withServices = spec.performWithServices {
            try await withServices(services)
        } else {
            try await spec.perform()
        }
    }

    private func resolveStartURL(_ call: ExtensionCall) async throws -> ExtensionPayload.BrowserStart? {
        let widgetId = try required(call.widgetId, "widgetId", call)
        guard let factory = factories.first(where: { $0.id == widgetId }) else {
            throw WidgetServiceError(message: "this extension has no widget '\(widgetId)'", suggestion: nil)
        }
        // A fresh instance: resolving the start URL needs no session, and must not activate one.
        guard let backed = factory.make() as? any Work42BrowserBacked, let surface = backed.browserSurface else { return nil }
        let url: URL
        switch surface.spec.source {
        case .url(let value): url = value
        case .provider(let produce): url = try await produce()
        @unknown default:
            throw WidgetServiceError(message: "widget '\(widgetId)' declares a browser source this SDK does not know",
                                     suggestion: "rebuild the plugin with the SDK Work42 reports (`work42 sdk`)")
        }
        return ExtensionPayload.BrowserStart(
            url: url, selector: surface.spec.selector, dataStoreKey: surface.spec.dataStoreKey,
            title: surface.spec.title, icon: surface.spec.icon, cacheKey: surface.cacheKey)
    }

    private func backgroundStart(_ call: ExtensionCall, taskId: String?) throws {
        let key = try instanceKey(call)
        guard agents[key] == nil else { return }
        guard let channel else {
            throw WidgetServiceError(message: "the extension is not connected to Work42", suggestion: "retry the action")
        }
        guard let factory = factories.first(where: { $0.id == key.widgetId }),
              let backgrounded = factory.make() as? any Work42WidgetBackground else {
            throw WidgetServiceError(
                message: "widget '\(key.widgetId)' has no background agent",
                suggestion: "conform the widget to Work42WidgetBackground, or stop asking for one")
        }
        let agent = backgrounded.makeBackgroundAgent()
        agents[key] = agent
        agent.start(services: ExtensionServices.background(channel: channel, sessionId: key.sessionId,
                                                           widgetId: key.widgetId, taskId: taskId))
    }

    private func runHook(_ call: ExtensionCall, _ args: ExtensionPayload.Hook) async throws {
        guard args.event == "onCreate" else { throw WidgetServiceError.unsupported(call) }
        guard let sessionHooks else {
            throw WidgetServiceError(message: "this extension has no session hooks",
                                     suggestion: "return them from `sessionHooks` in the extension")
        }
        guard let channel else {
            throw WidgetServiceError(message: "the extension is not connected to Work42", suggestion: "retry the action")
        }
        let sessionId = try required(call.sessionId, "sessionId", call)
        try await sessionHooks.onCreate(ExtensionServices.createContext(
            channel: channel, sessionId: sessionId, name: args.name, worktreePath: args.worktreePath, params: args.params))
    }

    // MARK: Helpers

    private func instanceKey(_ call: ExtensionCall) throws -> InstanceKey {
        InstanceKey(widgetId: try required(call.widgetId, "widgetId", call),
                    sessionId: try required(call.sessionId, "sessionId", call))
    }

    private func required(_ value: String?, _ field: String, _ call: ExtensionCall) throws -> String {
        guard let value, !value.isEmpty else {
            throw WidgetServiceError(message: "\(call.name) needs a \(field)",
                                     suggestion: "the host must set \(field) on this call")
        }
        return value
    }
}
