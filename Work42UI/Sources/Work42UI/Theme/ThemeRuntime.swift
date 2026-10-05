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
    public nonisolated static var current: ThemeSnapshot {
        _holder.snapshot
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
        _holder.generation
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
}
