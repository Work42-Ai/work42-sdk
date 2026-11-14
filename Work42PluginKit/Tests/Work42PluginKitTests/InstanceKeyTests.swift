// InstanceKeyTests.swift — WOR-794: every browser-based widget is its own instance per session (and per device when personal).
//
// An instance owns its tabs, history, scroll and page state. Two sessions never share one, two devices never share a personal one, and
// a surface the host gave no scope to is isolated rather than sharing a bare key. Only the website data store (`dataStoreKey`) is
// shared underneath.

import Foundation
import Testing
@testable import Work42PluginKit

@Suite("Instance isolation (WOR-794)", .serialized)
@MainActor
struct InstanceKeyTests {

    private func uniqueWidget() -> String { "instance.test.\(UUID().uuidString)" }

    @Test("an instance key names its session, widget and, for a personal widget, its device")
    func cacheKeyFormat() {
        #expect(InstanceKey(sessionID: "S1", widgetID: "browser").cacheKey == "S1/browser")
        #expect(InstanceKey(sessionID: "S1", widgetID: "browser", deviceID: "d-mac").cacheKey == "S1/browser@d-mac")
        // The shared form is the key a surface in that session has always had.
        #expect(InstanceKey(sessionID: "S1", widgetID: "figma").cacheKey == BrowserSurfaceCache.scopedKey("figma", scope: "S1"))
        #expect(BrowserSurfaceCache.scopedKey(for: InstanceKey(sessionID: "S1", widgetID: "figma", deviceID: "d")) == "S1/figma@d")
    }

    @Test("keys differing in the session, the widget or the device never meet")
    func keysAreDistinct() {
        let base = InstanceKey(sessionID: "S1", widgetID: "browser", deviceID: "d1")
        #expect(base.cacheKey != InstanceKey(sessionID: "S2", widgetID: "browser", deviceID: "d1").cacheKey)
        #expect(base.cacheKey != InstanceKey(sessionID: "S1", widgetID: "files", deviceID: "d1").cacheKey)
        #expect(base.cacheKey != InstanceKey(sessionID: "S1", widgetID: "browser", deviceID: "d2").cacheKey)
        #expect(base.cacheKey != InstanceKey(sessionID: "S1", widgetID: "browser").cacheKey)
    }

    @Test("one widget in two sessions gets two models with their own tabs and history")
    func sessionsKeepSeparateTabs() {
        let widget = uniqueWidget()
        let cache = BrowserSurfaceCache.shared
        let a = InstanceKey(sessionID: "A", widgetID: widget)
        let b = InstanceKey(sessionID: "B", widgetID: widget)
        let modelA = cache.model(forKey: a.cacheKey) { BrowserWidgetModel(canEditURL: true) }
        let modelB = cache.model(forKey: b.cacheKey) { BrowserWidgetModel(canEditURL: true) }
        #expect(modelA !== modelB)
        modelA.openTab(url: URL(string: "https://a.example/one")!, title: "One")
        modelA.openTab(url: URL(string: "https://a.example/two")!, title: "Two")
        #expect(modelA.tabs.count > modelB.tabs.count)
        #expect(!modelB.tabs.contains { $0.url?.host == "a.example" })
        cache.scope = "A"; cache.teardown(key: widget)
        cache.scope = "B"; cache.teardown(key: widget)
        cache.scope = nil
    }

    @Test("a personal widget on two devices of one session is two instances")
    func devicesKeepSeparateInstances() {
        let widget = uniqueWidget()
        let cache = BrowserSurfaceCache.shared
        let mac = InstanceKey(sessionID: "S", widgetID: widget, deviceID: "yan-mac")
        let ipad = InstanceKey(sessionID: "S", widgetID: widget, deviceID: "ana-ipad")
        let onMac = cache.model(forKey: mac.cacheKey) { BrowserWidgetModel(canEditURL: true) }
        let onIPad = cache.model(forKey: ipad.cacheKey) { BrowserWidgetModel(canEditURL: true) }
        #expect(onMac !== onIPad)
        #expect(cache.existingModel(forKey: mac.cacheKey) === onMac)
        #expect(cache.existingModel(forKey: ipad.cacheKey) === onIPad)
        cache.tearDown(scopedKey: mac.cacheKey)
        #expect(cache.existingModel(forKey: mac.cacheKey) == nil)
        #expect(cache.existingModel(forKey: ipad.cacheKey) === onIPad, "tearing one instance down leaves the other")
        cache.tearDown(scopedKey: ipad.cacheKey)
    }

    @Test("a surface with no session scope is isolated: it gets a scope of its own, never a bare key and never another surface's")
    func unscopedSurfaceIsIsolated() {
        let one = BrowserSurfaceCache.effectiveScope(environment: nil, isolationID: "view-1")
        let two = BrowserSurfaceCache.effectiveScope(environment: nil, isolationID: "view-2")
        #expect(one.isolated && two.isolated)
        #expect(one.scope != two.scope)
        let keyOne = BrowserSurfaceCache.scopedKey("shared-widget", scope: one.scope)
        let keyTwo = BrowserSurfaceCache.scopedKey("shared-widget", scope: two.scope)
        #expect(keyOne != keyTwo)
        #expect(keyOne != "shared-widget")
        // An empty scope is no scope.
        #expect(BrowserSurfaceCache.effectiveScope(environment: "", isolationID: "v").isolated)
    }

    @Test("a surface the host scoped keeps the host's scope")
    func scopedSurfaceKeepsScope() {
        let resolved = BrowserSurfaceCache.effectiveScope(environment: "session-9", isolationID: "view-1")
        #expect(resolved.scope == "session-9")
        #expect(!resolved.isolated)
    }

    @Test("an isolated surface never finds the model of a scoped session")
    func isolatedNeverMeetsScoped() {
        let widget = uniqueWidget()
        let cache = BrowserSurfaceCache.shared
        let session = cache.model(forKey: BrowserSurfaceCache.scopedKey(widget, scope: "S")) { BrowserWidgetModel(canEditURL: true) }
        let isolated = BrowserSurfaceCache.effectiveScope(environment: nil, isolationID: UUID().uuidString)
        #expect(cache.existingModel(forKey: BrowserSurfaceCache.scopedKey(widget, scope: isolated.scope)) == nil)
        #expect(BrowserSurface.model(forKey: widget, scope: nil) == nil)
        #expect(BrowserSurface.model(forKey: widget, scope: "S") === session)
        cache.scope = "S"; cache.teardown(key: widget); cache.scope = nil
    }

    @Test("the website data store key is the one thing instances may share")
    func dataStoreIsShared() {
        let url = URL(string: "https://example.com")!
        let one = BrowserSurfaceSpec(url: url, dataStoreKey: "github", title: "GitHub")
        let two = BrowserSurfaceSpec(url: url, dataStoreKey: "github", title: "GitHub")
        #expect(one.dataStoreKey == two.dataStoreKey)
        // The instance keys of the two are still different when their sessions are.
        #expect(InstanceKey(sessionID: "A", widgetID: "github").cacheKey != InstanceKey(sessionID: "B", widgetID: "github").cacheKey)
    }
}
