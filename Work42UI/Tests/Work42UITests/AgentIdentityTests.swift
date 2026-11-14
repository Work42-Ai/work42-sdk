import Foundation
import Testing

@testable import Work42UI

@Suite("The supported agents (SDK 2.14.0)")
struct AgentIdentityTests {
    @Test("Claude and Codex are defined, in the order a list shows them")
    func catalog() {
        #expect(SupportedAgents.all.map(\.id) == ["claude", "codex"])
        #expect(SupportedAgents.claude.name == "Claude" && SupportedAgents.codex.name == "Codex")
        #expect(SupportedAgents.isSupported("claude") && SupportedAgents.isSupported("codex") && !SupportedAgents.isSupported("gemini"))
        #expect(SupportedAgents.identity(for: "claude") == SupportedAgents.claude)
    }

    @Test("their colours, marks and symbols are the ones the app has always drawn")
    func values() {
        #expect(SupportedAgents.claude.tintHex == "#d97757" && SupportedAgents.codex.tintHex == "#1a1a1c")
        #expect(SupportedAgents.claude.markAsset == "claude-logo" && SupportedAgents.codex.markAsset == "openai-logo")
        #expect(SupportedAgents.claude.markKeepsColor && !SupportedAgents.codex.markKeepsColor)
        #expect(SupportedAgents.claude.symbol == "sparkles" && SupportedAgents.codex.symbol == "chevron.left.forwardslash.chevron.right")
        #expect(SupportedAgents.claude.markTile.hex == "#fff4ee" && SupportedAgents.codex.markTile.hex == "#ffffff")
    }

    @Test("the pointer colours are the hues the dart has always used")
    func pointers() {
        // hsb(14°, 0.62, 0.86) and hsb(175°, 0.62, 0.86)
        #expect(SupportedAgents.claude.pointer.hex == AgentColor(hue: 14, saturation: 0.62, brightness: 0.86).hex)
        #expect(SupportedAgents.codex.pointer.hex == AgentColor(hue: 175, saturation: 0.62, brightness: 0.86).hex)
        #expect(SupportedAgents.claude.pointer != SupportedAgents.codex.pointer)
    }

    @Test("an id this build does not define is a generic Agent in Claude's colours, with no mark")
    func unknown() {
        let unknown = SupportedAgents.identity(for: "gemini")
        #expect(unknown.id == "gemini" && unknown.name == "Agent")
        #expect(unknown.color == SupportedAgents.claude.color && unknown.pointer == SupportedAgents.claude.pointer)
        #expect(unknown.markAsset == nil && unknown.symbol == "circle.dashed")
        // No id at all reads the same.
        #expect(SupportedAgents.identity(for: "").name == "Agent")
    }

    @Test("colours read and write #rrggbb")
    func colours() {
        #expect(AgentColor(hex: "#d97757") == AgentColor(rgb: 0xD97757))
        #expect(AgentColor(hex: "d97757")?.hex == "#d97757")
        #expect(AgentColor(hex: "#d9775") == nil && AgentColor(hex: "zzzzzz") == nil)
        #expect(AgentColor(rgb: 0xFFFFFF).hex == "#ffffff" && AgentColor(rgb: 0x000000).hex == "#000000")
    }

    @Test("an identity survives being encoded, as it travels to plugins and devices")
    func codable() throws {
        let data = try JSONEncoder().encode(SupportedAgents.codex)
        #expect(try JSONDecoder().decode(AgentIdentity.self, from: data) == SupportedAgents.codex)
    }

    @MainActor
    @Test("both marks ship in the SDK, as the PNG and the SVG")
    func marks() {
        for agent in SupportedAgents.all {
            let asset = agent.markAsset ?? ""
            #expect(AgentMarks.url(named: asset, withExtension: "png") != nil, "\(asset).png")
            #expect(AgentMarks.url(named: asset, withExtension: "svg") != nil, "\(asset).svg")
            #expect(AgentMarks.image(for: agent, template: true) != nil)
        }
        #expect(AgentMarks.image(for: SupportedAgents.identity(for: "gemini"), template: true) == nil)
    }
}
