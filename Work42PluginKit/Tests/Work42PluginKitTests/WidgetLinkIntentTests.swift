import Foundation
import SwiftUI
import Testing

@testable import Work42PluginKit

@MainActor
private final class ExplicitLinkWidget: Work42Widget {
    let id = "explicit-links"
    let title = "Explicit Links"
    let icon = "link"
    let linkIntents: [WidgetLinkIntentSpec]

    init() {
        linkIntents = [WidgetLinkIntentSpec(
            matchers: [.regex(#"^https://github\.com/"#), .scheme("file")],
            perform: { _ in }
        )]
    }

    func makeView(services: SessionServices) -> AnyView { AnyView(EmptyView()) }
}

@Suite("Widget link intent SDK contract")
@MainActor
struct WidgetLinkIntentTests {
    @Test("current ABI keeps explicit link declarations and defaults brand image to nil")
    func currentAbiVersion() {
        #expect(WidgetSDK.abiVersion == 11)
        let widget: any Work42Widget = ExplicitLinkWidget()
        #expect(widget.iconImageData == nil)
        #expect(widget.linkIntents.count == 1)
        #expect(widget.linkIntents[0].matchers == [
            .regex(#"^https://github\.com/"#),
            .scheme("file"),
        ])
    }
}
