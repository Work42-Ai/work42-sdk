// ExtensionSurfaces.swift — what a widget computes live, and the surfaces it draws besides its tile, carried across the
// process boundary (SDK 3.4.0).
//
// In process the host reads `isEnabled`, `actionAreaTitle`, a `.menu`'s choices and `headerLabels` straight off the widget on
// every render, and asks it for a pill, a custom header and an action-area popover. Out of process none of that can be read
// synchronously, so the extension reads it for the host: whenever it changes it sends one `widget.state` call (the intents'
// live state and the header labels), and the host applies it to the stand-in it keeps for the widget. The pill, the header and
// a popover are drawn by the extension in the same scene as the tile: `scene.attach` carries a `surface` that says which.
//
// Everything here is additive and optional on the wire: an extension built with 3.3.0 never sends `widget.state` (its buttons
// stay static, as before), and a 3.3.0 host answers it with a named "not supported" error the extension ignores.

import Foundation
import Observation
import SwiftUI
import Work42PluginKit

// MARK: - Plain data

/// One choice of an action-area menu (`WidgetIntentMenuOption`).
nonisolated public struct ExtensionMenuOption: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var icon: String?
    public var isSelected: Bool

    public init(id: String, title: String, icon: String? = nil, isSelected: Bool = false) {
        self.id = id; self.title = title; self.icon = icon; self.isSelected = isSelected
    }

    public init(_ option: WidgetIntentMenuOption) {
        self.init(id: option.id, title: option.title, icon: option.icon, isSelected: option.isSelected)
    }

    public var option: WidgetIntentMenuOption {
        WidgetIntentMenuOption(id: id, title: title, icon: icon, isSelected: isSelected)
    }
}

/// What one intent's closures answered the last time the extension asked: `isEnabled`, `isConfirmed`, `actionAreaTitle` and,
/// for a `.menu` intent, the live choices.
nonisolated public struct ExtensionIntentState: Codable, Sendable, Equatable {
    public var name: String
    public var enabled: Bool
    public var confirmed: Bool
    /// `actionAreaTitle()`, or nil when the intent has none (the static title stays).
    public var title: String?
    /// The live choices of a `.menu` intent, or nil.
    public var menu: [ExtensionMenuOption]?

    public init(name: String, enabled: Bool = true, confirmed: Bool = false, title: String? = nil,
                menu: [ExtensionMenuOption]? = nil) {
        self.name = name; self.enabled = enabled; self.confirmed = confirmed; self.title = title; self.menu = menu
    }

    /// Reads `spec`'s closures now.
    @MainActor
    public init(reading spec: WidgetIntentSpec) {
        var menu: [ExtensionMenuOption]?
        if case .menu(let options, _) = spec.actionAreaStyle { menu = options().map(ExtensionMenuOption.init) }
        self.init(name: spec.name, enabled: spec.isEnabled?() ?? true, confirmed: spec.isConfirmed?() ?? false,
                  title: spec.actionAreaTitle?(), menu: menu)
    }
}

/// One header label (`WidgetHeaderLabel`) as data.
nonisolated public struct ExtensionHeaderLabel: Codable, Sendable, Equatable {
    public var text: String
    public var systemIcon: String?
    public var iconURL: URL?
    public var iconImageData: Data?
    public var brandColorHex: String?
    /// `neutral`, `success`, `warning`, `failure` or `accent`.
    public var tint: String
    public var url: URL?
    public var groupId: String?

    public init(text: String, systemIcon: String? = nil, iconURL: URL? = nil, iconImageData: Data? = nil,
                brandColorHex: String? = nil, tint: String = "neutral", url: URL? = nil, groupId: String? = nil) {
        self.text = text; self.systemIcon = systemIcon; self.iconURL = iconURL; self.iconImageData = iconImageData
        self.brandColorHex = brandColorHex; self.tint = tint; self.url = url; self.groupId = groupId
    }

    @MainActor
    public init(_ label: WidgetHeaderLabel) {
        let tint: String
        switch label.tint {
        case .neutral: tint = "neutral"
        case .success: tint = "success"
        case .warning: tint = "warning"
        case .failure: tint = "failure"
        case .accent: tint = "accent"
        @unknown default: tint = "neutral"
        }
        self.init(text: label.text, systemIcon: label.systemIcon, iconURL: label.iconURL,
                  iconImageData: label.iconImageData, brandColorHex: label.brandColorHex, tint: tint, url: label.url,
                  groupId: label.groupId)
    }

    @MainActor
    public var label: WidgetHeaderLabel {
        let role: WidgetHeaderLabelTint
        switch tint {
        case "success": role = .success
        case "warning": role = .warning
        case "failure": role = .failure
        case "accent": role = .accent
        default: role = .neutral
        }
        return WidgetHeaderLabel(text: text, systemIcon: systemIcon, iconURL: iconURL, iconImageData: iconImageData,
                                 brandColorHex: brandColorHex, tint: role, url: url, groupId: groupId)
    }
}

extension ExtensionPayload {
    /// `widget.state` (extension to host): a widget's, or its background agent's, live state. A widget's carries its intents'
    /// state and its header labels; an agent's (the call says `agent`) only its header labels.
    nonisolated public struct WidgetState: Codable, Sendable, Equatable {
        public var intents: [ExtensionIntentState]
        public var headerLabels: [ExtensionHeaderLabel]

        public init(intents: [ExtensionIntentState] = [], headerLabels: [ExtensionHeaderLabel] = []) {
            self.intents = intents; self.headerLabels = headerLabels
        }
    }

    /// `extension.selectMenuOption` (host to extension): the person chose `optionId` in the menu of intent `name`.
    nonisolated public struct MenuSelect: Codable, Sendable, Equatable {
        public var name: String, optionId: String
        public init(name: String, optionId: String) { self.name = name; self.optionId = optionId }
    }

    /// `widget.dismissPopover` (extension to host): the popover of action-area intent `intent` asked to close.
    nonisolated public struct PopoverClosed: Codable, Sendable, Equatable {
        public var intent: String
        public init(intent: String) { self.intent = intent }
    }
}

/// What the host learns from an extension about one of its widgets, other than through a service.
nonisolated public enum ExtensionWidgetEvent: Sendable, Equatable {
    /// The widget's (or, with `agent`, its agent's) live state changed.
    case state(widgetId: String, sessionId: String, agent: Bool, ExtensionPayload.WidgetState)
    /// The widget's popover for `intent` asked to close.
    case dismissPopover(widgetId: String, sessionId: String, intent: String)
}

/// The surface names `scene.attach` carries (`ExtensionPayload.SessionContext.surface`). Absent means the tile.
nonisolated public enum ExtensionSurface {
    public static let tile = "widget"
    public static let pill = "pill"
    public static let header = "header"
    /// `popover:<intent name>`.
    public static func popover(_ intent: String) -> String { "popover:\(intent)" }
    public static let popoverPrefix = "popover:"
}

// MARK: - Pushing live state (extension side)

/// Reads a widget's, or an agent's, live state and sends it to Work42 whenever it changes. The reading is observed (an
/// `@Observable` widget that changes what `isEnabled` or `headerLabels` read wakes it at once) and is repeated every
/// `tick` seconds (the smallest `livePeriodicTick` of the intents, else one second) for what no observation covers, such
/// as a timer in `actionAreaTitle`. Only a changed state is sent.
@MainActor
final class ExtensionStatePusher {
    /// How long an unchanged state goes unsent.
    static let heartbeat: TimeInterval = 5

    private var task: Task<Void, Never>?

    /// A pusher for a widget instance (its intents and header labels).
    static func widget(_ widget: any Work42Widget, channel: ExtensionChannel, sessionId: String, widgetId: String)
        -> ExtensionStatePusher {
        let pusher = ExtensionStatePusher()
        pusher.run(channel: channel, sessionId: sessionId, widgetId: widgetId, agent: false,
                   tick: { [weak widget] in widget?.intents.compactMap(\.livePeriodicTick).min() },
                   read: { [weak widget] in
                       guard let widget else { return nil }
                       // `headerLabels` is an opt-in protocol (`Work42WidgetHeaderLabels`): a widget without it has none.
                       let labels = (widget as? any Work42WidgetHeaderLabels)?.headerLabels ?? []
                       return ExtensionPayload.WidgetState(
                           intents: widget.intents.map(ExtensionIntentState.init(reading:)),
                           headerLabels: labels.map(ExtensionHeaderLabel.init))
                   })
        return pusher
    }

    /// A pusher for a background agent (its header labels).
    static func agent(_ agent: any WidgetBackgroundAgent, channel: ExtensionChannel, sessionId: String, widgetId: String)
        -> ExtensionStatePusher {
        let pusher = ExtensionStatePusher()
        pusher.run(channel: channel, sessionId: sessionId, widgetId: widgetId, agent: true, tick: { nil },
                   read: { [weak agent] in
                       guard let agent else { return nil }
                       return ExtensionPayload.WidgetState(headerLabels: agent.headerLabels.map(ExtensionHeaderLabel.init))
                   })
        return pusher
    }

    private func run(channel: ExtensionChannel, sessionId: String, widgetId: String, agent: Bool,
                     tick: @escaping @MainActor () -> TimeInterval?,
                     read: @escaping @MainActor () -> ExtensionPayload.WidgetState?) {
        task = Task { @MainActor in
            var last: ExtensionPayload.WidgetState?
            var lastSent = Date.distantPast
            while !Task.isCancelled {
                let (wakes, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                // The closures are read inside the observation, so a change of anything they read wakes the loop.
                guard let state = withObservationTracking({ read() }, onChange: { wake.yield() }) else { return }
                // A state is also resent every few seconds when it has not changed: the host's stand-in for the widget may have
                // been made after the first push (the extension makes its instance before the tile attaches), and a push that
                // nobody received must not leave the buttons wrong until the next change.
                if state != last || Date().timeIntervalSince(lastSent) >= Self.heartbeat {
                    last = state
                    lastSent = Date()
                    // A host that predates `widget.state` answers "not supported": the buttons stay static there.
                    do {
                        try await channel.call("widget", "state", sessionId: sessionId, widgetId: widgetId,
                                               agent: agent ? true : nil, payload: state)
                    } catch let error as WidgetServiceError where error.message.contains("not supported") {
                        return
                    } catch {
                        // The connection is gone or the host is busy: the next change sends it again.
                        last = nil
                    }
                }
                let interval = max(0.25, tick() ?? 1)
                let timer = Task { try? await Task.sleep(for: .seconds(interval)); wake.yield() }
                for await _ in wakes { break }
                timer.cancel()
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
