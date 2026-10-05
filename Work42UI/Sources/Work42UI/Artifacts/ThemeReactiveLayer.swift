// ThemeReactiveLayer.swift — live theme reactivity for a full-surface artifact
// webview (the `.artifacts` gallery detail view).
//
// The artifact server bakes the ACTIVE theme's resolved `--w42-*` tokens into the
// shell CSS it serves, so an already-rendered artifact does not re-resolve on its
// own when the app theme changes. This modifier closes that gap by pushing the
// freshly-resolved color tokens into the LIVE page — `window.__w42.theme.apply(…)`
// rewrites the `--w42-*` `:root` vars in place, so the open artifact reskins with
// NO reload (AC-C5): highlighting, callouts, tables, cards all re-resolve live.
// (If the components runtime isn't present, or the push fails, it falls back to a
// reload so the artifact still re-themes.) Applied only at artifact call sites, so
// shared `WebSectionView` hosts (jira/github/browser) are unaffected.

import SwiftUI
import WebKit

public extension View {
    /// Re-theme a cached `WebSectionLiveView` in place when the app theme
    /// changes — pushes the current `--w42-*` color tokens to the live page
    /// (no reload), falling back to a reload only if the push can't apply.
    func themeReactive(live: WebSectionLiveView) -> some View {
        modifier(LiveThemeReactive(live: live))
    }
}

@MainActor
struct LiveThemeReactive: ViewModifier {
    let live: WebSectionLiveView

    /// The last token payload pushed to this webview — a theme-change post that
    /// resolves to identical tokens (same appearance) is a no-op, so redundant
    /// posts never trigger a JS eval / style recalc.
    @State private var lastPushedJSON = ""

    func body(content: Content) -> some View {
        content.onReceive(
            NotificationCenter.default.publisher(for: .work42ThemeDidChange)
        ) { _ in
            applyLiveTheme()
        }
    }

    private func applyLiveTheme() {
        let tokens = CanvasTheme.currentColorTokens()
        guard
            let data = try? JSONSerialization.data(withJSONObject: tokens),
            let json = String(data: data, encoding: .utf8)
        else {
            live.webView.reload()
            return
        }
        // Nothing actually changed → don't touch the page.
        if json == lastPushedJSON { return }
        lastPushedJSON = json
        // Apply live; if the components runtime is absent (older artifact),
        // reload so the server re-composes with the new theme.
        let js = """
        (function(){
          if (window.__w42 && window.__w42.theme && window.__w42.theme.apply) {
            window.__w42.theme.apply(\(json)); return true;
          }
          return false;
        })()
        """
        live.webView.evaluateJavaScript(js) { result, error in
            let applied = (result as? Bool) ?? false
            if error != nil || !applied {
                MainActor.assumeIsolated { _ = live.webView.reload() }
            }
        }
    }
}
