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
    /// Past this many viewports from the top the reader has left, and the next arrival may load.
    public static let departureViewports: CGFloat = 2

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
            if offsetFromTop > viewportHeight * Self.departureViewports { phase = .armed }
            return nil
        case .inserting:
            return nil
        }
    }

    /// The page of `generation` is in place (or its hold ended). A stale generation is ignored.
    public mutating func pageDone(generation done: Int, offsetFromTop: CGFloat, viewportHeight: CGFloat) {
        guard phase == .inserting(generation: done) else { return }
        phase = offsetFromTop > viewportHeight * Self.departureViewports ? .armed : .waitingForDeparture
    }

    /// A different conversation, or the view went back to the bottom: start again.
    public mutating func reset() {
        phase = .armed
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
