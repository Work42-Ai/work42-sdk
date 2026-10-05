// CanvasTheme.swift - Design-token → CSS bridge for the agent canvas.
//
// The agent canvas (T-001) serves agent-authored HTML over a real
// `http://127.0.0.1` origin, wrapped in a built-in themed template. So
// that an agent which writes plain HTML already lands on the app's
// visual language, the server injects the stylesheet this file emits.
//
// `CanvasTheme.css()` is a pure, deterministic generator: it reads the
// `DT` design tokens (Sources/Work42UI/Tokens/DesignTokens.swift),
// resolves every adaptive color under BOTH a light (`.aqua`) and a dark
// (`.darkAqua`) appearance, and emits:
//
//   * a `:root { … }` block of `--w42-*` custom properties (the LIGHT
//     values) so agent CSS can reference `var(--w42-primary)` etc.
//   * a base reset so unstyled agent content already looks on-brand,
//   * a `@media (prefers-color-scheme: dark) { :root { … } }` block that
//     overrides the color tokens with their DARK values.
//
// DT colors are SwiftUI `Color`s wrapping name-based dynamic `NSColor`s
// (`NSColor(name:dynamicProvider:)`) — they pick light vs dark at
// draw-time via `appearance.bestMatch(from: [.darkAqua, .vibrantDark])`.
// To pull a concrete hex out of one we resolve it *inside* a specific
// `NSAppearance` drawing context (see `hex(_:under:)`).
//
// Isolation: color resolution touches NSColor / NSAppearance (AppKit,
// main-actor), and the system accent is read live at generation time.
// `css()` is therefore a `@MainActor static func`. Its only consumers —
// the canvas server + template composition — run app-side on the main
// actor, so this is the natural and correct isolation.

import AppKit
import SwiftUI

public enum CanvasTheme {

    /// Generates the canvas theme stylesheet from the `DT` design tokens.
    ///
    /// Pure and deterministic for a given appearance pair + system
    /// accent: the same tokens always produce the same CSS. Resolves
    /// each adaptive color under light (`.aqua`) and dark (`.darkAqua`)
    /// `NSAppearance`s and the live system accent, emitting light values
    /// in `:root` and dark values under `@media (prefers-color-scheme:
    /// dark)`.
    ///
    /// - Returns: a complete CSS stylesheet string (UTF-8 safe, hex
    ///   colors as `#rrggbb`).
    /// The theme-dependent color tokens (name → DT Color). Order is stable so
    /// the CSS output stays deterministic. Shared by `css()` (bakes both
    /// appearances) and `currentColorTokens()` (the live push).
    @MainActor
    static var colorTokenList: [(name: String, color: Color)] {
        [
            ("backdrop",        DT.backdrop),
            ("surface",         DT.surface),
            ("elevated",        DT.elevated),
            ("text-primary",    DT.textPrimary),
            ("text-secondary",  DT.textSecondary),
            ("text-tertiary",   DT.textTertiary),
            // Accent / primary both map to the live system accent (DT.systemAccent).
            ("accent",          DT.systemAccent),
            ("primary",         DT.systemAccent),
            ("orange",          DT.orange),
            ("cyan",            DT.cyan),
            ("green",           DT.green),
            ("red",             DT.red),
            ("amber",           DT.amber),
        ]
    }

    /// The color tokens resolved under the CURRENTLY-active app appearance,
    /// as `name → "#rrggbb"`. Pushed into an open artifact via
    /// `window.__w42.theme.apply(...)` on a theme change so the `--w42-*`
    /// vars re-resolve LIVE, with no reload (AC-C5). Only colors change with
    /// the theme — spacing / radii / fonts are appearance-independent.
    @MainActor
    public static func currentColorTokens() -> [String: String] {
        let appearance = NSApplication.shared.effectiveAppearance
        var out: [String: String] = [:]
        for token in colorTokenList {
            out[token.name] = hex(token.color, under: appearance)
        }
        // Push the shared syntax palette too, so a code block in an open artifact
        // recolours live on a theme change exactly like the editor — not just on
        // reload / OS light-dark flip.
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        for entry in EditorSyntaxPalette.resolvedHex(dark: isDark) {
            out[entry.name] = entry.hex
        }
        return out
    }

    @MainActor
    public static func css() -> String {
        let light = NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing()
        let dark = NSAppearance(named: .darkAqua) ?? light

        // Color tokens: name → SwiftUI Color from DT (shared so the live
        // theme push in `currentColorTokens()` stays in lock-step).
        let colorTokens = Self.colorTokenList

        // Non-color tokens are appearance-independent — emitted once in
        // `:root`. Spacing / radii / font-size values are CSS px.
        let spacingTokens: [(name: String, value: CGFloat)] = [
            ("s4",  DT.s4),  ("s8",  DT.s8),  ("s12", DT.s12), ("s16", DT.s16),
            ("s20", DT.s20), ("s24", DT.s24), ("s32", DT.s32), ("s40", DT.s40),
        ]

        let radiusTokens: [(name: String, value: CGFloat)] = [
            ("r-window", DT.rWindow), ("r-panel", DT.rPanel), ("r-card", DT.rCard),
            ("r-button", DT.rButton), ("r-input", DT.rInput), ("r-pill", DT.rPill),
        ]

        let fontTokens: [(name: String, value: CGFloat)] = [
            ("f9",  DT.f9),  ("f10", DT.f10), ("f11", DT.f11), ("f12", DT.f12),
            ("f13", DT.f13), ("f14", DT.f14), ("f15", DT.f15), ("f17", DT.f17),
            ("f22", DT.f22), ("f30", DT.f30), ("f32", DT.f32),
        ]

        // System font stack mirroring macOS / the app's `-apple-system`.
        let fontFamily = "-apple-system, BlinkMacSystemFont, \"SF Pro Text\", "
            + "\"Helvetica Neue\", Helvetica, Arial, sans-serif"

        // --- :root (light values + appearance-independent tokens) ---
        var root = ""
        root += "  /* Colors (light) */\n"
        for token in colorTokens {
            root += "  --w42-\(token.name): \(hex(token.color, under: light));\n"
        }
        root += "\n  /* Typography */\n"
        root += "  --w42-font-family: \(fontFamily);\n"
        for token in fontTokens {
            root += "  --w42-\(token.name): \(px(token.value));\n"
        }
        root += "\n  /* Spacing (4-pt grid) */\n"
        for token in spacingTokens {
            root += "  --w42-\(token.name): \(px(token.value));\n"
        }
        root += "\n  /* Corner radii */\n"
        for token in radiusTokens {
            root += "  --w42-\(token.name): \(px(token.value));\n"
        }
        // Syntax palette — the SAME tokens the native code editor uses (base One
        // Dark/Light overlaid with the active theme's `editor:` overrides), so
        // artifact/markdown code highlighting matches the editor. See
        // `EditorSyntaxPalette`.
        root += "\n  /* Syntax palette (shared with the code editor) */\n"
        for entry in EditorSyntaxPalette.resolvedHex(dark: false) {
            root += "  --w42-\(entry.name): \(entry.hex);\n"
        }

        // --- dark color overrides (media query, 4-space indent) ---
        var darkRoot = ""
        for token in colorTokens {
            darkRoot += "    --w42-\(token.name): \(hex(token.color, under: dark));\n"
        }
        for entry in EditorSyntaxPalette.resolvedHex(dark: true) {
            darkRoot += "    --w42-\(entry.name): \(entry.hex);\n"
        }


        return """
        /* Work42 canvas theme — generated from DT design tokens. Do not edit by hand. */

        :root {
        \(root.trimmingTrailingNewline())

          color-scheme: light dark;
        }

        @media (prefers-color-scheme: dark) {
          :root {
        \(darkRoot.trimmingTrailingNewline())
          }
        }

        /* --- Base reset: unstyled agent content already looks on-brand --- */

        *,
        *::before,
        *::after {
          box-sizing: border-box;
        }

        html {
          color-scheme: light dark;
          -webkit-text-size-adjust: 100%;
        }

        body {
          margin: 0;
          padding: var(--w42-s20);
          background: var(--w42-backdrop);
          color: var(--w42-text-primary);
          font-family: var(--w42-font-family);
          font-size: var(--w42-f13);
          line-height: 1.5;
          -webkit-font-smoothing: antialiased;
          -moz-osx-font-smoothing: grayscale;
        }

        a {
          color: var(--w42-primary);
          text-decoration: none;
        }

        a:hover {
          text-decoration: underline;
        }

        h1, h2, h3, h4, h5, h6 {
          margin: 0 0 var(--w42-s12);
          line-height: 1.2;
          color: var(--w42-text-primary);
        }

        h1 { font-size: var(--w42-f32); }
        h2 { font-size: var(--w42-f22); }
        h3 { font-size: var(--w42-f17); }
        h4 { font-size: var(--w42-f15); }

        p {
          margin: 0 0 var(--w42-s12);
          color: var(--w42-text-secondary);
        }

        small {
          font-size: var(--w42-f11);
          color: var(--w42-text-tertiary);
        }

        code, pre {
          font-family: ui-monospace, "SF Mono", Menlo, Monaco, "Courier New", monospace;
          font-size: var(--w42-f12);
        }

        pre {
          padding: var(--w42-s16);
          background: var(--w42-surface);
          border-radius: var(--w42-r-card);
          overflow: auto;
        }

        hr {
          border: none;
          border-top: 1px solid var(--w42-elevated);
          margin: var(--w42-s24) 0;
        }
        """
    }

    // MARK: - Color resolution

    /// Resolves a (possibly appearance-adaptive) SwiftUI `Color` to a
    /// concrete `#rrggbb` hex string under the given `NSAppearance`.
    ///
    /// DT colors wrap name-based dynamic `NSColor`s that pick their value
    /// from the *current drawing appearance*. Setting that appearance for
    /// the duration of the resolution forces the dynamic provider down
    /// the light or dark branch, so we read the right concrete RGB.
    @MainActor
    private static func hex(_ color: Color, under appearance: NSAppearance) -> String {
        let dynamic = NSColor(color)
        var resolved = dynamic
        appearance.performAsCurrentDrawingAppearance {
            resolved = dynamic.usingColorSpace(.sRGB) ?? dynamic
        }
        let srgb = resolved.usingColorSpace(.sRGB) ?? resolved
        let r = Int((srgb.redComponent * 255).rounded())
        let g = Int((srgb.greenComponent * 255).rounded())
        let b = Int((srgb.blueComponent * 255).rounded())
        let clamp: (Int) -> Int = { Swift.max(0, Swift.min(255, $0)) }
        return String(format: "#%02x%02x%02x", clamp(r), clamp(g), clamp(b))
    }

    // MARK: - Numeric formatting

    /// Formats a CGFloat token as a CSS `px` value, dropping a trailing
    /// `.0` so integral tokens read as `12px`, not `12.0px`.
    private static func px(_ value: CGFloat) -> String {
        if value == value.rounded() {
            return "\(Int(value))px"
        }
        return "\(value)px"
    }
}

// MARK: - String trimming helper

private extension String {
    /// Drops a single trailing newline so interpolated blocks don't
    /// leave a blank line before the closing brace.
    func trimmingTrailingNewline() -> String {
        hasSuffix("\n") ? String(dropLast()) : self
    }
}
