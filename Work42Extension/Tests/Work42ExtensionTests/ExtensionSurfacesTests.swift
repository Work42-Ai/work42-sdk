// ExtensionSurfacesTests.swift — live intent state, header labels, menus and the pill / header / popover surfaces over the
// wire (SDK 3.4.0).

import Foundation
import Observation
import SwiftUI
import Testing
import Work42Extension
import Work42PluginKit

/// A widget shaped like meet42's Recording tile: Record while idle, a timed Stop while recording, a menu, header labels, a pill, a
/// custom header and a popover.
@MainActor
@Observable
final class RecorderLikeWidget: Work42Widget, Work42WidgetHeaderLabels, Work42WidgetPill, Work42WidgetCustomHeader,
                                Work42WidgetActionPopovers {
    let id = "recording"
    let title = "Recording"
    let icon = "record.circle"
    let linkIntents: [WidgetLinkIntentSpec] = []

    var recording = false
    var seconds = 0
    var mic = "built-in"
    var picked: [String] = []
    var headerLabels: [WidgetHeaderLabel] = []

    var intents: [WidgetIntentSpec] {
        [
            WidgetIntentSpec(name: "record", title: "Record", icon: "record.circle", placement: [.palette, .actionArea],
                             actionAreaStyle: .icon, isEnabled: { [self] in !recording }, perform: { [self] in recording = true }),
            WidgetIntentSpec(name: "stop", title: "Stop", icon: "stop.fill", placement: [.palette, .actionArea],
                             actionAreaStyle: .labeled, isEnabled: { [self] in recording },
                             actionAreaTitle: { [self] in String(format: "%d:%02d", seconds / 60, seconds % 60) },
                             livePeriodicTick: 1, perform: { [self] in recording = false }),
            WidgetIntentSpec(name: "mic", title: "Microphone", icon: "mic", placement: [.palette, .actionArea],
                             actionAreaStyle: .menu(
                                 options: { [self] in
                                     ["built-in", "usb"].map { WidgetIntentMenuOption(id: $0, title: $0, isSelected: $0 == mic) }
                                 },
                                 onSelect: { [self] choice in mic = choice; picked.append(choice) }),
                             isEnabled: nil, perform: {}),
            WidgetIntentSpec(name: "settings", title: "Settings", icon: "gearshape", placement: [.palette, .actionArea],
                             actionAreaStyle: .icon, perform: {}),
        ]
    }

    func makeView(services: SessionServices) -> AnyView { AnyView(Text("tile")) }
    func makePillView(services: SessionServices) -> AnyView? { AnyView(Text("pill")) }
    var pillMetadata: WidgetPillMetadata { WidgetPillMetadata(preferredSize: WidgetMinSize(width: 412, height: 108), title: "Recording", icon: "record.circle") }
    func makeHeaderView() -> AnyView { AnyView(Text("header")) }
    var contentPadding: Double { 12 }
    func actionAreaPopover(for intentName: String, dismiss: @escaping @MainActor () -> Void) -> AnyView? {
        intentName == "settings" ? AnyView(Text("settings popover")) : nil
    }
}

/// The widgets' state events the host got, in order.
@MainActor
final class StateLog {
    var states: [(widget: String, session: String, agent: Bool, state: ExtensionPayload.WidgetState)] = []
    var dismissed: [String] = []
}

@MainActor
private func connect(_ widget: RecorderLikeWidget, session: String = "s1") -> (Pair, StateLog) {
    let pair = Pair(widgets: [ExtensionWidgetFactory("recording") { widget }])
    let log = StateLog()
    pair.link.server.widgetEvents = { event in
        switch event {
        case .state(let widgetId, let sessionId, let agent, let state):
            log.states.append((widgetId, sessionId, agent, state))
        case .dismissPopover(_, _, let intent):
            log.dismissed.append(intent)
        }
    }
    pair.link.server.attach(hostServices(shell: CountingShell(), storage: MemoryStore(), sessionId: session),
                            widgetId: "recording", sessionId: session)
    return (pair, log)
}

@Suite("Live widget state and surfaces over the wire", .serialized)
@MainActor
struct ExtensionSurfacesTests {

    // MARK: description

    @Test("the description carries the tick, the menu style, the pill, the header and the popover intents")
    func description() {
        let description = ExtensionWidgetDescription(describing: RecorderLikeWidget())
        let byName = Dictionary(uniqueKeysWithValues: description.intents.map { ($0.name, $0) })
        #expect(byName["stop"]?.livePeriodicTick == 1)
        #expect(byName["record"]?.livePeriodicTick == nil)
        #expect(byName["mic"]?.actionAreaStyle == "menu")
        #expect(byName["record"]?.actionAreaStyle == "icon")
        #expect(description.pillMetadata?.preferredSize.width == 412)
        #expect(description.pillMetadata?.title == "Recording")
        #expect(description.customHeaderContentPadding == 12)
        #expect(description.popoverIntents == ["settings"])
    }

    @Test("a widget with none of it describes none of it, and its description is the 3.3.0 wire")
    func plainWidget() throws {
        let description = ExtensionWidgetDescription(describing: ShellWidget())
        #expect(description.pillMetadata == nil && description.customHeaderContentPadding == nil && description.popoverIntents == nil)
        let json = String(decoding: try ExtensionJSON.encode(description), as: UTF8.self)
        #expect(!json.contains("pillMetadata") && !json.contains("popoverIntents") && !json.contains("customHeaderContentPadding"))
        #expect(!json.contains("livePeriodicTick"))
    }

    @Test("a description with none of the new keys (what a 3.3.0 handshake is) decodes with them absent")
    func oldDescriptionDecodes() throws {
        let plain = try ExtensionJSON.encode(ExtensionWidgetDescription(describing: ShellWidget()))
        let decoded = try ExtensionJSON.decode(ExtensionWidgetDescription.self, from: plain)
        #expect(decoded.pillMetadata == nil && decoded.popoverIntents == nil && decoded.intents.allSatisfy { $0.livePeriodicTick == nil })
    }

    // MARK: live state

    @Test("the intents' live state is pushed at once, and again when it changes")
    func pushesState() async throws {
        let widget = RecorderLikeWidget()
        let (pair, log) = connect(widget)
        _ = try pair.runtime.view(widgetId: "recording", sessionId: "s1", worktreePath: "/tmp/s1", surface: nil)

        #expect(await until { !log.states.isEmpty })
        let first = try #require(log.states.first?.state.intents.map { ($0.name, $0.enabled) })
        #expect(first.contains { $0 == ("record", true) } && first.contains { $0 == ("stop", false) })

        widget.recording = true
        #expect(await until { log.states.last?.state.intents.first { $0.name == "record" }?.enabled == false })
        let now = try #require(log.states.last?.state.intents.first { $0.name == "stop" })
        #expect(now.enabled && now.title == "0:00")

        widget.seconds = 61
        #expect(await until { log.states.last?.state.intents.first { $0.name == "stop" }?.title == "1:01" })
    }

    @Test("a state that has not changed is not sent again")
    func quiet() async throws {
        let (pair, log) = connect(RecorderLikeWidget())
        _ = try pair.runtime.view(widgetId: "recording", sessionId: "s1", worktreePath: nil, surface: nil)
        #expect(await until { !log.states.isEmpty })
        try await Task.sleep(for: .milliseconds(1_500))
        #expect(log.states.count == 1)
    }

    @Test("a menu intent's live choices travel, and choosing one runs the widget's handler")
    func menu() async throws {
        let widget = RecorderLikeWidget()
        let (pair, log) = connect(widget)
        _ = try pair.runtime.view(widgetId: "recording", sessionId: "s1", worktreePath: nil, surface: nil)
        #expect(await until { !log.states.isEmpty })
        let menu = try #require(log.states.last?.state.intents.first { $0.name == "mic" }?.menu)
        #expect(menu.map(\.id) == ["built-in", "usb"] && menu.first?.isSelected == true)

        let call = try ExtensionCall.make(service: "extension", method: "selectMenuOption", sessionId: "s1", widgetId: "recording",
                                          payload: ExtensionPayload.MenuSelect(name: "mic", optionId: "usb"))
        _ = try await pair.link.send(call, kind: .ui)
        #expect(widget.picked == ["usb"] && widget.mic == "usb")
        #expect(await until { log.states.last?.state.intents.first { $0.name == "mic" }?.menu?.last?.isSelected == true })

        let bad = try ExtensionCall.make(service: "extension", method: "selectMenuOption", sessionId: "s1", widgetId: "recording",
                                         payload: ExtensionPayload.MenuSelect(name: "record", optionId: "x"))
        await #expect(throws: WidgetServiceError.self) { _ = try await pair.link.send(bad, kind: .ui) }
    }

    @Test("header labels travel with the widget's state")
    func headerLabels() async throws {
        let widget = RecorderLikeWidget()
        let (pair, log) = connect(widget)
        _ = try pair.runtime.view(widgetId: "recording", sessionId: "s1", worktreePath: nil, surface: nil)
        widget.headerLabels = [WidgetHeaderLabel(text: "Recording didn't start", systemIcon: "exclamationmark.triangle",
                                                 tint: .failure, url: URL(string: "meet42://widget/permissions"))]
        #expect(await until { log.states.last?.state.headerLabels.first?.text == "Recording didn't start" })
        let sent = try #require(log.states.last?.state.headerLabels.first)
        #expect(sent.tint == "failure" && sent.systemIcon == "exclamationmark.triangle")
        let back = sent.label
        #expect(back.tint == .failure && back.url == URL(string: "meet42://widget/permissions"))
    }

    // MARK: surfaces

    @Test("the pill, the header and a popover are drawn by the extension; an unknown surface is refused by name")
    func surfaces() throws {
        let (pair, _) = connect(RecorderLikeWidget())
        for surface in [nil, ExtensionSurface.pill, ExtensionSurface.header, ExtensionSurface.popover("settings")] {
            _ = try pair.runtime.view(widgetId: "recording", sessionId: "s1", worktreePath: nil, surface: surface)
        }
        #expect(throws: WidgetServiceError.self) {
            _ = try pair.runtime.view(widgetId: "recording", sessionId: "s1", worktreePath: nil, surface: ExtensionSurface.popover("record"))
        }
        let error = #expect(throws: WidgetServiceError.self) {
            _ = try pair.runtime.view(widgetId: "recording", sessionId: "s1", worktreePath: nil, surface: "sidebar")
        }
        #expect(error?.message.contains("sidebar") == true)
    }

    @Test("a widget without a pill refuses the pill surface")
    func noPill() {
        let pair = Pair(widgets: [ExtensionWidgetFactory("todos") { ShellWidget() }])
        pair.link.server.attach(hostServices(shell: CountingShell(), storage: MemoryStore(), sessionId: "s1"), widgetId: "todos", sessionId: "s1")
        #expect(throws: WidgetServiceError.self) {
            _ = try pair.runtime.view(widgetId: "todos", sessionId: "s1", worktreePath: nil, surface: ExtensionSurface.pill)
        }
    }

    @Test("a popover tells Work42 when it asks to close")
    func popoverDismiss() async throws {
        let (pair, log) = connect(RecorderLikeWidget())
        _ = try pair.runtime.view(widgetId: "recording", sessionId: "s1", worktreePath: nil, surface: ExtensionSurface.popover("settings"))
        // The dismiss closure the extension handed the widget calls `widget.dismissPopover`; call it as the widget would.
        let call = try ExtensionCall.make(service: "widget", method: "dismissPopover", sessionId: "s1", widgetId: "recording",
                                          payload: ExtensionPayload.PopoverClosed(intent: "settings"))
        _ = try await pair.runtime.channel?.sendRaw(call)
        #expect(await until { log.dismissed == ["settings"] })
    }

    // MARK: lifetime

    @Test("releasing the session stops its pushers: nothing more is sent")
    func releaseStops() async throws {
        let widget = RecorderLikeWidget()
        let (pair, log) = connect(widget)
        _ = try pair.runtime.view(widgetId: "recording", sessionId: "s1", worktreePath: nil, surface: nil)
        #expect(await until { !log.states.isEmpty })
        pair.runtime.releaseSession("s1")
        let before = log.states.count
        widget.recording = true
        try await Task.sleep(for: .milliseconds(600))
        #expect(log.states.count == before)
    }

    @Test("a segment from a host that predates isPartial decodes as final")
    func transcriptSegment() throws {
        let old = Data(#"{"start":1,"end":2,"text":"hello"}"#.utf8)
        let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: old)
        #expect(decoded.isFinal && decoded.isPartial == nil)
        let partial = TranscriptSegment(start: 1, end: 2, text: "hel", source: .microphone, isPartial: true)
        #expect(!partial.isFinal)
        let encoded = String(decoding: try JSONEncoder().encode(TranscriptSegment(start: 1, end: 2, text: "hello")), as: UTF8.self)
        #expect(!encoded.contains("isPartial"))
    }
}

/// Polls (without blocking a thread) until `condition` holds or `within` passes.
@MainActor
private func until(within limit: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: limit)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}
