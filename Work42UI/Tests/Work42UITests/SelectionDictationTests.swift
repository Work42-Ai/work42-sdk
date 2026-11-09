// SelectionDictationTests.swift — which highlight a Pencil squeeze dictates into (AC166).

import Testing
@testable import Work42UI

@MainActor
@Suite("Selection dictation registry (AC166)", .serialized)
struct SelectionDictationTests {
    private final class Owner {}

    @Test("the owner highlighted in most recently is asked first")
    func mostRecentFirst() async {
        let a = Owner(), b = Owner()
        var asked: [String] = []
        Work42SelectionDictation.register(a) { asked.append("a"); return true }
        Work42SelectionDictation.register(b) { asked.append("b"); return true }
        Work42SelectionDictation.noteSelectionChanged(a)
        Work42SelectionDictation.noteSelectionChanged(b)
        Work42SelectionDictation.noteSelectionChanged(a)
        #expect(await Work42SelectionDictation.dictateHighlight())
        #expect(asked == ["a"])
        Work42SelectionDictation.unregister(a)
        Work42SelectionDictation.unregister(b)
    }

    @Test("an owner with no highlight falls through to the next")
    func fallsThrough() async {
        let a = Owner(), b = Owner()
        var asked: [String] = []
        Work42SelectionDictation.register(a) { asked.append("a"); return false }
        Work42SelectionDictation.register(b) { asked.append("b"); return true }
        Work42SelectionDictation.noteSelectionChanged(b)
        Work42SelectionDictation.noteSelectionChanged(a)
        #expect(await Work42SelectionDictation.dictateHighlight())
        #expect(asked == ["a", "b"])
        Work42SelectionDictation.unregister(a)
        Work42SelectionDictation.unregister(b)
    }

    @Test("nobody holding a highlight is false, and a released owner is never asked")
    func noneAndWeak() async {
        var asked = 0
        var owner: Owner? = Owner()
        Work42SelectionDictation.register(owner!) { asked += 1; return true }
        owner = nil
        #expect(await Work42SelectionDictation.dictateHighlight() == false)
        #expect(asked == 0)
    }
}
