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

    /// A widget in a session, as its tile (`agent` false) or as its background agent (`agent` true). They are separate scopes:
    /// what the agent starts (a recording, a command) must outlive the tile leaving the screen.
    private struct Scope: Hashable { let sessionId: String; let widgetId: String; var agent = false }

    public let ledger: ExtensionRequestLedger
    /// Sends a stream item (or a stream's end) to the extension.
    public var push: (@MainActor (ExtensionStreamEvent) -> Void)?

    private var sessionServices: [Scope: SessionServices] = [:]
    /// What a headless tool call is answered with (3.5.0): the services Work42 attached for a session, and for the widget the
    /// tool belongs to (nil for a session type's tool), while calls run that have no tile. Counted, so two calls at once for
    /// the same session and owner share one lease and the first to finish does not take it from the second.
    private struct LeaseKey: Hashable { let sessionId: String; let widgetId: String? }
    private var toolLeases: [LeaseKey: (services: SessionServices, count: Int)] = [:]
    private var backgroundServices: [Scope: WidgetBackgroundServices] = [:]
    private var createContexts: [String: SessionCreateContext] = [:]
    private var streams: [UUID: Task<Void, Never>] = [:]
    /// Which widget scope opened a stream, for the streams that must end with it (a started command, 3.3.0).
    private var streamScopes: [UUID: Scope] = [:]
    /// The commands the extension started with `shell.start`, by the id of the stream carrying their output.
    private var shellProcesses: [UUID: WidgetShellProcess] = [:]
    /// The recordings the extension started with `audio.startRecording`, by the id of the stream carrying their levels (the
    /// id the extension knows the recording by).
    private var recordings: [UUID: AudioRecording] = [:]
    /// The services that answer `permissions`, `audio`, `speech` and `calendar` calls: Work42 sets it per link, because the
    /// plugin the link belongs to (and so what it declared) is known to Work42, not to the call. Without it those calls
    /// fail with a named error.
    public var capabilityProvider: (@MainActor (ExtensionCall) -> WidgetCapabilities)?
    /// Asked before `shell.run` and `shell.start` (3.5.0): Work42 sets it per link to check that the plugin declared
    /// `run-commands` and that the person allowed it, and throws (a `PluginPermissionError`) when not. Unset, a command
    /// runs as it did before.
    public var authorizeShell: (@MainActor (ExtensionCall) async throws -> Void)?
    /// Asked before a plugin's `tools.call` runs a tool of another MCP server (3.5.0): a tool that runs commands or reaches
    /// protected places is the same power as `services.shell`, so Work42 gates it with the same permissions. Throwing refuses the
    /// call; unset, every call is allowed.
    public var authorizeToolCall: (@MainActor (_ call: ExtensionCall, _ server: String, _ tool: String) async throws -> Void)?
    /// Told when an extension says something about one of its widgets that is not a service call (3.4.0): its live state
    /// (intents, header labels) changed, or a popover asked to close. Work42 sets it per link; unset, those calls are
    /// accepted and dropped.
    public var widgetEvents: (@MainActor (ExtensionWidgetEvent) -> Void)?
    /// Told when a running tool reports progress (3.5.0): the progress and the session it is for. Work42 sets it per link and
    /// passes it on to the agent that called the tool; unset, progress is accepted and dropped.
    public var toolProgress: (@MainActor (_ progress: ExtensionPayload.ToolProgress, _ sessionId: String?) -> Void)?

    public init(ledger: ExtensionRequestLedger) {
        self.ledger = ledger
    }

    // MARK: Which services answer

    /// The services widget `widgetId` was activated with in `sessionId`: what its scene, intents and link intents use.
    public func attach(_ services: SessionServices, widgetId: String, sessionId: String) {
        sessionServices[Scope(sessionId: sessionId, widgetId: widgetId)] = services
    }

    /// Attaches the services a tool call uses when the owner has no tile shown (3.5.0): an agent calls an MCP tool of a widget
    /// or session type that is not on screen, so the call is answered from these instead of from a tile's services. Call it
    /// before sending `extension.callTool` and `detachToolLease` when the call is over.
    public func attachToolLease(_ services: SessionServices, sessionId: String, widgetId: String?) {
        let key = LeaseKey(sessionId: sessionId, widgetId: widgetId)
        toolLeases[key] = (services, (toolLeases[key]?.count ?? 0) + 1)
    }

    /// Ends one hold on the lease; the last one removes it.
    public func detachToolLease(sessionId: String, widgetId: String?) {
        let key = LeaseKey(sessionId: sessionId, widgetId: widgetId)
        guard let lease = toolLeases[key] else { return }
        if lease.count <= 1 { toolLeases.removeValue(forKey: key) } else { toolLeases[key] = (lease.services, lease.count - 1) }
    }

    /// The number of tool leases held, for tests.
    public var toolLeaseCount: Int { toolLeases.count }

    /// The folder of the session `call` is for (the `worktreePath` its widget was activated with), or nil when the call names
    /// no session or none of its widgets is attached. A capability host resolves a recording's relative folder against it.
    public func sessionFolder(for call: ExtensionCall) -> String? {
        guard let sessionId = call.sessionId else { return nil }
        return sessionServices.first { $0.key.sessionId == sessionId }?.value.worktreePath
            ?? toolLeases.first { $0.key.sessionId == sessionId }?.value.services.worktreePath
    }

    public func detach(widgetId: String, sessionId: String) {
        let scope = Scope(sessionId: sessionId, widgetId: widgetId)
        sessionServices.removeValue(forKey: scope)
        endProcesses(in: scope)
    }

    /// The services widget `widgetId`'s background agent was started with in `sessionId`.
    public func attachBackground(_ services: WidgetBackgroundServices, widgetId: String, sessionId: String) {
        backgroundServices[Scope(sessionId: sessionId, widgetId: widgetId, agent: true)] = services
    }

    public func detachBackground(widgetId: String, sessionId: String) {
        let scope = Scope(sessionId: sessionId, widgetId: widgetId, agent: true)
        backgroundServices.removeValue(forKey: scope)
        endProcesses(in: scope)
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
        // Cancelling a started command's stream stops the command (its cancellation handler calls `stop`).
        for task in streams.values { task.cancel() }
        streams.removeAll()
        streamScopes.removeAll()
        shellProcesses.removeAll()
        recordings.removeAll()
    }

    public var openStreamCount: Int { streams.count }

    /// The number of commands started by `shell.start` that are still running, for tests.
    public var runningProcessCount: Int { shellProcesses.count }

    /// The number of recordings started by `audio.startRecording` that are still running, for tests.
    public var runningRecordingCount: Int { recordings.count }

    /// A widget's scope ended: every command it started is stopped, and the extension is told their streams are over.
    private func endProcesses(in scope: Scope) {
        for (streamId, owner) in streamScopes where owner == scope { closeStream(streamId, notify: true) }
    }

    /// Cancels stream `streamId` (which stops a command it carries) and forgets it; `notify` also tells the extension.
    private func closeStream(_ streamId: UUID, notify: Bool) {
        streams.removeValue(forKey: streamId)?.cancel()
        streamScopes.removeValue(forKey: streamId)
        shellProcesses.removeValue(forKey: streamId)
        recordings.removeValue(forKey: streamId)
        if notify { push?(ExtensionStreamEvent(streamId: streamId, finished: true)) }
    }

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
        } catch let error as PluginPermissionError {
            // Crosses the wire as a prefixed `WidgetServiceError`, and the proxy makes it a `PluginPermissionError` again.
            return .failure(error.serviceError)
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
            let a = try args(ExtensionPayload.Command.self)
            try await authorizeShell?(call)
            let service = try shell(call)
            if let seconds = a.timeoutSeconds {
                return try .success(try await service.run(command: a.command, timeout: .seconds(seconds)))
            }
            return try .success(try await service.run(command: a.command))
        case "shell.start":
            // The stream carries the command's lines and ends after `.exited`; a refusal throws here, to the caller.
            let sub = try args(ExtensionSubscription<ExtensionPayload.Command>.self)
            try await authorizeShell?(call)
            let process = try await shell(call).start(command: sub.arguments.command)
            shellProcesses[sub.streamId] = process
            open(sub.streamId, scope: scope(call)) { yield in
                await withTaskCancellationHandler {
                    for await line in process.output { yield(try? ExtensionJSON.encode(line)) }
                } onCancel: {
                    Task { await process.stop() }
                }
            }
            return empty
        case "shell.stop":
            // Ends the command; its stream still delivers `.exited` and finishes by itself.
            await shellProcesses[try args(ExtensionPayload.StreamRef.self).streamId]?.stop()
            return empty
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

        // a widget's live state and popovers (3.4.0)
        case "widget.state":
            let state = try args(ExtensionPayload.WidgetState.self)
            if let sessionId = call.sessionId, let widgetId = call.widgetId {
                widgetEvents?(.state(widgetId: widgetId, sessionId: sessionId, agent: call.agent == true, state))
            }
            return empty
        case "widget.dismissPopover":
            let closed = try args(ExtensionPayload.PopoverClosed.self)
            if let sessionId = call.sessionId, let widgetId = call.widgetId {
                widgetEvents?(.dismissPopover(widgetId: widgetId, sessionId: sessionId, intent: closed.intent))
            }
            return empty
        case "tool.progress":
            toolProgress?(try args(ExtensionPayload.ToolProgress.self), call.sessionId)
            return empty

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
            try await authorizeToolCall?(call, a.server, a.tool)
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
        case "files.write":
            let a = try args(ExtensionPayload.FileWrite.self)
            try WidgetFilePath.validate(a.path)
            try await files(call).write(a.path, data: a.data)
            return empty
        case "files.remove":
            let path = try args(ExtensionPayload.Path.self).path
            try WidgetFilePath.validate(path)
            try await files(call).remove(path)
            return empty
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

        // permissions, audio, speech, calendar (3.3.0)
        case "permissions.status":
            let permission = try args(ExtensionPayload.PermissionArg.self).permission
            return try .success(ExtensionPayload.PermissionState(status: try await capabilities(call).permissions.status(permission)))
        case "permissions.request":
            let permission = try args(ExtensionPayload.PermissionArg.self).permission
            return try .success(ExtensionPayload.PermissionState(status: try await capabilities(call).permissions.request(permission)))
        case "audio.startRecording":
            // A refusal (not declared, not granted) throws here, to the caller; the stream then carries the levels.
            let sub = try args(ExtensionSubscription<ExtensionPayload.AudioStart>.self)
            let recording = try await capabilities(call).audio.startRecording(sub.arguments.request)
            recordings[sub.streamId] = recording
            open(sub.streamId, scope: scope(call)) { yield in
                await withTaskCancellationHandler {
                    for await levels in recording.levels { yield(try? ExtensionJSON.encode(levels)) }
                } onCancel: {
                    // The widget's scope ended, the consumer stopped reading or the connection closed: the files so far stay.
                    Task { _ = try? await recording.stop() }
                }
            }
            return empty
        case "audio.stop":
            let id = try args(ExtensionPayload.StreamRef.self).streamId
            guard let recording = recordings.removeValue(forKey: id) else {
                throw WidgetServiceError(message: "no recording \(id.uuidString) is running", suggestion: nil)
            }
            return try .success(ExtensionPayload.AudioStopped(files: try await recording.stop()))
        case "speech.transcribe":
            let a = try args(ExtensionPayload.Transcribe.self)
            let locale = a.locale.map { Locale(identifier: $0) }
            return try .success(ExtensionPayload.Segments(segments: try await capabilities(call).speech.transcribe(file: a.file, locale: locale)))
        case "speech.liveTranscript":
            // The extension names the recording by the id it has (the levels stream's id); the host's own id is the recording's.
            let sub = try args(ExtensionSubscription<ExtensionPayload.LiveTranscript>.self)
            guard let recording = recordings[sub.arguments.recording] else {
                throw WidgetServiceError(message: "no recording \(sub.arguments.recording.uuidString) is running", suggestion: nil)
            }
            let speech = try capabilities(call).speech
            let source = sub.arguments.partialResults == true
                ? speech.liveTranscript(of: recording.id, partialResults: true)
                : speech.liveTranscript(of: recording.id)
            open(sub.streamId) { yield in
                do { for try await segment in source { yield(try? ExtensionJSON.encode(segment)) } } catch {}
            }
            return empty
        case "calendar.events":
            let a = try args(ExtensionPayload.DateRange.self)
            return try .success(ExtensionPayload.Events(events: try await capabilities(call).calendar.events(from: a.from, to: a.to)))
        case "calendar.changes":
            let sub = try args(ExtensionSubscription<ExtensionEmpty>.self)
            let source = try capabilities(call).calendar.changes()
            open(sub.streamId) { yield in for await _ in source { yield(try? ExtensionJSON.encode(ExtensionEmpty())) } }
            return empty

        // disk read and automation (3.5.0)
        case "diskRead.stat":
            let path = try args(ExtensionPayload.Path.self).path
            return try .success(try await capabilities(call).diskRead.stat(path: path))
        case "diskRead.list":
            let a = try args(ExtensionPayload.DiskList.self)
            return try .success(try await capabilities(call).diskRead.list(path: a.path, cursor: a.cursor, limit: a.limit))
        case "diskRead.read":
            let a = try args(ExtensionPayload.DiskRead.self)
            return try .success(try await capabilities(call).diskRead.read(path: a.path, offset: a.offset, length: a.length))
        case "automation.send":
            let request = try args(AppleEventRequest.self)
            return try .success(try await capabilities(call).automation.send(request))

        case "stream.cancel":
            // The consumer stopped reading: a command the stream carried is stopped too (nobody is left to read it).
            closeStream(try args(ExtensionSubscription<ExtensionEmpty>.self).streamId, notify: false)
            return empty

        default:
            return .failure(WidgetServiceError.unsupported(call))
        }
    }

    // MARK: Streams

    /// Runs `body` as stream `streamId`, pushing what it yields, then the stream's end.
    private func open(_ streamId: UUID, scope: Scope? = nil,
                      _ body: @escaping @MainActor (_ yield: @MainActor (Data?) -> Void) async -> Void) {
        streams[streamId]?.cancel()
        if let scope { streamScopes[streamId] = scope }
        streams[streamId] = Task { [weak self] in
            await body { item in
                guard let item, !Task.isCancelled else { return }
                self?.push?(ExtensionStreamEvent(streamId: streamId, item: item))
            }
            guard let self, !Task.isCancelled else { return }
            self.streams.removeValue(forKey: streamId)
            self.streamScopes.removeValue(forKey: streamId)
            self.shellProcesses.removeValue(forKey: streamId)
            self.recordings.removeValue(forKey: streamId)
            self.push?(ExtensionStreamEvent(streamId: streamId, finished: true))
        }
    }

    // MARK: Service lookup

    /// The scope a call belongs to, and so the one that owns what it starts: the agent's when it says so, the tile's otherwise.
    private func scope(_ call: ExtensionCall) -> Scope? {
        guard let sessionId = call.sessionId, let widgetId = call.widgetId else { return nil }
        return Scope(sessionId: sessionId, widgetId: widgetId, agent: call.agent == true)
    }

    private func background(_ call: ExtensionCall) -> WidgetBackgroundServices? {
        guard let sessionId = call.sessionId, let widgetId = call.widgetId else { return nil }
        return backgroundServices[Scope(sessionId: sessionId, widgetId: widgetId, agent: true)]
    }

    private func session(_ call: ExtensionCall) throws -> SessionServices {
        if call.agent != true, let scope = scope(call), let services = sessionServices[scope] { return services }
        if call.agent != true, let sessionId = call.sessionId,
           let lease = toolLeases[LeaseKey(sessionId: sessionId, widgetId: call.widgetId)] {
            return lease.services
        }
        throw unavailable(call, "a widget shown in a session")
    }

    /// The service for `call`: an agent's call is answered by its agent's services only; any other call by its tile's services,
    /// or, from an extension that predates `agent`, by the widget's agent's.
    private func lookup<Service>(_ call: ExtensionCall, session: (SessionServices) -> Service,
                                 background: (WidgetBackgroundServices) -> Service) -> Service? {
        if call.agent != true, let scope = scope(call), let services = sessionServices[scope] { return session(services) }
        if call.agent != true, let sessionId = call.sessionId,
           let lease = toolLeases[LeaseKey(sessionId: sessionId, widgetId: call.widgetId)] { return session(lease.services) }
        return self.background(call).map(background)
    }

    /// The services for the plugin on this link, which answer `permissions`, `audio`, `speech` and `calendar`.
    private func capabilities(_ call: ExtensionCall) throws -> WidgetCapabilities {
        guard let provider = capabilityProvider else {
            throw unavailable(call, "the permission, audio, speech and calendar services")
        }
        return provider(call)
    }

    private func shell(_ call: ExtensionCall) throws -> any WidgetShellService {
        if let service = lookup(call, session: { $0.shell }, background: { $0.shell }) { return service }
        if let sessionId = call.sessionId, let context = createContexts[sessionId] { return context.shell }
        throw unavailable(call, "a widget, a background agent or a session hook")
    }

    private func storage(_ call: ExtensionCall) throws -> any WidgetStorageService {
        if let service = lookup(call, session: { $0.storage }, background: { $0.storage }) { return service }
        if let sessionId = call.sessionId, let context = createContexts[sessionId] { return context.storage }
        throw unavailable(call, "a widget, a background agent or a session hook")
    }

    private func tools(_ call: ExtensionCall) throws -> any WidgetToolService {
        if let service = lookup(call, session: { $0.tools }, background: { $0.tools }) { return service }
        if let sessionId = call.sessionId, let context = createContexts[sessionId] { return context.tools }
        throw unavailable(call, "a widget, a background agent or a session hook")
    }

    private func pill(_ call: ExtensionCall) throws -> any WidgetPillService {
        if let service = lookup(call, session: { $0.pill }, background: { $0.pill }) { return service }
        throw unavailable(call, "a widget or a background agent")
    }

    private func files(_ call: ExtensionCall) throws -> any WidgetFileService {
        if let service = lookup(call, session: { $0.files }, background: { $0.files }) { return service }
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
