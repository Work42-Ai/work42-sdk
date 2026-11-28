// ExtensionChannel.swift — request/reply and streams over one connection (SDK 3.2.0).
//
// The channel knows nothing about XPC: it sends encoded `ExtensionCall`s through an `ExtensionTransport` and decodes the
// `ExtensionReply`. The extension wires the transport to its NSXPC connection to Work42; tests wire it to an in-memory
// dispatcher. A reply of `nil` means the connection was lost, which every waiting call turns into `interruption`, never
// a retry.

import Foundation
import Work42PluginKit

/// Sends one encoded `ExtensionCall` and hands back the encoded `ExtensionReply`, or `nil` when the connection is gone.
nonisolated public protocol ExtensionTransport: Sendable {
    func send(_ call: Data, reply: @escaping @Sendable (Data?) -> Void)
}

/// A transport backed by a closure, for an NSXPC proxy or a test double.
nonisolated public struct ClosureExtensionTransport: ExtensionTransport {
    private let body: @Sendable (Data, @escaping @Sendable (Data?) -> Void) -> Void

    public init(_ body: @escaping @Sendable (Data, @escaping @Sendable (Data?) -> Void) -> Void) {
        self.body = body
    }

    public func send(_ call: Data, reply: @escaping @Sendable (Data?) -> Void) { body(call, reply) }
}

/// The arguments of a call that opens a stream: the subscriber picks the stream id, so the other side can push items the
/// moment it has them, before the call's reply arrives.
nonisolated public struct ExtensionSubscription<Arguments: Codable & Sendable>: Codable, Sendable {
    public var streamId: UUID
    public var arguments: Arguments

    public init(streamId: UUID, arguments: Arguments) {
        self.streamId = streamId
        self.arguments = arguments
    }
}

/// One side's end of the wire: typed calls, and the streams the other side pushes into.
nonisolated public final class ExtensionChannel: @unchecked Sendable {
    private let transport: any ExtensionTransport
    private let interruption: WidgetServiceError
    private let lock = NSLock()
    private var streams: [UUID: AsyncStream<Data>.Continuation] = [:]
    private var streamErrors: [UUID: WidgetServiceError] = [:]
    private var closed = false

    /// - Parameter interruption: what a waiting call throws when the connection is lost (`hostInterrupted` inside an
    ///   extension, `extensionInterrupted` in the host).
    public init(transport: any ExtensionTransport, interruption: WidgetServiceError = .hostInterrupted) {
        self.transport = transport
        self.interruption = interruption
    }

    /// Sends `call` and returns the decoded reply payload. Throws the callee's `WidgetServiceError`, or `interruption`
    /// when the connection is lost before the reply.
    public func send<Result: Decodable>(_ call: ExtensionCall, as type: Result.Type) async throws -> Result {
        let data = try await sendRaw(call)
        return try ExtensionJSON.decode(type, from: data)
    }

    /// Sends `call` and returns the raw reply payload (an empty object when the callee returned none).
    public func sendRaw(_ call: ExtensionCall) async throws -> Data {
        if isClosed { throw interruption }
        let encoded = try ExtensionJSON.encode(call)
        let interruption = self.interruption
        let replyData: Data? = await withCheckedContinuation { continuation in
            transport.send(encoded) { continuation.resume(returning: $0) }
        }
        guard let replyData else { throw interruption }
        let reply = try ExtensionJSON.decode(ExtensionReply.self, from: replyData)
        if let error = reply.error { throw error }
        return reply.payload ?? Data("{}".utf8)
    }

    /// Builds the call (adding a `requestId` when the method is non-idempotent), sends it and decodes the reply.
    public func call<Payload: Encodable, Result: Decodable>(
        _ service: String, _ method: String, sessionId: String?, widgetId: String?, agent: Bool? = nil,
        payload: Payload, as type: Result.Type
    ) async throws -> Result {
        try await send(ExtensionCall.make(service: service, method: method, sessionId: sessionId,
                                          widgetId: widgetId, agent: agent, payload: payload), as: type)
    }

    /// The same, for a call with no result.
    public func call<Payload: Encodable>(_ service: String, _ method: String, sessionId: String?, widgetId: String?,
                                         agent: Bool? = nil, payload: Payload) async throws {
        _ = try await sendRaw(ExtensionCall.make(service: service, method: method, sessionId: sessionId,
                                                 widgetId: widgetId, agent: agent, payload: payload))
    }

    /// Opens a stream: registers it, then asks the other side to start pushing into it. The stream finishes when the other
    /// side ends it, when the call fails, when the connection is lost, or when the consumer stops iterating (which tells the
    /// other side to stop with `stream.cancel`).
    public func subscribe<Arguments: Codable & Sendable>(
        _ service: String, _ method: String, sessionId: String?, widgetId: String?, agent: Bool? = nil, arguments: Arguments
    ) -> AsyncStream<Data> {
        let streamId = UUID()
        let stream = register(streamId, sessionId: sessionId, widgetId: widgetId, agent: agent)
        Task {
            do {
                try await self.call(service, method, sessionId: sessionId, widgetId: widgetId, agent: agent,
                                    payload: ExtensionSubscription(streamId: streamId, arguments: arguments))
            } catch {
                ExtensionLog.channel.error("subscribe-failed stream=\(ExtensionLog.short(streamId), privacy: .public) call=\(service, privacy: .public).\(method, privacy: .public) error=\(String(describing: error), privacy: .public)")
                self.finishStream(streamId)
            }
        }
        return stream
    }

    /// Opens a stream like `subscribe`, but waits for the other side to accept it, so a refusal (a command that cannot
    /// start, a path that is not allowed) is thrown to the caller instead of ending the stream silently. Returns the
    /// stream's id, which later calls about it (`shell.stop`) name, and the stream. The call carries a `requestId` when
    /// `service.method` is non-idempotent, so a crash never opens it twice.
    public func openStream<Arguments: Codable & Sendable>(
        _ service: String, _ method: String, sessionId: String?, widgetId: String?, agent: Bool? = nil, arguments: Arguments
    ) async throws -> (id: UUID, stream: AsyncStream<Data>) {
        let streamId = UUID()
        let stream = register(streamId, sessionId: sessionId, widgetId: widgetId, agent: agent)
        do {
            try await call(service, method, sessionId: sessionId, widgetId: widgetId, agent: agent,
                           payload: ExtensionSubscription(streamId: streamId, arguments: arguments))
        } catch {
            ExtensionLog.channel.error("open-stream-failed stream=\(ExtensionLog.short(streamId), privacy: .public) call=\(service, privacy: .public).\(method, privacy: .public) error=\(String(describing: error), privacy: .public)")
            finishStream(streamId)
            throw error
        }
        ExtensionLog.channel.info("open-stream-ok stream=\(ExtensionLog.short(streamId), privacy: .public) call=\(service, privacy: .public).\(method, privacy: .public)")
        return (streamId, stream)
    }

    /// Registers stream `streamId` so pushed items reach the returned stream. A closed channel gives a finished stream.
    private func register(_ streamId: UUID, sessionId: String?, widgetId: String?, agent: Bool?) -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        lock.lock()
        let wasClosed = closed
        if !wasClosed { streams[streamId] = continuation }
        lock.unlock()
        if wasClosed {
            ExtensionLog.channel.notice("stream-register-refused stream=\(ExtensionLog.short(streamId), privacy: .public) reason=channel-closed")
            continuation.finish()
            return stream
        }
        ExtensionLog.channel.info("stream-register stream=\(ExtensionLog.short(streamId), privacy: .public) session=\(sessionId ?? "-", privacy: .public) widget=\(widgetId ?? "-", privacy: .public)")
        continuation.onTermination = { [weak self] reason in
            guard let self else { return }
            let stillOpen = self.removeStream(streamId)
            ExtensionLog.channel.info("stream-terminated stream=\(ExtensionLog.short(streamId), privacy: .public) reason=\(Self.describe(reason), privacy: .public) byConsumer=\(stillOpen, privacy: .public)")
            // Only a consumer that stopped iterating needs to tell the other side; a finish from the other side does not.
            if stillOpen, case .cancelled = reason {
                Task { try? await self.call("stream", "cancel", sessionId: sessionId, widgetId: widgetId, agent: agent,
                                            payload: ExtensionSubscription(streamId: streamId, arguments: ExtensionEmpty())) }
            }
        }
        return stream
    }

    /// Hands a pushed item (or the end of a stream) to the stream it belongs to. Unknown stream ids are ignored: the
    /// consumer already stopped.
    public func deliver(_ event: ExtensionStreamEvent) {
        lock.lock()
        let continuation = streams[event.streamId]
        lock.unlock()
        guard let continuation else { return }
        if let item = event.item { continuation.yield(item) }
        if event.finished {
            // Recorded before the stream finishes, so a consumer whose loop just ended finds it.
            if let error = event.error {
                ExtensionLog.channel.error("stream-end-error stream=\(ExtensionLog.short(event.streamId), privacy: .public) message=\(error.message, privacy: .public) suggestion=\(error.suggestion ?? "-", privacy: .public)")
                lock.withLock { streamErrors[event.streamId] = error }
            } else {
                ExtensionLog.channel.info("stream-end stream=\(ExtensionLog.short(event.streamId), privacy: .public)")
            }
            finishStream(event.streamId)
        }
    }

    /// The error stream `streamId` ended with, if the other side ended it with one. Taken once, after the stream finished.
    func takeStreamError(_ streamId: UUID) -> WidgetServiceError? {
        lock.withLock { streamErrors.removeValue(forKey: streamId) }
    }

    /// The connection is gone: every open stream finishes and every later call throws the interruption error.
    public func close() {
        lock.lock()
        closed = true
        let open = streams
        streams.removeAll()
        lock.unlock()
        ExtensionLog.channel.error("channel-closed openStreams=\(open.count, privacy: .public) streams=\(open.keys.map(ExtensionLog.short).joined(separator: ","), privacy: .public)")
        for continuation in open.values { continuation.finish() }
    }

    private static func describe(_ reason: AsyncStream<Data>.Continuation.Termination) -> String {
        switch reason {
        case .finished: "finished"
        case .cancelled: "cancelled"
        @unknown default: "unknown"
        }
    }

    public var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    /// The number of streams still open, for tests.
    public var openStreamCount: Int {
        lock.lock(); defer { lock.unlock() }
        return streams.count
    }

    private func finishStream(_ streamId: UUID) {
        lock.lock()
        let continuation = streams.removeValue(forKey: streamId)
        lock.unlock()
        continuation?.finish()
    }

    /// Removes the stream and reports whether it was still registered.
    private func removeStream(_ streamId: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return streams.removeValue(forKey: streamId) != nil
    }
}
