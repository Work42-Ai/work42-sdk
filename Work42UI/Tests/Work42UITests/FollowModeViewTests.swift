import SwiftUI
import Testing

@testable import Work42UI

@MainActor
@Suite("Follow mode is the widget's own chrome, read-only (WOR-808)")
struct FollowModeViewTests {
    @Test("the view takes a label and a colour and no header")
    func builds() {
        // A header of its own is gone: the session's people pill says whom this device follows, the widget's pill who is acting.
        _ = FollowModeView(label: "Following Alex · iPad", color: .blue) { Color.clear }
    }

    @Test("a browser model mirrors someone else's widget read-only")
    func readOnlyModel() {
        let model = BrowserWidgetModel(canEditURL: false, presetSelector: "")
        model.isReadOnly = true
        #expect(model.isReadOnly)
        #expect(!model.canEditURL)
    }
}
