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
}
