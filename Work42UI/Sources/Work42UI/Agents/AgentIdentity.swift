// AgentIdentity.swift — who the supported AI agents are, defined once (SDK 2.14.0, ABI 16; WOR-773).
//
// An agent has a name, a colour, a mark and a symbol, and every place that names or draws one reads them from here: the chat and its
// rows, the composer's medallion and model picker, Settings, onboarding, a terminal's name, the people pills, the dart and the glow,
// and a plugin's widget through `WidgetCollaborator.agent`. Nothing else defines an agent's look; a place that wants to show Claude
// asks `SupportedAgents.identity(for: "claude")`.
//
// This file is Foundation only, so the app's model layer (Work42Models, Work42Remote) can name an agent without a UI framework. The
// SwiftUI side (a colour, the mark's image, the avatar) is `AgentMarkView.swift`.

import Foundation

/// A colour as the catalog states it: three components from 0 to 1, with no UI framework behind it.
public nonisolated struct AgentColor: Hashable, Sendable, Codable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `0xrrggbb`.
    public init(rgb value: UInt32) {
        self.init(
            red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    /// `#rrggbb` (the `#` optional); nil for anything else.
    public init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(rgb: value)
    }

    /// Hue in degrees, saturation and brightness from 0 to 1.
    public init(hue: Double, saturation: Double, brightness: Double) {
        let h = hue / 360
        let i = Int(h * 6) % 6
        let f = h * 6 - Double(Int(h * 6))
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - f * saturation)
        let t = brightness * (1 - (1 - f) * saturation)
        switch i {
        case 0: self.init(red: brightness, green: t, blue: p)
        case 1: self.init(red: q, green: brightness, blue: p)
        case 2: self.init(red: p, green: brightness, blue: t)
        case 3: self.init(red: p, green: q, blue: brightness)
        case 4: self.init(red: t, green: p, blue: brightness)
        default: self.init(red: brightness, green: p, blue: q)
        }
    }

    /// `#rrggbb`, lower case.
    public var hex: String {
        func byte(_ component: Double) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(red), byte(green), byte(blue))
    }
}

/// One supported agent: how it is named and drawn, everywhere.
public nonisolated struct AgentIdentity: Hashable, Sendable, Codable, Identifiable {
    /// The provider's id (`claude`, `codex`): what a session, a chat and a participant name an agent by.
    public let id: String
    /// What a person reads: "Claude", "Codex"; "Agent" for an id this build does not know.
    public let name: String
    /// Its brand colour: its avatar, its chips, its glow.
    public let color: AgentColor
    /// The colour of its pointer (the dart) and its tag, where the brand colour is too dark to read over a page.
    public let pointer: AgentColor
    /// The file name (no extension) of its bundled mark, or nil when it has none.
    public let markAsset: String?
    /// Whether its mark keeps its own colours on a plain surface (Claude's terracotta starburst); the others draw as a silhouette in the
    /// surrounding colour, so OpenAI's mark inverts with the appearance.
    public let markKeepsColor: Bool
    /// An SF Symbol for where there is no mark to draw.
    public let symbol: String
    /// What goes before its name on a pointer's tag.
    public let tagGlyph: String
    /// The tile its mark sits on where the mark is shown large (the onboarding rows): a warm tint for Claude's terracotta, white for a
    /// mark that is black.
    public let markTile: AgentColor

    public init(
        id: String, name: String, color: AgentColor, pointer: AgentColor, markAsset: String? = nil, markKeepsColor: Bool = false,
        symbol: String = "circle.dashed", tagGlyph: String = "✳︎", markTile: AgentColor = AgentColor(rgb: 0xFFFFFF)
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.pointer = pointer
        self.markAsset = markAsset
        self.markKeepsColor = markKeepsColor
        self.symbol = symbol
        self.tagGlyph = tagGlyph
        self.markTile = markTile
    }

    /// The provider id, under the name the sessions use for it.
    public var providerID: String { id }
    /// The brand colour as `#rrggbb`, for the tokens stream.
    public var tintHex: String { color.hex }
}

/// The agents Work42 supports, and the one place their identities are defined.
public nonisolated enum SupportedAgents {
    public static let claude = AgentIdentity(
        id: "claude", name: "Claude", color: AgentColor(rgb: 0xD97757), pointer: AgentColor(hue: 14, saturation: 0.62, brightness: 0.86),
        markAsset: "claude-logo", markKeepsColor: true, symbol: "sparkles", markTile: AgentColor(rgb: 0xFFF4EE))

    public static let codex = AgentIdentity(
        id: "codex", name: "Codex", color: AgentColor(rgb: 0x1A1A1C), pointer: AgentColor(hue: 175, saturation: 0.62, brightness: 0.86),
        markAsset: "openai-logo", markKeepsColor: false, symbol: "chevron.left.forwardslash.chevron.right")

    /// Every supported agent, in the order a list shows them.
    public static let all: [AgentIdentity] = [claude, codex]

    /// The identity of provider `id`. An id this build does not know (a provider added since) is a generic "Agent" in Claude's colours,
    /// with no mark, so it still has a name and a colour.
    public static func identity(for id: String) -> AgentIdentity {
        all.first { $0.id == id }
            ?? AgentIdentity(id: id, name: "Agent", color: claude.color, pointer: claude.pointer, markAsset: nil, symbol: "circle.dashed")
    }

    /// Whether this build defines provider `id`.
    public static func isSupported(_ id: String) -> Bool { all.contains { $0.id == id } }
}
