// Work42PluginExtension.swift — the ExtensionKit side of an out-of-process plugin (SDK 3.2.0, macOS 26.2+).
//
// A plugin that runs out of process ships a container app with one ExtensionKit extension. Its `@main` type is a final
// class conforming to `Work42PluginExtension` and lists its widgets; everything ExtensionKit needs (binding to Work42's
// extension point, the widget scene, the XPC connections, pairing each scene with its connection) is provided here:
//
// ```swift
// import Work42Extension
//
// @main
// nonisolated final class TodosExtension: Work42PluginExtension {
//     required init() {}
//     @MainActor var widgets: [ExtensionWidgetFactory] { [ExtensionWidgetFactory("todos") { TodosWidget() }] }
// }
// ```
//
// The extension target also needs, in its Info.plist, `EXAppExtensionAttributes.EXExtensionPointIdentifier =
// com.work42.app.plugin`, `Work42SDKVersion`, and `XPCService = {ServiceType = Application; RunLoopType =
// _NSApplicationMain}`; the app-sandbox entitlement; and the `-e _NSExtensionMain` entry point. The template `work42 plugin
// build` generates sets all of them (WOR-861 lists why each is required).

#if os(macOS) && canImport(ExtensionKit)
import ExtensionFoundation
import ExtensionKit
import Foundation
import SwiftUI
import Work42PluginKit

// MARK: - XPC protocols

/// What the Work42 app calls on an extension (process connection and scene connections alike). One generic method each
/// way: the method a call names travels in the JSON (`ExtensionCall`), so new methods never change these selectors.
@objc public protocol Work42ExtensionXPC {
    /// Answers one encoded `ExtensionCall` with one encoded `ExtensionReply`.
    nonisolated func handle(_ call: Data, reply: @escaping @Sendable (Data) -> Void)
    /// Receives one encoded `ExtensionStreamEvent` for a stream the extension subscribed to.
    nonisolated func deliver(_ event: Data)
}

/// What an extension calls on the Work42 app: every `SessionServices` proxy goes through this.
@objc public protocol Work42HostXPC {
    nonisolated func handle(_ call: Data, reply: @escaping @Sendable (Data) -> Void)
}

// MARK: - The protocol a plugin's @main type conforms to

/// The protocol itself is nonisolated, and the conforming class must be too (`nonisolated final class`): plugin code
/// compiles with MainActor as its default isolation, which would make the class's `AppExtension` conformance
/// main-actor-isolated, and a protocol refining `AppExtension` cannot be satisfied by an isolated conformance. The two
/// requirements are `@MainActor`, so the widgets and hooks they return are ordinary main-actor plugin code.
@available(macOS 26.2, *)
nonisolated public protocol Work42PluginExtension: AppExtension {
    /// The plugin's widgets, by the ids its `plugin.yaml` declares.
    @MainActor var widgets: [ExtensionWidgetFactory] { get }
    /// The plugin's session hooks, or nil.
    @MainActor var sessionHooks: (any Work42SessionHooks)? { get }
}

@available(macOS 26.2, *)
nonisolated public extension Work42PluginExtension {
    @MainActor var sessionHooks: (any Work42SessionHooks)? { nil }

    /// Binds the extension to Work42's point, `com.work42.app.plugin`.
    @AppExtensionPoint.Bind
    var extensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier(host: "com.work42.app", name: "plugin")
    }

    /// The widget scene plus the process-level connection.
    var configuration: AppExtensionSceneConfiguration {
        // ExtensionKit makes this object once and nothing else touches it; it is only read on the main actor here.
        nonisolated(unsafe) let plugin = self
        onMain { Work42ExtensionHost.start(widgets: plugin.widgets, sessionHooks: plugin.sessionHooks) }
        return AppExtensionSceneConfiguration(Work42WidgetScene(), configuration: Work42ProcessConnection())
    }
}

// MARK: - Process state

/// The one runtime of this extension process.
@MainActor
public enum Work42ExtensionHost {
    public private(set) static var runtime: Work42ExtensionRuntime?

    static func start(widgets: [ExtensionWidgetFactory], sessionHooks: (any Work42SessionHooks)?) {
        if runtime == nil { runtime = Work42ExtensionRuntime(widgets: widgets, sessionHooks: sessionHooks) }
    }
}

/// Runs `body` on the main actor from whatever queue ExtensionKit calls us on.
nonisolated private func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T {
    if Thread.isMainThread { return MainActor.assumeIsolated(body) }
    return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
}

/// The object an extension exports on each connection.
nonisolated final class Work42ExtensionEndpoint: NSObject, Work42ExtensionXPC, @unchecked Sendable {
    /// Calls this endpoint answers itself before the runtime sees them (a scene's `scene.attach`).
    let local: (@MainActor @Sendable (ExtensionCall) async -> ExtensionReply?)?

    init(local: (@MainActor @Sendable (ExtensionCall) async -> ExtensionReply?)? = nil) {
        self.local = local
    }

    func handle(_ call: Data, reply: @escaping @Sendable (Data) -> Void) {
        let local = self.local
        Task { @MainActor in
            if let local, let decoded = try? ExtensionJSON.decode(ExtensionCall.self, from: call),
               let answer = await local(decoded) {
                reply((try? ExtensionJSON.encode(answer)) ?? Data("{}".utf8))
                return
            }
            guard let runtime = Work42ExtensionHost.runtime else {
                reply((try? ExtensionJSON.encode(ExtensionReply(error: .hostInterrupted))) ?? Data("{}".utf8))
                return
            }
            reply(await runtime.handle(encoded: call))
        }
    }

    func deliver(_ event: Data) {
        guard let decoded = try? ExtensionJSON.decode(ExtensionStreamEvent.self, from: event) else { return }
        Task { @MainActor in Work42ExtensionHost.runtime?.channel?.deliver(decoded) }
    }
}

/// A transport over an NSXPC connection: a lost connection answers `nil`, exactly once per call.
nonisolated private func xpcTransport(_ connection: NSXPCConnection) -> any ExtensionTransport {
    // NSXPCConnection is thread-safe but not marked Sendable.
    nonisolated(unsafe) let connection = connection
    return ClosureExtensionTransport { data, reply in
        let once = OnceReply(reply)
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in once.send(nil) } as? (any Work42HostXPC)
        guard let proxy else { once.send(nil); return }
        proxy.handle(data) { once.send($0) }
    }
}

nonisolated private final class OnceReply: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: (@Sendable (Data?) -> Void)?
    init(_ reply: @escaping @Sendable (Data?) -> Void) { self.reply = reply }
    func send(_ value: Data?) {
        lock.lock(); let pending = reply; reply = nil; lock.unlock()
        pending?(value)
    }
}

/// The process-level connection: host requests (`extension.*`) in, service calls out.
nonisolated struct Work42ProcessConnection: AppExtensionConfiguration {
    func accept(connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: Work42ExtensionXPC.self)
        connection.remoteObjectInterface = NSXPCInterface(with: Work42HostXPC.self)
        connection.exportedObject = Work42ExtensionEndpoint()
        let channel = ExtensionChannel(transport: xpcTransport(connection), interruption: .hostInterrupted)
        let lost: @Sendable () -> Void = {
            Task { @MainActor in
                if Work42ExtensionHost.runtime?.channel === channel { Work42ExtensionHost.runtime?.disconnect() }
            }
        }
        connection.interruptionHandler = lost
        connection.invalidationHandler = lost
        onMain { Work42ExtensionHost.runtime?.connect(channel) }
        connection.resume()
        return true
    }
}

// MARK: - The widget scene

/// One widget scene's state. A scene's view and its connection arrive in either order (WOR-861): whichever comes first
/// parks a model and the other takes it.
@MainActor
final class Work42SceneModel: ObservableObject {
    static var waitingForView: [Work42SceneModel] = []
    static var waitingForConnection: [Work42SceneModel] = []

    @Published var content: AnyView?
    @Published var failure: String?

    static func forView() -> Work42SceneModel {
        if !waitingForView.isEmpty { return waitingForView.removeFirst() }
        let model = Work42SceneModel(); waitingForConnection.append(model); return model
    }

    static func forConnection() -> Work42SceneModel {
        if !waitingForConnection.isEmpty { return waitingForConnection.removeFirst() }
        let model = Work42SceneModel(); waitingForView.append(model); return model
    }

    /// `scene.attach`: shows `widgetId`'s view for `sessionId`.
    func attach(_ call: ExtensionCall) -> ExtensionReply {
        do {
            guard let runtime = Work42ExtensionHost.runtime else { throw WidgetServiceError.hostInterrupted }
            guard let widgetId = call.widgetId, let sessionId = call.sessionId else {
                throw WidgetServiceError(message: "scene.attach needs a widgetId and a sessionId",
                                         suggestion: "the host must set both on the scene's first call")
            }
            let context = try ExtensionJSON.decode(ExtensionPayload.SessionContext.self, from: call.payload)
            let (widget, services) = try runtime.instance(widgetId: widgetId, sessionId: sessionId,
                                                          worktreePath: context.worktreePath)
            content = widget.makeView(services: services)
            failure = nil
            return try .success(ExtensionEmpty())
        } catch {
            failure = (error as? WidgetServiceError)?.errorDescription ?? error.localizedDescription
            return .failure(error)
        }
    }
}

struct Work42SceneView: View {
    @StateObject private var model = Work42SceneModel.forView()

    var body: some View {
        if let content = model.content {
            content
        } else if let failure = model.failure {
            Text(failure).foregroundStyle(.secondary).padding()
        } else {
            Color.clear
        }
    }
}

struct Work42WidgetScene: AppExtensionScene {
    var body: some AppExtensionScene {
        PrimitiveAppExtensionScene(id: Work42ExtensionPoint.sceneIdentifier, content: { Work42SceneView() },
                                   onConnection: { connection in
            let model = onMain { Work42SceneModel.forConnection() }
            connection.exportedInterface = NSXPCInterface(with: Work42ExtensionXPC.self)
            connection.remoteObjectInterface = NSXPCInterface(with: Work42HostXPC.self)
            connection.exportedObject = Work42ExtensionEndpoint(local: { call in
                call.name == "scene.attach" ? model.attach(call) : nil
            })
            connection.resume()
            return true
        })
    }
}
#endif
