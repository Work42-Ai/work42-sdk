// BrowserSurfaceOpeningTests.swift — WOR-400.
//
// A surface whose URL provider does not answer used to show a bare spinner for ever. It now says it could not
// open after `BrowserSurface.openingTimeout`, offers Retry, and an answer that arrives after a Retry has started
// a newer attempt is dropped. Driven through `BrowserSurface.resolve` with a short timeout and providers the
// test controls; no WebKit needed.

import Foundation
import Testing
@testable import Work42PluginKit
@testable import Work42UI

@Suite("BrowserSurface opening: timeout, Retry and late answers (WOR-400)", .serialized)
@MainActor
struct BrowserSurfaceOpeningTests {

    private let urlA = URL(string: "https://a.example.com/pr/1")!
    private let urlB = URL(string: "https://b.example.com/pr/2")!

    /// A provider answer the test releases by hand.
    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<URL, Never>?
        func wait() async -> URL { await withCheckedContinuation { continuation = $0 } }
        func open(_ url: URL) { continuation?.resume(returning: url); continuation = nil }
        var isWaiting: Bool { continuation != nil }
    }

    @MainActor
    private final class Counter {
        var calls = 0
    }

    private struct Boom: LocalizedError { var errorDescription: String? { "boom" } }

    private func spec(_ source: BrowserSurfaceSpec.Source) -> BrowserSurfaceSpec {
        BrowserSurfaceSpec(source: source, dataStoreKey: "w42-opening-tests", title: "Board")
    }

    private func newKey() -> String { "opening-\(UUID().uuidString)" }

    private func wait(_ seconds: TimeInterval = 5, until condition: () -> Bool) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func isTimedOut(_ state: BrowserSurfaceState) -> Bool {
        if case .timedOut = state.resolution { true } else { false }
    }

    private func isReady(_ state: BrowserSurfaceState) -> Bool {
        if case .ready = state.resolution { true } else { false }
    }

    private func resolve(
        _ spec: BrowserSurfaceSpec, key: String, state: BrowserSurfaceState, timeout: Duration = .milliseconds(80)
    ) async {
        await BrowserSurface.resolve(spec: spec, cacheKey: key, state: state, configure: nil, timeout: timeout)
    }

    // MARK: Timeout

    @Test("no answer within the timeout: the timed-out state, and no model or tab has been made (AC23)")
    func timesOut() async throws {
        let key = newKey(), state = BrowserSurfaceState(), gate = Gate()
        defer { BrowserSurfaceCache.shared.teardown(key: key) }
        let attempt = Task { await resolve(spec(.provider { await gate.wait() }), key: key, state: state) }

        #expect(await wait { isTimedOut(state) })
        #expect(BrowserSurface.model(forKey: key) == nil)

        gate.open(urlA)
        await attempt.value
    }

    @Test("the default timeout is 10 seconds and the message tells the user to try again")
    func defaults() {
        #expect(BrowserSurface.openingTimeout == .seconds(10))
        #expect(BrowserSurface.timedOutMessage.contains("Try again"))
    }

    @Test("an answer that comes in time never shows the timed-out state")
    func answersInTime() async throws {
        let key = newKey(), state = BrowserSurfaceState()
        defer { BrowserSurfaceCache.shared.teardown(key: key) }
        await resolve(spec(.provider { [urlA] in urlA }), key: key, state: state)
        #expect(isReady(state))
        try await Task.sleep(for: .milliseconds(250))          // well past the deadline
        #expect(isReady(state))
        #expect(BrowserSurface.model(forKey: key)?.tabs.first?.url == urlA)
    }

    @Test("a static URL needs no provider and opens at once")
    func staticURL() async {
        let key = newKey(), state = BrowserSurfaceState()
        defer { BrowserSurfaceCache.shared.teardown(key: key) }
        await resolve(spec(.url(urlA)), key: key, state: state)
        #expect(isReady(state))
        #expect(BrowserSurface.model(forKey: key)?.tabs.count == 1)
    }

    @Test("a provider that throws fails loud with its message")
    func failsLoud() async {
        let key = newKey(), state = BrowserSurfaceState()
        await resolve(spec(.provider { throw Boom() }), key: key, state: state)
        guard case .failed(let message) = state.resolution else { Issue.record("expected failed"); return }
        #expect(message == "boom")
        #expect(BrowserSurface.model(forKey: key) == nil)
    }

    // MARK: Retry and late answers

    @Test("an answer that arrives after the timeout, with no Retry, still opens the surface")
    func lateAnswerWithoutRetry() async throws {
        let key = newKey(), state = BrowserSurfaceState(), gate = Gate()
        defer { BrowserSurfaceCache.shared.teardown(key: key) }
        let attempt = Task { await resolve(spec(.provider { await gate.wait() }), key: key, state: state) }
        #expect(await wait { isTimedOut(state) })

        gate.open(urlA)
        await attempt.value
        #expect(isReady(state))
        #expect(BrowserSurface.model(forKey: key)?.tabs.first?.url == urlA)
    }

    @Test("Retry re-resolves: the timed-out surface opens with the new answer")
    func retryReResolves() async throws {
        let key = newKey(), state = BrowserSurfaceState(), gate = Gate(), counter = Counter()
        defer { BrowserSurfaceCache.shared.teardown(key: key) }
        let source = BrowserSurfaceSpec.Source.provider { [urlB] in
            let call = await MainActor.run { counter.calls += 1; return counter.calls }
            return call == 1 ? await gate.wait() : urlB
        }
        let first = Task { await resolve(spec(source), key: key, state: state) }
        #expect(await wait { isTimedOut(state) })

        state.retryNonce += 1                                   // the Retry button
        await resolve(spec(source), key: key, state: state)
        #expect(isReady(state))
        #expect(counter.calls == 2)
        #expect(state.generation == 2)
        #expect(BrowserSurface.model(forKey: key)?.tabs.first?.url == urlB)

        gate.open(urlA)
        await first.value
    }

    @Test("a provider that answers after Retry does not override it (AC23)")
    func lateAnswerAfterRetryIsIgnored() async throws {
        let key = newKey(), state = BrowserSurfaceState(), gate = Gate(), counter = Counter()
        defer { BrowserSurfaceCache.shared.teardown(key: key) }
        let source = BrowserSurfaceSpec.Source.provider { [urlB] in
            let call = await MainActor.run { counter.calls += 1; return counter.calls }
            return call == 1 ? await gate.wait() : urlB
        }
        let first = Task { await resolve(spec(source), key: key, state: state) }
        #expect(await wait { isTimedOut(state) })
        await resolve(spec(source), key: key, state: state)     // Retry, answered at once with B
        #expect(BrowserSurface.model(forKey: key)?.tabs.first?.url == urlB)

        gate.open(urlA)                                          // the first attempt answers last, with A
        await first.value

        #expect(isReady(state))
        #expect(BrowserSurface.model(forKey: key)?.tabs.count == 1)
        #expect(BrowserSurface.model(forKey: key)?.tabs.first?.url == urlB)
    }

    @Test("a throw from an attempt that Retry replaced does not turn the surface into an error")
    func staleFailureIsIgnored() async throws {
        let key = newKey(), state = BrowserSurfaceState(), counter = Counter()
        defer { BrowserSurfaceCache.shared.teardown(key: key) }
        let gate = Gate()
        let source = BrowserSurfaceSpec.Source.provider { [urlB] in
            let call = await MainActor.run { counter.calls += 1; return counter.calls }
            if call == 1 { _ = await gate.wait(); throw Boom() }
            return urlB
        }
        let first = Task { await resolve(spec(source), key: key, state: state) }
        #expect(await wait { isTimedOut(state) })
        await resolve(spec(source), key: key, state: state)

        gate.open(urlA)
        await first.value
        #expect(isReady(state))
    }

    // MARK: A model with no tab

    @Test("a cached model with no tab is seeded again, which is what Retry does for it")
    func emptyModelIsSeeded() async {
        let key = newKey(), state = BrowserSurfaceState()
        defer { BrowserSurfaceCache.shared.teardown(key: key) }
        let model = BrowserSurfaceCache.shared.model(forKey: key) {
            BrowserWidgetModel(canEditURL: true, presetSelector: "", initialURL: urlA)
        }
        #expect(model.tabs.isEmpty)

        await resolve(spec(.url(urlA)), key: key, state: state)

        #expect(isReady(state))
        #expect(BrowserSurface.model(forKey: key)?.tabs.count == 1)
    }

    @Test("a cached model that has its tab is not resolved again")
    func cachedModelShortCircuits() async {
        let key = newKey(), state = BrowserSurfaceState(), counter = Counter()
        defer { BrowserSurfaceCache.shared.teardown(key: key) }
        await resolve(spec(.url(urlA)), key: key, state: state)
        #expect(isReady(state))

        let again = BrowserSurfaceState()
        await resolve(spec(.provider { [urlB] in await MainActor.run { counter.calls += 1 }; return urlB }), key: key, state: again)
        #expect(isReady(again))
        #expect(counter.calls == 0)
        #expect(again.generation == 0)
    }
}
