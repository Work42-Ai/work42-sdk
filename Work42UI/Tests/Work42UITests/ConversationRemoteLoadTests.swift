// ConversationRemoteLoadTests.swift - WOR-642: history the host keeps is asked for once per arrival at the top, never while a request
// is out, never when there is no more, and a page that lands in front is told from a chat that only grew at its end.

import CoreGraphics
import Testing
@testable import Work42UI

@Suite("Conversation remote load (WOR-642)")
struct ConversationRemoteLoadTests {

    private let viewport: CGFloat = 1000

    /// What the view asks `ConversationPaging.readerMoved` for one upward arrival at the top.
    private func arrive(
        _ paging: inout ConversationPaging, hiddenOlder: Int = 0, hasMore: Bool, isLoading: Bool = false, offsetFromTop: CGFloat = 400
    ) -> Int? {
        paging.readerMoved(
            offsetFromTop: offsetFromTop, direction: .up, viewportHeight: viewport,
            hasOlder: ConversationRemoteLoad.hasOlder(hiddenOlder: hiddenOlder, hasMore: hasMore, isLoading: isLoading))
    }

    @Test("a load is asked for once per arrival at the top")
    func onceAtTheTop() {
        var paging = ConversationPaging()
        #expect(arrive(&paging, hasMore: true) == 1)
        // The request is out: more upward moves ask for nothing.
        #expect(arrive(&paging, hasMore: true, offsetFromTop: 100) == nil)
        #expect(paging.phase == .inserting(generation: 1))
    }

    @Test("nothing is asked while a request is out")
    func notWhileLoading() {
        var paging = ConversationPaging()
        #expect(arrive(&paging, hasMore: true, isLoading: true) == nil)
        #expect(paging.phase == .armed, "nothing was started, so the next arrival can ask")
    }

    @Test("nothing is asked when the host has no more")
    func notWithoutMore() {
        var paging = ConversationPaging()
        #expect(arrive(&paging, hasMore: false) == nil)
    }

    @Test("rows still hidden in the window come first: the host is asked only once all that is held is shown")
    func windowFirst() {
        #expect(ConversationRemoteLoad.canLoad(hiddenOlder: 30, hasMore: true, isLoading: false) == false)
        #expect(ConversationRemoteLoad.hasOlder(hiddenOlder: 30, hasMore: false, isLoading: false), "a local page is older")
        #expect(ConversationRemoteLoad.canLoad(hiddenOlder: 0, hasMore: true, isLoading: false))
    }

    @Test("a request that ended with nothing in front arms the next arrival to ask again")
    func endedWithNothing() {
        var paging = ConversationPaging()
        let generation = arrive(&paging, hasMore: true)
        #expect(generation == 1)
        paging.pageDone(generation: 1, offsetFromTop: 300, viewportHeight: viewport, placed: false)
        #expect(arrive(&paging, hasMore: true) == 2)
    }

    @Test("a page placed at the top waits for the reader to leave it before the next load")
    func placedPageWaitsForDeparture() {
        var paging = ConversationPaging()
        _ = arrive(&paging, hasMore: true)
        paging.pageDone(generation: 1, offsetFromTop: 1200, viewportHeight: viewport, placed: true)
        #expect(arrive(&paging, hasMore: true) == nil)
        #expect(paging.phase == .waitingForDeparture)
    }

    @Test("items added in front are a page; growth at the end, or no growth, is not")
    func prependedIsTold() {
        // 40 items [a ... ] before; a page of 20 arrived in front: the first id changed and the count went up by 20.
        #expect(ConversationRemoteLoad.prepended(firstBefore: "a", countBefore: 40, firstNow: "z", countNow: 60) == 20)
        // The chat only grew at its end: the first item is the same.
        #expect(ConversationRemoteLoad.prepended(firstBefore: "a", countBefore: 40, firstNow: "a", countNow: 45) == nil)
        // Nothing arrived.
        #expect(ConversationRemoteLoad.prepended(firstBefore: "a", countBefore: 40, firstNow: "a", countNow: 40) == nil)
        // A different first item with fewer items is a different chat, not a page.
        #expect(ConversationRemoteLoad.prepended(firstBefore: "a", countBefore: 40, firstNow: "q", countNow: 10) == nil)
        // From an empty chat.
        #expect(ConversationRemoteLoad.prepended(firstBefore: nil, countBefore: 0, firstNow: "a", countNow: 3) == 3)
    }
}
