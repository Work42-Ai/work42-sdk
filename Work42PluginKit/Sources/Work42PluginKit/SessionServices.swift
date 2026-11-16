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
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

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

    /// The prefix every "not permitted" error starts with. `WidgetServiceError` has no stored code (its
    /// layout is pinned by `PublicLayoutStabilityTests`), so this prefix is how a caller tells a refusal
    /// from any other failure, on either side of the device link.
    nonisolated public static let notPermittedPrefix = "not permitted: "

    /// A refusal: the request was well formed but is not allowed (a path outside the session folder, a
    /// widget or command a device may not use). Nothing ran.
    public static func notPermitted(_ reason: String, suggestion: String? = nil) -> WidgetServiceError {
        WidgetServiceError(message: notPermittedPrefix + reason, suggestion: suggestion)
    }

    /// Whether this error is a refusal made by `notPermitted(_:suggestion:)`.
    public var isNotPermitted: Bool { message.hasPrefix(Self.notPermittedPrefix) }
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

    /// The acting person's own value at `key` in this widget's namespace (SDK 2.14.0), or nil when they have not set one.
    /// Another person's value under the same key is a different value. Default: throws, for a host that keeps no per-person state.
    func person(key: String) async throws -> WidgetJSONValue?

    /// Set the acting person's own value at `key`. Only they write it. Default: throws.
    func setPerson(key: String, value: WidgetJSONValue) async throws

    /// Remove the acting person's own value at `key`. No-op when they have none. Default: throws.
    func deletePerson(key: String) async throws

    /// Every person's value at `key`, by the person's id (who approved, who has read it). Read-only. Default: throws.
    func people(key: String) async throws -> [String: WidgetJSONValue]
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

// MARK: - Tools

/// One work42 tool a plugin can call (SDK 2.8.0): the same catalog agents get over MCP.
nonisolated public struct WidgetToolInfo: Sendable, Codable, Equatable {
    /// The reserved server the tool belongs to (e.g. `work42-session`).
    public var server: String
    public var name: String
    public var description: String
    /// The tool's JSON Schema input, as a JSON value.
    public var inputSchema: WidgetJSONValue

    public init(server: String, name: String, description: String, inputSchema: WidgetJSONValue) {
        self.server = server
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// Calls the work42 tools (`work42-session`, `work42-artifact`, `work42-terminal`, `work42-device`) the way an
/// agent does, in-process. Every work42 tool is callable; plugin calls are not stage-gated by the workflow, which
/// only governs agent calls. Failures throw `WidgetServiceError` carrying the tool's message and suggestion.
nonisolated public protocol WidgetToolService: Sendable {

    /// Every tool the host serves, across all servers.
    func listTools() async throws -> [WidgetToolInfo]

    /// Run `tool` on `server`. `session` targets another session by id; `nil` runs it for the widget's own
    /// session (a session-less surface such as Home has none, so it must pass `session`). Returns the tool's
    /// result as a JSON value.
    func call(server: String, tool: String, arguments: [String: WidgetJSONValue],
              session: String?) async throws -> WidgetJSONValue
}

/// The default for hosts without tool support (previews, tests): every call throws a named
/// `WidgetServiceError` instead of returning fabricated data.
nonisolated public struct UnavailableWidgetToolService: WidgetToolService {
    public init() {}

    private var error: WidgetServiceError {
        WidgetServiceError(
            message: "this host does not provide work42 tools",
            suggestion: "run the widget inside Work42 2.8.0 or later, or pass a WidgetToolService when constructing the services")
    }

    public func listTools() async throws -> [WidgetToolInfo] { throw error }
    public func call(server: String, tool: String, arguments: [String: WidgetJSONValue],
                     session: String?) async throws -> WidgetJSONValue { throw error }
}

// MARK: - Account

/// The signed-in Work42 account, as a widget may see it.
///
/// Privacy: every installed plugin can read this. It is the person's display name, email and profile
/// photo URL; plugins already run shell commands as the user, so it adds no new capability, but it is
/// an explicit data surface (see the SDK changelog).
nonisolated public struct WidgetAccountUser: Sendable, Equatable {
    public let displayName: String?
    public let email: String?
    /// The provider's profile photo (Google or GitHub), a remote https URL.
    public let photoURL: URL?

    public init(displayName: String?, email: String?, photoURL: URL?) {
        self.displayName = displayName
        self.email = email
        self.photoURL = photoURL
    }
}

/// Who is signed in to Work42, for widgets that show "you" (a transcript, a comment author).
nonisolated public protocol WidgetAccountService: Sendable {
    /// The signed-in user, or nil when signed out (or in a build without sign-in).
    func currentUser() async -> WidgetAccountUser?
}

// MARK: - Files

/// One entry of a directory listing in the session folder. Plain data so it crosses the device link unchanged.
nonisolated public struct WidgetFileEntry: Sendable, Codable, Equatable {
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    public var modifiedAt: Date

    public init(name: String, isDirectory: Bool, size: Int64, modifiedAt: Date) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

/// The one rule for a path a widget hands to `WidgetFileService`: relative to the session folder, never
/// absolute, never leaving it. Every implementation (the Mac's local one, the Mac's answer to a device, the
/// tests) calls this first, so a widget gets the same refusal wherever it runs.
nonisolated public enum WidgetFilePath {

    /// Throws `WidgetServiceError.notPermitted` for an empty path, an absolute path (leading `/` or `~`), a path
    /// with a NUL byte, or any `..` component. Relative paths such as `meeting.json`, `notes/a.md` and `.`
    /// (the session folder itself) pass.
    public static func validate(_ relativePath: String) throws {
        let suggestion = "pass a path relative to the session folder, such as \"meeting.json\" or \"notes/a.md\""
        if relativePath.isEmpty {
            throw WidgetServiceError.notPermitted("the path is empty", suggestion: suggestion)
        }
        if relativePath.hasPrefix("/") || relativePath.hasPrefix("~") {
            throw WidgetServiceError.notPermitted("\"\(relativePath)\" is not relative to the session folder", suggestion: suggestion)
        }
        if relativePath.contains("\0") {
            throw WidgetServiceError.notPermitted("the path contains a NUL byte", suggestion: suggestion)
        }
        if relativePath.split(separator: "/", omittingEmptySubsequences: true).contains("..") {
            throw WidgetServiceError.notPermitted("\"\(relativePath)\" leaves the session folder", suggestion: suggestion)
        }
    }
}

/// Reads the session's folder (SDK 2.16.0, ABI 17). On the Mac a widget reads the folder itself; on an iPad the
/// same calls are answered by the paired Mac, so a widget never touches `FileManager` for session files.
/// All paths are relative to the session folder (see `WidgetFilePath`); read-only by design. A symbolic link that
/// points outside the session folder is refused like a `..` path (`WidgetServiceError.notPermitted`).
nonisolated public protocol WidgetFileService: Sendable {

    /// The bytes of the file at `relativePath`. Throws `WidgetServiceError` when it doesn't exist or can't be read.
    func read(_ relativePath: String) async throws -> Data

    /// The entries of the directory at `relativeDir`, sorted by name (plain byte order, the same on every device).
    /// `"."` lists the session folder itself. Entries whose name starts with `.` are omitted.
    func list(_ relativeDir: String) async throws -> [WidgetFileEntry]

    /// Yields once each time the file at `relativePath` changes, or, for a directory, when an entry is added,
    /// removed or renamed. Rapid changes coalesce into one pending yield. Finishes when the consumer stops
    /// iterating, and at once for a path that is refused. A path that doesn't exist yet yields when it appears.
    func watch(_ relativePath: String) -> AsyncStream<Void>
}

/// The default for hosts without file access (previews, tests): `read` throws a named error, `list` is empty
/// and `watch` finishes at once, so a widget shows its empty state rather than crashing.
nonisolated public struct NoopWidgetFileService: WidgetFileService {
    public init() {}

    public func read(_ relativePath: String) async throws -> Data {
        throw WidgetServiceError(
            message: "this host does not provide session files",
            suggestion: "run the widget inside Work42 2.16.0 or later, or pass a WidgetFileService when constructing the services")
    }

    public func list(_ relativeDir: String) async throws -> [WidgetFileEntry] { [] }

    public func watch(_ relativePath: String) -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}

// MARK: - Platform

/// The few things a widget does to the device it's on (SDK 2.16.0, ABI 17): open a link, copy text. They are
/// `@MainActor` because both platforms require it, and they act on THIS device (the iPad's pasteboard, not the Mac's).
nonisolated public protocol WidgetPlatformService: Sendable {

    /// Open `url` in its default app (the browser for a web address, Mail for `mailto:`).
    @MainActor func open(_ url: URL)

    /// Put `text` on the device's general pasteboard.
    @MainActor func copy(_ text: String)
}

/// The real implementation on both platforms: `NSWorkspace` / `NSPasteboard` on macOS, `UIApplication` /
/// `UIPasteboard` on iOS. It is also the default, so a widget that never customizes it works everywhere.
nonisolated public struct SystemWidgetPlatformService: WidgetPlatformService {
    public init() {}

    @MainActor public func open(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #elseif canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }

    @MainActor public func copy(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
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

    /// Calls every work42 tool in-process, as an agent would (SDK 2.8.0, ABI 13).
    public let tools: any WidgetToolService

    /// Reads the session's folder, relative to it (SDK 2.16.0, ABI 17). On an iPad the paired Mac answers.
    public let files: any WidgetFileService

    /// Opens links and copies text on the device the widget runs on (SDK 2.16.0, ABI 17).
    public let platform: any WidgetPlatformService

    /// The owning session's id (task42-plugin-conversion, s3) — needed for
    /// e.g. artifact URL derivation (`[[artifact:id]]` embeds) and
    /// self-registration. `nil` on session-less surfaces (Home).
    public let sessionId: String?

    /// The owning session's working directory — its worktree root for a
    /// real session, or the project root on the session-less Home surface
    /// (s3). `nil` only when neither is available.
    public let worktreePath: String?

    /// Who is acting now: the person at this device, or the agent whose call this is (SDK 2.14.0, ABI 16).
    public let actor: WidgetCollaborator

    /// Who is in the session and where their cursors are (SDK 2.14.0, ABI 16).
    public let collaboration: any WidgetCollaborationService

    public init(
        composer: any WidgetComposerService,
        shell: any WidgetShellService,
        intents: any WidgetIntentsService,
        storage: any WidgetStorageService,
        pill: any WidgetPillService,
        tools: any WidgetToolService = UnavailableWidgetToolService(),
        files: any WidgetFileService = NoopWidgetFileService(),
        platform: any WidgetPlatformService = SystemWidgetPlatformService(),
        sessionId: String? = nil,
        worktreePath: String? = nil,
        actor: WidgetCollaborator = .solo,
        collaboration: (any WidgetCollaborationService)? = nil
    ) {
        self.actor = actor
        self.collaboration = collaboration ?? SoloWidgetCollaborationService(actor: actor)
        self.composer = composer
        self.shell = shell
        self.intents = intents
        self.storage = storage
        self.pill = pill
        self.tools = tools
        self.files = files
        self.platform = platform
        self.sessionId = sessionId
        self.worktreePath = worktreePath
    }
}

// MARK: - Host streams

/// A stream the host pushes to a widget (SDK 2.16.0, ABI 17), the way it pushes a chat to an iPad: the stream's current
/// state first, then every change, as the bytes the host sent. The widget decodes them. It ends when the consumer stops
/// iterating. On the Mac a widget reads its own files and gets no stream (`NoopWidgetStreamService`); an iPad, which
/// cannot read the Mac's files, subscribes through the paired Mac.
nonisolated public protocol WidgetStreamService: Sendable {

    /// The state of stream `stream` of `widget` in `session`, then each update.
    func subscribe(session: String, widget: String, stream: String) -> AsyncStream<Data>
}

/// The default for hosts with no streams: it finishes at once, so the widget keeps to its own source.
nonisolated public struct NoopWidgetStreamService: WidgetStreamService {
    public init() {}

    public func subscribe(session: String, widget: String, stream: String) -> AsyncStream<Data> {
        AsyncStream { $0.finish() }
    }
}

/// Where the host registers its stream service. Set once at startup, like `WidgetAccountRegistry`, and for the same reason:
/// `SessionServices`' memory layout is part of the binary contract with plugins built against older SDKs, so this is not a
/// stored property.
@MainActor
public enum WidgetStreamRegistry {
    public static var service: (any WidgetStreamService)?
}

extension SessionServices {
    /// Stream `name` of widget `widget` in this session, or an empty stream on a host without streams. Computed, so the
    /// struct's layout is unchanged.
    @MainActor
    public func stream(_ name: String, widget: String) -> AsyncStream<Data> {
        guard let sessionId, let service = WidgetStreamRegistry.service else { return AsyncStream { $0.finish() } }
        return service.subscribe(session: sessionId, widget: widget, stream: name)
    }
}

// MARK: - Account access

/// Where the host registers its account service. Set once at startup; nil on hosts without
/// sign-in (tests, previews, SDK before 2.6.0).
///
/// It lives here rather than as a stored property of `SessionServices` because that struct's
/// memory layout is part of the binary contract with plugins built against older SDKs (see
/// `PublicLayoutStabilityTests`): adding a stored property would change its size.
@MainActor
public enum WidgetAccountRegistry {
    public static var service: (any WidgetAccountService)?
}

extension SessionServices {
    /// Who is signed in (name, email, photo URL), or nil on a host without account support.
    /// A nil `account` and a nil `currentUser()` both mean "show the fallback". Computed, so the
    /// struct's layout is unchanged.
    @MainActor
    public var account: (any WidgetAccountService)? { WidgetAccountRegistry.service }
}
