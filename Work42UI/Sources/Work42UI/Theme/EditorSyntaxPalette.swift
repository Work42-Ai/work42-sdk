// EditorSyntaxPalette.swift — the ONE syntax-colour palette shared by the
// native code-file editor and artifact/markdown code highlighting (highlight.js),
// so a code block renders identically in both surfaces.
//
// The base is the app's One Dark / One Light editor palette. A theme may override
// any field via its per-mode `editor:` block (`ThemeEditorTokenSet`). Both the
// native editor (`SourceEditorThemes.stable`, which builds `NSColor`s from
// `baseDark`/`baseLight`) and `CanvasTheme.css()` (which emits `--w42-syntax-*`
// custom properties from `resolvedHex`) resolve through HERE — so the two
// surfaces never drift. Edit a syntax colour in ONE place.
//
// Everything is `nonisolated` — this is pure, Sendable data read from both
// nonisolated (`SourceEditorThemes.stable`) and main-actor contexts. Work42UI
// uses `@MainActor` default isolation, so the annotations are required (mirrors
// `ThemeEditorTokenSet`).

import Foundation

public enum EditorSyntaxPalette {

    /// A syntax colour set as 24-bit RGB (`0xRRGGBB`).
    public struct Colors: Sendable {
        public nonisolated let keyword: UInt32
        public nonisolated let function: UInt32
        public nonisolated let type: UInt32
        public nonisolated let attribute: UInt32
        public nonisolated let variable: UInt32
        public nonisolated let number: UInt32
        public nonisolated let string: UInt32
        public nonisolated let comment: UInt32
        public nonisolated let text: UInt32

        public nonisolated init(keyword: UInt32, function: UInt32, type: UInt32, attribute: UInt32,
                                variable: UInt32, number: UInt32, string: UInt32, comment: UInt32,
                                text: UInt32) {
            self.keyword = keyword; self.function = function; self.type = type
            self.attribute = attribute; self.variable = variable; self.number = number
            self.string = string; self.comment = comment; self.text = text
        }
    }

    /// One Dark base (the editor's default dark syntax palette).
    public nonisolated static let baseDark = Colors(
        keyword: 0xC678DD, function: 0x61AFEF, type: 0xE5C07B, attribute: 0x56B6C2,
        variable: 0xE06C75, number: 0xD19A66, string: 0x98C379, comment: 0x5C6370,
        text: 0xABB2BF
    )

    /// One Light base (the editor's default light syntax palette).
    public nonisolated static let baseLight = Colors(
        keyword: 0xA626A4, function: 0x4078F2, type: 0xC18401, attribute: 0x0184BC,
        variable: 0xE45649, number: 0x986801, string: 0x50A14F, comment: 0xA0A1A7,
        text: 0x383A42
    )

    /// `(cssVarSuffix, "#RRGGBB")` pairs for a mode — the base overlaid with the
    /// active theme's `editor:` overrides. `CanvasTheme.css()` emits these as
    /// `--w42-<suffix>` custom properties (light in `:root`, dark under the
    /// dark media query), which `highlightCSS` maps every hljs scope onto.
    public nonisolated static func resolvedHex(dark: Bool) -> [(name: String, hex: String)] {
        let base = dark ? baseDark : baseLight
        let over = dark ? ThemeRuntime.current.spec.dark.editor
                        : ThemeRuntime.current.spec.light.editor
        func pick(_ override: String?, _ fallback: UInt32) -> String {
            if let override, let norm = normalizeHex(override) { return norm }
            return hexString(fallback)
        }
        return [
            ("syntax-keyword",   pick(over?.keywords,   base.keyword)),
            ("syntax-function",  pick(over?.commands,   base.function)),
            ("syntax-type",      pick(over?.types,      base.type)),
            ("syntax-attribute", pick(over?.attributes, base.attribute)),
            ("syntax-variable",  pick(over?.variables,  base.variable)),
            ("syntax-number",    pick(over?.numbers,    base.number)),
            ("syntax-string",    pick(over?.strings,    base.string)),
            ("syntax-comment",   pick(over?.comments,   base.comment)),
            ("syntax-text",      pick(over?.text,       base.text)),
        ]
    }

    nonisolated private static func hexString(_ rgb: UInt32) -> String {
        String(format: "#%06X", Int(rgb & 0xFFFFFF))
    }

    nonisolated private static func normalizeHex(_ s: String) -> String? {
        let body = s.hasPrefix("#") ? String(s.dropFirst()) : s
        guard body.count == 6, UInt32(body, radix: 16) != nil else { return nil }
        return "#" + body.uppercased()
    }
}
