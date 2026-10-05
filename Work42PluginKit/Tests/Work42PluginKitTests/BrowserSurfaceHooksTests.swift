// BrowserSurfaceHooksTests.swift — browser-widgets-not-extending-from-browser.3
//
// Unit tests for the browser hook API added in subtask .3 (AC3 + AC5):
//
//   - `BrowserSurface.model(forKey:)` — returns nil before a model is cached,
//     non-nil after.
//
//   - `BrowserSurface.wireHooks(on:cacheKey:configure:)` — configure: closure
//     is called exactly once per wireHooks call (the "exactly once per mount"
//     invariant is enforced by `BrowserSurfaceState.configureInvoked` in the
//     view layer; wireHooks itself always calls configure, enabling direct
//     testing here without requiring a running SwiftUI view).
//
//   - Default `onNewTab` wiring — opens an empty tab.
//
//   - `onTabClosed` composition:
//       1. Cache-release fires first (`BrowserSurfaceCache` drops the live-view
//          slot for the closed tab).
//       2. Widget's handler (set by configure:) fires second.
//
//   - Empty-tab URL pinning — `model.navigateToDraft()` on an empty-URL tab
//     pins the resolved URL onto the tab via `updateTab`.
//
// All tests are @MainActor — `BrowserSurfaceCache`, `BrowserWidgetModel`, and
// `BrowserSurface.wireHooks` are all @MainActor-isolated.
//
// No WKWebView is created in any test (the live-view cache tests only check
// that the cache slot is released, not that a real webview exists). Only one
// test (`onTabClosedReleasesLiveView`) calls `BrowserSurfaceCache.liveView`
// which builds a real WebSectionLiveView and therefore a real WKWebView —
// annotated accordingly.

import Foundation
import Testing
@testable import Work42PluginKit

// MARK: - BrowserSurface.model(forKey:) Tests

@Suite("BrowserSurface.model(forKey:)", .serialized)
@MainActor
struct BrowserSurfaceModelAccessorTests {

    private func uniqueKey(_ label: String = "") -> String {
        "test.accessor.\(label.isEmpty ? "" : "\(label).")\(UUID().uuidString)"
    }

    @Test("returns nil when no model is cached for that key")
    func returnsNilWhenNotCached() {
        let key = uniqueKey("nil")
        #expect(BrowserSurface.model(forKey: key) == nil)
    }

    @Test("returns the model after it is seeded into BrowserSurfaceCache")
    func returnsModelAfterCaching() {
        let key = uniqueKey("seeded")

        _ = BrowserSurfaceCache.shared.model(forKey: key) { BrowserWidgetModel() }
        let retrieved = BrowserSurface.model(forKey: key)
        #expect(retrieved != nil, "model(forKey:) must return the cached model")

        // Clean up.
        BrowserSurfaceCache.shared.teardown(key: key)
    }

    @Test("returns the same instance that was cached")
    func returnsSameInstance() {
        let key = uniqueKey("identity")
        let seeded = BrowserSurfaceCache.shared.model(forKey: key) { BrowserWidgetModel() }
        let retrieved = BrowserSurface.model(forKey: key)

        #expect(retrieved === seeded, "model(forKey:) must return the exact cached instance")

        // Clean up.
        BrowserSurfaceCache.shared.teardown(key: key)
    }

    @Test("returns nil again after teardown")
    func returnsNilAfterTeardown() {
        let key = uniqueKey("post-teardown")

        _ = BrowserSurfaceCache.shared.model(forKey: key) { BrowserWidgetModel() }
        #expect(BrowserSurface.model(forKey: key) != nil)

        BrowserSurfaceCache.shared.teardown(key: key)
        #expect(BrowserSurface.model(forKey: key) == nil)
    }
}

// MARK: - wireHooks configure: invocation Tests

@Suite("BrowserSurface.wireHooks configure: closure", .serialized)
@MainActor
struct BrowserSurfaceConfigureTests {

    private func uniqueKey(_ label: String = "") -> String {
        "test.configure.\(label.isEmpty ? "" : "\(label).")\(UUID().uuidString)"
    }

    @Test("configure is called exactly once when non-nil")
    func configureCalledOnce() {
        let model = BrowserWidgetModel()
        var invokeCount = 0

        BrowserSurface.wireHooks(on: model, cacheKey: uniqueKey(), configure: { _ in
            invokeCount += 1
        })

        #expect(invokeCount == 1, "configure must be called exactly once by wireHooks")
    }

    @Test("configure receives the model instance")
    func configureReceivesModel() {
        let model = BrowserWidgetModel()
        var received: BrowserWidgetModel?

        BrowserSurface.wireHooks(on: model, cacheKey: uniqueKey(), configure: { m in
            received = m
        })

        #expect(received === model, "configure must receive the exact model instance")
    }

    @Test("nil configure does not crash and wires defaults")
    func nilConfigureIsNoop() {
        let model = BrowserWidgetModel()
        // Should not crash.
        BrowserSurface.wireHooks(on: model, cacheKey: uniqueKey(), configure: nil)
        // Default onNewTab and composed onTabClosed should still be wired.
        #expect(model.onNewTab != nil, "default onNewTab must be set even when configure is nil")
        #expect(model.onTabClosed != nil, "composed onTabClosed must be set even when configure is nil")
    }

    @Test("configure can override the default onNewTab")
    func configureCanOverrideOnNewTab() {
        let model = BrowserWidgetModel()
        var customFired = false

        BrowserSurface.wireHooks(on: model, cacheKey: uniqueKey(), configure: { m in
            m.onNewTab = { customFired = true }
        })

        model.onNewTab?()
        #expect(customFired, "configure's onNewTab override must be in effect after wireHooks")
    }
}

// MARK: - Default onNewTab Tests

@Suite("BrowserSurface default onNewTab", .serialized)
@MainActor
struct BrowserSurfaceDefaultOnNewTabTests {

    @Test("default onNewTab opens an empty tab")
    func defaultOnNewTabOpensEmptyTab() {
        let model = BrowserWidgetModel()
        // Seed one tab (simulating resolveIfNeeded's first-tab seeding).
        let url = URL(string: "https://example.com")!
        _ = model.openTab(url: url, title: "Example")

        BrowserSurface.wireHooks(on: model, cacheKey: "test-default-\(UUID())", configure: nil)

        let tabCountBefore = model.tabs.count
        model.onNewTab?()
        let tabCountAfter = model.tabs.count

        #expect(tabCountAfter == tabCountBefore + 1, "onNewTab must add one tab")

        // The new tab should have no URL (empty tab).
        let newTab = model.tabs.last
        #expect(newTab != nil)
        #expect(newTab?.url == nil, "default onNewTab must open an empty tab (no URL)")
        #expect(newTab?.title == "New Tab", "default onNewTab must set title to 'New Tab'")
    }
}

// MARK: - onTabClosed composition Tests

@Suite("BrowserSurface onTabClosed composition", .serialized)
@MainActor
struct BrowserSurfaceTabClosedCompositionTests {

    private func uniqueKey(_ label: String = "") -> String {
        "test.tabclosed.\(label.isEmpty ? "" : "\(label).")\(UUID().uuidString)"
    }

    @Test("onTabClosed with no widget handler is a no-op beyond cache release")
    func onTabClosedNilWidgetHandler() {
        let model = BrowserWidgetModel()
        let cacheKey = uniqueKey("nil-handler")

        // Seed a tab and register a live view in the cache under the tab's key.
        let url = URL(string: "https://example.com")!
        let tabID = model.openTab(url: url, title: "Example")
        let liveKey = "\(cacheKey):\(tabID)"

        // Build the live view so it's in the cache.
        let spec = WebSectionSpec(url: url, selector: "", dataStoreKey: "test", title: nil)
        _ = BrowserSurfaceCache.shared.liveView(forKey: liveKey, building: spec)
        #expect(BrowserSurfaceCache.shared.existing(forKey: liveKey) != nil,
                "live view must be in cache before close")

        // Wire hooks with no widget configure (no onTabClosed from widget side).
        BrowserSurface.wireHooks(on: model, cacheKey: cacheKey, configure: nil)

        // Close the tab — the composed onTabClosed fires via model.closeTab.
        model.closeTab(tabID)

        // The live view slot must be released.
        #expect(BrowserSurfaceCache.shared.existing(forKey: liveKey) == nil,
                "live view must be released from cache after tab close")
    }

    @Test("onTabClosed calls cache-release THEN widget handler in order")
    func onTabClosedCompositionOrder() {
        let model = BrowserWidgetModel()
        let cacheKey = uniqueKey("order")

        let url = URL(string: "https://example.com")!
        let tabID = model.openTab(url: url, title: "Example")
        let liveKey = "\(cacheKey):\(tabID)"

        let spec = WebSectionSpec(url: url, selector: "", dataStoreKey: "test", title: nil)
        _ = BrowserSurfaceCache.shared.liveView(forKey: liveKey, building: spec)

        var callOrder: [String] = []

        BrowserSurface.wireHooks(on: model, cacheKey: cacheKey, configure: { m in
            m.onTabClosed = { _ in
                // Widget handler: check whether cache-release already fired.
                let liveViewGone = BrowserSurfaceCache.shared.existing(forKey: liveKey) == nil
                callOrder.append(liveViewGone ? "cache-first" : "cache-second")
            }
        })

        model.closeTab(tabID)

        #expect(callOrder == ["cache-first"],
                "cache-release must fire before the widget's onTabClosed handler")
    }

    @Test("onTabClosed widget handler fires with the closed tab's ID")
    func onTabClosedWidgetHandlerReceivesTabID() {
        let model = BrowserWidgetModel()
        let cacheKey = uniqueKey("tabid")

        let url = URL(string: "https://example.com")!
        let tabID = model.openTab(url: url, title: "Example")

        // Register a dummy live view so teardown has something to release.
        let liveKey = "\(cacheKey):\(tabID)"
        let spec = WebSectionSpec(url: url, selector: "", dataStoreKey: "test", title: nil)
        _ = BrowserSurfaceCache.shared.liveView(forKey: liveKey, building: spec)

        var receivedID: UUID?
        BrowserSurface.wireHooks(on: model, cacheKey: cacheKey, configure: { m in
            m.onTabClosed = { id in receivedID = id }
        })

        model.closeTab(tabID)

        #expect(receivedID == tabID,
                "widget's onTabClosed must receive the closed tab's ID")
    }

    @Test("closing two tabs releases each tab's live view independently")
    func onTabClosedReleasesEachTabLiveViewIndependently() {
        let model = BrowserWidgetModel()
        let cacheKey = uniqueKey("multi-tab")

        let url1 = URL(string: "https://example.com")!
        let url2 = URL(string: "https://other.example.com")!
        let tabID1 = model.openTab(url: url1, title: "Tab 1")
        let tabID2 = model.openTab(url: url2, title: "Tab 2")

        let liveKey1 = "\(cacheKey):\(tabID1)"
        let liveKey2 = "\(cacheKey):\(tabID2)"
        let spec1 = WebSectionSpec(url: url1, selector: "", dataStoreKey: "test1", title: nil)
        let spec2 = WebSectionSpec(url: url2, selector: "", dataStoreKey: "test2", title: nil)
        _ = BrowserSurfaceCache.shared.liveView(forKey: liveKey1, building: spec1)
        _ = BrowserSurfaceCache.shared.liveView(forKey: liveKey2, building: spec2)

        BrowserSurface.wireHooks(on: model, cacheKey: cacheKey, configure: nil)

        // Close the first tab; only its live view should be released.
        model.closeTab(tabID1)
        #expect(BrowserSurfaceCache.shared.existing(forKey: liveKey1) == nil,
                "first tab's live view must be released")
        #expect(BrowserSurfaceCache.shared.existing(forKey: liveKey2) != nil,
                "second tab's live view must survive closing the first")

        // Clean up the second tab's live view.
        model.closeTab(tabID2)
        #expect(BrowserSurfaceCache.shared.existing(forKey: liveKey2) == nil,
                "second tab's live view must be released after closing it")
    }
}

// MARK: - Empty-tab URL pinning Tests

@Suite("Empty-tab URL pinning", .serialized)
@MainActor
struct EmptyTabURLPinningTests {

    @Test("agent recording materializes only an empty active tab")
    func materializeEmptyActiveTabForRecording() {
        let model = BrowserWidgetModel()
        let blank = URL(string: "about:blank")!
        let existing = URL(string: "https://example.com")!

        let emptyID = model.openTab(title: "New Tab", icon: "globe")
        #expect(model.materializeEmptyActiveTab(at: blank) == emptyID)
        #expect(model.tabs.first(where: { $0.id == emptyID })?.url == blank)
        #expect(model.url == blank)
        #expect(model.urlDraft == "about:blank")

        let loadedID = model.openTab(url: existing, title: "Example")
        #expect(model.materializeEmptyActiveTab(at: blank) == loadedID)
        #expect(model.tabs.first(where: { $0.id == loadedID })?.url == existing,
                "recording start must not replace an existing page")
        #expect(model.url == existing)
    }

    @Test("navigateToDraft pins URL onto an empty tab")
    func navigateToDraftPinsURLOntoEmptyTab() {
        let model = BrowserWidgetModel()

        // Open an empty tab (no URL).
        let tabID = model.openTab(title: "New Tab", icon: "globe")

        // Verify the tab starts with no URL.
        let emptyTab = model.tabs.first(where: { $0.id == tabID })
        #expect(emptyTab != nil)
        #expect(emptyTab?.url == nil, "newly opened empty tab must have no URL")

        // Simulate the user typing a URL in the capsule and pressing Return.
        model.urlDraft = "github.com"
        model.navigateToDraft()

        // The tab must now have the resolved URL pinned.
        let pinnedTab = model.tabs.first(where: { $0.id == tabID })
        #expect(pinnedTab?.url != nil, "tab URL must be pinned after navigateToDraft")
        #expect(pinnedTab?.url?.absoluteString == "https://github.com",
                "pinned URL must be the resolved absolute URL")
    }

    @Test("navigateToDraft on empty tab sets model.url and urlDraft")
    func navigateToDraftSetsModelURL() {
        let model = BrowserWidgetModel()
        _ = model.openTab(title: "New Tab", icon: "globe")

        model.urlDraft = "https://example.com"
        model.navigateToDraft()

        #expect(model.url?.absoluteString == "https://example.com",
                "model.url must be set after navigateToDraft on an empty tab")
        #expect(model.urlDraft == "https://example.com",
                "urlDraft must match the navigated URL")
    }

    @Test("opening an empty tab via default onNewTab gives a URL-pinnable tab")
    func defaultOnNewTabProducesURLPinnableTab() {
        let model = BrowserWidgetModel()
        let url = URL(string: "https://example.com")!
        _ = model.openTab(url: url, title: "Example")

        BrowserSurface.wireHooks(on: model, cacheKey: "test-pin-\(UUID())", configure: nil)

        // + button fires onNewTab → opens empty tab.
        model.onNewTab?()

        let emptyTab = model.tabs.last
        #expect(emptyTab?.url == nil, "newly added tab via onNewTab must have no URL")

        // Simulate URL entry.
        model.urlDraft = "https://new.example.com"
        model.navigateToDraft()

        // The now-active (empty) tab must be pinned.
        let pinnedTab = model.tabs.last
        #expect(pinnedTab?.url?.absoluteString == "https://new.example.com",
                "empty tab opened via onNewTab must accept a pinned URL via navigateToDraft")
    }
}
