// ConversationPaging.swift - When an older page may load, and how the reader's place is held while it lands (WOR-553, WOR-554).
//
// Two small pure types, so the rules are tested without a view:
//
// `ConversationPaging` is the loading state machine: armed -> inserting(generation) -> waitingForDeparture -> armed. Only a
// reader-driven UPWARD move into the top threshold, while armed, loads a page. After the page is placed the reader must move
// out past a margin before another can load, so a page never triggers the next one and a layout change, a programmatic offset
// or a downward move never loads anything.
//
// `ConversationHold` is the decision of the place-holding loop that runs while a page lands: keep the reader's distance from
// the bottom through EVERY layout of that load, finish only after the content has been still for a while and at least one
// correction was applied, give up honestly (never report success for a hold that applied nothing), and stop at once when the
// reader scrolls.

import CoreGraphics

public nonisolated struct ConversationPaging: Equatable {

    public enum Phase: Equatable {
        case armed
        case inserting(generation: Int)
        case waitingForDeparture
    }

    public enum Direction: Equatable {
        case up, down, none
    }

    public private(set) var phase: Phase = .armed
    public private(set) var generation = 0

    public init() {}

    /// Within this many viewports of the top counts as "at the top" (a load is due).
    public static let arrivalViewports: CGFloat = 1
    /// Past this many viewports from the top the reader has left (a move down also leaves), and the next arrival may load.
    public static let departureViewports: CGFloat = 1.5

    /// The reader moved the content (a live scroll, never one of ours). Returns the generation of the page to load, or nil.
    public mutating func readerMoved(
        offsetFromTop: CGFloat, direction: Direction, viewportHeight: CGFloat, hasOlder: Bool
    ) -> Int? {
        switch phase {
        case .armed:
            guard hasOlder, direction == .up, offsetFromTop <= viewportHeight * Self.arrivalViewports else { return nil }
            generation += 1
            phase = .inserting(generation: generation)
            return generation
        case .waitingForDeparture:
            // The reader has left the top: any move DOWN does (so a short window, where the margin below can never be
            // reached, is never stuck), as does being far from it. Moves up while still at the top load nothing.
            if direction == .down || offsetFromTop > viewportHeight * Self.departureViewports { phase = .armed }
            return nil
        case .inserting:
            return nil
        }
    }

    /// The page of `generation` is finished. `placed` false means the hold could not keep the reader's place: the reader
    /// may be left at the top with the page above them, so the next upward move must be allowed to load, not wait for a
    /// departure that cannot happen. A stale generation is ignored.
    public mutating func pageDone(generation done: Int, offsetFromTop: CGFloat, viewportHeight: CGFloat, placed: Bool = true) {
        guard phase == .inserting(generation: done) else { return }
        phase = !placed || offsetFromTop > viewportHeight * Self.departureViewports ? .armed : .waitingForDeparture
    }

    /// A different conversation, or the view went back to the bottom: start again.
    public mutating func reset() {
        phase = .armed
    }
}

/// History the host keeps and the view asks for (WOR-642): a conversation whose older messages are not in `items` yet, such as the
/// iPad's, where the Mac holds them. Reaching the top with nothing older left in the window calls `load`; the page lands as items
/// added at the FRONT of `items`, and the reader stays on the message they were reading.
public struct ConversationLoadMore {
    /// Whether the host has older messages to send.
    public var hasMore: Bool
    /// Whether a request is out. No second one is made meanwhile.
    public var isLoading: Bool
    /// Why the last request failed, or nil. Shown above the first row with a Retry that calls `load`.
    public var error: String?
    /// Asks the host for the next older page.
    public var load: @MainActor () -> Void

    public init(hasMore: Bool, isLoading: Bool, error: String? = nil, load: @escaping @MainActor () -> Void) {
        self.hasMore = hasMore
        self.isLoading = isLoading
        self.error = error
        self.load = load
    }
}

/// The rules for asking the host for an older page, pure so they are tested without a view (WOR-642).
public nonisolated enum ConversationRemoteLoad {

    /// Whether arriving at the top should ask the host: nothing older is left to show from what is held, the host has more, and no
    /// request is out already.
    public static func canLoad(hiddenOlder: Int, hasMore: Bool, isLoading: Bool) -> Bool {
        hiddenOlder == 0 && hasMore && !isLoading
    }

    /// Whether there is anything older to bring in at the top: a page of what is held, or one the host can send. What
    /// `ConversationPaging.readerMoved` is told, so one arrival loads one page.
    public static func hasOlder(hiddenOlder: Int, hasMore: Bool, isLoading: Bool) -> Bool {
        hiddenOlder > 0 || canLoad(hiddenOlder: hiddenOlder, hasMore: hasMore, isLoading: isLoading)
    }

    /// How many items a page added to the front, given what was there when it was asked for and what is there now; nil when
    /// nothing was added in front (the request failed, or the chat only grew at its end).
    public static func prepended(
        firstBefore: AnyHashable?, countBefore: Int, firstNow: AnyHashable?, countNow: Int
    ) -> Int? {
        guard firstBefore != firstNow, countNow > countBefore else { return nil }
        return countNow - countBefore
    }
}

public nonisolated enum ConversationHold {

    public enum Step: Equatable {
        /// The content changed size since the last correction: apply the distance again now.
        case apply
        case keepWaiting
        /// At least one correction was applied and the content has been still: the page is in place.
        case settled
        /// Time ran out with no correction applied: the place was NOT held.
        case gaveUp
        /// The reader started scrolling: stop holding.
        case cancelled
    }

    /// How long a hold may run.
    public static let maxDuration: Double = 1.5
    /// Consecutive idle ticks (about 16 ms each) that count as "the content is still".
    public static let settleTicks = 8

    public static func step(
        contentChanged: Bool, applied: Int, idleTicks: Int, elapsed: Double, readerScrolling: Bool
    ) -> Step {
        if readerScrolling { return .cancelled }
        if contentChanged { return .apply }
        if elapsed >= maxDuration { return applied > 0 ? .settled : .gaveUp }
        if applied > 0, idleTicks >= settleTicks { return .settled }
        return .keepWaiting
    }

    /// The offset (from the top) that keeps `distanceFromBottom` between the viewport's bottom edge and the content's.
    public static func offset(documentHeight: CGFloat, viewportHeight: CGFloat, distanceFromBottom: CGFloat) -> CGFloat {
        let furthest = max(0, documentHeight - viewportHeight)
        return min(max(0, documentHeight - viewportHeight - distanceFromBottom), furthest)
    }
}
