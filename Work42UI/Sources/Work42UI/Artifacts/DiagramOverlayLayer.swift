// DiagramOverlayLayer.swift — native expand dialog wiring for lifted diagrams.
//
// Diagrams are intercepted in-page by `diagramControlsJS`: each is wrapped in a
// card with an HTML header (title + zoom/reset/expand controls, styled to match
// macOS) and a body with fast in-page pan/zoom. The header's Expand button
// posts `{type:"expand", svg}` to the `w42Diagram` message handler; this layer
// wires that signal to present the diagram full-size in a genuinely NATIVE
// dialog (a sheet — a separate window, where native controls render reliably,
// unlike content composited over a WKWebView inside a tile).
//
// IMPORTANT: `window.webkit.messageHandlers.w42Diagram` is only exposed to a
// page for handlers registered on the configuration BEFORE the page loads — a
// handler added afterwards is invisible to the already-loaded page. So the
// handler is registered at BUILD time (WebSectionView's seam); this layer only
// wires the callback.

import SwiftUI
import WebKit

public extension View {
    /// Wire the in-page diagrams of a cached `WebSectionLiveView` (artifact /
    /// spec surfaces) to present the native expand dialog when a diagram's
    /// Expand button is pressed. The `w42Diagram` handler is already registered
    /// on the webview at build time.
    func diagramOverlay(live: WebSectionLiveView, allowExpand: Bool = true) -> some View {
        modifier(LiveDiagramOverlay(live: live))
    }
}

@MainActor
struct LiveDiagramOverlay: ViewModifier {
    let live: WebSectionLiveView

    /// Carries the expand SVG into `.sheet(item:)`.
    private struct ExpandPayload: Identifiable {
        let id = UUID()
        let svg: String
    }
    @State private var expand: ExpandPayload?

    func body(content: Content) -> some View {
        content
            .onAppear { wire() }
            .onChange(of: ObjectIdentifier(live)) { _, _ in wire() }
            .onDisappear { live.setDiagramExpandHandler(nil) }
            .sheet(item: $expand) { payload in
                DiagramExpandDialog(svg: payload.svg) { expand = nil }
            }
    }

    private func wire() {
        // The page posts the small diagram id; fetch its SVG on demand (avoids
        // pushing a large SVG string through postMessage) and present the sheet.
        live.setDiagramExpandHandler { [weak live] id in
            guard let live else { return }
            live.webView.evaluateJavaScript(
                "window.__w42Diagram ? __w42Diagram.svg('\(id)') : ''"
            ) { result, _ in
                let svg = (result as? String) ?? ""
                if !svg.isEmpty { expand = ExpandPayload(svg: svg) }
            }
        }
    }
}

/// Weak-free forwarding handler: the `WKUserContentController` retains it
/// strongly, and it holds only a value-closure (`onExpand`) — no back-reference
/// — so there is no cycle. Registered at build time; torn down with the webview.
@MainActor
public final class DiagramMessageProxy: NSObject, WKScriptMessageHandler {
    /// Must match `HANDLER` in `CanvasTemplate.diagramControlsJS`.
    public static let name = "w42Diagram"

    /// Fires with the diagram's id when its Expand button is pressed.
    public var onExpand: ((String) -> Void)?

    public override init() { super.init() }

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let dict = message.body as? [String: Any],
              (dict["type"] as? String) == "expand",
              let id = dict["id"] as? String,
              !id.isEmpty
        else { return }
        onExpand?(id)
    }
}

// MARK: - Expand dialog

/// Owns the dialog's self-contained diagram webview. The diagram body renders
/// the SVG (with the in-page bridge for fast pan/zoom); the dialog supplies its
/// OWN native header (title + zoom/reset + close), so the card header is hidden
/// inside the dialog shell.
@MainActor
final class DiagramCanvas {
    let webView: WKWebView

    init() {
        let config = WKWebViewConfiguration()
        config.userContentController = WKUserContentController()
        self.webView = WKWebView(frame: .zero, configuration: config)
    }

    func load(svg: String, themeCSS: String) {
        webView.loadHTMLString(
            DiagramExpandDialog.shell(svg: svg, themeCSS: themeCSS), baseURL: nil)
    }
}

/// Full-size native dialog hosting a single diagram ("all the space only for
/// it"). The diagram fills the whole surface with fast in-page pan/zoom; the
/// dialog's native header drives zoom/reset (via the bridge's *All helpers) and
/// close.
@MainActor
struct DiagramExpandDialog: View {
    let svg: String
    let onClose: () -> Void

    @State private var canvas = DiagramCanvas()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            DiagramWebHost(webView: canvas.webView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 800, idealWidth: 1100, minHeight: 560, idealHeight: 800)
        .onAppear { canvas.load(svg: svg, themeCSS: CanvasTheme.css()) }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Diagram")
                .font(.system(size: DT.f13, weight: .semibold))
            Spacer(minLength: 8)
            headerButton("minus.magnifyingglass", "Zoom out") { run("__w42Diagram.zoomAll(1.3)") }
            headerButton("plus.magnifyingglass", "Zoom in") { run("__w42Diagram.zoomAll(1/1.3)") }
            headerButton("arrow.counterclockwise", "Reset view") { run("__w42Diagram.resetAll()") }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close")
            .glassIconButton()
        }
        .padding(.horizontal, DT.s12)
        .padding(.vertical, DT.s8)
    }

    private func headerButton(_ symbol: String, _ title: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    private func run(_ expr: String) {
        canvas.webView.evaluateJavaScript("window.__w42Diagram && \(expr)",
                                          completionHandler: nil)
    }

    /// The dialog document: the diagram fills the WHOLE surface (the card header
    /// is hidden — the dialog has its own native header). !important overrides
    /// the bridge's inline sizing.
    static func shell(svg: String, themeCSS: String) -> String {
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <style>
        \(themeCSS)
        \(CanvasTemplate.diagramControlsCSS)
        html, body { margin: 0; height: 100%; }
        body {
          display: block; padding: 16px; box-sizing: border-box;
          background: var(--w42-backdrop, transparent);
        }
        .w42-diagram-wrap { width: 100%; height: 100%; }
        .w42-diagram-wrap .w42-diagram-card {
          border: none !important; margin: 0 !important;
          background: transparent !important; height: 100% !important;
        }
        .w42-diagram-wrap .w42-diagram-header { display: none !important; }
        .w42-diagram-wrap .w42-diagram-slot {
          width: 100% !important; height: 100% !important; padding: 0 !important;
        }
        .w42-diagram-wrap .w42-diagram-slot > svg.w42-diagram {
          width: 100% !important; height: 100% !important; max-width: none !important;
        }
        </style></head>
        <body><div class="w42-diagram-wrap w42-mermaid">\(svg)</div>
        <script>\(CanvasTemplate.diagramControlsJS)</script></body></html>
        """
    }
}

/// NSViewRepresentable that displays a caller-owned `WKWebView` (the dialog's
/// diagram body — in-page gestures, no native overlay; the dialog owns the
/// header).
struct DiagramWebHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
