import SwiftUI
import Work42PluginKit

// A browser-based widget uses two things and nothing else: a `BrowserSurfaceDeclaration` (what to show) and
// `services.browser` (its tabs). `services.browser` is already scoped to this widget in this session, so it takes no widget id.
// Do not use `configure:` or `BrowserWidgetModel`: they are deprecated.

final class ExampleBrowserWidget: Work42BrowserBacked {
    let id = "example-browser"
    let title = "Example browser"
    let icon = "globe"
    let linkIntents: [WidgetLinkIntentSpec] = []

    var browserSurface: BrowserSurfaceDeclaration? {
        BrowserSurfaceDeclaration(
            spec: BrowserSurfaceSpec(
                url: URL(string: "https://example.com")!, dataStoreKey: "example-browser", title: "Example"),
            cacheKey: id)
    }

    func makeView(services: SessionServices) -> AnyView {
        guard let declaration = browserSurface else { return AnyView(EmptyView()) }
        return AnyView(
            BrowserSurface(spec: declaration.spec, cacheKey: declaration.cacheKey, services: services)
                .task { await Self.answerTabBar(services) })
    }

    /// The "+" button asks for a tab and the widget decides what a new tab is; here, an empty one.
    private static func answerTabBar(_ services: SessionServices) async {
        let browser = services.browser
        let latest = LatestTabs()
        Task { for await state in browser.tabs { latest.state = state } }
        for await event in browser.events {
            switch event {
            case .newTabRequested:
                try? await browser.setTabs(latest.state.tabs + [BrowserTab(title: "New Tab")])
            case .tabClosed:
                break  // forget anything you kept for that tab
            @unknown default:
                break  // a later 3.x release may add events; ignore the ones you do not know
            }
        }
    }
}

/// The widget's tabs as the host last reported them.
@MainActor
private final class LatestTabs {
    var state = BrowserTabsState()
}

@_cdecl("work42_widget_sdk_version")
public func work42_widget_sdk_version() -> Int32 { Work42SDKCompatibility.versionProbeValue }

@_cdecl("work42_widget_main")
public func work42_widget_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated { result = WidgetEntryPoint.register(ExampleBrowserWidget()) }
    return result
}
