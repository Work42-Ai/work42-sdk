// BrowserSurfaceHeadlessTests.swift — WOR-644.
//
// A browser-backed widget declares its surface, and the host builds the model from the declaration while a device watches, with no
// view on the Mac. `BrowserSurface.resolveHeadless` seeds the same scoped cache entry a mounted surface uses, so a view that mounts
// later reuses it, and `releaseHeadless` lets go of a model the host built unless a view is showing it. No WebKit needed.

import Foundation
import Testing
@testable import Work42PluginKit
@testable import Work42UI

@Suite("BrowserSurface headless resolution (WOR-644)", .serialized)
@MainActor
struct BrowserSurfaceHeadlessTests {

    private let url = URL(string: "https://board.example.com/pr/1")!

    @MainActor
    private final class Counter {
        var providerRuns = 0
        var configured = 0
    }

    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<URL, Never>?
        func wait() async -> URL { await withCheckedContinuation { continuation = $0 } }
        func open(_ url: URL) { continuation?.resume(returning: url); continuation = nil }
        var isWaiting: Bool { continuation != nil }
    }

    private struct Boom: LocalizedError { var errorDescription: String? { "boom" } }

    private func newKey() -> String { "headless-\(UUID().uuidString)" }

    private func declaration(
        key: String, counter: Counter, source: BrowserSurfaceSpec.Source? = nil
    ) -> BrowserSurfaceDeclaration {
        let target = url
        let spec = BrowserSurfaceSpec(
            source: source ?? .provider { await MainActor.run { counter.providerRuns += 1 }; return target },
            dataStoreKey: "w42-headless-tests", title: "Board")
        return BrowserSurfaceDeclaration(spec: spec, cacheKey: key, configure: { _ in counter.configured += 1 })
    }

    private func wait(_ seconds: TimeInterval = 5, until condition: () -> Bool) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test("resolving headless builds the model, seeds the scoped cache and calls configure once")
    func seedsTheCache() async throws {
        let key = newKey(), counter = Counter()
        let scoped = BrowserSurfaceCache.scopedKey(key, scope: "s1")
        defer { BrowserSurfaceCache.shared.tearDown(scopedKey: scoped) }

        let model = await BrowserSurface.resolveHeadless(declaration(key: key, counter: counter), scope: "s1")
        let built = try #require(model)
        #expect(built.tabs.count == 1 && built.tabs.first?.url == url)
        #expect(BrowserSurface.model(forKey: key, scope: "s1") === built, "the same entry a mounted surface would read")
        #expect(BrowserSurface.model(forKey: key, scope: "s2") == nil, "another session's is untouched")
        #expect(counter.providerRuns == 1 && counter.configured == 1)
    }

    @Test("a cached model is returned at once and the provider does not run again")
    func cacheHitSkipsTheProvider() async throws {
        let key = newKey(), counter = Counter()
        defer { BrowserSurfaceCache.shared.tearDown(scopedKey: BrowserSurfaceCache.scopedKey(key, scope: "s1")) }
        let first = await BrowserSurface.resolveHeadless(declaration(key: key, counter: counter), scope: "s1")
        let second = await BrowserSurface.resolveHeadless(declaration(key: key, counter: counter), scope: "s1")
        #expect(first != nil && first === second)
        #expect(counter.providerRuns == 1 && counter.configured == 1)
    }

    @Test("two readers asking at once share one provider run")
    func concurrentReadersShareARun() async throws {
        let key = newKey(), counter = Counter(), gate = Gate()
        let scoped = BrowserSurfaceCache.scopedKey(key, scope: "s1")
        defer { BrowserSurfaceCache.shared.tearDown(scopedKey: scoped) }
        let target = url
        let declared = BrowserSurfaceDeclaration(
            spec: BrowserSurfaceSpec(
                source: .provider { await MainActor.run { counter.providerRuns += 1 }; return await gate.wait() },
                dataStoreKey: "w42-headless-tests", title: "Board"),
            cacheKey: key)
        async let one = BrowserSurface.resolveHeadless(declared, scope: "s1", timeout: .seconds(5))
        async let two = BrowserSurface.resolveHeadless(declared, scope: "s1", timeout: .seconds(5))
        #expect(await wait { gate.isWaiting })
        gate.open(target)
        let (a, b) = await (one, two)
        #expect(a != nil && a === b)
        #expect(counter.providerRuns == 1)
    }

    @Test("a provider that fails leaves no model, and says nothing was built")
    func failureBuildsNothing() async {
        let key = newKey(), counter = Counter()
        let scoped = BrowserSurfaceCache.scopedKey(key, scope: "s1")
        defer { BrowserSurfaceCache.shared.tearDown(scopedKey: scoped) }
        let declared = BrowserSurfaceDeclaration(
            spec: BrowserSurfaceSpec(
                source: .provider { await MainActor.run { counter.providerRuns += 1 }; throw Boom() },
                dataStoreKey: "w42-headless-tests", title: "Board"),
            cacheKey: key)
        let model = await BrowserSurface.resolveHeadless(declared, scope: "s1", timeout: .milliseconds(200))
        #expect(model == nil)
        #expect(BrowserSurface.model(forKey: key, scope: "s1") == nil)
    }

    @Test("a provider that does not answer in time returns nil, and its late answer still lands in the cache")
    func lateAnswerLands() async throws {
        let key = newKey(), counter = Counter(), gate = Gate()
        let scoped = BrowserSurfaceCache.scopedKey(key, scope: "s1")
        defer { BrowserSurfaceCache.shared.tearDown(scopedKey: scoped) }
        let target = url
        let declared = BrowserSurfaceDeclaration(
            spec: BrowserSurfaceSpec(
                source: .provider { await gate.wait() }, dataStoreKey: "w42-headless-tests", title: "Board"),
            cacheKey: key)
        let model = await BrowserSurface.resolveHeadless(declared, scope: "s1", timeout: .milliseconds(80))
        #expect(model == nil)
        gate.open(target)
        #expect(await wait { BrowserSurface.model(forKey: key, scope: "s1")?.tabs.isEmpty == false })
    }

    @Test("releasing lets go of a model the host built, unless a view is showing it")
    func releaseKeepsAMountedModel() async throws {
        let key = newKey(), counter = Counter()
        let scoped = BrowserSurfaceCache.scopedKey(key, scope: "s1")
        defer { BrowserSurfaceCache.shared.tearDown(scopedKey: scoped) }
        _ = await BrowserSurface.resolveHeadless(declaration(key: key, counter: counter), scope: "s1")

        // A view is showing it: the host's release keeps it.
        BrowserSurfaceCache.shared.mounted(scoped)
        BrowserSurface.releaseHeadless(cacheKey: key, scope: "s1")
        #expect(BrowserSurface.model(forKey: key, scope: "s1") != nil)

        // The view leaves: now the release drops it.
        BrowserSurfaceCache.shared.unmounted(scoped)
        BrowserSurface.releaseHeadless(cacheKey: key, scope: "s1")
        #expect(BrowserSurface.model(forKey: key, scope: "s1") == nil)
    }

    @Test("a model a widget's own lifecycle built is not the host's to release")
    func releaseLeavesWidgetOwnedModels() async throws {
        let key = newKey(), counter = Counter()
        let scoped = BrowserSurfaceCache.scopedKey(key, scope: "s1")
        defer { BrowserSurfaceCache.shared.tearDown(scopedKey: scoped) }
        // Built the way a mounted surface builds it.
        await BrowserSurface.resolve(
            spec: declaration(key: key, counter: counter).spec, cacheKey: scoped, state: BrowserSurfaceState(),
            configure: nil, timeout: .seconds(5))
        BrowserSurface.releaseHeadless(cacheKey: key, scope: "s1")
        #expect(BrowserSurface.model(forKey: key, scope: "s1") != nil)
    }

    @Test("a surface made from a declaration is the one made from its parts")
    func declarationInitForwards() {
        let counter = Counter()
        let declared = declaration(key: "k", counter: counter)
        let surface = BrowserSurface(declared)
        #expect(surface.cacheKey == "k")
        #expect(surface.spec.dataStoreKey == declared.spec.dataStoreKey)
        #expect(surface.configure != nil)
    }
}
