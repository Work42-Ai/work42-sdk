// LoadingGate.swift - Anti-flash loading gate + shared widget loading state.
//
// Two exports:
//
//   1. `WidgetLoadingState` — the shared enum consumed by `WidgetChrome`
//      (S2) and every content-widget that declares a loading state.
//
//   2. `LoadingGate` — an `ObservableObject` that implements the
//      anti-flash timing contract (AC2):
//        • 150 ms *grace period* — if the underlying `isActive` source
//          clears before the grace window expires the indicator is
//          SUPPRESSED entirely (fast sub-150ms ops stay invisible).
//        • 300 ms *minimum show time* — once `shouldShow` flips to `true`
//          it stays true for at least 300 ms even if `isActive` goes false
//          sooner (prevents a one-frame strobe).
//
// Concurrency note: `LoadingGate` is an `ObservableObject` — route it as
// `@StateObject` (owner) / `@ObservedObject` (observer). Observe it only
// from the small indicator view, not from the parent body, so re-renders
// stay scoped to the indicator subtree (the per-frame-@State-write
// regression documented in the codebase memory is avoided this way).

import SwiftUI
import Combine

// MARK: - WidgetLoadingState

/// Shared loading state enum consumed by `WidgetChrome` (S2) and
/// content widgets (S5). `.idle` is the zero-cost default so existing
/// call sites compile and render identically with no visual change.
public enum WidgetLoadingState {
    /// No loading in progress. The widget content renders normally.
    case idle
    /// Content is loading. `label` is optional (e.g. "Loading…").
    case loading(label: String? = nil)
    /// Loading failed. `message` describes the error; `retry` is an
    /// optional action the widget chrome surfaces as a Retry button.
    case failed(message: String, retry: (() -> Void)? = nil)

    // MARK: - Helpers

    /// `true` when the state is `.loading(_)`.
    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    /// `true` when the state is `.failed(_)`.
    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    /// Extracts the loading label, if any.
    public var loadingLabel: String? {
        if case .loading(let label) = self { return label }
        return nil
    }

    /// Extracts the failure message, if any.
    public var failureMessage: String? {
        if case .failed(let message, _) = self { return message }
        return nil
    }

    /// Extracts the retry closure, if any.
    public var retryAction: (() -> Void)? {
        if case .failed(_, let retry) = self { return retry }
        return nil
    }
}

/// Manual `Equatable` conformance that ignores the non-`Equatable`
/// `retry` closure — two `.failed` states are equal when their messages
/// match, regardless of the retry action.
extension WidgetLoadingState: Equatable {
    public static func == (lhs: WidgetLoadingState, rhs: WidgetLoadingState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle):
            return true
        case (.loading(let l), .loading(let r)):
            return l == r
        case (.failed(let lm, _), .failed(let rm, _)):
            return lm == rm
        default:
            return false
        }
    }
}

// MARK: - LoadingGate

/// Anti-flash gate (AC2). Wraps a boolean `isActive` source and
/// publishes `shouldShow`, applying:
///
/// - **150 ms grace period** — suppresses the indicator for fast ops.
/// - **300 ms minimum show time** — prevents a one-frame strobe.
///
/// Typical usage inside a small indicator view:
///
///     @StateObject private var gate = LoadingGate()
///
///     var body: some View {
///         if gate.shouldShow {
///             LoadingIndicator(label: label)
///         }
///     }
///     .onChange(of: isActive) { gate.update(isActive: $0) }
///     .onAppear { gate.update(isActive: isActive) }
///
/// Important: hold this as `@StateObject` (or pass as `@ObservedObject`)
/// only in the indicator subtree — never in a large parent body — so
/// re-renders from `objectWillChange` stay scoped to the small indicator
/// view (the per-frame @State re-render regression documented in the
/// codebase is avoided this way).
public final class LoadingGate: ObservableObject {

    // MARK: - Constants

    /// Grace period before the indicator appears (ms). Fast ops that
    /// complete before this window expires are suppressed entirely.
    public static let gracePeriodSeconds: Double = 0.15

    /// Minimum time the indicator stays visible once shown (ms). Prevents
    /// a one-frame strobe when the source clears immediately after the
    /// grace period expires.
    public static let minimumShowSeconds: Double = 0.30

    // MARK: - Published state

    /// `true` when the indicator should be visible. Incorporates both
    /// the grace period and the minimum show time.
    @Published public private(set) var shouldShow: Bool = false

    // MARK: - Internal state

    private var graceTask: Task<Void, Never>?
    private var minimumTask: Task<Void, Never>?
    /// Tracks whether the source was active when the minimum-show timer
    /// was started, so we know whether to hide on timer expiry.
    private var pendingHide: Bool = false

    public init() {}

    deinit {
        graceTask?.cancel()
        minimumTask?.cancel()
    }

    // MARK: - Public API

    /// Drive the gate from a boolean `isActive` source. Call this in
    /// `.onAppear` and `.onChange(of:)` on the indicator subtree.
    public func update(isActive: Bool) {
        if isActive {
            activate()
        } else {
            deactivate()
        }
    }

    // MARK: - Private

    private func activate() {
        guard !shouldShow else { return } // already showing
        // Cancel any pending hide work from a previous fast cycle.
        pendingHide = false

        // Guard: if the grace timer is already running, do nothing.
        if graceTask != nil { return }

        graceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.gracePeriodSeconds * 1_000_000_000))
            } catch {
                return // Task was cancelled — source cleared before grace expired.
            }
            self.graceTask = nil
            self.shouldShow = true
            // Start the minimum-show timer.
            self.startMinimumTimer()
        }
    }

    private func deactivate() {
        if graceTask != nil {
            // Source cleared during grace period — cancel and suppress entirely.
            graceTask?.cancel()
            graceTask = nil
            return
        }

        if shouldShow {
            // Indicator is visible. If minimum timer is running, flag a
            // pending hide; if it already expired, hide immediately.
            if minimumTask != nil {
                pendingHide = true
            } else {
                shouldShow = false
            }
        }
    }

    private func startMinimumTimer() {
        minimumTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.minimumShowSeconds * 1_000_000_000))
            } catch {
                return
            }
            self.minimumTask = nil
            if self.pendingHide {
                self.pendingHide = false
                self.shouldShow = false
            }
        }
    }
}

// MARK: - GatedLoadingOverlay

/// A convenience view modifier that composes `LoadingGate` + `LoadingIndicator`
/// into a single overlay driven by a `Bool`. Apply it over any content:
///
///     myContent
///         .gatedLoadingOverlay(isActive: isLoading, label: "Loading…")
///
/// The overlay centres a `LoadingIndicator` inside a `ZStack` — useful
/// for widget content areas. For full widget-chrome integration see
/// `WidgetChrome` (S2).
public struct GatedLoadingOverlay: ViewModifier {
    let isActive: Bool
    let label: String?
    let tint: Color
    let size: LoadingIndicator.Size

    @StateObject private var gate = LoadingGate()

    public func body(content: Content) -> some View {
        content
            .overlay {
                if gate.shouldShow {
                    ZStack {
                        // A semi-opaque backdrop so the indicator reads
                        // on any content; using a card surface gives it
                        // the glass treatment on macOS 26.
                        Color.clear
                        LoadingIndicator(label: label, tint: tint, size: size)
                    }
                }
            }
            .onAppear { gate.update(isActive: isActive) }
            .onChange(of: isActive) { _, newValue in gate.update(isActive: newValue) }
    }
}

public extension View {
    /// Overlay a gated `LoadingIndicator` that respects the 150 ms grace
    /// period and 300 ms minimum show time (AC2). The indicator is
    /// suppressed for fast operations and never strobes.
    func gatedLoadingOverlay(
        isActive: Bool,
        label: String? = nil,
        tint: Color = DT.systemAccent,
        size: LoadingIndicator.Size = .regular
    ) -> some View {
        modifier(GatedLoadingOverlay(isActive: isActive, label: label, tint: tint, size: size))
    }
}
