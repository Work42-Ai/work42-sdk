// BrowserSurfaceScopeTests.swift — linear42 s28 (AC66).
//
// One plugin widget shown in two sessions must not share a web page: `BrowserSurface` prefixes its cache
// keys with the widget's session scope (`widgetCacheScope`), and the host sets `BrowserSurfaceCache.scope`
// around a widget instance's `activate`/`deactivate` so the widget's own `teardown(key: id)` reaches only
// its session's entries.

import Foundation
import SwiftUI
import Testing
@testable import Work42PluginKit

@Suite("BrowserSurface session scope (AC66)", .serialized)
@MainActor
struct BrowserSurfaceScopeTests {

    private func uniqueKey() -> String { "scope.test.\(UUID().uuidString)" }

    @Test("a scoped key is '<scope>/<key>' and an absent scope leaves the key alone")
    func scopedKeyFormat() {
        #expect(BrowserSurfaceCache.scopedKey("linear-spec", scope: "S1") == "S1/linear-spec")
        #expect(BrowserSurfaceCache.scopedKey("linear-spec", scope: nil) == "linear-spec")
    }

    @Test("two scopes keep separate models for the same cacheKey")
    func separateModelsPerScope() {
        let key = uniqueKey()
        let cache = BrowserSurfaceCache.shared
        let a = cache.model(forKey: BrowserSurfaceCache.scopedKey(key, scope: "A")) { BrowserWidgetModel(canEditURL: true) }
        let b = cache.model(forKey: BrowserSurfaceCache.scopedKey(key, scope: "B")) { BrowserWidgetModel(canEditURL: true) }
        #expect(a !== b)
        #expect(BrowserSurface.model(forKey: key, scope: "A") === a)
        #expect(BrowserSurface.model(forKey: key, scope: "B") === b)
        #expect(BrowserSurface.model(forKey: key) == nil)
        cache.scope = "A"; cache.teardown(key: key)
        cache.scope = "B"; cache.teardown(key: key)
        cache.scope = nil
    }

    @Test("teardown with a scope set reaches only that scope's entries")
    func teardownIsScoped() {
        let key = uniqueKey()
        let cache = BrowserSurfaceCache.shared
        _ = cache.model(forKey: BrowserSurfaceCache.scopedKey(key, scope: "A")) { BrowserWidgetModel(canEditURL: true) }
        _ = cache.model(forKey: BrowserSurfaceCache.scopedKey(key, scope: "B")) { BrowserWidgetModel(canEditURL: true) }
        cache.scope = "A"
        cache.teardown(key: key)
        cache.scope = nil
        #expect(BrowserSurface.model(forKey: key, scope: "A") == nil)
        #expect(BrowserSurface.model(forKey: key, scope: "B") != nil)
        cache.scope = "B"; cache.teardown(key: key); cache.scope = nil
    }

    @Test("teardown with no scope keeps its old meaning")
    func unscopedTeardownUnchanged() {
        let key = uniqueKey()
        let cache = BrowserSurfaceCache.shared
        _ = cache.model(forKey: key) { BrowserWidgetModel(canEditURL: true) }
        cache.teardown(key: key)
        #expect(BrowserSurface.model(forKey: key) == nil)
    }

    @Test("the cache scope environment value defaults to nil and round-trips")
    func environmentValue() {
        #expect(EnvironmentValues().widgetCacheScope == nil)
        var environment = EnvironmentValues()
        environment.widgetCacheScope = "S1"
        #expect(environment.widgetCacheScope == "S1")
    }
}
