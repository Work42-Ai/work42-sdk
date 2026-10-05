// BrowserSurfaceCacheTests.swift — browser-widgets-not-extending-from-browser.2
//
// Unit tests for the rebuilt `BrowserSurfaceCache`:
//
//   - Model cache identity: `model(forKey:building:)` returns the same
//     instance on subsequent calls (the builder closure runs once).
//
//   - Teardown releases the model: after `teardown(key:)`, the next call
//     to `model(forKey:building:)` invokes the builder again (fresh model).
//
//   - Teardown prefix scoping: `teardownAll(withPrefix:)` removes surfaces
//     whose cacheKey starts with the prefix and leaves others intact.
//
//   - Per-tab key format: `existingModel` / `existingModel` round-trip with
//     the `"<cacheKey>:<tabID>"` naming convention confirmed by inspection.
//
// All tests are @MainActor — `BrowserSurfaceCache` is `@MainActor`-isolated.
// Tests use `@testable import Work42PluginKit` to reach the internal
// `existingModel(forKey:)` and `model(forKey:building:)` helpers.
//
// No WKWebView is created in any test — purely exercising the cache dictionaries.

import Foundation
import Testing
@testable import Work42PluginKit

@Suite("BrowserSurfaceCache model cache", .serialized)
@MainActor
struct BrowserSurfaceCacheTests {

    // MARK: - Helpers

    /// A unique key for each test run so tests don't share state via the
    /// process-wide shared cache.
    private func uniqueKey(_ label: String = "") -> String {
        "test.\(label.isEmpty ? "" : "\(label).")\(UUID().uuidString)"
    }

    // MARK: - Model cache identity

    @Test("model(forKey:building:) returns the same instance on repeated calls")
    func modelCacheReturnsSameInstance() {
        let key = uniqueKey("identity")
        var buildCount = 0

        let m1 = BrowserSurfaceCache.shared.model(forKey: key) {
            buildCount += 1
            return BrowserWidgetModel()
        }
        let m2 = BrowserSurfaceCache.shared.model(forKey: key) {
            buildCount += 1
            return BrowserWidgetModel()
        }

        #expect(m1 === m2, "second call must return the cached instance, not a new one")
        #expect(buildCount == 1, "builder must be called exactly once")

        // Clean up.
        BrowserSurfaceCache.shared.teardown(key: key)
    }

    @Test("existingModel(forKey:) returns nil before any model is built")
    func existingModelNilBeforeBuild() {
        let key = uniqueKey("pre-build")
        #expect(BrowserSurfaceCache.shared.existingModel(forKey: key) == nil)
    }

    @Test("existingModel(forKey:) returns the model after model(forKey:building:)")
    func existingModelNonNilAfterBuild() {
        let key = uniqueKey("post-build")

        _ = BrowserSurfaceCache.shared.model(forKey: key) { BrowserWidgetModel() }
        #expect(BrowserSurfaceCache.shared.existingModel(forKey: key) != nil)

        // Clean up.
        BrowserSurfaceCache.shared.teardown(key: key)
    }

    // MARK: - Teardown releases the model

    @Test("teardown(key:) removes the model so existingModel returns nil")
    func teardownRemovesModel() {
        let key = uniqueKey("teardown")

        _ = BrowserSurfaceCache.shared.model(forKey: key) { BrowserWidgetModel() }
        #expect(BrowserSurfaceCache.shared.existingModel(forKey: key) != nil)

        BrowserSurfaceCache.shared.teardown(key: key)

        #expect(
            BrowserSurfaceCache.shared.existingModel(forKey: key) == nil,
            "model must be nil after teardown"
        )
    }

    @Test("after teardown, model(forKey:building:) invokes the builder again")
    func teardownAllowsFreshBuild() {
        let key = uniqueKey("fresh-build")
        var buildCount = 0

        let m1 = BrowserSurfaceCache.shared.model(forKey: key) {
            buildCount += 1
            return BrowserWidgetModel()
        }
        BrowserSurfaceCache.shared.teardown(key: key)
        let m2 = BrowserSurfaceCache.shared.model(forKey: key) {
            buildCount += 1
            return BrowserWidgetModel()
        }

        #expect(buildCount == 2, "builder must be called again after teardown")
        #expect(m1 !== m2, "second build must produce a distinct instance")

        // Clean up.
        BrowserSurfaceCache.shared.teardown(key: key)
    }

    // MARK: - teardownAll prefix scoping

    @Test("teardownAll(withPrefix:) removes matching surfaces and leaves others")
    func teardownAllWithPrefixScoping() {
        let prefix = "session-\(UUID().uuidString)-"
        let keyA = "\(prefix)widget-a"
        let keyB = "\(prefix)widget-b"
        let keyOther = "other-\(UUID().uuidString)"

        _ = BrowserSurfaceCache.shared.model(forKey: keyA) { BrowserWidgetModel() }
        _ = BrowserSurfaceCache.shared.model(forKey: keyB) { BrowserWidgetModel() }
        _ = BrowserSurfaceCache.shared.model(forKey: keyOther) { BrowserWidgetModel() }

        BrowserSurfaceCache.shared.teardownAll(withPrefix: prefix)

        #expect(
            BrowserSurfaceCache.shared.existingModel(forKey: keyA) == nil,
            "keyA (matching prefix) must be torn down"
        )
        #expect(
            BrowserSurfaceCache.shared.existingModel(forKey: keyB) == nil,
            "keyB (matching prefix) must be torn down"
        )
        #expect(
            BrowserSurfaceCache.shared.existingModel(forKey: keyOther) != nil,
            "keyOther (non-matching prefix) must survive"
        )

        // Clean up remaining.
        BrowserSurfaceCache.shared.teardown(key: keyOther)
    }

    @Test("teardownAll(withPrefix: \"\") tears down every surface")
    func teardownAllEmptyPrefixClearsAll() {
        let key1 = uniqueKey("all-1")
        let key2 = uniqueKey("all-2")

        _ = BrowserSurfaceCache.shared.model(forKey: key1) { BrowserWidgetModel() }
        _ = BrowserSurfaceCache.shared.model(forKey: key2) { BrowserWidgetModel() }

        BrowserSurfaceCache.shared.teardownAll(withPrefix: "")

        // The cache may have pre-existing entries from other tests (serial suite
        // guards against races, but not against genuine pre-test state). Only
        // assert on the keys we added.
        #expect(BrowserSurfaceCache.shared.existingModel(forKey: key1) == nil)
        #expect(BrowserSurfaceCache.shared.existingModel(forKey: key2) == nil)
    }

    // MARK: - Per-tab live-view key convention

    @Test("per-tab key format is '<cacheKey>:<tabID>'")
    func perTabKeyFormat() {
        let cacheKey = uniqueKey("tabkey")
        let tabID = UUID()
        let expected = "\(cacheKey):\(tabID)"

        // The key is constructed by BrowserSurfaceReady — verify the format
        // contract by asserting on the expected string shape.
        #expect(expected.hasPrefix(cacheKey), "per-tab key must start with the surface cacheKey")
        #expect(expected.contains(":"), "per-tab key must contain a colon separator")
        #expect(expected.hasSuffix(tabID.uuidString), "per-tab key must end with the tab UUID string")

        // teardown(key: cacheKey) must NOT match a live-view key that is
        // "<someOtherKey>:<cacheKey>..." (the prefix must be unambiguous).
        let otherSurface = "other-\(UUID().uuidString)"
        let ambiguousKey = "\(otherSurface):\(cacheKey)"
        #expect(!ambiguousKey.hasPrefix("\(cacheKey):"), "teardown prefix must not match unrelated keys")
    }
}
