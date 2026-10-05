// ThemeSpec.swift — feat/theme-customization.1
//
// The theme value model: named palette + per-mode token sets.
// Foundation-only (no AppKit/SwiftUI) so this module is usable from
// both the Work42App target and the work42 CLI target.
//
// Concurrency: with `defaultIsolation(MainActor.self)` in the package
// settings, all unannotated code defaults to @MainActor. For these pure
// value types to be usable from nonisolated contexts (especially
// ThemeRuntime.current, read on the draw path from NSColor providers),
// we explicitly mark their initializers and static constants as
// `nonisolated`. Equatable/Sendable conformances are provided explicitly
// so the `==` operators are nonisolated too.
//
// Key design decisions:
//  - `ThemeAccent.system` is valid ONLY for the built-in System palette
//    (defined in code, never on disk). User/bundled YAML files must use
//    `.hex(_)`. ThemeStore enforces this at load time.
//  - Five independent surface tokens: backdrop (L0), sidebar (left rail),
//    titlebar (top chrome), surface (L1 card), elevated (L2 popover).
//  - System palette sets sidebar and titlebar equal to backdrop — reproducing
//    today's single-fill look so AC1 (zero visual change) holds.

import Foundation

// MARK: - ThemeAccent

/// The accent value for one mode of a theme.
///
/// Only the built-in System palette uses `.system`; all other themes
/// (including bundled ocean/sunset) pin an explicit hex value (AC8).
public enum ThemeAccent: Sendable {
    /// Follow the macOS system accent color (`Color.accentColor`).
    /// Valid only for the built-in System palette — never in YAML files.
    case system
    /// A pinned hex color string, e.g. `"#0d9488"`. Lower-cased, `#`-prefixed.
    case hex(String)
}

// Explicit nonisolated Equatable so comparisons work from any actor context,
// including nonisolated ThemeStore.list() and test assertions.
extension ThemeAccent: Equatable {
    public nonisolated static func == (lhs: ThemeAccent, rhs: ThemeAccent) -> Bool {
        switch (lhs, rhs) {
        case (.system, .system):            return true
        case (.hex(let a), .hex(let b)):    return a == b
        default:                            return false
        }
    }
}

// MARK: - ThemeMode

/// The light/dark mode preference for the active theme.
public enum ThemeMode: String, Sendable, CaseIterable {
    /// Force light appearance regardless of the system setting.
    case light
    /// Force dark appearance regardless of the system setting.
    case dark
    /// Follow the system appearance (default).
    case auto
}

extension ThemeMode: Equatable {
    public nonisolated static func == (lhs: ThemeMode, rhs: ThemeMode) -> Bool {
        lhs.rawValue == rhs.rawValue
    }
}

// Codable conformance for ThemeMode (used by ThemeStore.Selection JSON).
// Explicit raw-value codec so it's stable and works from any context.
extension ThemeMode: Codable {
    public nonisolated init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = ThemeMode(rawValue: raw) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown ThemeMode '\(raw)'. Expected: light, dark, auto"
                )
            )
        }
        self = value
    }

    public nonisolated func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - ThemeEditorTokenSet

/// Optional per-mode editor tokens (feat/theme-customization.9).
///
/// The source-editor tile has its own token world (CodeEditSourceEditor's
/// `EditorTheme`): editor chrome (background, line highlight, selection,
/// cursor, base text, invisibles) plus the syntax palette. A theme MAY
/// customize any subset of them under a per-mode `editor:` block — every
/// field is optional, and absent fields fall back to the app's stable
/// One Dark / One Light editor palette, so a theme without the block (or
/// with a partial one) renders the editor exactly as before.
///
/// All values are validated `#rrggbb` hex strings.
public struct ThemeEditorTokenSet: Sendable {
    // Editor chrome
    public nonisolated let background: String?
    public nonisolated let lineHighlight: String?
    public nonisolated let selection: String?
    public nonisolated let cursor: String?
    public nonisolated let text: String?
    public nonisolated let invisibles: String?
    // Syntax palette
    public nonisolated let keywords: String?
    public nonisolated let commands: String?
    public nonisolated let types: String?
    public nonisolated let attributes: String?
    public nonisolated let variables: String?
    public nonisolated let values: String?
    public nonisolated let numbers: String?
    public nonisolated let strings: String?
    public nonisolated let characters: String?
    public nonisolated let comments: String?

    public nonisolated init(
        background: String? = nil,
        lineHighlight: String? = nil,
        selection: String? = nil,
        cursor: String? = nil,
        text: String? = nil,
        invisibles: String? = nil,
        keywords: String? = nil,
        commands: String? = nil,
        types: String? = nil,
        attributes: String? = nil,
        variables: String? = nil,
        values: String? = nil,
        numbers: String? = nil,
        strings: String? = nil,
        characters: String? = nil,
        comments: String? = nil
    ) {
        self.background = background
        self.lineHighlight = lineHighlight
        self.selection = selection
        self.cursor = cursor
        self.text = text
        self.invisibles = invisibles
        self.keywords = keywords
        self.commands = commands
        self.types = types
        self.attributes = attributes
        self.variables = variables
        self.values = values
        self.numbers = numbers
        self.strings = strings
        self.characters = characters
        self.comments = comments
    }
}

extension ThemeEditorTokenSet: Equatable {
    public nonisolated static func == (lhs: ThemeEditorTokenSet, rhs: ThemeEditorTokenSet) -> Bool {
        lhs.background    == rhs.background    &&
        lhs.lineHighlight == rhs.lineHighlight &&
        lhs.selection     == rhs.selection     &&
        lhs.cursor        == rhs.cursor        &&
        lhs.text          == rhs.text          &&
        lhs.invisibles    == rhs.invisibles    &&
        lhs.keywords      == rhs.keywords      &&
        lhs.commands      == rhs.commands      &&
        lhs.types         == rhs.types         &&
        lhs.attributes    == rhs.attributes    &&
        lhs.variables     == rhs.variables     &&
        lhs.values        == rhs.values        &&
        lhs.numbers       == rhs.numbers       &&
        lhs.strings       == rhs.strings       &&
        lhs.characters    == rhs.characters    &&
        lhs.comments      == rhs.comments
    }
}

// MARK: - ThemeTokenSet

/// The resolved color tokens for one mode (light or dark) of a theme.
///
/// All surface/text values are hex strings (`#rrggbb`, lower-cased).
/// `accent` may be `.system` for the built-in System palette only.
public struct ThemeTokenSet: Sendable {
    // Accent
    /// Accent color — explicit hex, or `.system` for the built-in System palette.
    public nonisolated let accent: ThemeAccent
    // Surfaces (five independent tiers)
    /// L0 — the page backdrop behind everything.
    public nonisolated let backdrop: String
    /// The collapsible left rail (sidebar column).
    public nonisolated let sidebar: String
    /// The top chrome bar (titlebar strip).
    public nonisolated let titlebar: String
    /// L1 — card / surface above the page.
    public nonisolated let surface: String
    /// L2 — popover / interactive surface (input fields, raised menus).
    public nonisolated let elevated: String
    // Text
    /// Near-black on light, near-white on dark — body labels, headings.
    public nonisolated let textPrimary: String
    /// Supporting labels, inactive rows, breadcrumbs.
    public nonisolated let textSecondary: String
    /// Section eyebrows, placeholders, least-important metadata.
    public nonisolated let textTertiary: String
    // Editor (optional)
    /// Optional editor-token overrides for this mode. Absent (or partially
    /// filled) → the stable One Dark / One Light editor palette fills the
    /// gaps at resolution time.
    public nonisolated let editor: ThemeEditorTokenSet?

    public nonisolated init(
        accent: ThemeAccent,
        backdrop: String,
        sidebar: String,
        titlebar: String,
        surface: String,
        elevated: String,
        textPrimary: String,
        textSecondary: String,
        textTertiary: String,
        editor: ThemeEditorTokenSet? = nil
    ) {
        self.accent = accent
        self.backdrop = backdrop
        self.sidebar = sidebar
        self.titlebar = titlebar
        self.surface = surface
        self.elevated = elevated
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.textTertiary = textTertiary
        self.editor = editor
    }
}

extension ThemeTokenSet: Equatable {
    public nonisolated static func == (lhs: ThemeTokenSet, rhs: ThemeTokenSet) -> Bool {
        lhs.accent        == rhs.accent        &&
        lhs.backdrop      == rhs.backdrop      &&
        lhs.sidebar       == rhs.sidebar       &&
        lhs.titlebar      == rhs.titlebar      &&
        lhs.surface       == rhs.surface       &&
        lhs.elevated      == rhs.elevated      &&
        lhs.textPrimary   == rhs.textPrimary   &&
        lhs.textSecondary == rhs.textSecondary &&
        lhs.textTertiary  == rhs.textTertiary  &&
        lhs.editor        == rhs.editor
    }
}

// MARK: - ThemeSpec

/// A named theme: human-readable name plus per-mode token sets.
///
/// Value type — cheap to copy, safe to pass across actor boundaries.
public struct ThemeSpec: Sendable {
    /// Human-readable name shown in the command palette theme picker.
    public nonisolated let name: String
    /// Tokens to use when rendering in light mode.
    public nonisolated let light: ThemeTokenSet
    /// Tokens to use when rendering in dark mode.
    public nonisolated let dark: ThemeTokenSet

    public nonisolated init(name: String, light: ThemeTokenSet, dark: ThemeTokenSet) {
        self.name = name
        self.light = light
        self.dark = dark
    }

    // MARK: - Built-in System palette

    /// The built-in System palette.
    ///
    /// Hex values are sourced directly from `DesignTokens.swift`'s `DT.adaptive`
    /// calls (backdrop/surface/elevated/text*). `accent` is `.system` so it
    /// follows the macOS system accent color. `sidebar` and `titlebar` are set
    /// equal to `backdrop` in both modes, reproducing the current single-fill
    /// look where one `DT.backdrop` color paints the entire window — including
    /// the toolbar/titlebar strip (exposed via `toolbarBackgroundVisibility`)
    /// and the sidebar column (which inherits the window fill). This ensures
    /// AC1: zero visual change on first launch before the user opts in to a
    /// different theme.
    ///
    /// This palette is defined in code and never written to disk.
    ///
    /// Marked `nonisolated` so it is accessible from any actor context,
    /// including nonisolated draw-path closures in NSColor dynamic providers.
    public nonisolated static let system = ThemeSpec(
        name: "System",
        light: ThemeTokenSet(
            accent:        .system,
            backdrop:      "#f5f5f7",   // DT: adaptive(light: 0xF5F5F7, ...)
            sidebar:       "#f5f5f7",   // same as backdrop — AC1 zero-change
            titlebar:      "#f5f5f7",   // same as backdrop — AC1 zero-change
            surface:       "#ffffff",   // DT: adaptive(light: 0xFFFFFF, ...)
            elevated:      "#ffffff",   // DT: adaptive(light: 0xFFFFFF, ...)
            textPrimary:   "#18181a",   // DT: adaptive(light: 0x18181A, ...)
            textSecondary: "#3d3d45",   // DT: adaptive(light: 0x3D3D45, ...)
            textTertiary:  "#6b6b75"    // DT: adaptive(light: 0x6B6B75, ...)
        ),
        dark: ThemeTokenSet(
            accent:        .system,
            backdrop:      "#09090b",   // DT: adaptive(..., dark: 0x09090B)
            sidebar:       "#09090b",   // same as backdrop — AC1 zero-change
            titlebar:      "#09090b",   // same as backdrop — AC1 zero-change
            surface:       "#1a1a1d",   // DT: adaptive(..., dark: 0x1A1A1D)
            elevated:      "#222226",   // DT: adaptive(..., dark: 0x222226)
            textPrimary:   "#f2f2f5",   // DT: adaptive(..., dark: 0xF2F2F5)
            textSecondary: "#c8c8d0",   // DT: adaptive(..., dark: 0xC8C8D0)
            textTertiary:  "#9696a0"    // DT: adaptive(..., dark: 0x9696A0)
        )
    )
}

extension ThemeSpec: Equatable {
    public nonisolated static func == (lhs: ThemeSpec, rhs: ThemeSpec) -> Bool {
        lhs.name == rhs.name &&
        lhs.light == rhs.light &&
        lhs.dark  == rhs.dark
    }
}

// MARK: - ThemeSnapshot

/// The process-wide active state: a `ThemeSpec` plus the user's mode preference.
///
/// Held by `ThemeRuntime`; read on every draw call so it must be a cheap
/// value copy. The DT dynamic providers receive the NSAppearance and use
/// that to resolve `auto` mode at draw time.
public struct ThemeSnapshot: Sendable {
    public nonisolated let spec: ThemeSpec
    public nonisolated let mode: ThemeMode

    public nonisolated init(spec: ThemeSpec, mode: ThemeMode) {
        self.spec = spec
        self.mode = mode
    }

    /// Default: System palette + auto mode. What the app uses before any
    /// user selection is recorded.
    ///
    /// Marked `nonisolated` so `ThemeRuntime`'s lock container can reference
    /// it from any actor context, including draw callbacks and the
    /// `_Holder.init()` in a nonisolated context.
    public nonisolated static let `default` = ThemeSnapshot(spec: .system, mode: .auto)
}

extension ThemeSnapshot: Equatable {
    public nonisolated static func == (lhs: ThemeSnapshot, rhs: ThemeSnapshot) -> Bool {
        lhs.spec == rhs.spec && lhs.mode == rhs.mode
    }
}
