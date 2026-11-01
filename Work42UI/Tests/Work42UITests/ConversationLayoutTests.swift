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

    // MARK: Gap above a row (WOR-557)

    private func gap(
        divider: Bool = false, actor: Bool, runStart: Bool = true, previousIsMe: Bool = false, run: CGFloat? = 16
    ) -> CGFloat {
        ConversationLayout.gapBefore(
            hasDivider: divider, hasActor: actor, isRunStart: runStart, previousIsMe: previousIsMe,
            rowSpacing: 28, runSpacing: run)
    }

    @Test func rowsWithoutAnActorSitAtTheBlockGapInsideATurn() {
        #expect(gap(actor: false) == 16)
    }

    @Test func aRowWithoutAnActorAfterYourMessageKeepsTheTurnGap() {
        #expect(gap(actor: false, previousIsMe: true) == 28)
    }

    @Test func rowsWithAnActorKeepTheRunRule() {
        #expect(gap(actor: true, runStart: true) == 28)
        #expect(gap(actor: true, runStart: false) == 16)
    }

    @Test func aDateDividerKeepsTheTurnGap() {
        #expect(gap(divider: true, actor: false) == 28)
    }

    @Test func withoutARunGapEveryRowUsesTheRowGap() {
        #expect(gap(actor: false, run: nil) == 28)
        #expect(gap(actor: true, runStart: false, run: nil) == 28)
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
        // 15 minutes, the same in the chat and the transcript.
        let at900 = [Entry(id: 0, actorID: "a", isMe: false, date: t0),
                     Entry(id: 1, actorID: "a", isMe: false, date: t0.addingTimeInterval(900))]
        #expect(ConversationLayout.dividerBefore(entries: at900) == [1])
    }

    @Test func noDividerJustUnderTheGap() {
        let at899 = [Entry(id: 0, actorID: "a", isMe: false, date: t0),
                     Entry(id: 1, actorID: "a", isMe: false, date: t0.addingTimeInterval(899))]
        #expect(ConversationLayout.dividerBefore(entries: at899).isEmpty)
    }

    @Test func leadingPutsADividerOnTheFirstDatedItem() {
        let list = [Entry(id: 0, actorID: "a", isMe: false, date: nil),
                    Entry(id: 1, actorID: "a", isMe: false, date: t0),
                    Entry(id: 2, actorID: "a", isMe: false, date: t0.addingTimeInterval(60))]
        #expect(ConversationLayout.dividerBefore(entries: list, leading: true) == [1])
        #expect(ConversationLayout.dividerBefore(entries: list).isEmpty)
    }

    @Test func nilDatesNeverProduceADividerOrMoveTheReference() {
        let mixed = [Entry(id: 0, actorID: "a", isMe: false, date: t0),
                     Entry(id: 1, actorID: "a", isMe: false, date: nil),
                     Entry(id: 2, actorID: "a", isMe: false, date: t0.addingTimeInterval(1000))]
        #expect(ConversationLayout.dividerBefore(entries: mixed) == [2])
        let allNil = (0..<4).map { Entry(id: $0, actorID: "a", isMe: false, date: nil) }
        #expect(ConversationLayout.dividerBefore(entries: allNil).isEmpty)
    }

    @Test func dayClockLabelNamesTheDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = ConversationDateDivider.dayClockLabel(for: now, now: now, calendar: calendar)
        let yesterday = ConversationDateDivider.dayClockLabel(
            for: now.addingTimeInterval(-86_400), now: now, calendar: calendar
        )
        #expect(today.hasPrefix("Today \u{00B7} "))
        #expect(yesterday.hasPrefix("Yesterday \u{00B7} "))
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
