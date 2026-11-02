// WebSectionLiveView+iOS.swift — the live web view's API on iPadOS.
//
// On the Mac, `WebSectionLiveView` owns a cached WKWebView with find, zoom and window diagnostics. The
// iPad's browser widget shows a page the Mac streams or proxies, so the shared browser model only needs
// the same surface to compile; find and zoom act on the iPad's own web view once the iPad app wires one in.

#if !canImport(AppKit)
import SwiftUI
import WebKit

@MainActor
public final class WebSectionLiveView {
    public let webView: WKWebView
    public var status: WebSectionStatus = .loading
    public var pageZoom: CGFloat { webView.pageZoom }

    public init(webView: WKWebView = WKWebView(frame: .zero)) { self.webView = webView }

    public func zoomIn() { webView.pageZoom = min(webView.pageZoom * 1.1, 5) }
    public func zoomOut() { webView.pageZoom = max(webView.pageZoom / 1.1, 0.25) }
    public func resetZoom() { webView.pageZoom = 1 }

    public func find(_ query: String) async -> (current: Int, total: Int) {
        guard !query.isEmpty else { return (0, 0) }
        let config = WKFindConfiguration()
        let result = try? await webView.find(query, configuration: config)
        return (result?.matchFound == true ? 1 : 0, result?.matchFound == true ? 1 : 0)
    }

    public func findNext() async -> (current: Int, total: Int) { (0, 0) }
    public func findPrevious() async -> (current: Int, total: Int) { (0, 0) }
    public func clearFind() {}
}
#endif
