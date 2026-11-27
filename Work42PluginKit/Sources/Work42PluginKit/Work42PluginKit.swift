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
// /// Answers the loader's version probe, before any Swift type crosses the
// /// boundary. Compatibility itself is decided earlier, from the manifest's
// /// `sdk_version` (see `Work42SDKCompatibility.accepts(pluginSDK:)`), so a
// /// plugin built for another SDK is refused with a named "rebuild" or
// /// "update Work42" error — never a crash.
// @_cdecl("work42_widget_sdk_version")
// public func work42WidgetSDKVersion() -> Int32 { Work42SDKCompatibility.versionProbeValue }
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

    /// What the version-probe symbols return: always 3 in SDK 3.x.
    ///
    /// Before 3.0 this was an ABI generation counter that every SDK change to a stored layout or initializer
    /// bumped, forcing every plugin author to rebuild at once (its history, v2 to v17, is in `CHANGELOG.md`).
    /// It no longer decides anything. Compatibility is one number, the SDK's semantic version: a plugin's
    /// manifest records `sdk_version`, and `Work42SDKCompatibility.accepts(pluginSDK:)` decides.
    @available(*, deprecated, message: "Compatibility follows Work42SDKCompatibility.version and the manifest's sdk_version. To answer the version probe, return Work42SDKCompatibility.versionProbeValue.")
    nonisolated public static var abiVersion: Int32 { Work42SDKCompatibility.versionProbeValue }

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
