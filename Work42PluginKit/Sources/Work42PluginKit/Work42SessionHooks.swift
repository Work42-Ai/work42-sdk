// Work42SessionHooks.swift — the compiled plugin session-hook contract
// (plugin-platform-foundation, s2). A widget dylib exports
// `work42_widget_main`/`work42_widget_sdk_version` and is scoped to one
// mounted widget; a PLUGIN dylib exports `work42_plugin_main`/
// `work42_plugin_sdk_version` and is scoped to the plugin's session
// TYPES — it runs once per session creation, with no widget mounted.
// This entry point is OPTIONAL: a plugin with no `Sources/Plugin.swift`
// has no dylib, and the loader treats that as "no hooks" (back-compat,
// AC11) rather than an error.

import Foundation

/// The context passed to a session type's `onCreate` hook. Mirrors the
/// widget-side `SessionServices` shape (storage + shell) but is scoped to
/// session CREATION rather than an active mounted widget — there is no
/// composer/intents surface because no widget is necessarily present.
nonisolated public struct SessionCreateContext: Sendable {
    /// The newly minted session's id.
    public let sessionId: String
    /// The session's display name, as chosen at creation time. Falls back to
    /// `sessionId` when no name was given (mirrors the host's own fallback).
    public let name: String
    /// Absolute path to the session's worktree on disk.
    public let worktreePath: String
    /// The params passed to session creation (from an intent invocation, the
    /// CLI `--storage` flags, or a create-intent's collected parameters).
    public let params: [String: WidgetJSONValue]
    /// Scoped storage access for this session (same contract widgets use).
    public let storage: any WidgetStorageService
    /// Scoped shell access for this session's worktree (same contract widgets use).
    public let shell: any WidgetShellService

    public init(
        sessionId: String,
        name: String,
        worktreePath: String,
        params: [String: WidgetJSONValue],
        storage: any WidgetStorageService,
        shell: any WidgetShellService
    ) {
        self.sessionId = sessionId
        self.name = name
        self.worktreePath = worktreePath
        self.params = params
        self.storage = storage
        self.shell = shell
    }
}

/// The lifecycle hooks a plugin can implement for the session types it owns.
/// `onCreate` runs on an ALREADY-VALID session (worktree minted, row inserted,
/// initial stage entered) — it is additive setup (seed storage, checkout a
/// branch, resolve an external resource), never a precondition for validity.
/// A throw is caught by the kernel: the session is kept, the error is
/// surfaced in-session, and layout/compose/kickoff still run (AC6).
nonisolated public protocol Work42SessionHooks: AnyObject, Sendable {
    func onCreate(_ context: SessionCreateContext) async throws
}

// MARK: - PluginEntryPoint

/// The plugin-side mirror of `WidgetEntryPoint` — the raw-pointer handoff for
/// `work42_plugin_main`. Same box/claim discipline: `register` runs in the
/// plugin dylib, `claim` runs in the loader, both against the same embedded
/// Work42PluginKit framework so the unbox cast is exact.
public enum PluginEntryPoint {

    /// Plugin side: box `hooks` for the trip through `work42_plugin_main`'s C
    /// return value. +1 retained; ownership transfers to the caller (the
    /// loader's `claim`).
    @MainActor
    public static func register(_ hooks: any Work42SessionHooks) -> UnsafeMutableRawPointer {
        Unmanaged.passRetained(PluginHandoffBox(hooks)).toOpaque()
    }

    /// Loader side: take ownership of a pointer produced by `register` and
    /// unbox the hooks. Returns nil when the pointer is not a
    /// `register`-produced box — the loader treats that as a malformed
    /// plugin entry and reports it, never crashes.
    @MainActor
    public static func claim(_ pointer: UnsafeMutableRawPointer) -> (any Work42SessionHooks)? {
        let object = Unmanaged<AnyObject>.fromOpaque(pointer).takeRetainedValue()
        return (object as? PluginHandoffBox)?.hooks
    }
}

/// The opaque box `PluginEntryPoint` passes across the C boundary. A class
/// (not a struct) so it has a stable object identity `Unmanaged` can retain;
/// `@MainActor` because `register`/`claim` are (mirrors `WidgetHandoffBox`).
@MainActor
private final class PluginHandoffBox {
    let hooks: any Work42SessionHooks

    init(_ hooks: any Work42SessionHooks) {
        self.hooks = hooks
    }
}
