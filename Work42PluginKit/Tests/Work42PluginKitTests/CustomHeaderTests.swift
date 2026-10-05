import SwiftUI
import Testing
@testable import Work42PluginKit

@MainActor
private final class HeaderWidget: Work42Widget, Work42WidgetCustomHeader {
    let id = "header-widget"
    let title = "Header Widget"
    let icon = "rectangle.topthird.inset.filled"
    let linkIntents: [WidgetLinkIntentSpec] = []
    var contentPadding: Double { 0 }
    private(set) var headerBuildCount = 0

    func makeHeaderView() -> AnyView {
        headerBuildCount += 1
        return AnyView(Text("Live header"))
    }

    func makeView(services: SessionServices) -> AnyView { AnyView(EmptyView()) }
}

@MainActor
private final class LegacyWidget: Work42Widget {
    let id = "legacy-widget"
    let title = "Legacy Widget"
    let icon = "square"
    let linkIntents: [WidgetLinkIntentSpec] = []
    func makeView(services: SessionServices) -> AnyView { AnyView(EmptyView()) }
}

@Suite("Optional custom widget header", .serialized)
@MainActor
struct CustomHeaderTests {
    @Test("conforming widgets expose header and padding")
    func conformingWidget() {
        let widget: any Work42Widget = HeaderWidget()
        let custom = widget as? any Work42WidgetCustomHeader

        #expect(custom != nil)
        #expect(custom?.contentPadding == 0)
        _ = custom?.makeHeaderView()
        #expect((widget as? HeaderWidget)?.headerBuildCount == 1)
    }

    @Test("previously built non-conforming widgets keep the fallback path")
    func legacyWidget() {
        let widget: any Work42Widget = LegacyWidget()
        #expect((widget as? any Work42WidgetCustomHeader) == nil)
    }
}
