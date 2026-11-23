// ExtensionRequestLedger.swift — every request that must not run twice, and what became of it (SDK 3.2.0, host side).
//
// Work42 records each call that carries a `requestId` (`ExtensionCall.nonIdempotentMethods`), in both directions: the
// requests it sends an extension (an intent, a hook) and the ones an extension sends it (`shell.run`, `tools.call`, ...).
// A request is `sent` until its reply arrives (`done`). When the extension process stops, every request still `sent` becomes
// `interrupted`: the caller is told, and nothing is sent or run again. A `requestId` the ledger has already seen is refused,
// so a request that reaches the host twice still runs once. In memory only: a restart of Work42 starts a new ledger, and
// an extension process never outlives the Work42 that started it.

import Foundation

nonisolated public enum ExtensionRequestStatus: String, Sendable, Equatable {
    case sent, done, interrupted
}

@MainActor
public final class ExtensionRequestLedger {

    public struct Entry: Sendable, Equatable {
        public let requestId: UUID
        /// `service.method`.
        public let name: String
        public let sessionId: String?
        public let widgetId: String?
        public internal(set) var status: ExtensionRequestStatus
    }

    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []
    /// Finished entries kept for answering a repeated id; the oldest go first.
    private let capacity: Int

    public init(capacity: Int = 4096) {
        self.capacity = capacity
    }

    /// Records `call` as sent. Returns false, and records nothing, when the call has no `requestId` (nothing to track) or
    /// when that id was already recorded (it must not run again).
    @discardableResult
    public func begin(_ call: ExtensionCall) -> Bool {
        guard let id = call.requestId, entries[id] == nil else { return false }
        entries[id] = Entry(requestId: id, name: call.name, sessionId: call.sessionId, widgetId: call.widgetId,
                            status: .sent)
        order.append(id)
        trim()
        return true
    }

    /// The reply for `requestId` arrived (success or error alike).
    public func finish(_ requestId: UUID) {
        guard entries[requestId]?.status == .sent else { return }
        entries[requestId]?.status = .done
    }

    /// The extension process stopped: every request still in flight is interrupted. Returns those requests.
    @discardableResult
    public func interruptInFlight() -> [Entry] {
        var interrupted: [Entry] = []
        for id in order where entries[id]?.status == .sent {
            entries[id]?.status = .interrupted
            if let entry = entries[id] { interrupted.append(entry) }
        }
        return interrupted
    }

    public func entry(_ requestId: UUID) -> Entry? { entries[requestId] }

    /// Every recorded request of `sessionId`, oldest first.
    public func entries(forSession sessionId: String) -> [Entry] {
        order.compactMap { entries[$0] }.filter { $0.sessionId == sessionId }
    }

    public var inFlightCount: Int { entries.values.filter { $0.status == .sent }.count }

    private func trim() {
        while order.count > capacity, let index = order.firstIndex(where: { entries[$0]?.status != .sent }) {
            entries.removeValue(forKey: order.remove(at: index))
        }
    }
}
