// WebSectionNavigationState.swift — who owns the page load right now, and what to do when it goes wrong (WOR-111).
//
// WebKit delivers navigation callbacks for superseded navigations too: A is cancelled *after* B has started, A
// finishes late, a stale paint message arrives. This value type is the one place that decides which callbacks
// belong to the active navigation. It holds no timers and no WebKit objects beyond opaque navigation tokens, so the
// coordinator and live view drive it and tests can drive it directly with a fake clock.
//
// Vocabulary:
//   * generation — bumps every time a new top-level navigation becomes the current one (a load/retry intent, a
//                  page-originated request, a recovery). Scheduled work captures it and is dropped if it changed.
//   * token      — the `WKNavigation` of the active navigation (any object in tests); callbacks carrying another
//                  token are stale.
//   * intended   — the latest top-level request the user or page asked for. It is what Retry loads when WebKit has
//                  nothing committed (first load failed) and what automatic recovery reloads.

import Foundation

struct WebSectionNavigationState {

    /// How long a navigation may stay incomplete before the stall notice is offered.
    static let stallInterval: TimeInterval = 30
    /// Automatic recoveries allowed per incident chain (until a navigation succeeds).
    static let maxAutomaticRecoveries = 1

    enum Phase: Equatable {
        case idle
        case loading
        case finished
        case failed(String)
    }

    /// What a failure callback means for the visible state.
    enum FailureOutcome: Equatable {
        /// A superseded navigation: no state change at all.
        case ignored
        /// The active navigation was cancelled (Stop, or WebKit replacing it): not an error.
        case cancelled
        case failed(String)
    }

    /// What the host should do after a content-process termination.
    enum RecoveryAction {
        /// Reload; the budget was spent.
        case reload(URLRequest)
        /// Out of budget, or nothing safe to reload: show Retry.
        case manual
    }

    /// What Retry/Refresh should ask WebKit to do.
    enum RetryAction {
        /// A committed healthy page: `WKWebView.reload()`.
        case reload
        /// Nothing committed (or reload cannot proceed): load this safe request.
        case load(URLRequest)
        case none
    }

    private(set) var generation = 0
    private(set) var phase: Phase = .idle
    private(set) var intended: URLRequest?
    private(set) var committedURL: URL?
    private(set) var stallDeadline: Date?
    private(set) var isStalled = false
    private(set) var automaticRecoveriesUsed = 0
    /// The last GET-style address that is safe to load again without side effects.
    private(set) var lastSafeURL: URL?

    private var activeToken: AnyObject?

    // MARK: Intent

    /// A load the host (or page) asked for. Becomes the current navigation immediately; the matching WebKit
    /// navigation attaches when it reports `didStart`. Returns the new generation.
    @discardableResult
    mutating func beginIntent(_ request: URLRequest, now: Date) -> Int {
        generation += 1
        activeToken = nil
        intended = request
        if Self.isSafe(request), let url = request.url { lastSafeURL = url }
        committedURL = nil
        phase = .loading
        isStalled = false
        stallDeadline = now.addingTimeInterval(Self.stallInterval)
        return generation
    }

    /// A top-level request WebKit is about to make that we did not start (a link click, a form post, a script
    /// redirect). Recorded as the intent without disturbing a newer one: it only replaces the intent when it is not
    /// the request already tracked.
    mutating func recordPageRequest(_ request: URLRequest, now: Date) {
        guard request.url != nil else { return }
        if let current = intended, current.url == request.url, current.httpMethod == request.httpMethod { return }
        if phase == .loading {
            // A redirect or a request racing the one in flight: update what Retry would load, keep the
            // navigation (and its token) that WebKit is actually running.
            intended = request
            if Self.isSafe(request), let url = request.url { lastSafeURL = url }
            return
        }
        beginIntent(request, now: now)
    }

    // MARK: WebKit callbacks

    /// A provisional navigation started. It attaches to a pending intent; any other start (a reload, a history
    /// move, a script redirect, or a navigation replacing the active one) opens a new generation and owns the view.
    mutating func didStart(token: AnyObject, now: Date) {
        if !(phase == .loading && activeToken == nil) {
            generation += 1
            stallDeadline = now.addingTimeInterval(Self.stallInterval)
        }
        activeToken = token
        phase = .loading
        isStalled = false
    }

    @discardableResult
    mutating func didCommit(token: AnyObject, url: URL?) -> Bool {
        guard isActive(token) else { return false }
        committedURL = url
        return true
    }

    /// Returns false for a stale finish (it must not touch status, paint or the watchdog).
    @discardableResult
    mutating func didFinish(token: AnyObject, url: URL?) -> Bool {
        guard isActive(token) else { return false }
        phase = .finished
        committedURL = url ?? committedURL
        if let url = committedURL, intended.map(Self.isSafe) ?? true { lastSafeURL = url }
        stallDeadline = nil
        isStalled = false
        // A page that loaded ends the incident chain.
        automaticRecoveriesUsed = 0
        return true
    }

    mutating func didFail(token: AnyObject, error: Error) -> FailureOutcome {
        guard isActive(token) else { return .ignored }
        stallDeadline = nil
        isStalled = false
        if Self.isCancellation(error) {
            phase = .idle
            return .cancelled
        }
        let message = error.localizedDescription
        phase = .failed(message)
        return .failed(message)
    }

    /// A same-document change (pushState, fragment) moved the committed address without a new navigation.
    mutating func sameDocumentURLChanged(_ url: URL) {
        guard phase == .finished || phase == .idle else { return }
        committedURL = url
        lastSafeURL = url
    }

    // MARK: Watchdog

    /// Whether the stall deadline has passed for the navigation `generation` was captured from.
    /// Returns true exactly when the notice should now be shown.
    mutating func stallTimerFired(generation fired: Int, now: Date) -> Bool {
        guard fired == generation, phase == .loading, let deadline = stallDeadline, now >= deadline else { return false }
        isStalled = true
        return true
    }

    /// "Keep waiting": hide the notice and re-arm another interval without restarting the request.
    mutating func keepWaiting(now: Date) {
        guard phase == .loading else { return }
        isStalled = false
        stallDeadline = now.addingTimeInterval(Self.stallInterval)
    }

    // MARK: Stop and recovery

    /// The user stopped the load. Later callbacks of that navigation are stale; nothing is shown as an error.
    mutating func stop() {
        guard phase == .loading else { return }
        generation += 1
        activeToken = nil
        phase = .idle
        stallDeadline = nil
        isStalled = false
    }

    /// The web content process died. At most one automatic reload per incident chain, and only of a safe request.
    mutating func processTerminated(now: Date) -> RecoveryAction {
        stallDeadline = nil
        isStalled = false
        guard automaticRecoveriesUsed < Self.maxAutomaticRecoveries,
              let url = recoveryURL else {
            generation += 1
            activeToken = nil
            phase = .failed("The page stopped responding.")
            return .manual
        }
        automaticRecoveriesUsed += 1
        var request = URLRequest(url: url)
        request.cachePolicy = .useProtocolCachePolicy
        beginIntent(request, now: now)
        return .reload(request)
    }

    // MARK: Idle reconciliation

    /// WebKit went idle while a navigation is still marked in flight: a delegate callback was lost (a view whose
    /// delegates were detached, a start that never came). Ends the navigation as finished when the view shows a
    /// page, failed when it shows nothing, and returns the resulting phase. A phase that is not loading is left
    /// alone and returned as it is.
    mutating func reconcileIdle(url: URL?) -> Phase {
        guard phase == .loading else { return phase }
        activeToken = nil
        stallDeadline = nil
        isStalled = false
        if let url {
            committedURL = url
            lastSafeURL = url
            phase = .finished
        } else {
            phase = .failed("The page didn't load.")
        }
        return phase
    }

    // MARK: Retry

    /// What Retry/Refresh does now. A committed healthy page reloads; otherwise the safe intended address loads
    /// again. An unsafe intent (a POST) is never replayed: the last safe address loads instead.
    func retryAction() -> RetryAction {
        if committedURL != nil, phase == .finished || phase == .idle { return .reload }
        if let url = recoveryURL { return .load(URLRequest(url: url)) }
        return .none
    }

    /// The address a recovery may load: the safe intended request, else the last safe address.
    private var recoveryURL: URL? {
        if let intended, Self.isSafe(intended), let url = intended.url { return url }
        return lastSafeURL
    }

    // MARK: Helpers

    func isActive(_ token: AnyObject) -> Bool { activeToken === token }

    static func isSafe(_ request: URLRequest) -> Bool {
        let method = (request.httpMethod ?? "GET").uppercased()
        return (method == "GET" || method == "HEAD") && request.httpBody == nil && request.httpBodyStream == nil
    }

    static func isCancellation(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
            // WebKit "Frame load interrupted" (policy change / replaced navigation).
            || ns.domain == "WebKitErrorDomain" && ns.code == 102
    }
}
