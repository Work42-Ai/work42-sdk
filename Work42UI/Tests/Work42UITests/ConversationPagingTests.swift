// ConversationPagingTests.swift - WOR-553/554: one page per arrival at the top, and a hold that never counts a failure as success.

import CoreGraphics
import Testing
@testable import Work42UI

@Suite("Conversation paging and place holding (WOR-553, WOR-554)")
struct ConversationPagingTests {

    private let viewport: CGFloat = 1000

    @Test("an upward arrival at the top loads one page; nothing else does")
    func oneLoadPerArrival() {
        var paging = ConversationPaging()
        #expect(paging.readerMoved(offsetFromTop: 1500, direction: .up, viewportHeight: viewport, hasOlder: true) == nil)
        #expect(paging.readerMoved(offsetFromTop: 900, direction: .down, viewportHeight: viewport, hasOlder: true) == nil)
        #expect(paging.readerMoved(offsetFromTop: 900, direction: .up, viewportHeight: viewport, hasOlder: false) == nil)
        #expect(paging.readerMoved(offsetFromTop: 900, direction: .up, viewportHeight: viewport, hasOlder: true) == 1)
        // The page is in flight: more upward moves load nothing.
        #expect(paging.readerMoved(offsetFromTop: 100, direction: .up, viewportHeight: viewport, hasOlder: true) == nil)
        #expect(paging.phase == .inserting(generation: 1))
    }

    @Test("after the page lands the reader must leave the top before another can load: any move down, or far away")
    func needsDeparture() {
        var paging = ConversationPaging()
        _ = paging.readerMoved(offsetFromTop: 500, direction: .up, viewportHeight: viewport, hasOlder: true)
        paging.pageDone(generation: 1, offsetFromTop: 1200, viewportHeight: viewport)
        #expect(paging.phase == .waitingForDeparture)
        // Flicking up while still near the top loads nothing.
        #expect(paging.readerMoved(offsetFromTop: 900, direction: .up, viewportHeight: viewport, hasOlder: true) == nil)
        #expect(paging.phase == .waitingForDeparture)
        // Any move down leaves the top (a short window can never reach a far margin): armed, and the next arrival loads.
        #expect(paging.readerMoved(offsetFromTop: 1000, direction: .down, viewportHeight: viewport, hasOlder: true) == nil)
        #expect(paging.phase == .armed)
        #expect(paging.readerMoved(offsetFromTop: 800, direction: .up, viewportHeight: viewport, hasOlder: true) == 2)
    }

    @Test("being far from the top also arms, without a move down")
    func farAway() {
        var paging = ConversationPaging()
        _ = paging.readerMoved(offsetFromTop: 500, direction: .up, viewportHeight: viewport, hasOlder: true)
        paging.pageDone(generation: 1, offsetFromTop: 1200, viewportHeight: viewport)
        #expect(paging.readerMoved(offsetFromTop: 1600, direction: .up, viewportHeight: viewport, hasOlder: true) == nil)
        #expect(paging.phase == .armed)
    }

    @Test("a page whose place could not be held never leaves the reader stuck at the top")
    func failedHoldDoesNotStick() {
        var paging = ConversationPaging()
        _ = paging.readerMoved(offsetFromTop: 500, direction: .up, viewportHeight: viewport, hasOlder: true)
        paging.pageDone(generation: 1, offsetFromTop: 0, viewportHeight: viewport, placed: false)
        #expect(paging.phase == .armed)
        #expect(paging.readerMoved(offsetFromTop: 0, direction: .up, viewportHeight: viewport, hasOlder: true) == 2)
    }

    @Test("a page that lands already far from the top arms at once; a stale generation is ignored")
    func placement() {
        var paging = ConversationPaging()
        _ = paging.readerMoved(offsetFromTop: 500, direction: .up, viewportHeight: viewport, hasOlder: true)
        paging.pageDone(generation: 7, offsetFromTop: 5000, viewportHeight: viewport)
        #expect(paging.phase == .inserting(generation: 1), "a stale generation changes nothing")
        paging.pageDone(generation: 1, offsetFromTop: 5000, viewportHeight: viewport)
        #expect(paging.phase == .armed)
    }

    @Test("a reset starts again")
    func reset() {
        var paging = ConversationPaging()
        _ = paging.readerMoved(offsetFromTop: 500, direction: .up, viewportHeight: viewport, hasOlder: true)
        paging.reset()
        #expect(paging.phase == .armed)
    }

    @Test("the hold applies on every change, settles after stillness, and never counts nothing-applied as success")
    func holdSteps() {
        func step(_ changed: Bool, _ applied: Int, _ idle: Int, _ elapsed: Double, _ scrolling: Bool) -> ConversationHold.Step {
            ConversationHold.step(contentChanged: changed, applied: applied, idleTicks: idle, elapsed: elapsed, readerScrolling: scrolling)
        }
        #expect(step(true, 0, 0, 0.1, false) == .apply)
        #expect(step(false, 1, 3, 0.2, false) == .keepWaiting)
        #expect(step(false, 1, ConversationHold.settleTicks, 0.3, false) == .settled)
        // Never applied: waiting, then an honest failure.
        #expect(step(false, 0, 20, 0.5, false) == .keepWaiting)
        #expect(step(false, 0, 20, ConversationHold.maxDuration, false) == .gaveUp)
        #expect(step(false, 2, 0, ConversationHold.maxDuration, false) == .settled)
        // The reader scrolling ends it at once, whatever else is true.
        #expect(step(true, 0, 0, 0.1, true) == .cancelled)
    }

    @Test("the held offset keeps the distance from the bottom, clamped to the scrollable range")
    func holdOffset() {
        // 3177 tall, 1078 viewport, 1022 from the bottom (the QA log's numbers); 2000 pt of rows land above.
        let before = ConversationHold.offset(documentHeight: 3177, viewportHeight: 1078, distanceFromBottom: 1022)
        #expect(before == 1077)
        let after = ConversationHold.offset(documentHeight: 5177, viewportHeight: 1078, distanceFromBottom: 1022)
        #expect(after == 3077)
        #expect(ConversationHold.offset(documentHeight: 500, viewportHeight: 1078, distanceFromBottom: 10) == 0)
        #expect(ConversationHold.offset(documentHeight: 3000, viewportHeight: 1000, distanceFromBottom: -50) == 2000)
    }
}
