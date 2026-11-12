// Collaboration.swift — widgets are collaborative by default (SDK 2.14.0, ABI 16; WOR-773, WOR-779).
//
// A session can have several people and several agents in it, and a widget is the same widget for all of them. What this file adds is
// the vocabulary a widget uses to say how it behaves with more than one of them:
//
//   - `WidgetCollaboration` — which of three kinds of widget it is: shared (one state, everyone edits it), personal (each person has
//     their own and others may watch) or hosted (it runs on one device and others see it and may type into it).
//   - `WidgetScopeSpec` — the things a collaborator can be allowed to do in the widget. A person is let into a widget with some of its
//     scopes, and an intent says which scope it needs (`WidgetIntentSpec.requires`).
//   - `WidgetCollaborator` — who is acting: a person (with a role in the session) or an agent. `SessionServices.actor` is the one
//     acting now, and a button can read differently for each viewer.
//   - `WidgetAudience` — which people an intent is for.
//   - `WidgetCollaborationService` — who is here, where their cursors are, and how this widget reports its own.
//
// Nothing here has to be used: a widget that declares none of it is a shared widget with last-write-wins, no cursors, one scope (`use`)
// and intents that everyone in the session may press and agents may not.

import Foundation

// MARK: - Instances

/// Which instance of a widget something belongs to: one session, one widget, and for a personal widget one device.
///
/// Every browser-based widget is its own instance. Its tabs, history, scroll and page state belong to that instance alone and are never
/// shared with another session or, for a personal widget, another device. Only the website data store underneath (cookies and logins, named
/// by `dataStoreKey`) may be shared between instances. `cacheKey` is the key the SDK's caches use for the instance, so two keys that differ
/// in any part never meet.
nonisolated public struct InstanceKey: Sendable, Hashable, Codable {
    public let sessionID: String
    public let widgetID: String
    /// The device the instance lives on. Set for a personal widget (each device has its own), nil for a shared or hosted one.
    public let deviceID: String?

    public init(sessionID: String, widgetID: String, deviceID: String? = nil) {
        self.sessionID = sessionID
        self.widgetID = widgetID
        self.deviceID = deviceID
    }

    /// `<session>/<widget>`, or `<session>/<widget>@<device>` for a personal widget's instance on a device. The session part is the same
    /// scope `BrowserSurfaceCache.scopedKey` puts before a surface's key, so a shared instance keeps the key it always had.
    public var cacheKey: String {
        deviceID.map { "\(sessionID)/\(widgetID)@\($0)" } ?? "\(sessionID)/\(widgetID)"
    }
}

// MARK: - Scopes

/// One thing a collaborator can be allowed to do in a widget (for a browser: `view`, `navigate`, `act`). The id is lowercase and stable:
/// it is what a person's access to the widget names.
nonisolated public struct WidgetScopeSpec: Sendable, Hashable, Codable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    /// The scope every widget has when it declares none: being allowed to use it at all.
    public static let use = WidgetScopeSpec(id: "use", title: "Use")
}

// MARK: - The three kinds of widget

/// What happens when two people change the same shared state at once.
nonisolated public enum WidgetConflictPolicy: Sendable, Hashable, Codable {
    /// The later write wins. What every widget did before collaboration.
    case lastWriteWins
    /// A write made from an older version than the stored one is refused, so the person who lost sees it instead of overwriting.
    case rejectStale
}

/// What a shared widget shows of the others looking at it.
nonisolated public enum WidgetCursorKind: Sendable, Hashable, Codable {
    /// No cursors.
    case none
    /// A pointer at a position in the widget (`WidgetAnchor.point`).
    case pointer
    /// A caret and selection in text (`WidgetAnchor.text`).
    case text
    /// A pointer and selection in a rendered page (`WidgetAnchor.page`).
    case page
}

/// Whether an agent may drive a personal widget, on the person's own device.
nonisolated public enum WidgetAgentControl: Sendable, Hashable, Codable {
    case never
    /// Only an agent the person allows.
    case withPermission
}

/// Whether others may type into a hosted widget.
nonisolated public enum WidgetHostedInput: Sendable, Hashable, Codable {
    case viewOnly
    /// People the host allows may send input to it.
    case withPermission
}

/// How a widget behaves with more than one collaborator.
nonisolated public enum WidgetCollaboration: Sendable, Hashable, Codable {
    /// One state for the whole session: a file, a plan, a board.
    case shared(conflict: WidgetConflictPolicy, cursors: WidgetCursorKind)
    /// One state per device: each has its own browser. Who watches it is not the widget's to say: following a device (approved by that
    /// device, for the whole session) shows its personal widgets read-only, and the host draws that, not the widget.
    case personal(agentControl: WidgetAgentControl)
    /// It runs on one device (a simulator, a terminal) and others see it and, with permission, type into it.
    case hosted(input: WidgetHostedInput)

    /// What a widget is when it says nothing.
    public static let `default`: WidgetCollaboration = .shared(conflict: .lastWriteWins, cursors: .none)
}

/// What a personal widget tells the devices that follow it about itself: its tabs, and which one is in front. The follower's header
/// draws these read-only next to the live picture (WOR-796).
nonisolated public struct FollowSummary: Sendable, Hashable, Codable {
    /// The titles of the widget's tabs, in order.
    public let tabs: [String]
    /// The index of the tab in front, nil when none is.
    public let selected: Int?

    public init(tabs: [String], selected: Int? = nil) {
        self.tabs = tabs
        // A selection outside the tabs names nothing.
        self.selected = selected.flatMap { tabs.indices.contains($0) ? $0 : nil }
    }

    /// What a widget with no tabs says.
    public static let none = FollowSummary(tabs: [])
}

// MARK: - Collaborators

/// Who is acting in a session: a person, or an agent.
nonisolated public struct WidgetCollaborator: Sendable, Hashable, Codable, Identifiable {

    public enum Kind: String, Sendable, Hashable, Codable {
        case person
        case agent
    }

    /// The role a person was let into the session with. An agent has none.
    public enum Role: String, Sendable, Hashable, Codable {
        case owner
        case member
    }

    /// The person's account, or the agent's own id (`agent:…`). The same person on another device has the same id.
    public let id: String
    public let displayName: String
    public let kind: Kind
    public let role: Role?
    /// The roles the session's workflow gave them (`reviewer`, `approver`), sorted.
    public let workflowRoles: [String]
    /// Whether this is the person's own device, as opposed to a sidekick (a second device of theirs that follows their role).
    public let isPrimaryDevice: Bool
    /// A stable key the host draws their colour from, so a person looks the same in every widget.
    public let colorKey: String

    public init(
        id: String,
        displayName: String,
        kind: Kind = .person,
        role: Role? = nil,
        workflowRoles: [String] = [],
        isPrimaryDevice: Bool = true,
        colorKey: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        // An agent has no administrative role, whatever it is told.
        self.role = kind == .agent ? nil : role
        self.workflowRoles = Set(workflowRoles).sorted()
        self.isPrimaryDevice = isPrimaryDevice
        self.colorKey = colorKey ?? id
    }

    public var isAgent: Bool { kind == .agent }
    public var isOwner: Bool { role == .owner }

    /// Whether `other` is the same person as this collaborator (a sidekick of theirs counts). An agent is only itself.
    public func isSamePerson(as other: WidgetCollaborator) -> Bool { id == other.id }

    /// The collaborator a host without sessions of several people (previews, tests, Home) acts as: the person at the keyboard.
    public static let solo = WidgetCollaborator(id: "local", displayName: "You", role: .owner)
}

// MARK: - Audience

/// One entry in an intent's allow-list.
nonisolated public enum WidgetAudienceRule: Sendable, Hashable, Codable {
    case everyone
    /// People let in as owner.
    case owners
    /// People let in as member (not owners).
    case members
    /// People who hold this workflow role.
    case role(String)
}

/// Which people an intent is for: a list of who is allowed, and optionally only on their own device. An agent is never in an audience;
/// whether an agent may press an intent is the intent's own `agents` setting.
nonisolated public struct WidgetAudience: Sendable, Hashable, Codable {
    public let allowed: [WidgetAudienceRule]
    public let requiresPrimaryDevice: Bool

    public init(_ allowed: [WidgetAudienceRule], requiresPrimaryDevice: Bool = false) {
        self.allowed = allowed
        self.requiresPrimaryDevice = requiresPrimaryDevice
    }

    public static let everyone = WidgetAudience([.everyone])
    public static let owners = WidgetAudience([.owners])
    public static let members = WidgetAudience([.members])
    public static func roles(_ roles: String...) -> WidgetAudience { WidgetAudience(roles.map { .role($0) }) }
    /// Nobody: an intent that is declared but not for anyone yet.
    public static let nobody = WidgetAudience([])

    /// The same audience, only from the person's own device: a sidekick of theirs does not count. For an approval that must come from
    /// the person themselves.
    public var primaryDeviceOnly: WidgetAudience { WidgetAudience(allowed, requiresPrimaryDevice: true) }

    public func allows(_ who: WidgetCollaborator) -> Bool {
        guard !who.isAgent else { return false }
        if requiresPrimaryDevice && !who.isPrimaryDevice { return false }
        return allowed.contains { rule in
            switch rule {
            case .everyone: return true
            case .owners: return who.role == .owner
            case .members: return who.role == .member
            case .role(let role): return who.workflowRoles.contains(role)
            }
        }
    }
}

/// Whether an agent may press an intent.
nonisolated public enum WidgetAgentAccess: Sendable, Hashable, Codable {
    /// The default: an agent cannot press it.
    case notAllowed
    /// An agent may press it, as itself.
    case allowed
}

// MARK: - Anchors and cursors

/// A place in a widget, in the terms of what the widget shows. Positions are in the widget's own coordinates or content, never the
/// screen's, so they mean the same on every device.
nonisolated public enum WidgetAnchor: Sendable, Hashable, Codable {
    /// A point in the widget, each coordinate 0 to 1 of its size.
    case point(x: Double, y: Double)
    /// A position in a text document, 0-based, in the version the reporter had.
    case text(path: String, version: Int, line: Int, column: Int)
    /// A position in a rendered page, found again by the text around it so it survives the page changing.
    case page(quote: String, prefix: String, suffix: String, elementPath: String)
}

/// What a widget reports about the acting collaborator's own pointer.
nonisolated public struct WidgetCursorReport: Sendable, Hashable, Codable {
    public let anchor: WidgetAnchor
    /// The other end of a selection that starts at `anchor`, or nil for a plain cursor.
    public let selectionEnd: WidgetAnchor?
    /// Whether this report is a click at the anchor.
    public let isClick: Bool

    public init(anchor: WidgetAnchor, selectionEnd: WidgetAnchor? = nil, isClick: Bool = false) {
        self.anchor = anchor
        self.selectionEnd = selectionEnd
        self.isClick = isClick
    }
}

/// Where one collaborator is in a widget now.
nonisolated public struct WidgetCursor: Sendable, Hashable, Codable, Identifiable {
    public let who: WidgetCollaborator
    public let report: WidgetCursorReport

    public var id: String { who.id }

    public init(who: WidgetCollaborator, report: WidgetCursorReport) {
        self.who = who
        self.report = report
    }
}

// MARK: - The service

/// Who is in the session and where they are. Backed by the host's session stream; the widget only sees these payloads.
nonisolated public protocol WidgetCollaborationService: Sendable {

    /// Everyone in the session now: the people (one entry per person) and the agents.
    func members() async throws -> [WidgetCollaborator]

    /// The others' cursors in this widget, as the full current set each time one changes. The acting collaborator's own is left out.
    /// The stream ends when the widget deactivates.
    func cursors() -> AsyncStream<[WidgetCursor]>

    /// Say where the acting collaborator's pointer is in this widget, or `nil` that it left. Rate-limited by the host: a widget may
    /// report as often as it likes and the host sends the latest.
    func report(_ cursor: WidgetCursorReport?) async throws
}

/// The service for a host with one person and no live session around it (previews, tests, Home): nobody else is here, so there is
/// nothing to show and nothing to send.
nonisolated public struct SoloWidgetCollaborationService: WidgetCollaborationService {
    public let actor: WidgetCollaborator

    public init(actor: WidgetCollaborator = .solo) { self.actor = actor }

    public func members() async throws -> [WidgetCollaborator] { [actor] }

    public func cursors() -> AsyncStream<[WidgetCursor]> {
        AsyncStream { $0.finish() }
    }

    public func report(_ cursor: WidgetCursorReport?) async throws {}
}

// MARK: - Per-person storage

extension WidgetStorageService {

    private var unavailable: WidgetServiceError {  // defaults for the requirements declared on the protocol
        WidgetServiceError(
            message: "this host does not keep storage per person",
            suggestion: "run the widget inside Work42 2.14.0 or later, or use set(key:value:) for state the whole session shares")
    }

    /// The acting person's own value at `key` in this widget's namespace, or nil when they have not set one. What another person
    /// stored under the same key is a different value.
    public func person(key: String) async throws -> WidgetJSONValue? { throw unavailable }

    /// Set the acting person's own value at `key`. Only they write it.
    public func setPerson(key: String, value: WidgetJSONValue) async throws { throw unavailable }

    /// Remove the acting person's own value at `key`. No-op when they have none.
    public func deletePerson(key: String) async throws { throw unavailable }

    /// Every person's value at `key`, by the person's id: who approved, who has read it. Read-only.
    public func people(key: String) async throws -> [String: WidgetJSONValue] { throw unavailable }
}
