// BrowserChromeHostedTests.swift — browser-widgets-not-extending-from-browser.5
//
// Tests for AC7 (chrome-as-header for custom browser widgets):
//
//   (a) Environment key: default value is `false` (in-body chrome renders);
//       when set `true` the suppression flag is set correctly.
//
//   (b) Opt-out protocol: a widget conforming to `Work42BrowserWidgetOptions`
//       with `prefersDefaultWidgetHeader == true` is detected via `as?`;
//       a non-conforming widget returns `nil` from the cast (default = false).
//
//   (c) Detection logic: `BrowserSurfaceCache.existingModel(forKey:)` returns
//       `nil` before any surface resolves and non-nil after — this is the
//       host-side signal for "browser-based" detection.
//
// These are purely model-layer / protocol tests — no SwiftUI view rendering is
// required, which keeps the test target host-less. The "no chrome row when
// host-owned" behaviour is validated at the app integration level (QA).

import Foundation
import SwiftUI
import Testing
@testable import Work42PluginKit

// MARK: - Environment key constant

@Suite("BrowserChromeHostOwned environment key")
struct BrowserChromeHostOwnedKeyTests {

    @Test("default value is false — in-body chrome renders by default")
    func defaultIsFalse() {
        #expect(BrowserChromeHostOwnedKey.defaultValue == false)
    }
}

// MARK: - Work42BrowserWidgetOptions opt-out protocol

/// A widget that explicitly opts out of the browser chrome header.
@MainActor
private final class OptOutWidget: Work42Widget, Work42BrowserWidgetOptions {
    let id = "opt-out-widget"
    let title = "Opt-Out Widget"
    let icon = "xmark"
    let linkIntents: [WidgetLinkIntentSpec] = []
    var prefersDefaultWidgetHeader: Bool { true }
    func makeView(services: SessionServices) -> AnyView { AnyView(EmptyView()) }
}

/// A widget that opts IN (returns false) — identical to not conforming at all.
@MainActor
private final class OptInWidget: Work42Widget, Work42BrowserWidgetOptions {
    let id = "opt-in-widget"
    let title = "Opt-In Widget"
    let icon = "checkmark"
    let linkIntents: [WidgetLinkIntentSpec] = []
    var prefersDefaultWidgetHeader: Bool { false }
    func makeView(services: SessionServices) -> AnyView { AnyView(EmptyView()) }
}

/// A plain widget with no conformance to Work42BrowserWidgetOptions — simulates
/// an old dylib that was compiled before the opt-out protocol existed.
@MainActor
private final class PlainWidget: Work42Widget {
    let id = "plain-widget"
    let title = "Plain Widget"
    let icon = "square"
    let linkIntents: [WidgetLinkIntentSpec] = []
    func makeView(services: SessionServices) -> AnyView { AnyView(EmptyView()) }
}

@Suite("Work42BrowserWidgetOptions opt-out protocol", .serialized)
@MainActor
struct Work42BrowserWidgetOptionsTests {

    // MARK: - Opt-out: conforming widget with prefersDefaultWidgetHeader == true

    @Test("as? cast succeeds for a conforming widget and reads prefersDefaultWidgetHeader")
    func conformingWidgetCastSucceeds() {
        let widget: any Work42Widget = OptOutWidget()
        let optsOut = (widget as? any Work42BrowserWidgetOptions)?
            .prefersDefaultWidgetHeader == true
        #expect(optsOut == true, "a widget with prefersDefaultWidgetHeader == true must opt out")
    }

    // MARK: - Opt-in via conformance with false

    @Test("as? cast on an opt-in widget (conforming, prefersDefaultWidgetHeader == false) returns false")
    func optInConformingWidgetReturnsFalse() {
        let widget: any Work42Widget = OptInWidget()
        let optsOut = (widget as? any Work42BrowserWidgetOptions)?
            .prefersDefaultWidgetHeader == true
        #expect(optsOut == false, "conforming widget returning false must not opt out")
    }

    // MARK: - Old dylib simulation: non-conforming widget

    @Test("as? cast returns nil for a non-conforming widget — default browser-chrome behavior")
    func nonConformingWidgetCastReturnsNil() {
        let widget: any Work42Widget = PlainWidget()
        let options = widget as? any Work42BrowserWidgetOptions
        #expect(options == nil, "non-conforming widget must not satisfy the opt-out cast")
    }

    @Test("host opt-out check: non-conforming widget defaults to false (browser chrome)")
    func nonConformingWidgetDefaultsToFalse() {
        let widget: any Work42Widget = PlainWidget()
        // Mirrors the host's actual check: if nil, optsOut is false → browser header.
        let optsOut = (widget as? any Work42BrowserWidgetOptions)?
            .prefersDefaultWidgetHeader == true
        #expect(optsOut == false,
            "non-conforming widgets must get the browser chrome header by default (optsOut == false)")
    }
}

// MARK: - Detection logic: BrowserSurfaceCache existingModel signals "browser-based"

@Suite("Browser-based detection via BrowserSurfaceCache", .serialized)
@MainActor
struct BrowserBasedDetectionTests {

    private func uniqueKey() -> String {
        "ac7-test.\(UUID().uuidString)"
    }

    @Test("existingModel returns nil before any surface resolves — not browser-based")
    func nilBeforeResolution() {
        let key = uniqueKey()
        // No model has been added → detection returns nil → generic header.
        #expect(BrowserSurfaceCache.shared.existingModel(forKey: key) == nil,
            "must return nil before the surface has resolved")
    }

    @Test("existingModel returns non-nil after the surface resolves — browser-based detected")
    func nonNilAfterResolution() {
        let key = uniqueKey()
        _ = BrowserSurfaceCache.shared.model(forKey: key) { BrowserWidgetModel() }
        let detected = BrowserSurfaceCache.shared.existingModel(forKey: key) != nil
        #expect(detected == true,
            "must return non-nil once the model is live (host should render browser chrome header)")
        BrowserSurfaceCache.shared.teardown(key: key)
    }

    @Test("teardown clears the model — widget reverts to 'not browser-based'")
    func teardownClearsDetection() {
        let key = uniqueKey()
        _ = BrowserSurfaceCache.shared.model(forKey: key) { BrowserWidgetModel() }
        BrowserSurfaceCache.shared.teardown(key: key)
        #expect(BrowserSurfaceCache.shared.existingModel(forKey: key) == nil,
            "after teardown the widget must no longer be detected as browser-based")
    }

    @Test("opt-out check: optsOut == true AND model live → host should NOT use browser chrome")
    func optOutOverridesLiveModel() {
        // Set up a live model:
        let key = uniqueKey()
        _ = BrowserSurfaceCache.shared.model(forKey: key) { BrowserWidgetModel() }
        defer { BrowserSurfaceCache.shared.teardown(key: key) }

        let widget: any Work42Widget = OptOutWidget()
        let optsOut = (widget as? any Work42BrowserWidgetOptions)?
            .prefersDefaultWidgetHeader == true
        let isBrowserBased = !optsOut &&
            BrowserSurfaceCache.shared.existingModel(forKey: key) != nil

        #expect(isBrowserBased == false,
            "opt-out must win even when the model is live — generic header is used")
    }

    @Test("default path: non-conforming widget + live model → host should use browser chrome")
    func defaultPathUseBrowserChrome() {
        let key = uniqueKey()
        _ = BrowserSurfaceCache.shared.model(forKey: key) { BrowserWidgetModel() }
        defer { BrowserSurfaceCache.shared.teardown(key: key) }

        let widget: any Work42Widget = PlainWidget()
        let optsOut = (widget as? any Work42BrowserWidgetOptions)?
            .prefersDefaultWidgetHeader == true
        let isBrowserBased = !optsOut &&
            BrowserSurfaceCache.shared.existingModel(forKey: key) != nil

        #expect(isBrowserBased == true,
            "non-conforming widget with a live model must be detected as browser-based")
    }
}
