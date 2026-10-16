// ConversationLayout.swift — the pure, testable half of the shared conversation view.
//
// `ConversationView` (WOR-235) renders the agent chat and the meeting transcript through one
// component. Everything that is decidable without a view lives here, as plain values: whether
// the conversation is labeled, which items start a run from one actor, where a time divider
// goes, and the load-more window math. No SwiftUI, no isolation: callable from any context
// and covered by `ConversationLayoutTests`.

import Foundation

/// One item of a conversation, reduced to what layout needs.
public struct ConversationEntry<ID: Hashable & Sendable>: Sendable {
    /// The item's identity (the row's `Identifiable.id`).
    public let id: ID
    /// Who said it. Equal ids are the same actor; the count of distinct ids decides labeled mode.
    public let actorID: String
    /// True for the local user. Their items sit on the trailing edge and are never labeled.
    public let isMe: Bool
    /// When it was said; nil items never produce a divider.
    public let date: Date?

    public init(id: ID, actorID: String, isMe: Bool, date: Date?) {
        self.id = id
        self.actorID = actorID
        self.isMe = isMe
        self.date = date
    }
}

public nonisolated enum ConversationLayout {

    /// A conversation with this many distinct actors or more shows avatars and names.
    public static let labeledActorThreshold = 3

    /// A gap of at least this many seconds between consecutive items shows a time divider.
    public static let dividerGap: TimeInterval = 300

    /// True when the conversation has three or more distinct actors.
    ///
    /// Pass the WHOLE conversation, not the rendered window: the mode must not flip while the
    /// user scrolls through history, and a late third speaker must label the earlier items too.
    public static func labeledMode<ID>(entries: [ConversationEntry<ID>]) -> Bool {
        var seen = Set<String>()
        for entry in entries {
            seen.insert(entry.actorID)
            if seen.count >= labeledActorThreshold { return true }
        }
        return false
    }

    /// The ids of the first item of every run of consecutive items from the same actor.
    public static func runStarts<ID>(entries: [ConversationEntry<ID>]) -> Set<ID> {
        var starts = Set<ID>()
        var previousActor: String?
        for entry in entries {
            if entry.actorID != previousActor { starts.insert(entry.id) }
            previousActor = entry.actorID
        }
        return starts
    }

    /// The ids of items that follow the previous dated item by at least `gap` seconds.
    ///
    /// An item with no date never gets a divider and does not move the reference point, so a
    /// dateless item between two dated ones does not hide (or fake) a gap.
    public static func dividerBefore<ID>(
        entries: [ConversationEntry<ID>], gap: TimeInterval = dividerGap
    ) -> Set<ID> {
        var dividers = Set<ID>()
        var previousDate: Date?
        for entry in entries {
            guard let date = entry.date else { continue }
            if let previousDate, date.timeIntervalSince(previousDate) >= gap {
                dividers.insert(entry.id)
            }
            previousDate = date
        }
        return dividers
    }

    // MARK: Load-more window

    /// First rendered chronological index: the trailing `renderCount` items render, everything
    /// before the returned index is hidden until the next page loads.
    public static func renderedStart(itemCount: Int, renderCount: Int) -> Int {
        max(0, itemCount - max(0, renderCount))
    }

    /// The render count after loading one more page of older items.
    public static func grownRenderCount(current: Int, pageSize: Int) -> Int {
        current + max(0, pageSize)
    }
}
