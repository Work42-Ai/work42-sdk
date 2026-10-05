// ThemeStore.swift — feat/theme-customization.1
//
// Theme directory listing, bundled-palette seeding, and selection.json
// read/write — all purely filesystem operations (Foundation only).
//
// Contract:
//  - `list(in:)` — System palette + every parseable *.yaml in the dir,
//    alphabetical by filename. File-based themes that use `accent: system`
//    are silently skipped (AC8: only the built-in System palette may do that).
//  - `seedBundledIfAbsent(in:)` — writes ocean.yaml and sunset.yaml ONLY
//    when the file is absent; never clobbers user edits (AC2).
//  - `readSelection(from:)` / `writeSelection(_:to:)` — selection.json
//    round-trip. Writes are ATOMIC (temp-file then rename via Data.write
//    with .atomic) so CLI + app + editor writers never see a torn file.
//
// The `in:` / `from:` / `to:` overloads default to `~/.work42/themes/`
// and `~/.work42/themes/selection.json` for production use. Pass a temp
// URL in tests to avoid touching real user data.
//
// Note: Work42UI does not depend on Work42Core, so we derive the default
// themes path using FileManager directly rather than Work42Paths.

import Foundation

// MARK: - ThemeStore

/// Manages the themes directory, bundled-palette seeding, and selection
/// persistence.
///
/// Not annotated `nonisolated` — these methods do filesystem I/O and are
/// only called from app startup, `FileWatcher` callbacks, or CLI commands,
/// all of which run on the main actor. ThemeRuntime (the hot-path singleton)
/// is the piece that MUST be nonisolated; ThemeStore is not on the draw path.
public enum ThemeStore {

    // MARK: - Paths

    /// Default themes directory: `~/.work42/themes/`.
    public static var defaultThemesDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".work42/themes", isDirectory: true)
    }

    /// Default selection file: `~/.work42/themes/selection.json`.
    public static var defaultSelectionURL: URL {
        defaultThemesDir.appendingPathComponent("selection.json")
    }

    // MARK: - LoadedTheme

    /// A theme that has been loaded and is ready for use.
    public struct LoadedTheme: Sendable, Equatable {
        /// Identifier used in `selection.json` and the CLI.
        /// The built-in System palette uses `"system"`;
        /// file-based themes use the YAML filename without the `.yaml` extension.
        public let slug: String
        /// The parsed theme specification.
        public let spec: ThemeSpec
        /// `true` for the built-in System palette (not backed by a file).
        public let isBuiltIn: Bool

        public init(slug: String, spec: ThemeSpec, isBuiltIn: Bool) {
            self.slug = slug
            self.spec = spec
            self.isBuiltIn = isBuiltIn
        }
    }

    // MARK: - List

    /// Returns all available themes: built-in System first, then every
    /// parseable `.yaml` in `dir`, sorted alphabetically by filename.
    ///
    /// Themes that fail to parse are silently skipped — this prevents one
    /// broken user-created file from hiding all other themes. The ThemeController
    /// (app-layer) independently watches for parse errors and surfaces them to the user.
    ///
    /// File-based themes with `accent: .system` (which violates AC8) are also
    /// silently skipped; only the built-in code-defined System palette may use that sentinel.
    ///
    /// - Parameter dir: The directory to scan. Defaults to `~/.work42/themes/`.
    public static func list(in dir: URL = defaultThemesDir) -> [LoadedTheme] {
        var themes = [LoadedTheme(slug: "system", spec: .system, isBuiltIn: true)]

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: .skipsHiddenFiles
        ) else {
            return themes
        }

        let yamlURLs = entries
            .filter { $0.pathExtension.lowercased() == "yaml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for url in yamlURLs {
            let slug = url.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: url),
                  let spec = try? ThemeYAML.decode(data: data) else {
                // Parse failure — skip silently.
                continue
            }
            // AC8: file-based themes may not use `accent: system`.
            if spec.light.accent == .system || spec.dark.accent == .system {
                continue
            }
            themes.append(LoadedTheme(slug: slug, spec: spec, isBuiltIn: false))
        }

        return themes
    }

    // MARK: - Seed

    /// Writes the bundled palettes (`ocean.yaml`, `sunset.yaml`) to `dir`
    /// only when a file of that name is absent — never overwrites user edits (AC2).
    ///
    /// Also creates the directory if it doesn't exist yet.
    ///
    /// - Parameter dir: The themes directory. Defaults to `~/.work42/themes/`.
    /// - Throws: If the directory cannot be created or a file cannot be written.
    public static func seedBundledIfAbsent(in dir: URL = defaultThemesDir) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        for (filename, yaml) in bundledPalettes {
            let url = dir.appendingPathComponent(filename)
            guard !fm.fileExists(atPath: url.path) else {
                continue  // AC2: never clobber an existing file
            }
            try yaml.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Selection

    /// The persisted theme selection (`~/.work42/themes/selection.json`).
    public struct Selection: Sendable, Equatable, Codable {
        /// Slug of the active theme. `"system"` for the built-in System palette.
        public let theme: String
        /// Light/dark/auto mode preference.
        public let mode: ThemeMode

        public init(theme: String, mode: ThemeMode) {
            self.theme = theme
            self.mode = mode
        }
    }

    /// Reads the current selection from `file` (or the default selection URL).
    /// Returns `nil` when the file is absent or cannot be parsed — callers
    /// should fall back to the System palette + auto mode in that case.
    ///
    /// - Parameter file: URL of the selection file. Defaults to `~/.work42/themes/selection.json`.
    public static func readSelection(from file: URL? = nil) -> Selection? {
        let url = file ?? defaultSelectionURL
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Selection.self, from: data)
    }

    /// Writes a selection atomically to `file` (or the default selection URL).
    ///
    /// Uses `Data.write(_:options: .atomic)` which writes to a temp file then
    /// renames, making it safe against concurrent CLI + app + editor writers (no
    /// torn reads). The parent directory is created if absent.
    ///
    /// - Parameters:
    ///   - selection: The selection to persist.
    ///   - file: URL of the selection file. Defaults to `~/.work42/themes/selection.json`.
    /// - Throws: On JSON encoding or file-write failure.
    public static func writeSelection(_ selection: Selection, to file: URL? = nil) throws {
        let url = file ?? defaultSelectionURL
        // Ensure the parent directory exists (e.g. on first launch before seed).
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(selection)
        // .atomic = write to a temp file, then rename — safe for concurrent readers.
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Create

    /// Creates a new theme file from `spec`, with a collision-safe
    /// auto-generated name/slug ("Theme 2" → `theme-2.yaml`, then
    /// "Theme 3", …). Used by the command palette's "Create New Theme"
    /// row: the caller passes the ACTIVE theme's spec (accent already
    /// pinned to explicit hex — a file-based theme may not carry
    /// `accent: system`, AC8) and gets back the written file's URL to
    /// open in the user's editor. No naming prompt, no dialog (spec:
    /// creation is fire-and-open).
    ///
    /// - Parameters:
    ///   - spec: Token values for the new theme; its `name` is replaced
    ///     by the auto-generated one.
    ///   - dir: Themes directory override for tests. Defaults to
    ///     `~/.work42/themes/`.
    /// - Returns: The new theme's slug and file URL.
    public static func createTheme(
        from spec: ThemeSpec,
        in dir: URL? = nil
    ) throws -> (slug: String, url: URL) {
        let themesDir = dir ?? defaultThemesDir
        try FileManager.default.createDirectory(
            at: themesDir, withIntermediateDirectories: true)

        // First free "theme-N" slug, N starting at 2 ("Theme 1" reads odd
        // when System/Ocean/Sunset already exist).
        var n = 2
        var url = themesDir.appendingPathComponent("theme-\(n).yaml")
        while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            url = themesDir.appendingPathComponent("theme-\(n).yaml")
        }

        let named = ThemeSpec(name: "Theme \(n)", light: spec.light, dark: spec.dark)
        try ThemeYAML.encode(named).write(to: url, atomically: true, encoding: .utf8)
        return ("theme-\(n)", url)
    }

    /// Persists a new active-theme slug, preserving the current mode
    /// (defaulting to `.auto` when no selection exists yet).
    public static func setActive(slug: String, selectionFile: URL? = nil) throws {
        let mode = readSelection(from: selectionFile)?.mode ?? .auto
        try writeSelection(Selection(theme: slug, mode: mode), to: selectionFile)
    }

    /// Persists a new mode, preserving the currently selected theme
    /// (defaulting to the System palette when no selection exists yet).
    public static func setMode(_ mode: ThemeMode, selectionFile: URL? = nil) throws {
        let theme = readSelection(from: selectionFile)?.theme ?? "system"
        try writeSelection(Selection(theme: theme, mode: mode), to: selectionFile)
    }

    // MARK: - Bundled palettes

    /// The bundled theme palettes seeded into `~/.work42/themes/` on first launch.
    ///
    /// Hex values are the confirmed, spec-locked values for Ocean and Sunset.
    /// Names/descriptions must not be changed without updating the spec.
    private static let bundledPalettes: [(filename: String, yaml: String)] = [
        ("ocean.yaml",  oceanYAML),
        ("sunset.yaml", sunsetYAML),
    ]

    // OCEAN — cool teal palette
    // light: teal accent, soft blue-grey surfaces, dark blue-grey text
    // dark:  bright teal accent, deep navy surfaces, light teal text
    private static let oceanYAML = """
    name: Ocean

    light:
      accent: "#0D9488"
      backdrop: "#EEF4F6"
      sidebar: "#E2EDEF"
      titlebar: "#F7FBFC"
      surface: "#FFFFFF"
      elevated: "#F7FBFC"
      text:
        primary: "#0F1B1E"
        secondary: "#33474C"
        tertiary: "#5E767B"

    dark:
      accent: "#2DD4BF"
      backdrop: "#081014"
      sidebar: "#0C171B"
      titlebar: "#0A1318"
      surface: "#101B22"
      elevated: "#16242D"
      text:
        primary: "#EAF4F4"
        secondary: "#B8CDD0"
        tertiary: "#7E999E"
    """

    // SUNSET — warm orange/amber palette
    // light: burnt orange accent, warm cream surfaces, warm dark text
    // dark:  coral accent, deep warm-brown surfaces, warm light text
    private static let sunsetYAML = """
    name: Sunset

    light:
      accent: "#E25822"
      backdrop: "#FAF3EC"
      sidebar: "#F3E7DA"
      titlebar: "#FFF9F3"
      surface: "#FFFFFF"
      elevated: "#FFF9F3"
      text:
        primary: "#221510"
        secondary: "#4C3A31"
        tertiary: "#7C685D"

    dark:
      accent: "#FF8A5C"
      backdrop: "#140D09"
      sidebar: "#1C120C"
      titlebar: "#100A07"
      surface: "#201510"
      elevated: "#2A1C15"
      text:
        primary: "#F7EFEA"
        secondary: "#D6C4BA"
        tertiary: "#A08B80"
    """
}
