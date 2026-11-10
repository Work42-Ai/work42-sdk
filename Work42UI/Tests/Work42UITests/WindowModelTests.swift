import Foundation
import Testing

@testable import Work42UI

/// The rules both apps follow for "which window am I acting on" (WOR-752, R1 to R5): the window you are in is the target, it stays the
/// target when the app is in the background, a window closing hands over to the most recently focused one, a composer registering
/// never takes the target, and a highlight belongs to its window.
@MainActor
@Suite("Window model")
struct WindowModelTests {
    private func selection(_ excerpt: String) -> CommentableSelection {
        CommentableSelection(sourceLabel: "label", excerpt: excerpt, screenRect: nil, makeComment: { _ in })
    }

    private func composer(sent: Box? = nil) -> Composer {
        Composer(isFocused: { false }, canSend: { true }, send: { sent?.count += 1 }, insert: { _ in })
    }

    final class Box { var count = 0 }

    // MARK: WindowFocus

    @Test("a window becoming key is the key window and the last focused one, first in the order")
    func becameKey() {
        let focus = WindowFocus()
        let a = NSObject(), b = NSObject()
        let (ida, idb) = (ObjectIdentifier(a), ObjectIdentifier(b))
        focus.register(ida, isKey: false)
        focus.register(idb, isKey: false)

        focus.becameKey(idb)

        #expect(focus.keyWindow == idb)
        #expect(focus.lastFocused == idb)
        #expect(focus.order == [idb, ida])
    }

    @Test("a window registered while it is key is focused at once")
    func registeredKey() {
        let focus = WindowFocus()
        let a = NSObject()
        focus.register(ObjectIdentifier(a), isKey: true)
        #expect(focus.lastFocused == ObjectIdentifier(a))
    }

    @Test("R2: the last focused window stays the target when the keyboard leaves the app")
    func backgroundKeepsTheTarget() {
        let focus = WindowFocus()
        let a = NSObject()
        let ida = ObjectIdentifier(a)
        focus.register(ida, isKey: true)

        focus.resignedKey(ida)

        #expect(focus.keyWindow == nil)
        #expect(focus.lastFocused == ida)
    }

    @Test("R3: closing the last focused window hands over to the most recently focused survivor, and to nothing when none is left")
    func closeFallsBack() {
        let focus = WindowFocus()
        let a = NSObject(), b = NSObject(), c = NSObject()
        let (ida, idb, idc) = (ObjectIdentifier(a), ObjectIdentifier(b), ObjectIdentifier(c))
        for id in [ida, idb, idc] { focus.register(id, isKey: false) }
        focus.becameKey(ida)
        focus.becameKey(idb)
        focus.becameKey(idc)

        focus.unregister(idc)
        #expect(focus.lastFocused == idb)
        #expect(focus.keyWindow == nil)

        focus.unregister(ida)
        #expect(focus.lastFocused == idb, "closing a window that was not the target changes nothing")

        focus.unregister(idb)
        #expect(focus.lastFocused == nil)
        #expect(focus.order.isEmpty)
    }

    @Test("a window that is not registered (a panel) never becomes a target")
    func unregisteredIsNotATarget() {
        let focus = WindowFocus()
        let a = NSObject(), panel = NSObject()
        focus.register(ObjectIdentifier(a), isKey: true)

        focus.becameKey(ObjectIdentifier(panel))

        #expect(focus.keyWindow == ObjectIdentifier(panel))
        #expect(focus.lastFocused == ObjectIdentifier(a))
    }

    // MARK: ComposerTargets

    @Test("R4: a composer registering never takes the target; the target follows focus")
    func composerRegisteringDoesNotRetarget() {
        let focus = WindowFocus()
        let a = NSObject(), b = NSObject()
        let (ida, idb) = (ObjectIdentifier(a), ObjectIdentifier(b))
        focus.register(ida, isKey: true)
        focus.register(idb, isKey: false)
        let targets = ComposerTargets<WindowFocus.ID>(focusedKey: { focus.lastFocused })
        let sentA = Box(), sentB = Box()

        targets.update(composer(sent: sentA), for: ida)
        targets.update(composer(sent: sentB), for: idb)
        targets.target?.send()

        #expect(sentA.count == 1 && sentB.count == 0, "B registering last did not take A's typing")

        focus.becameKey(idb)
        targets.target?.send()
        #expect(sentB.count == 1)
    }

    @Test("a cleared composer is no longer a target, and no focus means no target")
    func clearedAndUnfocused() {
        let focus = WindowFocus()
        let a = NSObject()
        let ida = ObjectIdentifier(a)
        let targets = ComposerTargets<WindowFocus.ID>(focusedKey: { focus.lastFocused })
        targets.update(composer(), for: ida)
        #expect(targets.target == nil, "no focused window: no target")

        focus.register(ida, isKey: true)
        #expect(targets.target != nil)

        targets.clear(ida)
        #expect(targets.target == nil)
        #expect(targets.composer(for: ida) == nil)
    }

    // MARK: AnnotationRegistry

    private func registry(_ focus: WindowFocus) -> AnnotationRegistry {
        let registry = AnnotationRegistry()
        registry.focus = focus
        return registry
    }

    @Test("R5: a highlight in one window is not what dictation reads in another")
    func highlightBelongsToItsWindow() {
        let focus = WindowFocus()
        let a = NSObject(), b = NSObject()
        let (ida, idb) = (ObjectIdentifier(a), ObjectIdentifier(b))
        focus.register(ida, isKey: true)
        focus.register(idb, isKey: false)
        let annotations = registry(focus)

        annotations.present(selection("in A"), in: ida)
        #expect(annotations.active?.excerpt == "in A")

        focus.becameKey(idb)
        #expect(annotations.active == nil, "B is focused and has no highlight of its own")

        annotations.present(selection("in B"), in: idb)
        #expect(annotations.active?.excerpt == "in B")

        focus.becameKey(ida)
        #expect(annotations.active?.excerpt == "in A", "A's highlight survived B's")
    }

    @Test("clearing in one window leaves another window's highlight")
    func clearOnlyItsOwn() {
        let focus = WindowFocus()
        let a = NSObject(), b = NSObject()
        let (ida, idb) = (ObjectIdentifier(a), ObjectIdentifier(b))
        focus.register(ida, isKey: true)
        focus.register(idb, isKey: false)
        let annotations = registry(focus)
        annotations.present(selection("in A"), in: ida)
        annotations.present(selection("in B"), in: idb)

        annotations.clear(in: idb)

        #expect(annotations.active?.excerpt == "in A")
        focus.becameKey(idb)
        #expect(annotations.active == nil)
    }

    @Test("a surface that names no window uses the shared slot, as the one global selection did")
    func unscopedIsTheOldBehaviour() {
        let annotations = registry(WindowFocus())

        annotations.present(selection("old"))
        #expect(annotations.active?.excerpt == "old")

        annotations.clear()
        #expect(annotations.active == nil)
    }

    @Test("a window's own highlight wins over the shared slot while it is focused")
    func windowBeatsUnscoped() {
        let focus = WindowFocus()
        let a = NSObject()
        let ida = ObjectIdentifier(a)
        focus.register(ida, isKey: true)
        let annotations = registry(focus)
        annotations.present(selection("shared"))
        annotations.present(selection("window"), in: ida)

        #expect(annotations.active?.excerpt == "window")
        annotations.clear(in: ida)
        #expect(annotations.active?.excerpt == "shared")
    }

    @Test("highlightUsedUp clears that window's selection and posts the window it concerns")
    func usedUpPostsTheWindow() {
        let focus = WindowFocus()
        let a = NSObject()
        let ida = ObjectIdentifier(a)
        focus.register(ida, isKey: true)
        let annotations = registry(focus)
        annotations.present(selection("in A"), in: ida)
        let seen = NoteBox()
        let token = NotificationCenter.default.addObserver(forName: .work42ClearTextSelection, object: nil, queue: nil) { note in
            seen.windows.append(note.namedWindow)
        }
        defer { NotificationCenter.default.removeObserver(token) }

        annotations.highlightUsedUp(in: ida)
        annotations.highlightUsedUp(in: nil)

        #expect(annotations.active == nil)
        #expect(seen.windows == [ida, nil])
    }

    final class NoteBox: @unchecked Sendable { var windows: [WindowFocus.ID?] = [] }

    @Test("a note that names no window concerns every window, one that names a window only that window")
    func concernsWindow() {
        let a = NSObject(), b = NSObject()
        let (ida, idb) = (ObjectIdentifier(a), ObjectIdentifier(b))
        let everyone = Notification(name: .work42ClearTextSelection)
        let onlyA = Notification(
            name: .work42ClearTextSelection, object: nil, userInfo: [Notification.Name.work42WindowUserInfoKey: ida])

        #expect(everyone.concernsWindow(ida) && everyone.concernsWindow(idb) && everyone.concernsWindow(nil))
        #expect(onlyA.concernsWindow(ida))
        #expect(!onlyA.concernsWindow(idb))
        #expect(!onlyA.concernsWindow(nil))
    }
}
