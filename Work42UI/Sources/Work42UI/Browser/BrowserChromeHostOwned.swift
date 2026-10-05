// BrowserChromeHostOwned.swift — SwiftUI environment key that signals
// `BrowserSurfaceReady` when the host (the app's widget-chrome engine) owns
// and renders the browser chrome row for a custom widget.
//
// ## Purpose (AC7, browser-widgets-not-extending-from-browser.5)
//
// Browser-based custom widgets get the full browser chrome row AS their
// widget header by default — the same `makeWebWidgetChrome` path the
// built-in Browser, Jira, and GitHub PR widgets use. The host sets this key
// `true` around the widget's body content; `BrowserSurfaceReady` reads it
// and skips its own in-body `BrowserChromeRow` + `Divider` so exactly ONE
// chrome row ever renders (the header one).
//
// The find-bar overlay and empty-tab placeholder ALWAYS render in the body
// regardless of this key — they are not part of the chrome row.
//
// ## Usage
//
//   // Host (Work42App) sets the key around the widget content:
//   CustomWidgetContentView(slug: slug, services: services)
//       .browserChromeHostOwned(true)
//
//   // BrowserSurfaceReady reads the key:
//   @Environment(\.browserChromeHostOwned) private var chromeHostOwned
//   // ... and skips its chrome row when chromeHostOwned == true

import SwiftUI

// MARK: - BrowserChromeHostOwnedKey

/// Environment key: when `true`, `BrowserSurfaceReady` suppresses its in-body
/// `BrowserChromeRow` + `Divider`. The host owns the chrome row and renders it
/// in the widget's header via `makeWebWidgetChrome`.
///
/// Default: `false` — safe for standalone use of `BrowserSurface` (e.g. in
/// previews or a host that does not yet implement the header routing), where the
/// in-body chrome row should still render.
public struct BrowserChromeHostOwnedKey: EnvironmentKey {
    public static let defaultValue: Bool = false
}

extension EnvironmentValues {
    /// When `true`, `BrowserSurfaceReady` skips its in-body chrome row.
    /// Set by the widget host around a browser-based custom widget's body
    /// when it has routed the chrome row to the widget header instead.
    public var browserChromeHostOwned: Bool {
        get { self[BrowserChromeHostOwnedKey.self] }
        set { self[BrowserChromeHostOwnedKey.self] = newValue }
    }
}

extension View {
    /// Declare that this view's ancestor host owns the browser chrome row.
    /// `BrowserSurfaceReady` reads this and skips its own in-body chrome row
    /// so exactly one chrome row renders.
    ///
    /// Pass `false` to restore the default (in-body chrome row renders).
    public func browserChromeHostOwned(_ owned: Bool = true) -> some View {
        environment(\.browserChromeHostOwned, owned)
    }
}
