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
            // Chip surface (Title Bar Label): DT's translucent fill + hairline.
            ("chip-fill",       DT.chipFill),
            ("chip-stroke",     DT.chipStroke),
            // Accent-hue text for tint-on-tint surfaces, and the readable
            // foreground for solid accent fills (replaces a hard-coded white).
            ("accent-fg",       DT.accentForeground),
            ("on-accent",       DT.onAccent),
        ]
    }

    /// One color token with its explicit light and dark values, each a
    /// `#rrggbb` (opaque) or `#rrggbbaa` (translucent) hex string.
    struct ColorToken: Equatable {
        let name: String
        let light: String
        let dark: String
    }

    /// Web Kit tokens (WOR-151) whose values are fixed in the Figma Work42
    /// Design System ("Work42 · Color": Label, Fill, Table, Field, Overlay,
    /// Glass and Material groups). They mirror the Apple macOS 26/27 kit
    /// values the Figma components are built from, so they are literals here
    /// by design: there is no native `DT` counterpart to read. Order is stable
    /// so `css()` stays deterministic.
    static let kitColorTokens: [ColorToken] = [
        // Labels (kit Labels/Primary·Secondary·Tertiary)
        ColorToken(name: "label-primary",   light: "#000000d9", dark: "#ffffffd9"),
        ColorToken(name: "label-secondary", light: "#00000080", dark: "#ffffff8c"),
        ColorToken(name: "label-tertiary",  light: "#00000040", dark: "#ffffff40"),
        // Fills (kit Fills - Opaque)
        ColorToken(name: "fill-primary",    light: "#0000001a", dark: "#ffffff1a"),
        ColorToken(name: "fill-secondary",  light: "#00000014", dark: "#ffffff14"),
        ColorToken(name: "fill-tertiary",   light: "#0000000d", dark: "#ffffff0d"),
        ColorToken(name: "fill-quaternary", light: "#00000008", dark: "#ffffff08"),
        ColorToken(name: "fill-quinary",    light: "#00000005", dark: "#ffffff05"),
        // Table and field (kit Tables, _Input Fields)
        ColorToken(name: "separator",             light: "#0000001a", dark: "#ffffff1a"),
        ColorToken(name: "row-alt",               light: "#0000000d", dark: "#ffffff0d"),
        ColorToken(name: "row-selected",          light: "#0165e2",   dark: "#0158d2"),
        ColorToken(name: "row-selected-inactive", light: "#00000024", dark: "#ffffff2e"),
        ColorToken(name: "field-bg",              light: "#ffffff",   dark: "#1e1e1e"),
        ColorToken(name: "field-ring",            light: "#00000014", dark: "#ffffff0a"),
        ColorToken(name: "overlay",               light: "#ababab99", dark: "#1717179e"),
        // 42 capsule: light = brand-tile blue #C3EEFF at 33%, dark = palest blue #F0FBFF
        // at 75%; the label is black in both.
        ColorToken(name: "capsule-tint",          light: "#c3eeff54", dark: "#f0fbffbf"),
        ColorToken(name: "capsule-fg",            light: "#000000",   dark: "#000000"),
        // Liquid Glass (kit Liquid Glass - Medium / Large)
        ColorToken(name: "glass-fill",   light: "#ffffffb3", dark: "#1a1a1ab8"),
        ColorToken(name: "glass-tint",   light: "#bfbfbf1a", dark: "#00000000"),
        ColorToken(name: "glass-shadow", light: "#00000040", dark: "#00000073"),
        ColorToken(name: "glass-rim",    light: "#00000024", dark: "#ffffff1f"),
        ColorToken(name: "glass-edge",   light: "#0000001a", dark: "#ffffff14"),
        ColorToken(name: "glass-glow",   light: "#ffffff29", dark: "#ffffff1a"),
        // Materials (kit Materials, ultra thin to ultra thick)
        ColorToken(name: "material-ultra-thin",  light: "#f6f6f65c", dark: "#0000001a"),
        ColorToken(name: "material-thin",        light: "#f6f6f67a", dark: "#00000033"),
        ColorToken(name: "material-medium",      light: "#f6f6f699", dark: "#0000004a"),
        ColorToken(name: "material-thick",       light: "#f6f6f6b8", dark: "#00000066"),
        ColorToken(name: "material-ultra-thick", light: "#ececece0", dark: "#00000080"),
    ]

    /// Every color token (adaptive DT tokens, chip foregrounds, Web Kit
    /// literals) with its light and dark hex, in emission order. The single
    /// source for `css()` (bakes both) and `currentColorTokens()` (the live
    /// push), so the two can never drift.
    @MainActor
    static func resolvedColorTokens(light: NSAppearance, dark: NSAppearance) -> [ColorToken] {
        var out: [ColorToken] = colorTokenList.map {
            ColorToken(name: $0.name,
                       light: hex($0.color, under: light),
                       dark: hex($0.color, under: dark))
        }
        // Chip foregrounds follow DT.resolveChipTint (the native Title Bar
        // Label rule), evaluated per scheme so the result is deterministic.
        let chipTints: [(name: String, tint: Color)] = [
            ("chip-fg-success", DT.green),
            ("chip-fg-warning", DT.orange),
            ("chip-fg-failure", DT.red),
            ("chip-fg-accent",  DT.systemAccent),
        ]
        for entry in chipTints {
            out.append(ColorToken(
                name: entry.name,
                light: chipForegroundHex(entry.tint, appearance: light, scheme: .light),
                dark: chipForegroundHex(entry.tint, appearance: dark, scheme: .dark)))
        }
        out.append(contentsOf: kitColorTokens)
        return out
    }

    /// `DT.resolveChipTint(...).foreground` for one scheme, resolved to hex
    /// under the matching appearance (the formula reads the tint's live
    /// NSColor, so it has to run inside that appearance).
    @MainActor
    private static func chipForegroundHex(
        _ tint: Color, appearance: NSAppearance, scheme: ColorScheme
    ) -> String {
        var result = "#000000"
        appearance.performAsCurrentDrawingAppearance {
            let foreground = DT.resolveChipTint(tint, colorScheme: scheme).foreground
            result = hex(foreground, under: appearance)
        }
        return result
    }

    /// The color tokens resolved under the CURRENTLY-active app appearance,
    /// as `name → "#rrggbb"` (or `"#rrggbbaa"` for translucent tokens). Pushed
    /// into an open artifact via `window.__w42.theme.apply(...)` on a theme
    /// change so the `--w42-*` vars re-resolve LIVE, with no reload (AC-C5).
    /// Only colors change with the theme — spacing / radii / fonts are
    /// appearance-independent.
    @MainActor
    public static func currentColorTokens() -> [String: String] {
        let appearance = NSApplication.shared.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let light = NSAppearance(named: .aqua) ?? appearance
        let dark = NSAppearance(named: .darkAqua) ?? appearance
        var out: [String: String] = [:]
        for token in resolvedColorTokens(light: light, dark: dark) {
            out[token.name] = isDark ? token.dark : token.light
        }
        // Push the shared syntax palette too, so a code block in an open artifact
        // recolours live on a theme change exactly like the editor — not just on
        // reload / OS light-dark flip.
        for entry in EditorSyntaxPalette.resolvedHex(dark: isDark) {
            out[entry.name] = entry.hex
        }
        return out
    }

    @MainActor
    public static func css() -> String {
        let light = NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing()
        let dark = NSAppearance(named: .darkAqua) ?? light

        // Color tokens: light + dark hex per token (shared with the live
        // theme push in `currentColorTokens()`, so the two stay in lock-step).
        let colorTokens = Self.resolvedColorTokens(light: light, dark: dark)

        // Non-color tokens are appearance-independent — emitted once in
        // `:root`. Spacing / radii / font-size values are CSS px.
        let spacingTokens: [(name: String, value: CGFloat)] = [
            ("s4",  DT.s4),  ("s8",  DT.s8),  ("s12", DT.s12), ("s16", DT.s16),
            ("s20", DT.s20), ("s24", DT.s24), ("s32", DT.s32), ("s40", DT.s40),
        ]

        let radiusTokens: [(name: String, value: CGFloat)] = [
            ("r-window", DT.rWindow), ("r-panel", DT.rPanel), ("r-card", DT.rCard),
            ("r-button", DT.rButton), ("r-input", DT.rInput), ("r-pill", DT.rPill),
            // Liquid Glass Large corner (popover, menu, dialog, sheet, hero).
            ("r-glass-lg", 34),
        ]

        // Control, row and glass metrics from the Web Kit Figma ("Work42 ·
        // Spacing"): 24 pt controls and table rows, 36 pt Action Button
        // capsules, 28 pt table header, 16 pt glass blur, 60 pt materials blur,
        // 3.5 pt focus ring.
        let sizeTokens: [(name: String, value: CGFloat)] = [
            ("h-control", 24), ("h-action", 36), ("h-row", 20), ("h-table-header", 28),
            ("glass-blur", 16), ("material-blur", 60), ("focus-ring", 3.5),
        ]

        let fontTokens: [(name: String, value: CGFloat)] = [
            ("f9",  DT.f9),  ("f10", DT.f10), ("f11", DT.f11), ("f12", DT.f12),
            ("f13", DT.f13), ("f14", DT.f14), ("f15", DT.f15), ("f17", DT.f17),
            ("f22", DT.f22), ("f30", DT.f30), ("f32", DT.f32),
        ]

        // System font stack mirroring macOS / the app's `-apple-system`.
        let fontFamily = "-apple-system, BlinkMacSystemFont, \"SF Pro Text\", "
            + "\"Helvetica Neue\", Helvetica, Arial, sans-serif"

        // Monospace stack for code, inline code and keys.
        let fontMono = "ui-monospace, \"SF Mono\", Menlo, Monaco, \"Courier New\", monospace"

        // --- :root (light values + appearance-independent tokens) ---
        var root = ""
        root += "  /* Colors (light) */\n"
        for token in colorTokens {
            root += "  --w42-\(token.name): \(token.light);\n"
        }
        root += "\n  /* Typography */\n"
        root += "  --w42-font-family: \(fontFamily);\n"
        root += "  --w42-font-mono: \(fontMono);\n"
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
        root += "\n  /* Controls, rows and glass */\n"
        for token in sizeTokens {
            root += "  --w42-\(token.name): \(px(token.value));\n"
        }
        // Motion: one spring and a short/base/slow scale shared by every family,
        // so the kit moves with a single feel. `prefers-reduced-motion` collapses
        // the durations in w42-components.css.
        root += "\n  /* Motion */\n"
        root += "  --w42-ease: cubic-bezier(0.2, 0.8, 0.2, 1);\n"
        root += "  --w42-spring: linear(0, 0.009, 0.035 2.1%, 0.141, 0.281 6.7%, 0.723 12.9%, 0.938 16.7%, "
            + "1.017, 1.077, 1.121, 1.149 24.3%, 1.159, 1.163, 1.161, 1.154 29.9%, 1.129 32.8%, "
            + "1.051 39.6%, 1.017 43.1%, 0.991, 0.977 51%, 0.974 53.8%, 0.975 57.1%, 0.997 69.8%, "
            + "1.003 76.9%, 1);\n"
        root += "  --w42-dur-fast: 140ms;\n  --w42-dur-base: 240ms;\n  --w42-dur-slow: 420ms;\n"
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
            darkRoot += "    --w42-\(token.name): \(token.dark);\n"
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
          /* Mirrors the native chat text (MarkdownUI .work42 theme): 16pt body,
             6pt extra line spacing (about 1.55), system smoothing. */
          font-size: var(--w42-f14);
          line-height: 1.55;
        }

        a {
          color: var(--w42-primary);
          text-decoration: none;
        }

        a:hover {
          text-decoration: underline;
        }

        h1, h2, h3, h4, h5, h6 {
          margin: var(--w42-s16) 0 var(--w42-s4);
          line-height: 1.25;
          color: var(--w42-text-primary);
        }

        /* The chat heading scale: 24 bold, then 21 / 18 / 16 semibold. */
        h1 { font-size: 24px; font-weight: 700; margin-bottom: var(--w42-s8); }
        h2 { font-size: 21px; font-weight: 600; }
        h3 { font-size: 18px; font-weight: 600; margin-top: var(--w42-s12); }
        h4 { font-size: 16px; font-weight: 600; margin-top: var(--w42-s8); margin-bottom: 0; }

        /* Body paragraphs are primary text, as in chat (not the secondary grey). */
        p {
          margin: 0 0 var(--w42-s12);
          color: var(--w42-text-primary);
        }

        small {
          font-size: var(--w42-f11);
          color: var(--w42-text-tertiary);
        }

        code, pre {
          font-family: ui-monospace, "SF Mono", Menlo, Monaco, "Courier New", monospace;
          font-size: 14px;
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
          margin: var(--w42-s12) 0;
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
        let a = Int((srgb.alphaComponent * 255).rounded())
        let clamp: (Int) -> Int = { Swift.max(0, Swift.min(255, $0)) }
        // Opaque colors stay `#rrggbb`; translucent ones (chip fills, glass) keep
        // their alpha as `#rrggbbaa` so the web token matches the native one.
        if clamp(a) < 255 {
            return String(format: "#%02x%02x%02x%02x", clamp(r), clamp(g), clamp(b), clamp(a))
        }
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
