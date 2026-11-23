// BrowserTabsServiceTests.swift — SDK 3.1.0: `services.browser`, the calling widget's own tabs (WOR-858).
// The host implements the service; these pin the types, the unavailable default and the per-widget binding.

import Foundation
import Testing
@testable import Work42PluginKit
import Work42UI

private struct StubComposer: WidgetComposerService {
    nonisolated func insert(text: String) async throws {}
    nonisolated func attach(sourceLabel: String, excerpt: String, body: String) async throws {}
}

private struct StubShell: WidgetShellService {
    nonisolated func run(command: String) async throws -> WidgetShellResult {
        WidgetShellResult(stdout: "", stderr: "", exitCode: 0)
    }
}

private struct StubIntents: WidgetIntentsService {
    nonisolated func execute(id: String, params: [String: WidgetJSONValue]) async throws {}
}

private struct StubStorage: WidgetStorageService {
    nonisolated func get(namespace: String, key: String) async throws -> WidgetJSONValue? { nil }
    nonisolated func list(namespace: String) async throws -> [String: WidgetJSONValue] { [:] }
    nonisolated func set(key: String, value: WidgetJSONValue) async throws {}
    nonisolated func delete(key: String) async throws {}
}

private struct StubPill: WidgetPillService {
    nonisolated func present(widgetId: String, sessionId: String) async throws {}
    nonisolated func dismiss(widgetId: String) async throws {}
    nonisolated func isPresented(widgetId: String) async throws -> Bool { false }
}

private func services(session: String) -> SessionServices {
    SessionServices(
        composer: StubComposer(), shell: StubShell(), intents: StubIntents(), storage: StubStorage(), pill: StubPill(),
        sessionId: session)
}

/// A service that remembers what it was asked, and which session's services it was made for.
private final class RecordingBrowser: BrowserTabsService, @unchecked Sendable {
    let session: String?
    private let lock = NSLock()
    private var recorded: [String] = []

    init(session: String?) { self.session = session }

    var calls: [String] { lock.withLock { recorded } }
    private func record(_ call: String) { lock.withLock { recorded.append(call) } }

    func setTabs(_ tabs: [BrowserTab]) async throws { record("setTabs:\(tabs.count)") }
    func selectTab(_ id: UUID) async throws { record("selectTab") }
    func updateTab(_ id: UUID, title: String?, url: URL?, icon: String?) async throws { record("updateTab:\(title ?? "-")") }
    var tabs: AsyncStream<BrowserTabsState> { AsyncStream { $0.finish() } }
    var events: AsyncStream<BrowserEvent> { AsyncStream { $0.finish() } }
}

@Suite("services.browser (SDK 3.1.0)", .serialized)
@MainActor
struct BrowserTabsServiceTests {

    /// The registry is process-wide: every test leaves it as it found it.
    private func withRegistry(_ resolve: (@MainActor (SessionServices) -> (any BrowserTabsService)?)?, _ body: () async throws -> Void) async rethrows {
        let previous = BrowserTabsRegistry.resolve
        BrowserTabsRegistry.resolve = resolve
        defer { BrowserTabsRegistry.resolve = previous }
        try await body()
    }

    @Test("with no host registry, every call throws a named remedy and the streams end at once")
    func unavailableByDefault() async throws {
        try await withRegistry(nil) {
            let browser = services(session: "s1").browser
            #expect(browser is UnavailableBrowserTabsService)

            let error = await #expect(throws: WidgetServiceError.self) { try await browser.setTabs([]) }
            #expect(error?.suggestion?.contains("3.1") == true, "the suggestion names the version that has it")
            await #expect(throws: WidgetServiceError.self) { try await browser.selectTab(UUID()) }
            await #expect(throws: WidgetServiceError.self) { try await browser.updateTab(UUID(), title: "x", url: nil, icon: nil) }

            var states = 0
            for await _ in browser.tabs { states += 1 }
            var events = 0
            for await _ in browser.events { events += 1 }
            #expect(states == 0 && events == 0)
        }
    }

    @Test("services.browser resolves through the host registry, handing it the services of the widget that asked")
    func resolvesForTheCaller() async throws {
        var askedFor: [String?] = []
        try await withRegistry({ services in
            askedFor.append(services.sessionId)
            return RecordingBrowser(session: services.sessionId)
        }) {
            let first = services(session: "s1").browser
            let second = services(session: "s2").browser
            try await first.setTabs([BrowserTab(title: "a")])
            try await second.setTabs([BrowserTab(title: "a"), BrowserTab(title: "b")])

            #expect(askedFor == ["s1", "s2"])
            let one = try #require(first as? RecordingBrowser)
            let two = try #require(second as? RecordingBrowser)
            #expect(one !== two, "each widget instance gets its own service, so none can reach another's tabs")
            #expect(one.calls == ["setTabs:1"] && two.calls == ["setTabs:2"])
        }
    }

    @Test("the call forms a widget uses all reach the service")
    func callForms() async throws {
        try await withRegistry({ RecordingBrowser(session: $0.sessionId) }) {
            let browser = services(session: "s1").browser
            let tab = BrowserTab(url: URL(string: "https://example.com"), title: "Example", icon: "globe")
            try await browser.setTabs([tab])
            try await browser.selectTab(tab.id)
            try await browser.updateTab(tab.id, title: "Renamed", url: nil, icon: nil)
            #expect(try #require(browser as? RecordingBrowser).calls == ["setTabs:1", "selectTab", "updateTab:Renamed"])
        }
    }

    @Test("tab state and browser events survive a round trip through JSON")
    func codable() throws {
        let tab = BrowserTab(url: URL(string: "https://example.com/a"), title: "A", icon: "star")
        let state = BrowserTabsState(tabs: [tab, BrowserTab(title: "Empty")], activeTabId: tab.id)
        let decoded = try JSONDecoder().decode(BrowserTabsState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
        #expect(BrowserTabsState() == BrowserTabsState(tabs: [], activeTabId: nil))

        for event in [BrowserEvent.newTabRequested, .tabClosed(tab.id)] {
            #expect(try JSONDecoder().decode(BrowserEvent.self, from: JSONEncoder().encode(event)) == event)
        }
        #expect(BrowserEvent.tabClosed(tab.id) != .newTabRequested)
    }

    @Test("the host's attach hook runs after the surface's default hooks are in place, with the scoped key, and every time they are wired")
    func attachRunsAfterDefaults() {
        let previous = BrowserTabsRegistry.attach
        defer { BrowserTabsRegistry.attach = previous }
        var seen: [(key: String, hadDefaultNewTab: Bool, hadTabClosed: Bool)] = []
        BrowserTabsRegistry.attach = { model, key in
            seen.append((key, model.onNewTab != nil, model.onTabClosed != nil))
        }

        let model = BrowserWidgetModel(canEditURL: true, presetSelector: "", initialURL: nil)
        BrowserSurface.wireHooks(on: model, cacheKey: "s1/my-widget", configure: nil)
        // A view mounting on a model that already exists wires again; the host gets another chance to re-install.
        BrowserSurface.wireHooks(on: model, cacheKey: "s1/my-widget", configure: nil)

        #expect(seen.count == 2)
        #expect(seen.allSatisfy { $0.key == "s1/my-widget" && $0.hadDefaultNewTab && $0.hadTabClosed })
    }

    @Test("a surface declaration needs no closure; the configure: forms still work")
    func declarationForms() {
        let spec = BrowserSurfaceSpec(url: URL(string: "https://example.com")!, dataStoreKey: "x")
        #expect(BrowserSurfaceDeclaration(spec: spec, cacheKey: "w").configure == nil)
        #expect(BrowserSurface(spec: spec, cacheKey: "w").configure == nil)

        // The deprecated forms still compile and still carry the closure, so a plugin built against 3.0 keeps working.
        @available(*, deprecated)
        func deprecatedForms() -> (declaration: BrowserSurfaceDeclaration, surface: BrowserSurface) {
            (BrowserSurfaceDeclaration(spec: spec, cacheKey: "w", configure: { _ in }),
             BrowserSurface(spec: spec, cacheKey: "w", configure: { _ in }))
        }
        let forms = deprecatedForms()
        #expect(forms.declaration.configure != nil)
        #expect(forms.surface.configure != nil)
    }
}
