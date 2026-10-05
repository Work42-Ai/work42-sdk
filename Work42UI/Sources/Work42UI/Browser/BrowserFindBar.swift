// BrowserFindBar.swift - In-page find bar overlay for embedded-browser widgets.
//
// Moved from Work42App/Browser/ to Work42UI
// (browser-widgets-not-extending-from-browser.1).
//
// The find bar UI itself now lives in the shared `FindBar` component
// (Components/FindBar.swift) — the Liquid Glass capsule, keyboard contract, and
// X-of-N count are the exact same view the file editor and diff tile reuse.
// `BrowserFindBar` is a thin adapter that binds `FindBar` to a
// `BrowserWidgetModel` (its `FindBarBackend` conformance is below), so the
// existing browser/GitHub-PR/Jira/Canvas call sites (`BrowserFindBar(model:)`)
// stay unchanged.
//
// Rendered as an overlay on the web content area (pinned top-trailing),
// only when model.isFinding is true.

import SwiftUI

// MARK: - BrowserFindBar

/// The compact find-bar shown as an overlay on the web content when
/// `model.isFinding` is true — the shared `FindBar` bound to the browser model.
@MainActor
public struct BrowserFindBar: View {

    @ObservedObject public var model: BrowserWidgetModel

    public init(model: BrowserWidgetModel) {
        self.model = model
    }

    public var body: some View {
        FindBar(backend: model)
    }
}

// MARK: - BrowserWidgetModel: FindBarBackend

/// `BrowserWidgetModel` already exposes `findQuery`/`findCurrent`/`findTotal`
/// and `runFind`/`findNext`/`findPrevious`/`closeFind` (the JS-injection find
/// engine), so conformance is declaration-only.
extension BrowserWidgetModel: FindBarBackend {}
