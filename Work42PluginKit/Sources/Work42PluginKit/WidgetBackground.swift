// WidgetBackground.swift — opt-in background-execution SDK surface
// (bug/widgets-in-background-are-not-working.1)
//
// The capability protocols are additive. Service structs passed across the
// dylib boundary are versioned whenever their stored layout changes:
//
//   Work42WidgetBackground  — opt-in protocol; a widget conforms to declare
//                              that it can do headless work for a session.
//   WidgetBackgroundAgent   — the per-(session × widget) worker the host
//                              creates and owns; lifetime follows session
//                              liveness, not view mounting.
//   WidgetBackgroundServices — the HEADLESS service subset the agent receives.
//
// ABI safety: the capability types are SEPARATE from Work42Widget and introduce
// no new requirement into its Protocol Witness Table. The host discovers
// background capability via `as? any Work42WidgetBackground` — exactly the
// same pattern as `Work42BrowserWidgetOptions` and `Work42WidgetHeaderLabels`.
// Old dylibs without the conformance return nil from the cast and behave as
// before. `WidgetBackgroundServices` gained `activity` in SDK v11, so the
// loader rejects mismatched dylibs before constructing the service value.
//
// XPC-shaped rule: `WidgetBackgroundServices` carries only Sendable, Codable-
// compatible types — ready for the later out-of-process transport swap.
// The agent protocols are @MainActor class protocols (same as Work42Widget);
// they are always created and called on the main actor by the host.

import Foundation

// MARK: - Work42WidgetBackground

/// Opt-in: the widget can perform work for a session independently of whether
/// any view is mounted for it.
///
/// Conform with a class that also conforms to `Work42Widget`. The host
/// discovers the conformance via `as? any Work42WidgetBackground`; a widget
/// that does not conform is never asked for a background agent and its
/// existing `activate`/`deactivate` view-lifecycle path is unchanged.
///
/// ## ABI safety
///
/// This is a SEPARATE protocol — NOT a new requirement on `Work42Widget` —
/// following the `Work42BrowserWidgetOptions` / `Work42WidgetHeaderLabels`
/// pattern. The host checks conformance via a conditional cast; old dylibs
/// without the conformance return nil and behave exactly as today.
/// `WidgetSDK.abiVersion` is NOT bumped.
///
/// ## Lifecycle
///
/// The host calls `makeBackgroundAgent()` once per (session × widget) pair
/// when the session becomes eligible (foreground/background in the session
/// runtime and the widget is in the saved layout across any tab). It calls it again if the
/// widget is hot-reloaded — the old agent is stopped first.
///
/// Agents stop when the session becomes inactive, when the widget is
/// removed from the layout, on hot-reload, and on app quit.
///
/// ## Example
///
/// ```swift
/// final class MyWidget: Work42Widget, Work42WidgetBackground {
///     // ... Work42Widget requirements ...
///
///     func makeBackgroundAgent() -> any WidgetBackgroundAgent {
///         MyWidgetAgent()   // fresh instance — one per (session × widget)
///     }
/// }
/// ```
@MainActor
public protocol Work42WidgetBackground: AnyObject {

    /// Create a fresh background agent for ONE (session × widget) pair.
    ///
    /// The host calls this every time a session becomes eligible for background
    /// execution with this widget. Each call MUST return a new, independent
    /// instance — agents are never shared across sessions. Sharing state across
    /// calls (e.g. through a stored property on the widget class) defeats
    /// per-session isolation and is explicitly prohibited.
    func makeBackgroundAgent() -> any WidgetBackgroundAgent
}

// MARK: - WidgetBackgroundAgent

/// One background worker for a single (session × widget) pair.
///
/// The host creates agents via `Work42WidgetBackground.makeBackgroundAgent()`,
/// calls `start(services:)` when the session is eligible, and `stop()` when
/// the session goes dormant, the widget leaves the layout, the widget is
/// hot-reloaded, or the app quits.
///
/// ## Isolation
///
/// `@MainActor` — all calls from the host arrive on the main actor. Long-
/// running work (polling loops, shell calls) must be dispatched with `Task {}`
/// or structured concurrency; the agent MUST cancel those tasks in `stop()` to
/// prevent timer/task leaks after dormancy.
///
/// ## Header labels
///
/// `headerLabels` provides session-scoped header chips for widgets in any tab
/// of the session (not just the active one). The property MUST be backed by
/// `@Observable` storage so that mutating it during a poll cycle invalidates
/// only the header strip's render pass — no whole-grid re-render. Example:
///
/// ```swift
/// import Observation
///
/// @Observable
/// final class MyAgent: WidgetBackgroundAgent {
///     var headerLabels: [WidgetHeaderLabel] = []
///
///     private var pollTask: Task<Void, Never>?
///
///     func start(services: WidgetBackgroundServices) {
///         pollTask = Task { [weak self] in
///             while !Task.isCancelled {
///                 await self?.poll(services: services)
///                 try? await Task.sleep(for: .seconds(60))
///             }
///         }
///     }
///
///     func stop() {
///         pollTask?.cancel()
///         pollTask = nil
///     }
///
///     private func poll(services: WidgetBackgroundServices) async { ... }
/// }
/// ```
///
/// This mirrors the `@Observable`-backed pattern used by `Work42WidgetHeaderLabels`
/// on the view path — reading `headerLabels` inside the host's render pass
/// registers a dependency on the agent's observable storage, so label changes
/// trigger a targeted strip re-render without going through the widget's view.
///
/// ## Session-scoped vs. singleton
///
/// Unlike `Work42WidgetHeaderLabels` (which is a property on the widget
/// singleton and therefore shared across all sessions), `WidgetBackgroundAgent`
/// is a distinct instance per (session × widget). Each session's agent reads
/// and updates only that session's task storage — eliminating the first-mount-
/// services cross-contamination bug.
@MainActor
public protocol WidgetBackgroundAgent: AnyObject {

    /// Start background work for the session described by `services`.
    ///
    /// Called once after `makeBackgroundAgent()` returns. Spawn any `Task`s or
    /// timers here; store them so `stop()` can cancel them. `services` is bound
    /// to this specific session — its `sessionId` and `taskId` identify which
    /// task's storage and shell context the agent operates in.
    func start(services: WidgetBackgroundServices)

    /// Stop all background work immediately.
    ///
    /// Called when the session's runner goes dormant, the widget is removed
    /// from the layout, the widget is hot-reloaded (the old agent is stopped
    /// before the new one is started), or the app quits. Cancel every `Task`
    /// spawned in `start` — in-flight shell calls finish under their own
    /// timeout; results are discarded and produce no side effects after `stop`.
    func stop()

    /// Session-scoped header label chips contributed to the session header
    /// strip while this agent is running.
    ///
    /// Read live during the host's render pass. **Must be backed by
    /// `@Observable` storage** so mutating it during a poll cycle triggers
    /// a targeted header-strip re-render (not a whole-grid re-render).
    /// An empty array is always valid — no placeholder is shown while the
    /// first poll is in progress.
    ///
    /// These labels render for the widget's session regardless of which tab
    /// is active, unlike `Work42WidgetHeaderLabels` which requires the widget's
    /// tab to be the active one.
    var headerLabels: [WidgetHeaderLabel] { get }
}

// MARK: - WidgetBackgroundServices

/// Reports useful session work to the host's runtime policy. A ping refreshes
/// an already-active session's inactivity deadline; it never wakes an inactive
/// session and carries no other lifecycle authority.
nonisolated public protocol WidgetSessionActivityService: Sendable {
    func ping() async
}

nonisolated public struct NoopWidgetSessionActivityService: WidgetSessionActivityService {
    public init() {}
    public func ping() async {}
}

/// The HEADLESS subset of session services passed to a background agent.
///
/// Background agents run without a mounted view — they perform polling, emit
/// events, and update storage. Two services cover all of that:
///
/// - `shell` — run shell commands in the session's worktree.
/// - `storage` — read and write the session's task storage.
///
/// **Why no `composer` or `intents`?**
///
/// `ComposerDraftBridge`, `PendingCommentsStore`, and the palette scope
/// (`PaletteController`) are all bound to the session panel's UI lifecycle —
/// they only exist while `SessionDetailPanel` is mounted. A background agent
/// is explicitly designed to run without the panel; giving it access to
/// UI-bound services would either fail silently (no composer present) or
/// require keeping panel state alive purely for background agents, which
/// defeats the purpose of decoupling from view mounting. Composer and intents
/// access from agents is excluded from `WidgetBackgroundServices` v1 and may
/// be revisited if a safe non-UI-bound path is identified.
///
/// **XPC-shaped rule**: all fields are `Sendable`; `sessionId` and `taskId`
/// are plain `String`/`String?` so they cross any future XPC boundary unchanged.
///
/// **Fail-loud semantics** are preserved from `SessionServices`:
/// - On the Home surface (no task), storage throws `WidgetServiceError`.
/// - Shell context is the session's worktree; sessions without a worktree
///   throw `WidgetServiceError` from shell.
nonisolated public struct WidgetBackgroundServices: Sendable {

    /// Async shell runner bound to the session's worktree and environment
    /// (`WORK42_SESSION_ID` / `WORK42_SESSION_DIR` / `WORK42_TASK_ID`).
    /// Never call synchronously on the main actor — `await` from a `Task`.
    public let shell: any WidgetShellService

    /// Per-task key/value store. Readable from any namespace; writable only
    /// in the widget's own namespace (its `id`). Throws `WidgetServiceError`
    /// on the Home surface and sessions without a task.
    public let storage: any WidgetStorageService

    /// Presents/dismisses a pill-capable widget's pill view (see
    /// `Work42WidgetPill`) — lets a background agent float its own widget's
    /// pill with no view mounted (e.g. the transcript widget's auto-record
    /// agent presenting its RECORDING pill).
    public let pill: any WidgetPillService

    /// Activity heartbeat for useful headless work. Pings are ignored after
    /// the session becomes inactive.
    public let activity: any WidgetSessionActivityService

    /// The session's stable identifier — persists across dormancy/liveness
    /// cycles and is the key the host uses to route agent lifecycle events.
    public let sessionId: String

    /// The task identifier for task-bound sessions; `nil` for plain sessions
    /// and the Home surface. Provided for agents that need to form task-
    /// specific shell invocations or storage addresses from outside the
    /// service abstraction (e.g. constructing a `task42 event <taskId> …`
    /// shell call).
    public let taskId: String?

    public init(
        shell: any WidgetShellService,
        storage: any WidgetStorageService,
        pill: any WidgetPillService,
        activity: any WidgetSessionActivityService = NoopWidgetSessionActivityService(),
        sessionId: String,
        taskId: String?
    ) {
        self.shell = shell
        self.storage = storage
        self.pill = pill
        self.activity = activity
        self.sessionId = sessionId
        self.taskId = taskId
    }
}
