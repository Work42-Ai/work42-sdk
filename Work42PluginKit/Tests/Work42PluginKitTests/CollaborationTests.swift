// CollaborationTests.swift — the collaboration surface of SDK 2.14.0 (WOR-779): defaults, audiences, per-viewer intents.

import Foundation
import SwiftUI
import Testing
@testable import Work42PluginKit

@MainActor
@Suite("Collaboration surface (SDK 2.14.0)")
struct CollaborationTests {

    private let owner = WidgetCollaborator(id: "yan", displayName: "Yan", role: .owner)
    private let reviewer = WidgetCollaborator(id: "alex", displayName: "Alex", role: .member, workflowRoles: ["reviewer"])
    private let sidekick = WidgetCollaborator(id: "yan", displayName: "Yan's iPad", role: .owner, isPrimaryDevice: false)
    private let agent = WidgetCollaborator(id: "agent:s1:c1", displayName: "Claude", kind: .agent, role: .owner)

    private func spec() -> WidgetIntentSpec {
        WidgetIntentSpec(name: "approve", title: "Approve", icon: "checkmark") {}
    }

    @Test("a widget that declares nothing is shared, last write wins, no cursors, with one scope")
    func defaults() {
        final class Plain: Work42Widget {
            let id = "plain"
            let title = "Plain"
            let icon = "square"
            let linkIntents: [WidgetLinkIntentSpec] = []
            func makeView(services: SessionServices) -> AnyView { AnyView(EmptyView()) }
        }
        let widget = Plain()
        #expect(widget.collaboration == .shared(conflict: .lastWriteWins, cursors: .none))
        #expect(widget.scopes == [WidgetScopeSpec(id: "use", title: "Use")])
    }

    @Test("an intent nobody configured is for every person, not for agents, and has no scope")
    func intentDefaults() {
        let intent = spec()
        #expect(intent.requires == nil)
        #expect(intent.agents == .notAllowed)
        #expect(intent.permits(owner) && intent.permits(reviewer) && intent.permits(sidekick))
        #expect(!intent.permits(agent))
    }

    @Test("an agent presses an intent only when the intent says so")
    func agentsOptIn() {
        #expect(spec().allowingAgents().permits(agent))
        // An agent is never inside an audience, even one that allows everyone.
        #expect(!WidgetAudience.everyone.allows(agent))
        // And allowing agents does not widen who the people are.
        #expect(!spec().forAudience(.owners).allowingAgents().permits(reviewer))
    }

    @Test("an audience is an allow-list of owners, members and workflow roles")
    func audiences() {
        #expect(WidgetAudience.owners.allows(owner) && !WidgetAudience.owners.allows(reviewer))
        #expect(WidgetAudience.members.allows(reviewer) && !WidgetAudience.members.allows(owner))
        #expect(WidgetAudience.roles("reviewer").allows(reviewer) && !WidgetAudience.roles("reviewer").allows(owner))
        #expect(WidgetAudience([.owners, .role("reviewer")]).allows(reviewer))
        #expect(!WidgetAudience.nobody.allows(owner))
    }

    @Test("primaryDeviceOnly leaves out a sidekick of the same person")
    func primaryDevice() {
        let audience = WidgetAudience.owners.primaryDeviceOnly
        #expect(audience.allows(owner))
        #expect(!audience.allows(sidekick))
        #expect(sidekick.isSamePerson(as: owner))
    }

    @Test("a button reads differently for each viewer, and falls back to the viewer-independent one")
    func perViewer() {
        let intent = spec().perViewer(
            title: { $0.id == "yan" ? "Approved by you" : "Approve" },
            isConfirmed: { $0.id == "yan" })
        #expect(intent.title(for: owner) == "Approved by you")
        #expect(intent.title(for: reviewer) == "Approve")
        #expect(intent.isConfirmed(for: owner) && !intent.isConfirmed(for: reviewer))
        // Not given: the plain behaviour.
        #expect(intent.isEnabled(for: reviewer))
        #expect(spec().title(for: reviewer) == "Approve" && !spec().isConfirmed(for: reviewer))
    }

    @Test("the old live closures answer for every viewer when no per-viewer one is set")
    func liveClosuresStillApply() {
        let intent = WidgetIntentSpec(
            name: "go", title: "Go", icon: "play", isEnabled: { false }, actionAreaTitle: { "Going" }, perform: {})
        #expect(!intent.isEnabled(for: owner))
        #expect(intent.title(for: reviewer) == "Going")
    }

    @Test("an agent never has a role, whatever it is told")
    func agentHasNoRole() {
        #expect(agent.role == nil && agent.isAgent && !agent.isOwner)
    }

    @Test("the layouts a host and a widget exchange survive a JSON round trip")
    func codable() throws {
        let value = WidgetCursor(
            who: reviewer,
            report: WidgetCursorReport(anchor: .text(path: "a.swift", version: 3, line: 4, column: 5), selectionEnd: .point(x: 0.5, y: 1), isClick: true))
        let back = try JSONDecoder().decode(WidgetCursor.self, from: JSONEncoder().encode(value))
        #expect(back == value)
        let kind = WidgetCollaboration.personal(watchers: .withPermission, agentControl: .withPermission)
        #expect(try JSONDecoder().decode(WidgetCollaboration.self, from: JSONEncoder().encode(kind)) == kind)
    }

    @Test("a host with no session of several people has one member and no cursors")
    func solo() async throws {
        let service = SoloWidgetCollaborationService()
        #expect(try await service.members() == [.solo])
        var count = 0
        for await _ in service.cursors() { count += 1 }
        #expect(count == 0)
        try await service.report(WidgetCursorReport(anchor: .point(x: 0, y: 0)))
    }

    @Test("storage kept per person says so when the host cannot")
    func personStorageUnavailable() async {
        struct Plain: WidgetStorageService {
            func get(namespace: String, key: String) async throws -> WidgetJSONValue? { nil }
            func list(namespace: String) async throws -> [String: WidgetJSONValue] { [:] }
            func set(key: String, value: WidgetJSONValue) async throws {}
            func delete(key: String) async throws {}
        }
        await #expect(throws: WidgetServiceError.self) { _ = try await Plain().person(key: "approval") }
        await #expect(throws: WidgetServiceError.self) { _ = try await Plain().people(key: "approval") }
    }
}
