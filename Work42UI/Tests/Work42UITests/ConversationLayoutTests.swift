import Foundation
import Testing
@testable import Work42UI

struct ConversationLayoutTests {

    private typealias Entry = ConversationEntry<Int>

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func entries(_ actors: [String], me: String = "me", gap: TimeInterval = 5) -> [Entry] {
        actors.enumerated().map { index, actor in
            Entry(id: index, actorID: actor, isMe: actor == me, date: t0.addingTimeInterval(gap * Double(index)))
        }
    }

    // MARK: Labeled mode

    @Test func twoActorsAreNotLabeled() {
        #expect(!ConversationLayout.labeledMode(entries: entries(["me", "them", "me", "them"])))
    }

    @Test func threeActorsAreLabeled() {
        #expect(ConversationLayout.labeledMode(entries: entries(["me", "a", "b"])))
    }

    @Test func aLateThirdActorLabelsTheWholeConversation() {
        let early = entries(["me", "a", "me", "a"])
        #expect(!ConversationLayout.labeledMode(entries: early))
        #expect(ConversationLayout.labeledMode(entries: early + [Entry(id: 99, actorID: "b", isMe: false, date: nil)]))
    }

    @Test func emptyAndSingleItemConversationsAreNotLabeled() {
        #expect(!ConversationLayout.labeledMode(entries: [Entry]()))
        #expect(!ConversationLayout.labeledMode(entries: entries(["me"])))
    }

    @Test func repeatedActorsCountOnce() {
        #expect(!ConversationLayout.labeledMode(entries: entries(Array(repeating: "a", count: 50) + ["me"])))
    }

    // MARK: Runs

    @Test func runStartsMarkEachChangeOfActor() {
        let starts = ConversationLayout.runStarts(entries: entries(["a", "a", "me", "a", "a", "a"]))
        #expect(starts == [0, 2, 3])
    }

    @Test func runStartsOfAnEmptyConversationIsEmpty() {
        #expect(ConversationLayout.runStarts(entries: [Entry]()).isEmpty)
    }

    // MARK: Dividers

    @Test func dividerAppearsAtExactlyTheGap() {
        let at300 = [Entry(id: 0, actorID: "a", isMe: false, date: t0),
                     Entry(id: 1, actorID: "a", isMe: false, date: t0.addingTimeInterval(300))]
        #expect(ConversationLayout.dividerBefore(entries: at300) == [1])
    }

    @Test func noDividerJustUnderTheGap() {
        let at299 = [Entry(id: 0, actorID: "a", isMe: false, date: t0),
                     Entry(id: 1, actorID: "a", isMe: false, date: t0.addingTimeInterval(299))]
        #expect(ConversationLayout.dividerBefore(entries: at299).isEmpty)
    }

    @Test func nilDatesNeverProduceADividerOrMoveTheReference() {
        let mixed = [Entry(id: 0, actorID: "a", isMe: false, date: t0),
                     Entry(id: 1, actorID: "a", isMe: false, date: nil),
                     Entry(id: 2, actorID: "a", isMe: false, date: t0.addingTimeInterval(400))]
        #expect(ConversationLayout.dividerBefore(entries: mixed) == [2])
        let allNil = (0..<4).map { Entry(id: $0, actorID: "a", isMe: false, date: nil) }
        #expect(ConversationLayout.dividerBefore(entries: allNil).isEmpty)
    }

    @Test func customGapIsHonoured() {
        let list = entries(["a", "a", "a"], gap: 60)
        #expect(ConversationLayout.dividerBefore(entries: list, gap: 60) == [1, 2])
        #expect(ConversationLayout.dividerBefore(entries: list, gap: 61).isEmpty)
    }

    // MARK: Window math

    @Test func renderedStartTakesTheTrailingWindow() {
        #expect(ConversationLayout.renderedStart(itemCount: 100, renderCount: 20) == 80)
        #expect(ConversationLayout.renderedStart(itemCount: 100, renderCount: 100) == 0)
    }

    @Test func renderedStartClampsWhenTheWindowExceedsTheItems() {
        #expect(ConversationLayout.renderedStart(itemCount: 5, renderCount: 20) == 0)
        #expect(ConversationLayout.renderedStart(itemCount: 0, renderCount: 20) == 0)
        #expect(ConversationLayout.renderedStart(itemCount: 10, renderCount: -3) == 10)
    }

    @Test func grownRenderCountAddsOnePage() {
        #expect(ConversationLayout.grownRenderCount(current: 40, pageSize: 40) == 80)
        #expect(ConversationLayout.grownRenderCount(current: 40, pageSize: -5) == 40)
    }
}
