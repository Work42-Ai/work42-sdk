// ThemeRuntime.swift — feat/theme-customization.1
//
// Process-wide active-theme snapshot, protected by NSLock for cheap, safe
// concurrent reads from any thread — including NSColor dynamic-provider
// closures that fire on every draw call.
//
// Read path: single NSLock acquisition + struct copy. No I/O, no parsing,
// no allocation beyond the copy. This is intentionally minimal so the DT
// color providers (subtask .8) can call `ThemeRuntime.current` inside
// every `NSColor(name:dynamicProvider:)` closure without adding measurable
// overhead to the draw path.
//
// Write path: called only by `ThemeController` (app-layer, subtask .4)
// after it has validated the new spec. The write also acquires the lock
// once and returns immediately.
//
// Concurrency: all public members are explicitly `nonisolated` to bypass the
// `defaultIsolation(MainActor.self)` module setting. The `_Holder` class uses
// `nonisolated(unsafe)` for its stored variable (the NSLock provides the
// actual thread-safety guarantee). ThemeSnapshot and all its constituents
// have nonisolated inits and Equatable conformances so they are safe to
// create and compare from any actor.

import Foundation

// MARK: - ThemeRuntime

/// Process-wide holder of the active `ThemeSnapshot` (theme + mode).
///
/// Reads are designed to be cheap — one `NSLock` acquisition and a struct
/// copy — because the DT dynamic-color providers will call `current` on
/// every draw pass. Writes are performed only by `ThemeController`.
public nonisolated enum ThemeRuntime {

    // Static `let` of an `@unchecked Sendable` type — the compiler allows
    // this as a `nonisolated` stored constant even with defaultIsolation.
    private static let _holder = _Holder()

    // MARK: - Public API

    /// The currently active theme snapshot.
    ///
    /// Safe to call from any thread or actor, including NSColor dynamic
    /// providers. One lock + one struct copy, no I/O.
    ///
    /// While a scope is being resolved (`withScope(_:_:)`, which a color
    /// provider sets from its view's `ThemeScopeTrait`), this is that scope's
    /// theme, so every existing read inside a provider follows the view that
    /// draws it. A scope that has no theme of its own reads the global one.
    public nonisolated static var current: ThemeSnapshot {
        if let scope = _ScopeTLS.current, let scoped = _holder.snapshot(scope: scope) { return scoped }
        return _holder.snapshot
    }

    /// Replaces the active theme snapshot.
    ///
    /// Called only by `ThemeController` after validation. One lock, no I/O.
    public nonisolated static func update(_ snapshot: ThemeSnapshot) {
        _holder.set(snapshot)
    }

    /// Monotonically increasing counter, bumped on every `update(_:)`.
    ///
    /// Lets content that BAKES resolved theme values at compose time (the
    /// markdown WebView's document CSS, web-surface shells) key its
    /// staleness check on the active theme, so a same-mode theme swap —
    /// which changes token values without changing text/appearance —
    /// still triggers a re-compose (AC9).
    public nonisolated static var generation: Int {
        if let scope = _ScopeTLS.current, let scoped = _holder.generation(scope: scope) { return scoped }
        return _holder.generation
    }

    // MARK: - Scopes (iPad: one theme per window)

    /// Sets the theme of one scope, a window's theme when one process shows several (the iPad: each window is its own account,
    /// so its own Mac, so its own theme). The global theme is not touched. A nil scope is the global theme.
    public nonisolated static func update(_ snapshot: ThemeSnapshot, scope: String?) {
        guard let scope, !scope.isEmpty else { return update(snapshot) }
        _holder.set(snapshot, scope: scope)
    }

    /// The theme of `scope`, or the global one when the scope has none (or is nil).
    public nonisolated static func current(scope: String?) -> ThemeSnapshot {
        if let scope, !scope.isEmpty, let scoped = _holder.snapshot(scope: scope) { return scoped }
        return _holder.snapshot
    }

    /// The generation of `scope`'s theme, or the global one when the scope has none (or is nil).
    public nonisolated static func generation(scope: String?) -> Int {
        if let scope, !scope.isEmpty, let scoped = _holder.generation(scope: scope) { return scoped }
        return _holder.generation
    }

    /// Runs `body` with `scope` as the scope every `current` / `generation` read resolves against, on this thread. Content that bakes
    /// the theme outside a color provider (a web document's CSS) composes inside it with its own window's scope. A nil or empty scope
    /// keeps the scope already in force, so nesting inside an outer scope never loses it.
    public nonisolated static func withScope<T>(_ scope: String?, _ body: () throws -> T) rethrows -> T {
        guard let scope, !scope.isEmpty else { return try body() }
        let previous = _ScopeTLS.current
        _ScopeTLS.set(scope)
        defer { _ScopeTLS.set(previous) }
        return try body()
    }
}

// MARK: - Thread-local scope

/// The scope being resolved on this thread. A color provider sets it for the length of one call, so it is read far more often than it
/// is written; pthread keys keep both to a few instructions (a `Thread` dictionary would allocate on the draw path).
private nonisolated enum _ScopeTLS {
    private static let key: pthread_key_t = {
        var key = pthread_key_t()
        pthread_key_create(&key) { Unmanaged<NSString>.fromOpaque($0).release() }
        return key
    }()

    static var current: String? {
        guard let raw = pthread_getspecific(key) else { return nil }
        return Unmanaged<NSString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    static func set(_ scope: String?) {
        if let old = pthread_getspecific(key) { Unmanaged<NSString>.fromOpaque(old).release() }
        pthread_setspecific(key, scope.map { Unmanaged.passRetained($0 as NSString).toOpaque() })
    }
}

// MARK: - Theme-change notification

extension Notification.Name {
    /// Posted (on the main thread) by the app's ThemeController after a new
    /// theme snapshot has been applied. Web-surface hosts that fetch their
    /// themed CSS over loopback (artifact/canvas webviews) observe this to
    /// reload, since their baked CSS doesn't re-resolve on its own (AC9).
    public static let work42ThemeDidChange =
        Notification.Name("com.work42.theme.didChange")

    /// `userInfo` key of `work42ThemeDidChange`: the scope whose theme changed (a String), absent for the global theme. A web host
    /// that shows one window's content can ignore a change that is another window's.
    public nonisolated static let work42ThemeScopeUserInfoKey = "themeScope"
}

extension Notification {
    /// Whether this `work42ThemeDidChange` concerns content in `scope`: a change of the global theme (no scope) concerns everything,
    /// a change of one scope only that scope's content.
    public nonisolated func isThemeChange(for scope: String) -> Bool {
        guard let changed = userInfo?[Notification.Name.work42ThemeScopeUserInfoKey] as? String, !changed.isEmpty else { return true }
        return changed == scope
    }
}

// MARK: - Internal lock container

/// Lock-guarded snapshot container. All members are explicitly `nonisolated`
/// to bypass the `defaultIsolation(MainActor.self)` module-wide setting.
///
/// `nonisolated(unsafe)` on the stored var is correct here: the NSLock in
/// each accessor prevents concurrent mutation, which is what `@unchecked
/// Sendable` declares we are responsible for.
private final class _Holder: @unchecked Sendable {

    private let lock = NSLock()

    // `nonisolated(unsafe)`: the stored var defaults to @MainActor due to
    // `defaultIsolation(MainActor.self)`, but we handle synchronization via
    // the NSLock in the nonisolated accessors below.
    nonisolated(unsafe) private var _snapshot: ThemeSnapshot
    nonisolated(unsafe) private var _generation: Int = 0

    nonisolated init() {
        // ThemeSnapshot.default is nonisolated, so this init body is valid
        // in a nonisolated context.
        _snapshot = .default
    }

    nonisolated var snapshot: ThemeSnapshot {
        lock.lock(); defer { lock.unlock() }
        return _snapshot
    }

    nonisolated var generation: Int {
        lock.lock(); defer { lock.unlock() }
        return _generation
    }

    nonisolated func set(_ value: ThemeSnapshot) {
        lock.lock(); defer { lock.unlock() }
        _snapshot = value
        _generation &+= 1
    }

    // Per-scope themes. Their generations come from a counter of their own, so a scoped update never changes the process-wide
    // generation (global content must not re-compose because one window's theme changed), and a scope's generation never repeats
    // a value an earlier theme of the same scope had.
    nonisolated(unsafe) private var _scoped: [String: (snapshot: ThemeSnapshot, generation: Int)] = [:]
    nonisolated(unsafe) private var _scopedGeneration: Int = 0

    nonisolated func snapshot(scope: String) -> ThemeSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return _scoped[scope]?.snapshot
    }

    nonisolated func generation(scope: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return _scoped[scope]?.generation
    }

    nonisolated func set(_ value: ThemeSnapshot, scope: String) {
        lock.lock(); defer { lock.unlock() }
        _scopedGeneration &+= 1
        _scoped[scope] = (value, _scopedGeneration)
    }
}
