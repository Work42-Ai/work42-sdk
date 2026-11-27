// ExtensionRuntime.swift — what an extension does with the host's requests (SDK 3.2.0).
//
// One runtime per extension process. It keeps one widget instance per (widget, session), activated with proxy services the
// first time the host needs it, and answers the `extension.*` and `scene.*` calls. It is plain Swift on the main actor, so
// it is tested without ExtensionKit; `Work42PluginExtension` connects it to the real XPC connection.

import Foundation
import SwiftUI
import Work42PluginKit

/// How an extension makes one of its widgets. The runtime makes a fresh instance per session, as the in-process loader does.
nonisolated public struct ExtensionWidgetFactory: Sendable {
    public let id: String
    public let make: @MainActor @Sendable () -> any Work42Widget

    public init(_ id: String, make: @escaping @MainActor @Sendable () -> any Work42Widget) {
        self.id = id
        self.make = make
    }
}

extension ExtensionPayload {
    /// `extension.handshake` reply: who this extension is, and every widget's metadata (the host registers the widgets
    /// from it before any session uses them).
    nonisolated public struct Handshake: Codable, Sendable, Equatable {
        public var sdkVersion: String, widgets: [ExtensionWidgetDescription], hasSessionHooks: Bool
        /// The MCP tools each session type declares (3.5.0). Nil: none.
        public var sessionTypes: [ExtensionSessionTypeDescription]?
        public init(sdkVersion: String, widgets: [ExtensionWidgetDescription], hasSessionHooks: Bool) {
            self.sdkVersion = sdkVersion; self.widgets = widgets; self.hasSessionHooks = hasSessionHooks
        }
        public init(sdkVersion: String, widgets: [ExtensionWidgetDescription], hasSessionHooks: Bool,
                    sessionTypes: [ExtensionSessionTypeDescription]?) {
            self.init(sdkVersion: sdkVersion, widgets: widgets, hasSessionHooks: hasSessionHooks)
            self.sessionTypes = sessionTypes
        }
    }
    /// The session context the host sends with any call that may activate a widget.
    nonisolated public struct SessionContext: Codable, Sendable {
        public var worktreePath: String?
        /// Which of the widget's views the scene draws (`ExtensionSurface`, 3.4.0). Absent: the tile.
        public var surface: String?
        public init(worktreePath: String?) { self.worktreePath = worktreePath }
        public init(worktreePath: String?, surface: String?) { self.worktreePath = worktreePath; self.surface = surface }
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
    /// How the plugin makes the objects that declare its session types' tools (3.5.0).
    public let sessionTypeFactories: [ExtensionSessionTypeFactory]
    public private(set) var channel: ExtensionChannel?

    private struct SessionTypeKey: Hashable { let typeId: String; let sessionId: String }
    private var sessionTypeInstances: [SessionTypeKey: any Work42SessionTypeMCPs] = [:]
    /// The tool calls in flight, by invocation id, so `extension.cancelTool` can stop one.
    private var runningTools: [String: Task<PluginToolResult, any Error>] = [:]
    private var instances: [InstanceKey: (widget: any Work42Widget, services: SessionServices)] = [:]
    private var agents: [InstanceKey: any WidgetBackgroundAgent] = [:]
    /// What sends each widget's and agent's live state to Work42 (see `ExtensionStatePusher`).
    private var widgetPushers: [InstanceKey: ExtensionStatePusher] = [:]
    private var agentPushers: [InstanceKey: ExtensionStatePusher] = [:]

    public init(widgets: [ExtensionWidgetFactory], sessionHooks: (any Work42SessionHooks)?) {
        self.factories = widgets
        self.sessionHooks = sessionHooks
        self.sessionTypeFactories = []
    }

    public init(widgets: [ExtensionWidgetFactory], sessionHooks: (any Work42SessionHooks)?,
                sessionTypes: [ExtensionSessionTypeFactory]) {
        self.factories = widgets
        self.sessionHooks = sessionHooks
        self.sessionTypeFactories = sessionTypes
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
        for pusher in widgetPushers.values { pusher.cancel() }
        for pusher in agentPushers.values { pusher.cancel() }
        widgetPushers.removeAll()
        agentPushers.removeAll()
        for agent in agents.values { agent.stop() }
        agents.removeAll()
        for instance in instances.values { instance.widget.deactivate() }
        instances.removeAll()
        for task in runningTools.values { task.cancel() }
        runningTools.removeAll()
        sessionTypeInstances.removeAll()
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
                // A template instance per widget, only read for its metadata (never activated), as the in-process
                // loader reads its template.
                return try .success(ExtensionPayload.Handshake(
                    sdkVersion: Work42SDKCompatibility.version,
                    widgets: factories.map { ExtensionWidgetDescription(describing: $0.make()) },
                    hasSessionHooks: sessionHooks != nil,
                    sessionTypes: sessionTypeFactories.isEmpty ? nil : sessionTypeFactories.map { factory in
                        ExtensionSessionTypeDescription(id: factory.id,
                                                        mcps: factory.make().mcpTools.map(PluginMCPDescription.init(describing:)))
                    }))
            case "extension.callTool":
                let args = try ExtensionJSON.decode(ExtensionPayload.CallTool.self, from: call.payload)
                return try .success(await callTool(call, args))
            case "extension.cancelTool":
                let args = try ExtensionJSON.decode(ExtensionPayload.CancelTool.self, from: call.payload)
                runningTools[args.invocationId]?.cancel()
                return try .success(ExtensionEmpty())
            case "extension.performIntent":
                let args = try ExtensionJSON.decode(ExtensionPayload.PerformIntent.self, from: call.payload)
                try await performIntent(call, args)
                return try .success(ExtensionEmpty())
            case "extension.selectMenuOption":
                let args = try ExtensionJSON.decode(ExtensionPayload.MenuSelect.self, from: call.payload)
                try await selectMenuOption(call, args)
                return try .success(ExtensionEmpty())
            case "extension.openLink":
                let args = try ExtensionJSON.decode(ExtensionPayload.OpenLink.self, from: call.payload)
                try await openLink(call, args)
                return try .success(ExtensionEmpty())
            case "extension.resolveStartURL":
                return try .success(ExtensionPayload.OptionalBrowserStart(start: try await resolveStartURL(call)))
            case "extension.backgroundStart":
                let args = try ExtensionJSON.decode(ExtensionPayload.BackgroundStart.self, from: call.payload)
                try backgroundStart(call, taskId: args.taskId)
                return try .success(ExtensionEmpty())
            case "extension.backgroundStop":
                let key = try instanceKey(call)
                agentPushers.removeValue(forKey: key)?.cancel()
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
        widgetPushers[key] = ExtensionStatePusher.widget(widget, channel: channel, sessionId: sessionId, widgetId: widgetId)
        return (widget, services)
    }

    /// The view `surface` asks for (`ExtensionSurface`, tile by default) of `widgetId` in `sessionId`: the tile, the pill, the
    /// custom header, or the popover of one action-area intent. Throws when the widget has no such surface.
    public func view(widgetId: String, sessionId: String, worktreePath: String?, surface: String?) throws -> AnyView {
        let (widget, services) = try instance(widgetId: widgetId, sessionId: sessionId, worktreePath: worktreePath)
        let name = surface ?? ExtensionSurface.tile
        func missing(_ what: String) -> WidgetServiceError {
            WidgetServiceError(message: "widget '\(widgetId)' has no \(what)",
                               suggestion: "the host asks only for the surfaces the widget's description lists")
        }
        switch name {
        case ExtensionSurface.tile:
            return widget.makeView(services: services)
        case ExtensionSurface.pill:
            guard let view = (widget as? any Work42WidgetPill)?.makePillView(services: services) else { throw missing("pill") }
            return view
        case ExtensionSurface.header:
            guard let header = widget as? any Work42WidgetCustomHeader else { throw missing("custom header") }
            return header.makeHeaderView()
        case let popover where popover.hasPrefix(ExtensionSurface.popoverPrefix):
            let intent = String(popover.dropFirst(ExtensionSurface.popoverPrefix.count))
            let channel = self.channel
            // The popover closes itself by telling Work42, which owns the popover.
            let dismiss: @MainActor () -> Void = {
                guard let channel else { return }
                Task {
                    try? await channel.call("widget", "dismissPopover", sessionId: sessionId, widgetId: widgetId,
                                            payload: ExtensionPayload.PopoverClosed(intent: intent))
                }
            }
            guard let view = (widget as? any Work42WidgetActionPopovers)?.actionAreaPopover(for: intent, dismiss: dismiss) else {
                throw missing("popover for '\(intent)'")
            }
            return view
        default:
            throw missing("surface '\(name)'")
        }
    }

    /// Deactivates every widget of `sessionId` and stops its background agents.
    public func releaseSession(_ sessionId: String) {
        for key in widgetPushers.keys where key.sessionId == sessionId {
            widgetPushers.removeValue(forKey: key)?.cancel()
        }
        for key in agentPushers.keys where key.sessionId == sessionId {
            agentPushers.removeValue(forKey: key)?.cancel()
        }
        for key in instances.keys where key.sessionId == sessionId {
            instances.removeValue(forKey: key)?.widget.deactivate()
        }
        for key in agents.keys where key.sessionId == sessionId {
            agents.removeValue(forKey: key)?.stop()
        }
        for key in sessionTypeInstances.keys where key.sessionId == sessionId {
            sessionTypeInstances.removeValue(forKey: key)
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

    private func selectMenuOption(_ call: ExtensionCall, _ args: ExtensionPayload.MenuSelect) async throws {
        let key = try instanceKey(call)
        let (widget, _) = try instance(widgetId: key.widgetId, sessionId: key.sessionId, worktreePath: nil)
        guard let spec = widget.intents.first(where: { $0.name == args.name }),
              case .menu(_, let onSelect) = spec.actionAreaStyle else {
            throw WidgetServiceError(message: "widget '\(key.widgetId)' has no menu intent '\(args.name)'",
                                     suggestion: "use the name of an intent declared with the .menu style")
        }
        try await onSelect(args.optionId)
    }

    /// Runs one MCP tool for the widget or session type that owns it. A tool's own failure, an argument that does not fit its
    /// schema and an unknown tool come back as `ToolOutcome.failure`; only a call that cannot be routed at all throws.
    private func callTool(_ call: ExtensionCall, _ args: ExtensionPayload.CallTool) async throws -> ExtensionPayload.ToolOutcome {
        guard let channel else {
            throw WidgetServiceError(message: "the extension is not connected to Work42", suggestion: "retry the action")
        }
        let sessionId = try required(call.sessionId, "sessionId", call)
        let declared: [PluginMCPTools]
        let services: SessionServices
        let widgetId: String?
        switch args.owner {
        case ExtensionPayload.CallTool.widgetOwner:
            let (widget, widgetServices) = try instance(widgetId: args.ownerId, sessionId: sessionId, worktreePath: args.worktreePath)
            declared = (widget as? any Work42WidgetMCPs)?.mcpTools ?? []
            services = widgetServices
            widgetId = args.ownerId
        case ExtensionPayload.CallTool.sessionTypeOwner:
            let key = SessionTypeKey(typeId: args.ownerId, sessionId: sessionId)
            if sessionTypeInstances[key] == nil {
                guard let factory = sessionTypeFactories.first(where: { $0.id == args.ownerId }) else {
                    throw WidgetServiceError(message: "this extension has no session type '\(args.ownerId)'",
                                             suggestion: "list it in `sessionTypes` in the extension, under the id in session-types/*.json")
                }
                sessionTypeInstances[key] = factory.make()
            }
            declared = sessionTypeInstances[key]?.mcpTools ?? []
            services = ExtensionServices.session(channel: channel, sessionId: sessionId, widgetId: nil, worktreePath: args.worktreePath)
            widgetId = nil
        default:
            throw WidgetServiceError(message: "extension.callTool names an owner '\(args.owner)'",
                                     suggestion: "the owner is `widget` or `session-type`")
        }
        guard let tool = declared.first(where: { $0.id == args.mcp })?.tools.first(where: { $0.id == args.tool }) else {
            return ExtensionPayload.ToolOutcome(failure: PluginToolFailure(
                code: "no_such_tool", message: "'\(args.owner)' '\(args.ownerId)' has no tool '\(args.mcp)/\(args.tool)'",
                suggestion: "list the tools of the MCP and call one of them"))
        }
        if let problem = tool.input.problem(with: args.arguments) {
            return ExtensionPayload.ToolOutcome(failure: PluginToolFailure(
                code: "invalid_arguments", message: problem, suggestion: "pass the arguments the tool's input schema lists"))
        }

        let invocationId = args.invocationId
        let context = PluginToolContext(sessionId: sessionId, widgetId: widgetId, invocationId: invocationId, services: services,
                                        progress: { message, fraction in
            _ = try? await channel.call("tool", "progress", sessionId: sessionId, widgetId: widgetId,
                                        payload: ExtensionPayload.ToolProgress(invocationId: invocationId, message: message, fraction: fraction))
        })
        let arguments = PluginToolArguments(args.arguments)
        let task = Task { @MainActor in try await tool.run(arguments, context) }
        runningTools[invocationId] = task
        defer { runningTools[invocationId] = nil }
        do {
            return ExtensionPayload.ToolOutcome(result: try await task.value)
        } catch {
            return ExtensionPayload.ToolOutcome(failure: Self.failure(for: error))
        }
    }

    /// A thrown error as the failure a tool answers with: the tool's own, a permission refusal, a service error, or cancelled.
    private static func failure(for error: any Error) -> PluginToolFailure {
        if let failure = error as? PluginToolFailure { return failure }
        if error is CancellationError { return .cancelled }
        let typed = (error as? WidgetServiceError).flatMap(PluginPermissionError.init) ?? (error as? PluginPermissionError)
        switch typed {
        case .notDeclared?:
            return PluginToolFailure(code: "permission_not_declared", message: typed?.errorDescription ?? "permission not declared",
                                     suggestion: "declare the permission under permissions in plugin.yaml")
        case .denied(_, let message)?:
            return PluginToolFailure(code: "permission_denied", message: message,
                                     suggestion: "change it in Settings → Plugins → this plugin → Permissions")
        case nil:
            break
        @unknown default:
            break
        }
        if let service = error as? WidgetServiceError {
            return PluginToolFailure(code: "service_error", message: service.message, suggestion: service.suggestion)
        }
        return PluginToolFailure(code: "tool_error", message: error.localizedDescription)
    }

    private func openLink(_ call: ExtensionCall, _ args: ExtensionPayload.OpenLink) async throws {
        let key = try instanceKey(call)
        let (widget, _) = try instance(widgetId: key.widgetId, sessionId: key.sessionId, worktreePath: args.worktreePath)
        guard widget.linkIntents.indices.contains(args.index) else {
            throw WidgetServiceError(
                message: "widget '\(key.widgetId)' has no link intent \(args.index)",
                suggestion: "the host must use an index from the widget's description")
        }
        try await widget.linkIntents[args.index].perform(args.url)
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
        agentPushers[key] = ExtensionStatePusher.agent(agent, channel: channel, sessionId: key.sessionId, widgetId: key.widgetId)
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
