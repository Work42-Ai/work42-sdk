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

    // ABI generation 13 (SDK 2.8.0): `BrowserSurface` holds an optional `SessionServices`, which grew by the 40-byte
    // `tools` existential: 384 -> 424. Widgets built for ABI 12 or older are rejected by the loader.
    // ABI generation 16 (SDK 2.14.0): `SessionServices` gained `actor` and `collaboration`: 424 -> 536.
    // ABI generation 17 (SDK 2.16.0): `SessionServices` gained `files` and `platform` (two 40-byte existentials): 536 -> 616.
    // Widgets built for ABI 16 or older are rejected by the loader.
    @Test("BrowserSurface keeps the layout widgets built against this ABI generation expect")
    func browserSurface() {
        #expect(MemoryLayout<BrowserSurface>.size == 616)
        #expect(MemoryLayout<BrowserSurface>.alignment == 8)
    }

    @Test("the other public structs widgets embed are unchanged")
    func otherPublicStructs() {
        #expect(MemoryLayout<BrowserSurfaceSpec>.size == 88)
        #expect(MemoryLayout<WebSelection>.size == 88)
        #expect(MemoryLayout<WidgetHeaderLabel>.size == 120)
        // ABI generation 16 (SDK 2.14.0): `WidgetIntentSpec` gained `requires`, `audience`, `agents` and the three per-viewer closures: 240 -> 320.
        #expect(MemoryLayout<WidgetIntentSpec>.size == 320)
        #expect(MemoryLayout<WidgetLinkIntentSpec>.size == 24)
        #expect(MemoryLayout<ResolvedAnnotation>.size == 32)
        #expect(MemoryLayout<WidgetPillAppIcon>.size == 32)
        #expect(MemoryLayout<WidgetPillActionButtonStyle>.size == 16)
        // ABI generation 16 (SDK 2.14.0): `InstanceKey` is two strings and an optional string.
        #expect(MemoryLayout<InstanceKey>.size == 48)
    }

    // Added with WOR-70, measured at SDK 1.2.0 (ABI generation 11). `WidgetBackgroundServices` is what a widget's
    // background agent is handed and keeps (the Oct 3 `CalendarDetectionAgent` crash was in its copy), and
    // `SessionServices` is what every widget keeps for its session.
    @Test("the services and value types widgets receive and keep are unchanged")
    func servicesAndValueTypes() {
        // ABI generation 13 (SDK 2.8.0): each gained `tools` (one 40-byte existential): 192 -> 232, 232 -> 272.
        #expect(MemoryLayout<WidgetBackgroundServices>.size == 272)
        // ABI generation 16 (SDK 2.14.0): `SessionServices` gained `actor` (a struct) and `collaboration` (an existential): 272 -> 384.
        // ABI generation 17 (SDK 2.16.0): `SessionServices` gained `files` and `platform` (two 40-byte existentials): 384 -> 464.
        // `WidgetBackgroundServices` gained `files` (one): 232 -> 272.
        #expect(MemoryLayout<SessionServices>.size == 464)
        #expect(MemoryLayout<WidgetFileEntry>.size == 40)
        #expect(MemoryLayout<NoopWidgetFileService>.size == 0)
        #expect(MemoryLayout<SystemWidgetPlatformService>.size == 0)
        #expect(MemoryLayout<UnavailableWidgetToolService>.size == 0)
        #expect(MemoryLayout<NoopWidgetSessionActivityService>.size == 0)
        #expect(MemoryLayout<WidgetServiceError>.size == 32)
        #expect(MemoryLayout<WidgetShellResult>.size == 36)
        #expect(MemoryLayout<WidgetLinkRouter>.size == 32)
        #expect(MemoryLayout<WidgetMinSize>.size == 16)
        #expect(MemoryLayout<WidgetIntentMenuOption>.size == 49)
        #expect(MemoryLayout<WidgetPillMetadata>.size == 48)
        // ABI generation 13 (SDK 2.8.0): `SessionCreateContext` gained `tools` (one 40-byte existential): 136 -> 176.
        #expect(MemoryLayout<SessionCreateContext>.size == 176)
    }

    // A generic view is embedded with the widget's own type arguments; `EmptyView` pins the shell's own storage.
    @Test("the pill accessory shell keeps its own storage")
    func pillAccessoryShell() {
        #expect(MemoryLayout<WidgetPillAccessoryShell<EmptyView, EmptyView>>.size == 64)
    }

    // Not pinned, on purpose: `WidgetSessionServicesKey`, `WidgetCacheScopeKey` and `WidgetLinkRouterKey` are
    // `EnvironmentKey` namespaces with only static members. A widget never holds one, so they have no stored layout.
}
