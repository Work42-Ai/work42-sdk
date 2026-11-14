import Foundation
import Testing
import Work42UI

@testable import Work42PluginKit

@Suite("A collaborator that is an agent carries its identity (SDK 2.14.0)")
struct AgentCollaboratorTests {
    @Test("an agent carries the identity the host gives it, and a person never has one")
    func carries() {
        let claude = WidgetCollaborator(id: "agent:s1:main", displayName: "Claude", kind: .agent, agent: SupportedAgents.claude)
        #expect(claude.agent == SupportedAgents.claude)
        // A person is never an agent, whatever it is handed.
        let person = WidgetCollaborator(id: "yan", displayName: "Yan", role: .owner, agent: SupportedAgents.codex)
        #expect(person.agent == nil)
    }

    @Test("an agent the host does not name has the generic identity")
    func generic() {
        let agent = WidgetCollaborator(id: "agent:s1:main", displayName: "Agent", kind: .agent)
        #expect(agent.agent == SupportedAgents.identity(for: ""))
    }

    @Test("it travels with the collaborator through encoding")
    func codable() throws {
        let codex = WidgetCollaborator(id: "agent:s1:c2", displayName: "Codex", kind: .agent, agent: SupportedAgents.codex)
        let back = try JSONDecoder().decode(WidgetCollaborator.self, from: JSONEncoder().encode(codex))
        #expect(back == codex && back.agent?.name == "Codex")
    }
}
