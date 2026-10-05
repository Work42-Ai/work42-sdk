// ArtifactSnapshotRenderer.swift — AC2/AC3/AC4 infrastructure
// (feat/chat-performance-improvements.2).
//
// ONE app-wide offscreen WKWebView that renders artifact snapshots for the
// preview cards — replacing the per-card live webviews whose height churn
// drove the chat's layout-pass hangs (see the parent spec's hang evidence).
//
// Contract:
//   - Serial: requests queue behind an async chain; exactly one load runs at
//     a time on the single reused webview.
//   - Coalescing: concurrent requests for the same key (artifactId+hash)
//     share one render instead of queueing duplicates.
//   - Fixed viewport: 760pt logical width (the artifact's natural width, so
//     the miniature lays out exactly like the expanded view), content height
//     capped at 600pt.
//   - Settle: navigation didFinish + 300ms before the snapshot, so late
//     layout/JS (e.g. mermaid) lands in the image.
//   - Failure: 10s timeout per attempt, one retry, then a thrown error — the
//     card degrades to its metadata fallback (AC4), never a broken render.
//
// Consumers (subtask .3+) call `render(url:coalescingKey:)` and hand the PNG
// to `ArtifactPreviewCache.write` (Flow42Core). This module never imports
// Flow42Core (module boundary), so the cache write stays with the caller.

import AppKit
import WebKit

/// Errors a snapshot render can end in.
public enum ArtifactSnapshotError: Error, Sendable {
    /// The navigation did not finish within the per-attempt timeout.
    case timedOut
    /// WebKit reported a navigation failure.
    case navigationFailed(String)
    /// The finished page produced no image (snapshot returned nothing).
    case emptySnapshot
}

/// The app-wide offscreen snapshot renderer. `@MainActor` because WKWebView
/// is main-thread-only; the async surface means callers never block on it.
@MainActor
public final class ArtifactSnapshotRenderer: NSObject {

    public static let shared = ArtifactSnapshotRenderer()

    // MARK: - Tunables

    /// Logical viewport the artifact lays out against (spec: 760pt wide,
    /// height capped at 600pt of content).
    public static let viewportSize = CGSize(width: 760, height: 600)
    /// Smallest capture height — keeps a tiny artifact from a sliver preview.
    static let minCaptureHeight: CGFloat = 150
    /// Backing-pixel scale of the cached PNG.
    public static let snapshotScale: CGFloat = 2
    /// Post-didFinish settle delay before the snapshot.
    static let settleNanoseconds: UInt64 = 300_000_000
    /// Per-attempt ceiling; one retry after the first timeout/failure.
    static let attemptTimeoutNanoseconds: UInt64 = 10_000_000_000

    // MARK: - State

    /// The one reused offscreen webview (created lazily on first render).
    private var webView: WKWebView?

    /// Continuation for the in-flight navigation, resumed by the delegate.
    private var navigation: CheckedContinuation<Void, Error>?

    /// Coalescing table: key → the task performing that render. Concurrent
    /// callers for the same key await the same task.
    private var inFlight: [String: Task<Data, Error>] = [:]

    /// Serialisation chain: each render awaits the previous one's completion
    /// (success or failure alike) so the single webview never double-loads.
    private var chainTail: Task<Void, Never> = Task {}

    // MARK: - Public API

    /// Render `url` at the fixed viewport and return PNG data. Requests with
    /// the same `coalescingKey` share one render; distinct keys queue.
    public func render(url: URL, coalescingKey: String) async throws -> Data {
        if let existing = inFlight[coalescingKey] {
            return try await existing.value
        }

        let previousTail = chainTail
        let task = Task<Data, Error> {
            // Wait for the queue ahead of us — errors of predecessors are
            // irrelevant to this request.
            await previousTail.value
            return try await self.renderNowWithRetry(url: url)
        }
        inFlight[coalescingKey] = task
        chainTail = Task {
            _ = try? await task.value
            self.inFlight[coalescingKey] = nil
        }
        return try await task.value
    }

    // MARK: - Attempts

    private func renderNowWithRetry(url: URL) async throws -> Data {
        do {
            return try await renderNow(url: url)
        } catch {
            // One retry — offscreen WebKit's first paint is occasionally
            // flaky; a second attempt on the warmed process usually lands.
            return try await renderNow(url: url)
        }
    }

    private func renderNow(url: URL) async throws -> Data {
        let webView = ensureWebView()

        // Race the load against the attempt timeout.
        let timeout = Task {
            try await Task.sleep(nanoseconds: Self.attemptTimeoutNanoseconds)
            self.failNavigation(with: ArtifactSnapshotError.timedOut)
        }
        defer { timeout.cancel() }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // A stale continuation here would mean overlapping loads — the
            // serial chain prevents that; fail loud in debug if it breaks.
            assert(navigation == nil, "overlapping snapshot navigations")
            navigation = cont
            webView.load(URLRequest(url: url))
        }

        // Settle so late layout (fonts, mermaid) reaches the image.
        try await Task.sleep(nanoseconds: Self.settleNanoseconds)

        // Capture content-height (clamped) so the preview fits tightly — no
        // blank space under a short artifact, no letterboxing on the card.
        let captureHeight = await measuredContentHeight(webView)
        let captureSize = CGSize(width: Self.viewportSize.width, height: captureHeight)

        let config = WKSnapshotConfiguration()
        config.rect = CGRect(origin: .zero, size: captureSize)
        let image: NSImage = try await withCheckedThrowingContinuation { cont in
            webView.takeSnapshot(with: config) { image, error in
                if let image {
                    cont.resume(returning: image)
                } else {
                    cont.resume(throwing: error ?? ArtifactSnapshotError.emptySnapshot)
                }
            }
        }

        guard let png = Self.pngData(
            from: image,
            pixelSize: CGSize(
                width: captureSize.width * Self.snapshotScale,
                height: captureSize.height * Self.snapshotScale
            )
        ) else { throw ArtifactSnapshotError.emptySnapshot }
        return png
    }

    /// The artifact's rendered content height, clamped to
    /// `[minCaptureHeight, viewportSize.height]`. Measured off the live DOM so
    /// the snapshot rect matches the real content.
    private func measuredContentHeight(_ webView: WKWebView) async -> CGFloat {
        let js = "Math.ceil(Math.max("
            + "document.body ? document.body.scrollHeight : 0,"
            + "document.documentElement ? document.documentElement.scrollHeight : 0))"
        let measured: CGFloat = await withCheckedContinuation { cont in
            webView.evaluateJavaScript(js) { result, _ in
                let value: CGFloat
                if let d = result as? Double { value = CGFloat(d) }
                else if let i = result as? Int { value = CGFloat(i) }
                else if let n = result as? NSNumber { value = CGFloat(truncating: n) }
                else { value = Self.viewportSize.height }
                cont.resume(returning: value)
            }
        }
        return min(max(measured, Self.minCaptureHeight), Self.viewportSize.height)
    }

    private func ensureWebView() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        // Offscreen: never added to a window; a fixed frame gives WebKit its
        // layout viewport.
        let view = WKWebView(
            frame: CGRect(origin: .zero, size: Self.viewportSize),
            configuration: config
        )
        view.navigationDelegate = self
        webView = view
        return view
    }

    /// Resume the pending navigation once, dropping later signals — didFinish
    /// vs didFail vs timeout can race and a continuation must resume once.
    private func failNavigation(with error: Error) {
        navigation?.resume(throwing: error)
        navigation = nil
    }

    private func finishNavigation() {
        navigation?.resume(returning: ())
        navigation = nil
    }

    // MARK: - PNG encoding

    /// Encode an NSImage to PNG at an explicit pixel size (the 2× backing
    /// scale of the cached snapshot). Internal + deterministic for the smoke
    /// test — no WebKit involved.
    static func pngData(from image: NSImage, pixelSize: CGSize) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelSize.width),
            pixelsHigh: Int(pixelSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        image.draw(
            in: CGRect(origin: .zero, size: pixelSize),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        context.flushGraphics()
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - WKNavigationDelegate

extension ArtifactSnapshotRenderer: WKNavigationDelegate {

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishNavigation()
    }

    public func webView(
        _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) {
        failNavigation(with: ArtifactSnapshotError.navigationFailed(error.localizedDescription))
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        failNavigation(with: ArtifactSnapshotError.navigationFailed(error.localizedDescription))
    }
}
