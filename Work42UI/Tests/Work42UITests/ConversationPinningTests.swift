import Testing
@testable import Work42UI

struct ConversationPinningTests {

    @Test func atTheBottomStaysPinnedAndNeedsNoScroll() {
        #expect(ConversationPinning.resolve(pinned: true, distance: 0, isUserScrolling: false)
                == .init(pinned: true, follow: false))
        #expect(ConversationPinning.resolve(pinned: true, distance: -40, isUserScrolling: false).follow == false)
    }

    @Test func growthWhilePinnedFollowsTheBottom() {
        // Content grew: the anchor is now far below the viewport, but nobody scrolled.
        #expect(ConversationPinning.resolve(pinned: true, distance: 300, isUserScrolling: false)
                == .init(pinned: true, follow: true))
    }

    @Test func growthWhileUnpinnedLeavesTheViewAlone() {
        #expect(ConversationPinning.resolve(pinned: false, distance: 300, isUserScrolling: false)
                == .init(pinned: false, follow: false))
        // Even while the reader scrolls elsewhere.
        #expect(ConversationPinning.resolve(pinned: false, distance: 900, isUserScrolling: true)
                == .init(pinned: false, follow: false))
    }

    @Test func onlyAUserGestureAwayFromTheBottomUnpins() {
        #expect(ConversationPinning.resolve(pinned: true, distance: 120, isUserScrolling: true)
                == .init(pinned: false, follow: false))
        // A small wobble inside the threshold is still the bottom.
        #expect(ConversationPinning.resolve(pinned: true, distance: ConversationPinning.threshold, isUserScrolling: true).pinned)
    }

    @Test func returningWithinTheThresholdPinsAgain() {
        #expect(ConversationPinning.resolve(pinned: false, distance: 10, isUserScrolling: true)
                == .init(pinned: true, follow: false))
        #expect(ConversationPinning.resolve(pinned: false, distance: 10, isUserScrolling: false).pinned)
    }
}
