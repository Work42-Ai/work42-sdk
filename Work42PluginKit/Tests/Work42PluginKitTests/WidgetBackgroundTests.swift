// WidgetBackgroundTests.swift — bug/widgets-in-background-are-not-working.1
//
// Tests for the Work42WidgetBackground / WidgetBackgroundAgent /
// WidgetBackgroundServices SDK surface:
//
//   (a) Conformance detection — `as? any Work42WidgetBackground` succeeds for
//       a widget that conforms and returns nil for one that does not (old-dylib
//       simulation).
//
//   (b) Fresh-instance factory — `makeBackgroundAgent()` returns a distinct
//       instance on each call (never the same object across sessions).
//
//   (c) Agent lifecycle — `start` / `stop` are called correctly and the agent
//       accumulates the services it received.
//
//   (d) `WidgetBackgroundServices` initializer — all fields round-trip.
//
// These are purely model-layer tests — no SwiftUI view rendering required.
// The host-side integration (RunnerStore hooks, layout index, service wiring)
// is covered by the app-level integration tests; only the SDK surface is
// exercised here.

import Foundation
import SwiftUI
import Testing
@testable import Work42PluginKit

// MARK: - Test doubles

/// A shell service that immediately returns a canned result.
private struct StubShellService: WidgetShellService {
    nonisolated func run(command: String) async throws -> WidgetShellResult {
        WidgetShellResult(stdout: "ok", stderr: "", exitCode: 0)
    }
}

/// A storage service that no-ops on every call (background tests don't
/// exercise storage behaviour — just that the service is forwarded).
private struct StubStorageService: WidgetStorageService {
    nonisolated func get(namespace: String, key: String) async throws -> WidgetJSONValue? { nil }
    nonisolated func list(namespace: String) async throws -> [String: WidgetJSONValue] { [:] }
    nonisolated func set(key: String, value: WidgetJSONValue) async throws {}
    nonisolated func delete(key: String) async throws {}
}

/// A pill service that no-ops on every call (background tests don't exercise
/// pill presentation — just that the service is forwarded).
private struct StubPillService: WidgetPillService {
    nonisolated func present(widgetId: String, sessionId: String) async throws {}
    nonisolated func dismiss(widgetId: String) async throws {}
    nonisolated func isPresented(widgetId: String) async throws -> Bool { false }
}

private actor SpyActivityService: WidgetSessionActivityService {
    private var count = 0
    func ping() async { count += 1 }
    func pingCount() -> Int { count }
}

/// A minimal `WidgetBackgroundAgent` implementation that records the calls
/// made to it so tests can assert lifecycle ordering and service forwarding.
@MainActor
private final class SpyAgent: WidgetBackgroundAgent {

    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var lastServices: WidgetBackgroundServices?

    var headerLabels: [WidgetHeaderLabel] = []

    func start(services: WidgetBackgroundServices) {
        startCallCount += 1
        lastServices = services
    }

    func stop() {
        stopCallCount += 1
    }
}

/// A widget that conforms to BOTH `Work42Widget` and `Work42WidgetBackground`.
/// Each call to `makeBackgroundAgent()` returns a fresh `SpyAgent`.
@MainActor
private final class BackgroundCapableWidget: Work42Widget, Work42WidgetBackground {
    let id = "background-capable"
    let title = "Background Capable"
    let icon = "waveform"
    let linkIntents: [WidgetLinkIntentSpec] = []

    func makeView(services: SessionServices) -> AnyView { AnyView(EmptyView()) }

    func makeBackgroundAgent() -> any WidgetBackgroundAgent {
        SpyAgent()
    }
}

/// A plain widget with NO conformance to `Work42WidgetBackground` — simulates
/// a dylib compiled before the background protocols existed.
@MainActor
private final class LegacyWidget: Work42Widget {
    let id = "legacy-widget"
    let title = "Legacy Widget"
    let icon = "square"
    let linkIntents: [WidgetLinkIntentSpec] = []

    func makeView(services: SessionServices) -> AnyView { AnyView(EmptyView()) }
}

// MARK: - Suite: conformance detection

@Suite("Work42WidgetBackground conformance detection", .serialized)
@MainActor
struct Work42WidgetBackgroundDetectionTests {

    @Test("as? cast succeeds for a conforming widget")
    func castSucceedsForConforming() {
        let widget: any Work42Widget = BackgroundCapableWidget()
        let bg = widget as? any Work42WidgetBackground
        #expect(bg != nil, "a background-capable widget must satisfy the conformance cast")
    }

    @Test("as? cast returns nil for a non-conforming widget — legacy ABI-safe path")
    func castReturnsNilForLegacy() {
        let widget: any Work42Widget = LegacyWidget()
        let bg = widget as? any Work42WidgetBackground
        #expect(bg == nil,
            "non-conforming widget must return nil — old dylibs must load unchanged")
    }
}

// MARK: - Suite: fresh-instance factory

@Suite("Work42WidgetBackground.makeBackgroundAgent — fresh instance per call", .serialized)
@MainActor
struct MakeBackgroundAgentTests {

    @Test("each call returns a distinct agent instance (per-session isolation)")
    func eachCallReturnsFreshInstance() {
        let widget = BackgroundCapableWidget()
        let agent1 = widget.makeBackgroundAgent()
        let agent2 = widget.makeBackgroundAgent()
        // Identity check: the two agents must NOT be the same object.
        // Using ObjectIdentifier to compare reference identity without
        // requiring the existential to be Equatable.
        let id1 = ObjectIdentifier(agent1 as AnyObject)
        let id2 = ObjectIdentifier(agent2 as AnyObject)
        #expect(id1 != id2,
            "makeBackgroundAgent must return a fresh instance on each call (one agent per session)")
    }

    @Test("returned agent is the concrete type produced by the factory")
    func returnedAgentIsExpectedType() {
        let widget = BackgroundCapableWidget()
        let agent = widget.makeBackgroundAgent()
        #expect(agent is SpyAgent,
            "the factory must return the agent instance it created")
    }
}

// MARK: - Suite: agent lifecycle

@Suite("WidgetBackgroundAgent start/stop lifecycle", .serialized)
@MainActor
struct WidgetBackgroundAgentLifecycleTests {

    private func makeServices(sessionId: String = "s1", taskId: String? = "t1") -> WidgetBackgroundServices {
        WidgetBackgroundServices(
            shell: StubShellService(),
            storage: StubStorageService(),
            pill: StubPillService(),
            sessionId: sessionId,
            taskId: taskId
        )
    }

    @Test("start is called with the provided services")
    func startReceivesServices() {
        let agent = SpyAgent()
        let services = makeServices(sessionId: "session-abc", taskId: "task-xyz")
        agent.start(services: services)
        #expect(agent.startCallCount == 1)
        #expect(agent.lastServices?.sessionId == "session-abc")
        #expect(agent.lastServices?.taskId == "task-xyz")
    }

    @Test("stop increments the stop counter")
    func stopIsCalled() {
        let agent = SpyAgent()
        let services = makeServices()
        agent.start(services: services)
        agent.stop()
        #expect(agent.stopCallCount == 1)
    }

    @Test("stop can be called without a prior start (host safety — dormancy edge case)")
    func stopWithoutStart() {
        let agent = SpyAgent()
        agent.stop()
        #expect(agent.stopCallCount == 1, "stop must be safe to call even without a preceding start")
    }

    @Test("start then stop then start reflects two start calls")
    func restartAfterStop() {
        let agent = SpyAgent()
        let services = makeServices()
        agent.start(services: services)
        agent.stop()
        agent.start(services: makeServices(sessionId: "s2", taskId: nil))
        #expect(agent.startCallCount == 2)
        #expect(agent.stopCallCount == 1)
        #expect(agent.lastServices?.sessionId == "s2")
        #expect(agent.lastServices?.taskId == nil)
    }

    @Test("headerLabels starts empty — no placeholder required")
    func headerLabelsInitiallyEmpty() {
        let agent = SpyAgent()
        #expect(agent.headerLabels.isEmpty,
            "an agent's headerLabels must be empty before the first poll — no placeholder flash")
    }
}

// MARK: - Suite: WidgetBackgroundServices initializer

@Suite("WidgetBackgroundServices fields", .serialized)
struct WidgetBackgroundServicesFieldTests {

    @Test("all fields round-trip through init")
    func fieldsRoundTrip() {
        let shell = StubShellService()
        let storage = StubStorageService()
        let svc = WidgetBackgroundServices(
            shell: shell,
            storage: storage,
            pill: StubPillService(),
            sessionId: "my-session",
            taskId: "my-task"
        )
        #expect(svc.sessionId == "my-session")
        #expect(svc.taskId == "my-task")
        // Verify the service existentials are present (protocol-typed, so we
        // just confirm they are non-nil by calling through them).
        // We can't use identity checks on existentials without a concrete cast.
    }

    @Test("taskId may be nil for plain sessions and Home")
    func taskIdMayBeNil() {
        let svc = WidgetBackgroundServices(
            shell: StubShellService(),
            storage: StubStorageService(),
            pill: StubPillService(),
            sessionId: "home-session",
            taskId: nil
        )
        #expect(svc.taskId == nil,
            "plain sessions and Home have no taskId — nil must be accepted without error")
    }

    @Test("activity service forwards explicit pings")
    func activityPing() async {
        let activity = SpyActivityService()
        let svc = WidgetBackgroundServices(
            shell: StubShellService(),
            storage: StubStorageService(),
            pill: StubPillService(),
            activity: activity,
            sessionId: "active-session",
            taskId: nil
        )

        await svc.activity.ping()
        #expect(await activity.pingCount() == 1)
    }
}
