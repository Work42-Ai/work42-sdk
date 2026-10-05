// SessionServices.swift — the XPC-shaped session-service protocols
// (feat/custom-widgets.1; implementations arrive in subtask .4).
//
// `SessionServices` is the ONLY doorway between a widget and its owning
// session. The three service families — composer, shell, intents — are
// deliberately shaped like an XPC/ExtensionKit surface from day one:
//
//   - ALL requirements are `async throws`. There is no synchronous call a
//     widget can reach (the documented AttributeGraph tile-freeze class
//     comes from synchronous waits on the render path).
//   - Every parameter and return type is Codable + Sendable. No
//     app-internal type ever crosses this boundary, so moving a widget out
//     of process later is a host-side transport swap (proxy objects that
//     serialize these exact payloads), not a widget rewrite.
//   - Errors are data too: failures surface as `WidgetServiceError` with a
//     `suggestion`, matching the repo-wide error convention.
//
// The protocols are `nonisolated` (not main-actor) on purpose: service
// IMPLEMENTATIONS decide their own isolation (the shell runner is
// explicitly off-main), and widget code just `await`s from wherever it is.

import Foundation

// MARK: - WidgetJSONValue

/// A Codable, Sendable JSON-shaped value — the parameter/return currency of
/// the intents service (and any future service that needs open-shaped
/// payloads). Exists so the service boundary never needs `Any` or an
/// app-internal type, keeping every payload serializable for the later
/// out-of-process transport.
nonisolated public enum WidgetJSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([WidgetJSONValue])
    case object([String: WidgetJSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([WidgetJSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: WidgetJSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Value is not JSON-representable"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let bool): try container.encode(bool)
        case .number(let number): try container.encode(number)
        case .string(let string): try container.encode(string)
        case .array(let array): try container.encode(array)
        case .object(let object): try container.encode(object)
        }
    }
}

// MARK: - WidgetServiceError

/// The error every service throws. Carries a human/agent-readable message
/// plus the repo-conventional `suggestion` telling the caller what to do
/// next. Codable so it can cross a future XPC boundary unchanged.
///
/// Conforms to `LocalizedError` so `error.localizedDescription` — what
/// SwiftUI error surfaces (like `BrowserSurface`'s built-in fail-loud card)
/// read by default — actually shows `message`/`suggestion` instead of
/// Swift's generic NSError-bridging fallback ("The operation couldn't be
/// completed. (Work42PluginKit.WidgetServiceError error 1.)"), which is
/// what every widget's error card showed before this conformance existed.
nonisolated public struct WidgetServiceError: Error, LocalizedError, Codable, Sendable, Equatable {

    /// What went wrong (e.g. "intent 'jira.open' is not registered").
    public var message: String

    /// What the caller should do about it (e.g. "check
    /// services.intents ids via the palette registry; widget intents are
    /// namespaced widget.<slug>.<intent>").
    public var suggestion: String?

    public init(message: String, suggestion: String? = nil) {
        self.message = message
        self.suggestion = suggestion
    }

    public var errorDescription: String? {
        guard let suggestion, !suggestion.isEmpty else { return message }
        return "\(message) — \(suggestion)"
    }
}

// MARK: - Composer

/// Writes into the session's chat composer. Backed (subtask .4) by the
/// chat draft + `PendingCommentsStore` — the same path the PR-highlight
/// flow uses — but the widget only ever sees these Codable payloads.
nonisolated public protocol WidgetComposerService: Sendable {

    /// Append `text` to the session's chat composer draft. The user still
    /// sends the message — widgets draft, never speak.
    func insert(text: String) async throws

    /// Attach a structured pending comment to the composer, rendering
    /// exactly like the PR-highlight flow's cards.
    ///
    /// - Parameters:
    ///   - sourceLabel: Where the excerpt came from, shown on the card
    ///     (e.g. "Jira PROJ-123", "build log").
    ///   - excerpt: The quoted material.
    ///   - body: The widget's/user's note about the excerpt.
    func attach(sourceLabel: String, excerpt: String, body: String) async throws

    /// Publish a live commentable selection so DICTATION can drop a comment on
    /// it (highlight → push-to-talk → comment in the composer, no dialog),
    /// reusing the same path as `attach`. Call when the selection becomes live;
    /// clear it when the selection goes away. Closure-free so the seam stays
    /// XPC-safe — the host owns how a dictated body becomes a comment.
    func presentCommentableSelection(sourceLabel: String, excerpt: String) async throws
    func clearCommentableSelection() async throws
}

public extension WidgetComposerService {
    // Default no-ops so existing conformers / mocks keep compiling; the real
    // session-backed service overrides these.
    func presentCommentableSelection(sourceLabel: String, excerpt: String) async throws {}
    func clearCommentableSelection() async throws {}
}

// MARK: - Shell

/// The result of one shell command run. Plain data — Codable so it can
/// cross a future XPC boundary unchanged.
nonisolated public struct WidgetShellResult: Codable, Sendable, Equatable {

    public var stdout: String
    public var stderr: String
    public var exitCode: Int32

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

/// Runs shell commands for the widget. Backed (subtask .4) by an async
/// runner executing OFF the main thread with cwd = the session worktree
/// and the session env (`WORK42_SESSION_ID` / `WORK42_SESSION_DIR` /
/// `WORK42_TASK_ID` for task sessions), default 10s timeout.
///
/// This service is the reason widget code never needs `Process`: a
/// synchronous subprocess on the render path is the documented
/// tile-freeze class. `await` this from a `.task`/button action instead.
nonisolated public protocol WidgetShellService: Sendable {

    /// Run `command` through the session's shell and resolve with its
    /// captured output. Throws `WidgetServiceError` on timeout or when the
    /// session has no worktree to run in; a non-zero exit is NOT a throw —
    /// it comes back in `exitCode` with both streams intact.
    func run(command: String) async throws -> WidgetShellResult
}

// MARK: - Intents

/// Executes intents from the palette intent registry — the same catalog
/// the command palette renders (root globals, session intents, other
/// widgets' intents), subject to the palette scoping rule (a widget
/// reaches its session's and root's intents, never a sibling session's).
/// Backed (subtask .4) by the intents core from subtask .7.
nonisolated public protocol WidgetIntentsService: Sendable {

    /// Execute the intent registered under `id` (hierarchical, e.g.
    /// "session.run" or "widget.<slug>.<intent>") with `params`.
    /// Not-found and handler failure both throw `WidgetServiceError` —
    /// reported to the caller, never swallowed.
    func execute(id: String, params: [String: WidgetJSONValue]) async throws
}

// MARK: - Storage

/// Per-task key/value storage accessible from a widget. Reads may span any
/// namespace; writes and deletes target ONLY the widget's own namespace (its
/// `id`) — the boundary is enforced by the app-side implementation, not in SQL.
///
/// **Session-hosted widgets** (task sessions): backed by the task's
/// `task_storage` rows in `tracker.db`. The widget's `id` is its writable
/// namespace.
///
/// **Home-hosted widgets** and sessions without a task: storage is unavailable.
/// Every call throws `WidgetServiceError` with an honest remedy — never silent
/// fabricated data (the repo's fail-loud convention). This matches how
/// `HomeComposerUnavailableService` handles the composer service on the same
/// surface: the service protocol is the same; the backing differs by surface.
///
/// **Code-review sessions**: backed by the same `task_storage` interface as
/// task sessions — no separate database, no special routing. The widget code
/// is identical across session kinds.
///
/// Errors thrown by every method are `WidgetServiceError` with `message` and
/// `suggestion`, matching the repo-wide error convention.
nonisolated public protocol WidgetStorageService: Sendable {

    /// Read the value at `namespace/key` in this task's storage. Returns nil
    /// when the key has not been set. Any namespace may be read — the widget
    /// is not restricted to its own.
    func get(namespace: String, key: String) async throws -> WidgetJSONValue?

    /// List every key/value pair in `namespace` for this task. Returns an
    /// empty dictionary when the namespace exists but has no entries, or when
    /// the namespace has never been written. Any namespace may be listed.
    func list(namespace: String) async throws -> [String: WidgetJSONValue]

    /// Upsert `value` at `key` in THIS widget's own namespace (the widget's
    /// `id`). Cross-namespace writes are not exposed — the write surface is
    /// deliberately narrow so a widget can only modify its own data without
    /// the widget author having to name the namespace.
    func set(key: String, value: WidgetJSONValue) async throws

    /// Delete the entry at `key` from THIS widget's own namespace. No-op (not
    /// a throw) when the key is absent.
    func delete(key: String) async throws
}

// MARK: - Pill

/// Presents/dismisses a widget's pill view (see `Work42WidgetPill`) on the
/// floating pill accessory. Backed by `PillHost` — callable from BOTH
/// `SessionServices` (the Session/Home list picks) and
/// `WidgetBackgroundServices` (e.g. the transcript widget's auto-record
/// agent presenting its RECORDING pill without any view mounted).
///
/// `present`/`dismiss` operate on at most one floated pill at a time — a new
/// `present` call swaps out whatever pill is currently shown.
nonisolated public protocol WidgetPillService: Sendable {

    /// Float `widgetId`'s pill view for `sessionId`. Throws
    /// `WidgetServiceError` if the widget does not conform to
    /// `Work42WidgetPill` or its `makePillView` returns nil for this session.
    func present(widgetId: String, sessionId: String) async throws

    /// Dismiss `widgetId`'s pill if it is the one currently floated. No-op
    /// (not a throw) if a different widget's pill is showing or none is.
    func dismiss(widgetId: String) async throws

    /// Whether `widgetId`'s pill is the one currently floated.
    func isPresented(widgetId: String) async throws -> Bool
}

// MARK: - SessionServices

/// The bundle of session services handed to a widget's lifecycle and view
/// factory. One instance per (widget, session); the widget must not
/// assume the services outlive its `deactivate()`.
nonisolated public struct SessionServices: Sendable {

    /// Chat-composer access (draft insert + pending-comment attach).
    public let composer: any WidgetComposerService

    /// Async shell execution in the session worktree.
    public let shell: any WidgetShellService

    /// Palette-registry intent execution.
    public let intents: any WidgetIntentsService

    /// Per-task key/value storage. Readable from any namespace; writable only
    /// in the widget's own namespace (its `id`). Unavailable on the Home
    /// surface and task-less sessions — those throw `WidgetServiceError` with a
    /// named remedy rather than silently no-oping. Code-review sessions use the
    /// same `task_storage` backing (same protocol surface).
    public let storage: any WidgetStorageService

    /// Presents/dismisses a pill-capable widget's pill view (see
    /// `Work42WidgetPill`) — backs the pill's Session/Home list picks.
    public let pill: any WidgetPillService

    /// The owning session's id (task42-plugin-conversion, s3) — needed for
    /// e.g. artifact URL derivation (`[[artifact:id]]` embeds) and
    /// self-registration. `nil` on session-less surfaces (Home).
    public let sessionId: String?

    /// The owning session's working directory — its worktree root for a
    /// real session, or the project root on the session-less Home surface
    /// (s3). `nil` only when neither is available.
    public let worktreePath: String?

    public init(
        composer: any WidgetComposerService,
        shell: any WidgetShellService,
        intents: any WidgetIntentsService,
        storage: any WidgetStorageService,
        pill: any WidgetPillService,
        sessionId: String? = nil,
        worktreePath: String? = nil
    ) {
        self.composer = composer
        self.shell = shell
        self.intents = intents
        self.storage = storage
        self.pill = pill
        self.sessionId = sessionId
        self.worktreePath = worktreePath
    }
}
