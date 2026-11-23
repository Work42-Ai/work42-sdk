// ExtensionDescription.swift — what the host needs to know about an extension's widgets before any session uses them
// (SDK 3.2.0).
//
// In process the host reads a widget's title, icon, size and intents straight off the object. Out of process it reads
// them once, from the handshake: every value here is plain data. What a widget computes live (`isEnabled`,
// `isConfirmed`, `actionAreaTitle`, `.menu` choices) cannot be read synchronously across a process boundary, so an
// extension's action-area buttons are always enabled and show their static title. A custom header
// (`Work42WidgetCustomHeader`), header labels and item kinds stay in-process features in 3.2.0.

import Foundation
import Work42PluginKit

/// One intent's static metadata. Its handler stays in the extension; the host calls `extension.performIntent`.
nonisolated public struct ExtensionIntentDescription: Codable, Sendable, Equatable {
    public var name: String
    public var title: String
    public var icon: String
    public var iconImageData: Data?
    public var brandColorHex: String?
    public var keywords: [String]
    /// `palette`, `actionArea`, `header`.
    public var placement: [String]
    /// `labeled`, `icon` or `pill`. A `.menu` style is described as `labeled`: its choices are live.
    public var actionAreaStyle: String
    public var requires: String?

    public init(name: String, title: String, icon: String, iconImageData: Data? = nil, brandColorHex: String? = nil,
                keywords: [String] = [], placement: [String] = ["palette"], actionAreaStyle: String = "labeled",
                requires: String? = nil) {
        self.name = name; self.title = title; self.icon = icon; self.iconImageData = iconImageData
        self.brandColorHex = brandColorHex; self.keywords = keywords; self.placement = placement
        self.actionAreaStyle = actionAreaStyle; self.requires = requires
    }
}

/// One link matcher (`WidgetLinkMatcher`) as data.
nonisolated public struct ExtensionLinkMatcherDescription: Codable, Sendable, Equatable {
    /// `regex`, `scheme` or `wildcard`.
    public var kind: String
    public var value: String?

    public init(kind: String, value: String? = nil) { self.kind = kind; self.value = value }
}

/// One widget's static metadata.
nonisolated public struct ExtensionWidgetDescription: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var icon: String
    public var iconImageData: Data?
    public var minSize: WidgetMinSize
    public var storageNamespace: String?
    public var collaboration: WidgetCollaboration
    public var scopes: [WidgetScopeSpec]
    public var intents: [ExtensionIntentDescription]
    /// One entry per `linkIntents` element, in order: the host sends `extension.openLink` with that index.
    public var linkIntents: [[ExtensionLinkMatcherDescription]]
    /// The widget conforms to `Work42WidgetBackground`.
    public var hasBackgroundAgent: Bool
    /// The widget conforms to `Work42BrowserBacked` with a surface: the host draws its browser and needs no scene.
    public var isBrowserBacked: Bool
    /// `Work42BrowserWidgetOptions.prefersDefaultWidgetHeader` (false when the widget does not conform).
    public var prefersDefaultWidgetHeader: Bool

    public init(id: String, title: String, icon: String, iconImageData: Data? = nil, minSize: WidgetMinSize = .zero,
                storageNamespace: String? = nil, collaboration: WidgetCollaboration = .default,
                scopes: [WidgetScopeSpec] = [.use], intents: [ExtensionIntentDescription] = [],
                linkIntents: [[ExtensionLinkMatcherDescription]] = [], hasBackgroundAgent: Bool = false,
                isBrowserBacked: Bool = false, prefersDefaultWidgetHeader: Bool = false) {
        self.id = id; self.title = title; self.icon = icon; self.iconImageData = iconImageData; self.minSize = minSize
        self.storageNamespace = storageNamespace; self.collaboration = collaboration; self.scopes = scopes
        self.intents = intents; self.linkIntents = linkIntents; self.hasBackgroundAgent = hasBackgroundAgent
        self.isBrowserBacked = isBrowserBacked; self.prefersDefaultWidgetHeader = prefersDefaultWidgetHeader
    }
}

extension ExtensionPayload {
    /// `extension.openLink` arguments: which of the widget's `linkIntents` claimed the URL.
    nonisolated public struct OpenLink: Codable, Sendable {
        public var index: Int, url: URL, worktreePath: String?
        public init(index: Int, url: URL, worktreePath: String?) {
            self.index = index; self.url = url; self.worktreePath = worktreePath
        }
    }
}

@MainActor
extension ExtensionWidgetDescription {
    /// Reads `widget`'s metadata. Never activates it.
    public init(describing widget: any Work42Widget) {
        self.init(
            id: widget.id, title: widget.title, icon: widget.icon, iconImageData: widget.iconImageData,
            minSize: widget.minSize, storageNamespace: widget.storageNamespace, collaboration: widget.collaboration,
            scopes: widget.scopes,
            intents: widget.intents.map(ExtensionIntentDescription.init(describing:)),
            linkIntents: widget.linkIntents.map { $0.matchers.map(ExtensionLinkMatcherDescription.init(describing:)) },
            hasBackgroundAgent: widget is any Work42WidgetBackground,
            isBrowserBacked: (widget as? any Work42BrowserBacked)?.browserSurface != nil,
            prefersDefaultWidgetHeader: (widget as? any Work42BrowserWidgetOptions)?.prefersDefaultWidgetHeader ?? false)
    }
}

extension ExtensionIntentDescription {
    @MainActor public init(describing spec: WidgetIntentSpec) {
        let style: String
        switch spec.actionAreaStyle {
        case .icon: style = "icon"
        case .pill: style = "pill"
        default: style = "labeled"
        }
        self.init(
            name: spec.name, title: spec.title, icon: spec.icon, iconImageData: spec.iconImageData,
            brandColorHex: spec.brandColorHex, keywords: spec.keywords,
            placement: spec.placement.map { placement -> String in
                switch placement {
                case .palette: "palette"
                case .actionArea: "actionArea"
                case .header: "header"
                @unknown default: "palette"
                }
            }.sorted(),
            actionAreaStyle: style, requires: spec.requires)
    }
}

extension ExtensionLinkMatcherDescription {
    @MainActor public init(describing matcher: WidgetLinkMatcher) {
        switch matcher {
        case .regex(let pattern): self.init(kind: "regex", value: pattern)
        case .scheme(let scheme): self.init(kind: "scheme", value: scheme)
        case .wildcard: self.init(kind: "wildcard")
        @unknown default: self.init(kind: "wildcard")
        }
    }

    /// The matcher, or nil for a kind this SDK does not know (the host skips it).
    @MainActor public var matcher: WidgetLinkMatcher? {
        switch kind {
        case "regex": value.map(WidgetLinkMatcher.regex)
        case "scheme": value.map(WidgetLinkMatcher.scheme)
        case "wildcard": .wildcard
        default: nil
        }
    }
}
