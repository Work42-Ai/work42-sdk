// ThemeYAML.swift — feat/theme-customization.1
//
// Yams-backed YAML codec for ThemeSpec.
//
// Decode strategy: `Yams.load(yaml:)` produces a raw `Any` (dictionary),
// which we walk manually to emit typed `ThemeYAMLError`s that name the
// offending key — e.g. `missingKey("light.sidebar")`, `invalidHex(key:
// "dark.accent", value: "nothex")`. This is AC7's "fail loud, name the key".
//
// Expected YAML shape:
//
//   name: Ocean
//
//   light:
//     accent: "#0D9488"
//     backdrop: "#EEF4F6"
//     sidebar:  "#E2EDEF"
//     titlebar: "#F7FBFC"
//     surface:  "#FFFFFF"
//     elevated: "#F7FBFC"
//     text:
//       primary:   "#0F1B1E"
//       secondary: "#33474C"
//       tertiary:  "#5E767B"
//
//   dark:
//     (same structure)
//
// Accent may be the literal string "system" (for in-code System palette
// round-tripping), but ThemeStore rejects file-based themes that use it.

import Foundation
import Yams

// MARK: - Error type

/// Typed errors from the YAML codec, naming the offending key (AC7).
public enum ThemeYAMLError: Error, Equatable, CustomStringConvertible {
    /// YAML could not be parsed at all (syntax error, wrong type at root).
    case yamlParseFailure(String)
    /// A required key is absent from the mapping.
    case missingKey(String)
    /// A key exists but has the wrong type (e.g. mapping where string expected).
    case invalidType(key: String, expected: String)
    /// A hex color field contains a value that isn't a valid `#rrggbb` string.
    case invalidHex(key: String, value: String)

    public var description: String {
        switch self {
        case .yamlParseFailure(let msg):
            return "YAML parse error: \(msg)"
        case .missingKey(let key):
            return "missing required key '\(key)'"
        case .invalidType(let key, let expected):
            return "key '\(key)': expected \(expected)"
        case .invalidHex(let key, let value):
            return "key '\(key)': '\(value)' is not a valid hex color (#rrggbb)"
        }
    }
}

// MARK: - Codec

/// Yams-backed YAML codec for `ThemeSpec`.
///
/// - `decode(data:)` / `decode(yaml:)` — parse + validate a theme YAML
///   blob into a `ThemeSpec`. Throws `ThemeYAMLError` naming the offending key.
/// - `encode(_:)` — emit a human-readable YAML string from a `ThemeSpec`
///   (used by `work42 theme create` to seed a new file from the active theme).
public nonisolated enum ThemeYAML {

    // MARK: Decode

    /// Decodes raw YAML bytes into a `ThemeSpec`.
    ///
    /// - Parameter data: UTF-8-encoded YAML.
    /// - Throws: `ThemeYAMLError` naming the first problem found.
    public static func decode(data: Data) throws -> ThemeSpec {
        guard let yamlString = String(data: data, encoding: .utf8) else {
            throw ThemeYAMLError.yamlParseFailure("data is not valid UTF-8")
        }
        return try decode(yaml: yamlString)
    }

    /// Decodes a YAML string into a `ThemeSpec`.
    ///
    /// Package-internal so tests can call it directly without a `Data` wrap.
    static func decode(yaml: String) throws -> ThemeSpec {
        let raw: Any
        do {
            guard let node = try Yams.load(yaml: yaml) else {
                throw ThemeYAMLError.yamlParseFailure("empty YAML document")
            }
            raw = node
        } catch let err as ThemeYAMLError {
            throw err
        } catch {
            throw ThemeYAMLError.yamlParseFailure(error.localizedDescription)
        }

        guard let root = raw as? [String: Any] else {
            throw ThemeYAMLError.invalidType(key: "<root>", expected: "mapping")
        }

        let name   = try requireString(root, key: "name")
        let light  = try requireMapping(root, key: "light")
        let dark   = try requireMapping(root, key: "dark")

        return ThemeSpec(
            name:  name,
            light: try parseTokenSet(dict: light,  prefix: "light"),
            dark:  try parseTokenSet(dict: dark,   prefix: "dark")
        )
    }

    // MARK: Encode

    /// Encodes a `ThemeSpec` to a human-readable YAML string.
    ///
    /// Intended for `work42 theme create` — seeds a new file from the
    /// currently active theme's resolved tokens. When `accent` is `.system`,
    /// the literal `"system"` is emitted so the round-trip is lossless;
    /// callers that create user-editable files should substitute a real hex
    /// value before opening the file in the editor (handled by ThemeCommand).
    public static func encode(_ spec: ThemeSpec) -> String {
        func block(_ mode: ThemeTokenSet, indent: String) -> String {
            var lines = [
                "\(indent)accent: \"\(accentStr(mode.accent))\"",
                "\(indent)backdrop: \"\(mode.backdrop)\"",
                "\(indent)sidebar: \"\(mode.sidebar)\"",
                "\(indent)titlebar: \"\(mode.titlebar)\"",
                "\(indent)surface: \"\(mode.surface)\"",
                "\(indent)elevated: \"\(mode.elevated)\"",
                "\(indent)text:",
                "\(indent)  primary: \"\(mode.textPrimary)\"",
                "\(indent)  secondary: \"\(mode.textSecondary)\"",
                "\(indent)  tertiary: \"\(mode.textTertiary)\"",
            ]
            if let e = mode.editor {
                lines.append("\(indent)editor:")
                let fields: [(String, String?)] = [
                    ("background", e.background), ("lineHighlight", e.lineHighlight),
                    ("selection", e.selection), ("cursor", e.cursor),
                    ("text", e.text), ("invisibles", e.invisibles),
                    ("keywords", e.keywords), ("commands", e.commands),
                    ("types", e.types), ("attributes", e.attributes),
                    ("variables", e.variables), ("values", e.values),
                    ("numbers", e.numbers), ("strings", e.strings),
                    ("characters", e.characters), ("comments", e.comments),
                ]
                for (name, value) in fields where value != nil {
                    lines.append("\(indent)  \(name): \"\(value!)\"")
                }
            }
            return lines.joined(separator: "\n")
        }

        return """
        name: \(spec.name)

        light:
        \(block(spec.light, indent: "  "))

        dark:
        \(block(spec.dark, indent: "  "))
        """
    }

    // MARK: - Private helpers

    /// Render a ThemeAccent to its YAML string representation.
    private static func accentStr(_ accent: ThemeAccent) -> String {
        switch accent {
        case .system:       return "system"
        case .hex(let h):   return h
        }
    }

    /// Extract and validate one complete ThemeTokenSet from a YAML mapping.
    ///
    /// `prefix` is the logical path used in error messages ("light" or "dark").
    private static func parseTokenSet(
        dict: [String: Any],
        prefix: String
    ) throws -> ThemeTokenSet {
        // Accent: the string "system" is a valid round-trip value;
        // ThemeStore is responsible for rejecting file-based themes that use it.
        let accentRaw = try requireString(dict, key: "\(prefix).accent")
        let accent: ThemeAccent = accentRaw.lowercased() == "system"
            ? .system
            : .hex(try validateHex(accentRaw, key: "\(prefix).accent"))

        let backdrop = try validateHex(
            requireString(dict, key: "\(prefix).backdrop"), key: "\(prefix).backdrop")
        let sidebar  = try validateHex(
            requireString(dict, key: "\(prefix).sidebar"),  key: "\(prefix).sidebar")
        let titlebar = try validateHex(
            requireString(dict, key: "\(prefix).titlebar"), key: "\(prefix).titlebar")
        let surface  = try validateHex(
            requireString(dict, key: "\(prefix).surface"),  key: "\(prefix).surface")
        let elevated = try validateHex(
            requireString(dict, key: "\(prefix).elevated"), key: "\(prefix).elevated")

        let textDict = try requireMapping(dict, key: "\(prefix).text")

        let textPrimary   = try validateHex(
            requireString(textDict, key: "\(prefix).text.primary"),   key: "\(prefix).text.primary")
        let textSecondary = try validateHex(
            requireString(textDict, key: "\(prefix).text.secondary"), key: "\(prefix).text.secondary")
        let textTertiary  = try validateHex(
            requireString(textDict, key: "\(prefix).text.tertiary"),  key: "\(prefix).text.tertiary")

        return ThemeTokenSet(
            accent:        accent,
            backdrop:      backdrop,
            sidebar:       sidebar,
            titlebar:      titlebar,
            surface:       surface,
            elevated:      elevated,
            textPrimary:   textPrimary,
            textSecondary: textSecondary,
            textTertiary:  textTertiary,
            editor:        try parseEditorTokenSet(parent: dict, prefix: prefix)
        )
    }

    /// Extract and validate the OPTIONAL per-mode `editor:` block.
    ///
    /// Returns nil when the block is absent. Every field within the block is
    /// itself optional (absent fields fall back to the stable editor palette
    /// at resolution time); PRESENT fields are hex-validated fail-loud with
    /// the full dotted path (e.g. "dark.editor.keywords").
    private static func parseEditorTokenSet(
        parent: [String: Any],
        prefix: String
    ) throws -> ThemeEditorTokenSet? {
        guard parent["editor"] != nil else { return nil }
        let dict = try requireMapping(parent, key: "\(prefix).editor")

        func hex(_ field: String) throws -> String? {
            guard let raw = dict[field] else { return nil }
            guard let str = raw as? String else {
                throw ThemeYAMLError.invalidType(
                    key: "\(prefix).editor.\(field)", expected: "string")
            }
            return try validateHex(str, key: "\(prefix).editor.\(field)")
        }

        return ThemeEditorTokenSet(
            background:    try hex("background"),
            lineHighlight: try hex("lineHighlight"),
            selection:     try hex("selection"),
            cursor:        try hex("cursor"),
            text:          try hex("text"),
            invisibles:    try hex("invisibles"),
            keywords:      try hex("keywords"),
            commands:      try hex("commands"),
            types:         try hex("types"),
            attributes:    try hex("attributes"),
            variables:     try hex("variables"),
            values:        try hex("values"),
            numbers:       try hex("numbers"),
            strings:       try hex("strings"),
            characters:    try hex("characters"),
            comments:      try hex("comments")
        )
    }

    /// Requires a string value in `dict` whose logical path is `key`.
    ///
    /// The *lookup key* in the dictionary is the last component of the
    /// dotted path (e.g. `"light.accent"` → look up `"accent"` in `dict`).
    /// The full `key` is used in error messages so callers always see the
    /// complete path.
    private static func requireString(
        _ dict: [String: Any],
        key: String
    ) throws -> String {
        let localKey = lastComponent(of: key)
        guard let value = dict[localKey] else {
            throw ThemeYAMLError.missingKey(key)
        }
        guard let str = value as? String else {
            throw ThemeYAMLError.invalidType(key: key, expected: "string")
        }
        return str
    }

    /// Requires a mapping (dictionary) value in `dict` at the given logical path.
    private static func requireMapping(
        _ dict: [String: Any],
        key: String
    ) throws -> [String: Any] {
        let localKey = lastComponent(of: key)
        guard let value = dict[localKey] else {
            throw ThemeYAMLError.missingKey(key)
        }
        guard let mapping = value as? [String: Any] else {
            throw ThemeYAMLError.invalidType(key: key, expected: "mapping")
        }
        return mapping
    }

    /// Validates that `value` is a well-formed `#rrggbb` hex string.
    /// Normalizes to lower-case and ensures the `#` prefix is present.
    ///
    /// Accepts `#RRGGBB`, `#rrggbb` (6 hex digits after `#`).
    private static func validateHex(_ value: String, key: String) throws -> String {
        let normalized = value.hasPrefix("#") ? value : "#\(value)"
        guard normalized.count == 7 else {
            throw ThemeYAMLError.invalidHex(key: key, value: value)
        }
        let hex = normalized.dropFirst()
        guard hex.allSatisfy(\.isHexDigit) else {
            throw ThemeYAMLError.invalidHex(key: key, value: value)
        }
        return normalized.lowercased()
    }

    /// Returns the last dot-separated component of a logical key path.
    /// `"light.text.primary"` → `"primary"`, `"name"` → `"name"`.
    private static func lastComponent(of key: String) -> String {
        key.split(separator: ".").last.map(String.init) ?? key
    }
}
