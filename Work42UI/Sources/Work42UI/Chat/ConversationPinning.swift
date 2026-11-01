// ConversationPinning.swift - When the chat follows the bottom, and when it lets go (WOR-473, AC59).
//
// The conversation stays at its newest content while the reader is at the bottom: when content grows (a row opens,
// an image appears, the working indicator shows) the view follows. Only the reader's own scroll gesture moving away
// from the bottom unpins it; arriving back within the threshold pins again. Content growth never unpins, and while
// unpinned nothing moves the view.

import CoreGraphics

public nonisolated enum ConversationPinning {

    /// Within this many points of the bottom edge counts as "at the bottom".
    public static let threshold: CGFloat = 24

    public struct Outcome: Equatable {
        public var pinned: Bool
        /// The content grew while pinned: scroll to the bottom to keep following it.
        public var follow: Bool
    }

    /// The next state after the bottom anchor reported `distance` (points below the viewport's bottom edge; 0 or
    /// negative is at the bottom), while `pinned` and the reader is or is not `scrolling` by hand.
    public static func resolve(pinned: Bool, distance: CGFloat, isUserScrolling: Bool) -> Outcome {
        if distance <= threshold { return Outcome(pinned: true, follow: false) }
        if pinned {
            // Away from the bottom: the reader did it only if a gesture is live; otherwise the content grew.
            return isUserScrolling ? Outcome(pinned: false, follow: false) : Outcome(pinned: true, follow: true)
        }
        return Outcome(pinned: false, follow: false)
    }
}
