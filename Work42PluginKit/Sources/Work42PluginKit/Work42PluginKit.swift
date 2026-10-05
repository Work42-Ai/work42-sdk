// Work42PluginKit.swift — the custom-widget SDK umbrella (feat/custom-widgets.1).
//
// Work42PluginKit is what an out-of-repo, agent-authored widget package
// compiles against. It ships as a DYNAMIC framework embedded in the app
// bundle (`Contents/Frameworks/Work42PluginKit.framework`), alongside
// `Work42UI.framework`, and widgets link BOTH via `@rpath` — never
// statically. Exactly ONE runtime copy of each framework may exist:
// a widget that statically linked either module would duplicate Swift
// type metadata and protocol conformances against the app's copy, which
// manifests as subtle runtime crashes (mismatched casts, duplicate
// conformance tables). The scaffold's build script (subtask .5) makes
// static linking impossible-by-default; the loader (subtask .3) rejects
// dylibs that export SDK symbols.
//
// The SDK surface is deliberately XPC-shaped (see `SessionServices.swift`)
// so the later marketplace phase can move third-party widgets out of
// process behind ExtensionKit as a host-side transport swap — not a
// widget rewrite.
//
// ## The entry-point ABI (`work42_widget_main`)
//
// A widget dylib exports exactly two C symbols, both written by the widget
// author (the scaffold template generates them):
//
// ```swift
// import Work42PluginKit
//
// /// Checked FIRST by the loader, before any Swift type crosses the
// /// boundary. A mismatch against `WidgetSDK.abiVersion` produces a named
// /// "rebuild against SDK vN" error — never a crash.
// @_cdecl("work42_widget_sdk_version")
// public func work42WidgetSDKVersion() -> Int32 { WidgetSDK.abiVersion }
//
// /// The factory. Called on the main actor by the loader after the
// /// version check passes. Returns the widget instance boxed through
// /// `WidgetEntryPoint.register` (an opaque +1 retained pointer — the
// /// only shape that can safely cross the `dlsym` C boundary).
// ///
// /// `@_cdecl` functions are always nonisolated (C ABI carries no Swift
// /// actor annotation), so bridging into the `@MainActor`-isolated
// /// `register` needs `MainActor.assumeIsolated` — safe here because the
// /// loader always calls this synchronously ON the main actor, never off
// /// it. The `nonisolated(unsafe)` local is required because
// /// `UnsafeMutableRawPointer` does not conform to `Sendable` (explicitly
// /// unavailable in the stdlib), so it cannot be returned directly from
// /// `assumeIsolated`'s closure — write it into a pre-declared local
// /// instead.
// @_cdecl("work42_widget_main")
// public func work42WidgetMain() -> UnsafeMutableRawPointer {
//     nonisolated(unsafe) var result: UnsafeMutableRawPointer!
//     MainActor.assumeIsolated {
//         result = WidgetEntryPoint.register(MyWidget())
//     }
//     return result
// }
// ```
//
// Loader side (subtask .3): `dlopen` → `dlsym(WidgetSDK.versionSymbol)` →
// version check → `dlsym(WidgetSDK.entryPointSymbol)` → call on the main
// actor → `WidgetEntryPoint.claim(pointer)` to unbox the
// `any Work42Widget`. Because loader and widget both link the ONE
// embedded Work42PluginKit, the box class and the protocol type are the
// same runtime types on both sides and the cast is exact.

import Foundation

// Re-export the design system: `import Work42PluginKit` gives widget code
// the full Work42UI surface (DT tokens, Card/Toolbar/Glass components,
// Markdown theme, WebSection stack) from a single import — and, because
// Work42UI is itself an embedded dynamic framework, from the single
// shared runtime copy.
@_exported import Work42UI

// MARK: - WidgetSDK

/// Source-compatible access to the canonical Work42 SDK compatibility values.
public enum WidgetSDK {

    /// Semantic release of the public SDK used to compile the plugin.
    nonisolated public static var version: String { Work42SDKCompatibility.version }

    /// The SDK ABI version. The loader reads the widget's exported
    /// `work42_widget_sdk_version` BEFORE calling the factory; a mismatch
    /// is reported as a named "rebuild against SDK v\(abiVersion)" error,
    /// never a crash.
    /// v2: `WidgetIntentSpec` gained `placement` + `actionAreaStyle`
    /// (stored-layout change on an SDK struct — dylibs built against v1
    /// must rebuild).
    /// v3: `BrowserSurface.init` gained the `configure:` parameter
    /// (changes the init's mangled Swift symbol from
    /// `BrowserSurface.init(spec:cacheKey:)` to
    /// `BrowserSurface.init(spec:cacheKey:configure:)`). A widget dylib
    /// built against SDK v2 that calls the old symbol will fail at
    /// `dlopen(RTLD_NOW)` with "symbol not found" — the loader catches
    /// this and shows the fail-loud error card. The version bump ensures
    /// `widget.yaml` staleness detection and the version-mismatch message
    /// name the correct rebuild target.
    /// v4: `SessionServices` gained the `storage` property
    /// (`WidgetStorageService`), changing `SessionServices.init`'s
    /// parameter list. A widget dylib built against SDK v3 that calls
    /// the old 3-parameter init will fail at `dlopen(RTLD_NOW)` with
    /// "symbol not found". Rebuild with `work42 widget build <slug>`.
    /// v5: `Work42Widget` gained the required `linkIntents` property and the
    /// `WidgetLinkMatcher` / `WidgetLinkIntentSpec` link-opening contract.
    /// Every widget must rebuild and explicitly declare its capabilities.
    /// v6: widget and intent metadata gained optional bundled-image channels;
    /// widget intents also gained an optional action-area brand colour.
    /// First-party plugins rebuild to opt in; SF-Symbol-only source keeps the
    /// same behaviour through nil defaults and fallback glyphs.
    /// v7: widget intents gained confirmed state, service-aware handlers, and
    /// action-area menus with live options. These change the stored SDK types,
    /// so existing widget dylibs must rebuild.
    /// v8: a plugin bundle may ADDITIONALLY export a `work42_plugin_main`
    /// entry point (`Work42SessionHooks`, `PluginEntryPoint`) — a session-hook
    /// contract scoped to the plugin's session TYPES rather than one mounted
    /// widget. This is a purely additive symbol: it does not change any
    /// existing widget-side type, so an existing widget dylib built against
    /// v7 keeps loading unchanged (the version check is per-entry-point; a
    /// widget with no plugin entry is simply reported as having no hooks).
    /// The version bump exists so a plugin dylib itself is checked against
    /// the same single `sdk_version` ceiling as its widgets (one version
    /// governs the whole plugin).
    /// v9 (task42-plugin-conversion, s3): `SessionServices` gained
    /// `sessionId`/`worktreePath` (additive — defaulted in the init, so an
    /// existing widget dylib's call to the old init still links). `Work42Widget`
    /// gained the optional `storageNamespace` property, defaulting to `nil`
    /// (my own slug) via a protocol extension — no existing conformance
    /// breaks. Purely additive on both counts; the bump exists so a plugin
    /// declaring `sdk_version: 9` in its manifest is understood to rely on
    /// these two additions being present.
    /// v10 (meet42-plugin-conversion, s1): new opt-in `Work42WidgetPill`
    /// protocol (a widget's compact floatable "pill" presentation), mirroring
    /// `Work42WidgetBackground`'s cast-based discovery — additive, no
    /// existing conformance affected. The version bump is for the OTHER
    /// change this release: `SessionServices` and `WidgetBackgroundServices`
    /// both gain a new required `pill: any WidgetPillService` field, changing
    /// both structs' memberwise init signature. Neither struct is ever
    /// constructed by a widget/plugin dylib (only the host constructs them),
    /// so no existing dylib fails to link — the bump exists so a plugin
    /// declaring `sdk_version: 10` is understood to rely on `services.pill`
    /// being present.
    /// v11: `WidgetBackgroundServices` gained the required `activity` field,
    /// changing the stored layout of a value passed across the widget dylib
    /// boundary. Older hosts must reject widgets built against this layout
    /// before invoking their factory or background agent.
    nonisolated public static var abiVersion: Int32 { Work42SDKCompatibility.abiGeneration }

    /// C symbol name of the widget factory (`@_cdecl`). See the file
    /// header for the exact exported signature.
    nonisolated public static let entryPointSymbol = "work42_widget_main"

    /// C symbol name of the widget's SDK-version report (`@_cdecl`,
    /// `() -> Int32`). Checked before `entryPointSymbol` is ever called.
    nonisolated public static let versionSymbol = "work42_widget_sdk_version"

    /// C symbol name of the plugin session-hooks factory (`@_cdecl`,
    /// `() -> UnsafeMutableRawPointer`, optional — a plugin with no
    /// `Sources/Plugin.swift` has no dylib and thus no this symbol).
    nonisolated public static let pluginEntryPointSymbol = "work42_plugin_main"

    /// C symbol name of the plugin dylib's SDK-version report (`@_cdecl`,
    /// `() -> Int32`). Checked before `pluginEntryPointSymbol` is ever called.
    nonisolated public static let pluginVersionSymbol = "work42_plugin_sdk_version"

    /// Validates a widget slug: lowercase alphanumerics and hyphens,
    /// starting with an alphanumeric (the same grammar as artifact ids).
    /// Used by the loader and the `work42 widget` CLI so a bad slug fails
    /// loud at scaffold/load time, not deep inside catalog registration.
    nonisolated public static func isValidSlug(_ slug: String) -> Bool {
        guard let first = slug.unicodeScalars.first else { return false }
        let alnum = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        guard alnum.contains(first) else { return false }
        let allowed = alnum.union(CharacterSet(charactersIn: "-"))
        return slug.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

// MARK: - WidgetEntryPoint

/// The two halves of the raw-pointer handoff across the `dlsym` boundary.
///
/// `register` (widget side) boxes the widget instance and returns it as a
/// +1 retained opaque pointer — the only representation that can cross a
/// `@convention(c)` boundary without any Swift runtime assumptions.
/// `claim` (loader side) balances the retain and unboxes. Both sides run
/// against the SAME embedded framework, so the box class is one runtime
/// type and the unbox cast is exact — `claim` returning nil means the
/// pointer did not come from `register` (a malformed widget), which the
/// loader reports fail-loud.
public enum WidgetEntryPoint {

    /// Widget side: box `widget` for the trip through
    /// `work42_widget_main`'s C return value. +1 retained; ownership
    /// transfers to the caller (the loader's `claim`).
    @MainActor
    public static func register(_ widget: any Work42Widget) -> UnsafeMutableRawPointer {
        Unmanaged.passRetained(WidgetHandoffBox(widget)).toOpaque()
    }

    /// Loader side: take ownership of a pointer produced by `register` and
    /// unbox the widget. Returns nil when the pointer is not a
    /// `register`-produced box — the loader treats that as a malformed
    /// widget and reports it, never crashes.
    @MainActor
    public static func claim(_ pointer: UnsafeMutableRawPointer) -> (any Work42Widget)? {
        let object = Unmanaged<AnyObject>.fromOpaque(pointer).takeRetainedValue()
        return (object as? WidgetHandoffBox)?.widget
    }
}

/// The opaque box `WidgetEntryPoint` passes across the C boundary. A class
/// (not a struct) so it has a stable object identity `Unmanaged` can
/// retain, and `@MainActor` because the widget it carries is.
@MainActor
private final class WidgetHandoffBox {
    let widget: any Work42Widget

    init(_ widget: any Work42Widget) {
        self.widget = widget
    }
}
