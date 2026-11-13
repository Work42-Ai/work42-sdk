import SwiftUI
import Testing

@testable import Work42UI

@MainActor
@Suite("Header controls carry their own sizes (SDK 2.14.0)")
struct HeaderControlsTests {
    @Test("a pill draws a hairline between neighbours and none for one segment or none")
    func dividers() {
        #expect(HeaderPill.dividerCount(for: 0) == 0)
        #expect(HeaderPill.dividerCount(for: 1) == 0)
        #expect(HeaderPill.dividerCount(for: 3) == 2)
    }

    @Test("a segment is off and enabled unless it says otherwise, and runs its action")
    func segment() {
        var ran = 0
        let segment = HeaderSegment(id: "home", systemImage: "house", label: "Home") { ran += 1 }
        #expect(!segment.isOn && segment.isEnabled && segment.onLabel == nil && segment.id == "home")
        segment.action()
        #expect(ran == 1)
        let recording = HeaderSegment(id: "record", systemImage: "record.circle", label: "Record", isOn: true, onLabel: "0:12") {}
        #expect(recording.isOn && recording.onLabel == "0:12")
    }

    @Test("a toggle's options are identified by what they stand for, not their order")
    func toggle() {
        let options = [
            HeaderToggleOption(id: "preview", systemImage: "eye", label: "Preview"),
            HeaderToggleOption(id: "source", systemImage: "chevron.left.forwardslash.chevron.right", label: "Source"),
        ]
        #expect(options.map(\.id) == ["preview", "source"] && options.map(\.label) == ["Preview", "Source"])
    }

    @Test("the controls build at this platform's control height")
    func builds() {
        var choice = "preview"
        let binding = Binding(get: { choice }, set: { choice = $0 })
        // Building each is enough to prove its initializer and that nothing needs a size from the caller.
        _ = HeaderRoundButton(systemImage: "chevron.left", label: "Back") {}
        _ = HeaderPill([HeaderSegment(id: "a", systemImage: "house", label: "Home") {}])
        _ = HeaderSegmentedToggle(selection: binding, options: [HeaderToggleOption(id: "preview", systemImage: "eye", label: "Preview")])
        _ = WidgetHeaderTitle(name: "AuthoringPlugins.md", subtitle: "work42-sdk/Documentation")
        #expect(TileMetrics.controlHeight == TileMetrics.controlHeight(touch: TileMetrics.isTouch))
    }
}
