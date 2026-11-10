// ComposerTargets.swift — each window's (or session's) composer, and which one Return, dictation and the Pencil reach.
//
// A composer registering (a view appearing, a tab changing) never makes itself the target: the target is the composer of whatever
// `focusedKey` says is focused, so a window the user is not in cannot take their typing.

import Observation

/// What a composer offers to whatever sends or inserts on the user's behalf.
public struct Composer {
    public var isFocused: () -> Bool
    public var canSend: () -> Bool
    public var send: () -> Void
    public var insert: (String) -> Void

    public init(
        isFocused: @escaping () -> Bool,
        canSend: @escaping () -> Bool,
        send: @escaping () -> Void,
        insert: @escaping (String) -> Void
    ) {
        self.isFocused = isFocused
        self.canSend = canSend
        self.send = send
        self.insert = insert
    }
}

@MainActor
@Observable
public final class ComposerTargets<Key: Hashable> {
    @ObservationIgnored private let focusedKey: () -> Key?
    private var composers: [Key: Composer] = [:]

    /// `focusedKey` names the key that is focused now (the focused window, or the focused session).
    public init(focusedKey: @escaping () -> Key?) {
        self.focusedKey = focusedKey
    }

    /// Publishes (or refreshes) `key`'s composer. This never changes the target.
    public func update(_ composer: Composer, for key: Key) { composers[key] = composer }

    /// Drops `key`'s composer (its view went away).
    public func clear(_ key: Key) { composers[key] = nil }

    public func composer(for key: Key) -> Composer? { composers[key] }

    /// The focused key's composer, if it has one.
    public var target: Composer? {
        guard let key = focusedKey() else { return nil }
        return composers[key]
    }
}
