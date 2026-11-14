import Foundation
import SwiftUI
import Testing

@testable import Work42UI

@Suite("Item kinds (SDK 2.15.0)")
struct WidgetItemTests {

    // MARK: - Refs

    @Test("a key round-trips through the ref")
    func keyRoundTrip() {
        let ref = WidgetItemRef(kind: "artifact", id: "meeting-brief")
        #expect(ref.key == "artifact:meeting-brief")
        #expect(WidgetItemRef(key: ref.key) == ref)
    }

    @Test("the key is split at the first colon, so an id may contain colons")
    func idWithColons() {
        let ref = WidgetItemRef(key: "file:/tmp/a:b.txt")
        #expect(ref?.kind == "file")
        #expect(ref?.id == "/tmp/a:b.txt")
        #expect(ref?.key == "file:/tmp/a:b.txt")
    }

    @Test("a key without a valid kind or without an id is not a ref")
    func rejectsBadKeys() {
        for key in ["", ":x", "Bad:x", "artifact:", "artifact", "-x:id", "a_b:id", "a b:id", "é:id"] {
            #expect(WidgetItemRef(key: key) == nil, "\(key) should not parse")
        }
    }

    @Test("a valid kind id is lowercase letters, digits and hyphens, starting with a letter or digit")
    func kindIdShape() {
        for id in ["artifact", "a", "9", "github-prs", "github-prs-pr", "a-b-c"] {
            #expect(WidgetItemRef.isValidKindId(id), "\(id) should be valid")
        }
        for id in ["", "-a", "A", "a_b", "a.b", "a b", "a:b"] {
            #expect(!WidgetItemRef.isValidKindId(id), "\(id) should be invalid")
        }
    }

    @Test("refs encode and decode")
    func codable() throws {
        let ref = WidgetItemRef(kind: "terminal", id: "6f1c")
        let data = try JSONEncoder().encode(ref)
        #expect(try JSONDecoder().decode(WidgetItemRef.self, from: data) == ref)
    }

    // MARK: - Plugin kinds

    @Test("a plugin may declare its widget's slug, or the slug plus a hyphenated suffix")
    func pluginKinds() {
        #expect(WidgetItemKind.isPluginKind("github-prs", ownedBy: "github-prs"))
        #expect(WidgetItemKind.isPluginKind("github-prs-pr", ownedBy: "github-prs"))
        #expect(!WidgetItemKind.isPluginKind("github-prsx", ownedBy: "github-prs"))
        #expect(!WidgetItemKind.isPluginKind("artifact", ownedBy: "github-prs"))
        #expect(!WidgetItemKind.isPluginKind("github-prs-pr", ownedBy: "Bad Slug"))
        #expect(!WidgetItemKind.isPluginKind("", ownedBy: "github-prs"))
    }

    // MARK: - Declarations

    @Test("a kind is many-viewer and not detachable unless it says so")
    func kindDefaults() {
        let kind = WidgetItemKind(id: "artifact", collection: "artifacts")
        #expect(kind.viewers == .many)
        #expect(!kind.detachable)
        let terminal = WidgetItemKind(id: "terminal", collection: "terminal", viewers: .one, detachable: true)
        #expect(terminal.viewers == .one && terminal.detachable)
    }

    @Test("an item's info defaults to ready with no update time")
    func infoDefaults() {
        let info = WidgetItemInfo(ref: WidgetItemRef(kind: "artifact", id: "a"), title: "A")
        #expect(info.phase == .ready)
        #expect(info.updatedAt == nil)
    }

    // MARK: - Provider defaults

    @MainActor
    private final class MinimalProvider: WidgetItemProvider {
        let kinds = [WidgetItemKind(id: "fixture", collection: "fixture")]
        func items(of kind: String) -> [WidgetItemInfo] { [] }
        func info(for ref: WidgetItemRef) -> WidgetItemInfo { WidgetItemInfo(ref: ref, title: ref.id) }
        func makeViewer(for ref: WidgetItemRef, surface: WidgetItemSurface) -> AnyView { AnyView(EmptyView()) }
    }

    @Test("a provider that implements only the required members gets no current item and no-op hooks")
    @MainActor
    func providerDefaults() {
        let provider = MinimalProvider()
        #expect(provider.currentItem == nil)
        provider.release(WidgetItemSurface(key: "tab:fixture:x"))
        provider.tilesChanged([WidgetItemRef(kind: "fixture", id: "x")])
        #expect(provider.info(for: WidgetItemRef(kind: "fixture", id: "x")).title == "x")
    }

    // MARK: - Chrome

    @Test("the chrome has no item action until the host sets one, and the action runs")
    @MainActor
    func chromeItemAction() {
        var chrome = WidgetChrome<EmptyView>(title: "Artifacts")
        #expect(chrome.itemAction == nil)
        var performed = 0
        chrome.itemAction = WidgetItemAction(title: "Open as its own widget", systemImage: "arrow.up.forward.square") {
            performed += 1
        }
        #expect(chrome.itemAction?.title == "Open as its own widget")
        chrome.itemAction?.perform()
        #expect(performed == 1)
    }
}
