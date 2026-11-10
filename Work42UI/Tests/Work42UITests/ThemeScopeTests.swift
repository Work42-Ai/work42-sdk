import Foundation
import Testing

@testable import Work42UI

/// One theme per scope: the iPad shows a window per account, each with its own Mac's theme (WOR-758). These tests only write scoped
/// themes, under names no other test uses, so the process-wide theme other suites read is never touched.
@Suite("Theme scopes")
struct ThemeScopeTests {
    private func snapshot(_ name: String) -> ThemeSnapshot {
        ThemeSnapshot(spec: ThemeSpec(name: name, light: ThemeSpec.system.light, dark: ThemeSpec.system.dark), mode: .auto)
    }

    @Test("two scopes hold two themes at once, and each reads back its own")
    func twoScopes() {
        ThemeRuntime.update(snapshot("one"), scope: "wor758-mac-a")
        ThemeRuntime.update(snapshot("two"), scope: "wor758-mac-b")

        #expect(ThemeRuntime.current(scope: "wor758-mac-a").spec.name == "one")
        #expect(ThemeRuntime.current(scope: "wor758-mac-b").spec.name == "two")
    }

    @Test("a scoped theme leaves the process-wide one alone")
    func globalUntouched() {
        let before = ThemeRuntime.current(scope: nil)
        let generation = ThemeRuntime.generation(scope: nil)

        ThemeRuntime.update(snapshot("scoped"), scope: "wor758-global-check")

        #expect(ThemeRuntime.current(scope: nil) == before)
        #expect(ThemeRuntime.generation(scope: nil) == generation)
        #expect(ThemeRuntime.current(scope: "wor758-global-check").spec.name == "scoped")
    }

    @Test("a scope with no theme of its own, an empty scope and nil all read the process-wide theme")
    func fallsBackToGlobal() {
        let global = ThemeRuntime.current(scope: nil)

        #expect(ThemeRuntime.current(scope: "wor758-never-set") == global)
        #expect(ThemeRuntime.current(scope: "") == global)
        #expect(ThemeRuntime.generation(scope: "wor758-never-set") == ThemeRuntime.generation(scope: nil))
    }

    @Test("`current` inside withScope is that scope's theme, and is the process-wide one again after it")
    func withScopeRoutesCurrent() {
        ThemeRuntime.update(snapshot("inside"), scope: "wor758-route")
        let outside = ThemeRuntime.current

        let inside = ThemeRuntime.withScope("wor758-route") { ThemeRuntime.current }

        #expect(inside.spec.name == "inside")
        #expect(ThemeRuntime.current == outside)
    }

    @Test("a nil or empty scope inside withScope keeps the scope already in force")
    func nestingKeepsTheOuterScope() {
        ThemeRuntime.update(snapshot("outer"), scope: "wor758-nest")

        let names = ThemeRuntime.withScope("wor758-nest") {
            [
                ThemeRuntime.withScope(nil) { ThemeRuntime.current.spec.name },
                ThemeRuntime.withScope("") { ThemeRuntime.current.spec.name },
            ]
        }

        #expect(names == ["outer", "outer"])
    }

    @Test("an inner scope wins while it runs and the outer one is back after")
    func innerScopeRestores() {
        ThemeRuntime.update(snapshot("a"), scope: "wor758-in-a")
        ThemeRuntime.update(snapshot("b"), scope: "wor758-in-b")

        let seen = ThemeRuntime.withScope("wor758-in-a") {
            let first = ThemeRuntime.current.spec.name
            let inner = ThemeRuntime.withScope("wor758-in-b") { ThemeRuntime.current.spec.name }
            return [first, inner, ThemeRuntime.current.spec.name]
        }

        #expect(seen == ["a", "b", "a"])
    }

    @Test("a scope read on one thread is not seen by another")
    func scopeIsPerThread() async {
        ThemeRuntime.update(snapshot("here"), scope: "wor758-thread")
        let global = ThemeRuntime.current(scope: nil)

        let other = await withCheckedContinuation { continuation in
            ThemeRuntime.withScope("wor758-thread") {
                Thread.detachNewThread { continuation.resume(returning: ThemeRuntime.current) }
            }
        }

        #expect(other == global)
    }

    @Test("a scope's generation changes only when that scope's theme does")
    func generationPerScope() {
        ThemeRuntime.update(snapshot("g1"), scope: "wor758-gen-a")
        ThemeRuntime.update(snapshot("g1"), scope: "wor758-gen-b")
        let a = ThemeRuntime.generation(scope: "wor758-gen-a")
        let b = ThemeRuntime.generation(scope: "wor758-gen-b")

        ThemeRuntime.update(snapshot("g2"), scope: "wor758-gen-a")

        #expect(ThemeRuntime.generation(scope: "wor758-gen-a") != a)
        #expect(ThemeRuntime.generation(scope: "wor758-gen-b") == b)
        #expect(ThemeRuntime.withScope("wor758-gen-b") { ThemeRuntime.generation } == b)
    }

    @Test("a theme change reaches the content of its own scope and the global kind, not another scope's")
    func notificationFilter() {
        let global = Notification(name: .work42ThemeDidChange)
        let mine = Notification(
            name: .work42ThemeDidChange, object: nil, userInfo: [Notification.Name.work42ThemeScopeUserInfoKey: "mac-a"])

        #expect(global.isThemeChange(for: "mac-a"))
        #expect(global.isThemeChange(for: ""))
        #expect(mine.isThemeChange(for: "mac-a"))
        #expect(!mine.isThemeChange(for: "mac-b"))
        #expect(!mine.isThemeChange(for: ""))
    }
}
