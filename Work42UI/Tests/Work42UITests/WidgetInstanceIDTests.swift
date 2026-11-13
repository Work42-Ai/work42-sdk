import Foundation
import Testing
@testable import Work42UI

@Suite("Widget instance ids (WOR-798)")
@MainActor
struct WidgetInstanceIDTests {
    private let yanIPad = WidgetInstanceID.Owner(person: "Yan Rodriguez", device: "iPad")

    @Test("a shared or hosted widget is its own id; one person's instance of a personal widget adds whose and where")
    func ids() {
        #expect(WidgetInstanceID.runtimeID(kindID: "artifacts") == "w_artifacts")
        #expect(WidgetInstanceID.runtimeID(kindID: "iosSimulator") == "w_iosSimulator")
        #expect(WidgetInstanceID.runtimeID(kindID: "widget:github", owner: yanIPad) == "w_widget_github_yan-rodriguez_ipad")
        #expect(WidgetInstanceID.names("W_widget_github_yan-rodriguez_ipad", instanceOf: "w_widget_github"))
        #expect(WidgetInstanceID.names("w_widget_github", instanceOf: "w_widget_github"))
        #expect(!WidgetInstanceID.names("w_widget_githubber", instanceOf: "w_widget_github"))
    }

    @Test("a comment made in a personal widget names the instance it was made in, and only there")
    func comments() {
        let store = PendingCommentsStore()
        store.instanceOwner = { $0 == "browser" ? self.yanIPad : nil }
        store.append(PendingComment(
            source: .browserHighlight(pageUrl: "https://example.com", selector: "h1", excerpt: "Hi", screenshotPath: nil),
            startLine: 0, endLine: 0, excerpt: "Hi", body: "this"))
        store.append(PendingComment(
            source: .artifact(artifactId: "a1", artifactTitle: "Plan", excerpt: "x"), startLine: 0, endLine: 0, excerpt: "x", body: "that"))
        #expect(store.comments[0].widgetId == "w_browser_yan-rodriguez_ipad")
        #expect(store.comments[0].serializedBlock.contains("device `w_browser_yan-rodriguez_ipad`"))
        #expect(store.comments[1].widgetId == "w_artifacts", "a shared widget has one instance")
    }
}
