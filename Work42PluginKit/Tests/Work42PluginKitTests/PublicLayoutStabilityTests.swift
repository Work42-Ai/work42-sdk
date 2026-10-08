// PublicLayoutStabilityTests.swift — the in-memory size of every public struct a widget embeds BY VALUE.
//
// Work42PluginKit is not built with library evolution, so the size and layout of a public struct are
// compiled into every widget that uses it (the widget allocates, copies and destroys it itself). Adding or
// removing a stored property therefore silently breaks every widget built against the old SDK, and
// every widget built against the new one breaks in an app that ships the old: the host loads the dylib, the
// widget releases memory at the wrong offset, and the app dies with a bad release.
//
// That is exactly what happened when `BrowserSurface` gained an `@Environment` stored property
// (384 -> 624 bytes): Work42 and Work42 QA share ~/.work42/widgets but embed different SDKs, and both crashed in
// `outlined destroy of BrowserSurface`.
//
// These sizes were measured at SDK 1.1.0 (ABI generation 11). If one fails, do NOT update the number: move
// the new state somewhere widgets don't embed (an internal view, a class, the environment), or make a
// deliberate ABI-generation bump.

import SwiftUI
import Testing
@testable import Work42PluginKit

@Suite("Public struct layout is ABI (ABI generation 11)")
struct PublicLayoutStabilityTests {

    @Test("BrowserSurface keeps the 384-byte layout widgets built against SDK 1.0/1.1 expect")
    func browserSurface() {
        #expect(MemoryLayout<BrowserSurface>.size == 384)
        #expect(MemoryLayout<BrowserSurface>.alignment == 8)
    }

    @Test("the other public structs widgets embed are unchanged")
    func otherPublicStructs() {
        #expect(MemoryLayout<BrowserSurfaceSpec>.size == 88)
        #expect(MemoryLayout<WebSelection>.size == 88)
        #expect(MemoryLayout<WidgetHeaderLabel>.size == 120)
        #expect(MemoryLayout<WidgetIntentSpec>.size == 240)
        #expect(MemoryLayout<WidgetLinkIntentSpec>.size == 24)
        #expect(MemoryLayout<ResolvedAnnotation>.size == 32)
        #expect(MemoryLayout<WidgetPillAppIcon>.size == 32)
        #expect(MemoryLayout<WidgetPillActionButtonStyle>.size == 16)
    }

    // Added with WOR-70, measured at SDK 1.2.0 (ABI generation 11). `WidgetBackgroundServices` is what a widget's
    // background agent is handed and keeps (the Oct 3 `CalendarDetectionAgent` crash was in its copy), and
    // `SessionServices` is what every widget keeps for its session.
    @Test("the services and value types widgets receive and keep are unchanged")
    func servicesAndValueTypes() {
        #expect(MemoryLayout<WidgetBackgroundServices>.size == 192)
        #expect(MemoryLayout<SessionServices>.size == 232)
        #expect(MemoryLayout<NoopWidgetSessionActivityService>.size == 0)
        #expect(MemoryLayout<WidgetServiceError>.size == 32)
        #expect(MemoryLayout<WidgetShellResult>.size == 36)
        #expect(MemoryLayout<WidgetLinkRouter>.size == 32)
        #expect(MemoryLayout<WidgetMinSize>.size == 16)
        #expect(MemoryLayout<WidgetIntentMenuOption>.size == 49)
        #expect(MemoryLayout<WidgetPillMetadata>.size == 48)
        #expect(MemoryLayout<SessionCreateContext>.size == 136)
    }

    // A generic view is embedded with the widget's own type arguments; `EmptyView` pins the shell's own storage.
    @Test("the pill accessory shell keeps its own storage")
    func pillAccessoryShell() {
        #expect(MemoryLayout<WidgetPillAccessoryShell<EmptyView, EmptyView>>.size == 64)
    }

    // Not pinned, on purpose: `WidgetSessionServicesKey`, `WidgetCacheScopeKey` and `WidgetLinkRouterKey` are
    // `EnvironmentKey` namespaces with only static members. A widget never holds one, so they have no stored layout.
}
