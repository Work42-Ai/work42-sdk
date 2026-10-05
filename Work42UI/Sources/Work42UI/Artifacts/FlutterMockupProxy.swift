// FlutterMockupProxy.swift — the `w42FlutterMockup` message seam (Work42UI side).
//
// Mirrors `DiagramMessageProxy`: a `WKScriptMessageHandler` registered on the
// artifact webview at BUILD time (so `window.webkit.messageHandlers.w42FlutterMockup`
// exists when the injected component runtime runs — a handler added after the page
// loads is not exposed to it). The page's `<w42-flutter-mockup app=…>` posts
// `{type:"start", id, app, device}` (and `{type:"device", id, device}`); this proxy
// forwards the raw body to `coordinator.flutterMockupHandler`, which the app-side
// `FlutterMockupController` wires later (via `WebSectionLiveView.setFlutterMockupHandler`)
// to spawn the Flutter web run and post the served URL back with
// `window.__w42FlutterMockup.ready(id, url)`.

import Foundation
import WebKit

/// Weak-proxy message handler for the Flutter-mockup seam. Same retain-cycle
/// avoidance pattern as `DiagramMessageProxy`. Callbacks arrive on the main thread.
final class FlutterMockupProxy: NSObject, WKScriptMessageHandler {
    /// Must match the JS `FM_HANDLER` in `CanvasTemplate.componentsJS`.
    static let name = "w42FlutterMockup"

    /// Fires with the raw message body (`{type, id, app?, device?}`). Nil = dropped.
    var onMessage: (([String: Any]) -> Void)?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any] else { return }
        onMessage?(body)
    }
}
