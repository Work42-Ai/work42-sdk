import SwiftUI
import Testing
@testable import Work42UI

@MainActor
struct ConversationRowContextTests {

    private let me = ConversationActor(id: "me", name: "You", initials: "Y", color: .blue, isMe: true)
    private let them = ConversationActor(id: "them", name: "Them", initials: "T", color: .gray, isMe: false)

    private func context(_ actor: ConversationActor?, labeled: Bool, runStart: Bool, labelsMe: Bool) -> ConversationRowContext {
        ConversationRowContext(actor: actor, labeled: labeled, isRunStart: runStart, date: nil, labelsMe: labelsMe)
    }

    @Test func automaticModeNeverLabelsMe() {
        #expect(!context(me, labeled: true, runStart: true, labelsMe: false).showsLabel)
    }

    @Test func automaticModeLabelsOthersOnlyWhenLabeledAndAtARunStart() {
        #expect(context(them, labeled: true, runStart: true, labelsMe: false).showsLabel)
        #expect(!context(them, labeled: true, runStart: false, labelsMe: false).showsLabel)
        #expect(!context(them, labeled: false, runStart: true, labelsMe: false).showsLabel)
    }

    @Test func alwaysModeLabelsMeAtTheStartOfMyRunsOnly() {
        #expect(context(me, labeled: true, runStart: true, labelsMe: true).showsLabel)
        #expect(!context(me, labeled: true, runStart: false, labelsMe: true).showsLabel)
    }

    @Test func alwaysModeStillLabelsOthers() {
        #expect(context(them, labeled: true, runStart: true, labelsMe: true).showsLabel)
    }

    @Test func itemsWithNoActorAreNeverLabeled() {
        #expect(!context(nil, labeled: true, runStart: true, labelsMe: true).showsLabel)
    }

    @Test func theOlderInitializerMeansAutomatic() {
        let old = ConversationRowContext(actor: me, labeled: true, isRunStart: true, date: nil)
        #expect(!old.labelsMe)
        #expect(!old.showsLabel)
    }
}
