// BrowserSelectionComment.swift — generic highlight-to-comment for EVERY
// browser-based widget, owned by the SDK.
//
// This is the scalable replacement for each widget hand-rolling its own
// selection bubble + dictation publish (the GitHub PR widget used to). Any
// `BrowserSurface` that receives `services` gets, for free:
//
//   • select text → a floating "＋" bubble → `CommentComposerPopover` → the
//     note + highlighted excerpt land as a chat comment (`composer.attach`),
//   • the SAME selection published to `AnnotationRegistry` so holding
//     push-to-talk (or hands-free dictation) drops the transcript in as a
//     comment WITHOUT opening the composer.
//
// Both the typed path and the dictated path funnel through ONE `submit(...)`
// closure, so they behave identically — the invariant Yan asked for. A plugin
// contributes nothing here; enrichment of the raw selection into a useful
// source label (e.g. GitHub → "PR #42 · File.swift:L12–L18") is layered on via
// an optional resolver. With no resolver the label falls back to the page
// title / host.
//
// This is a DELIBERATE structural mirror of
// `Sources/Work42App/Artifact/ArtifactCommentLayer.swift` — same @State shape,
// same body/overlay/wire/onDisappear wiring, same bubble — so the browser
// affordance is identical to the artifact one. The only differences are the
// sink (`composer.attach` instead of the app's `PendingComment` append) and
// the optional plugin resolver applied at submit time.

import SwiftUI
import AppKit
import Work42UI

@MainActor
struct BrowserSelectionCommentLayer: ViewModifier {

    /// The live webview whose selection we track. Re-wired when its identity
    /// changes (tab switch).
    let live: WebSectionLiveView

    /// The composer sink. Nil (previews / no-services hosts) makes commit /
    /// dictation a no-op, but the wiring is otherwise identical.
    let composer: (any WidgetComposerService)?

    /// Optional plugin resolver. Applied at submit time (both typed + dictated
    /// paths) to enrich the raw selection; nil → plain page-title / host label.
    let resolver: WebSelectionResolver?

    /// Current page URL / title accessors, read lazily at selection time.
    let pageURL: () -> URL?
    let pageTitle: () -> String?

    /// A last-resort label when the page exposes neither title nor host
    /// (e.g. the widget's `spec.title`).
    let fallbackLabel: String?

    @State private var selectionText: String = ""
    @State private var selectionRect: CGRect = .zero
    @State private var selectionDomContext: [String: String] = [:]
    @State private var selectionPageURL: URL?
    @State private var selectionPageTitle: String?
    @State private var hasSelection = false
    @State private var showingComposer = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) { bubble }
            .onAppear { wire() }
            .onChange(of: ObjectIdentifier(live)) { _, _ in wire() }
        // NOTE: deliberately NO `.onDisappear { live.selectionHandler = nil }`.
        // BrowserSurfaceReady churns this modifier (tab-sync re-renders + the
        // `.id("surface:<tab>")` remount), and every instance shares ONE cached
        // `live`. A torn-down instance's onDisappear would nil the handler a
        // freshly-appeared instance just installed — leaving selection dead
        // (no bubble, no dictation publish). The current displayed instance
        // owns the handler via onAppear/onChange; `live` (and its handler) is
        // released when the widget tears down its BrowserSurfaceCache entry.
    }

    // MARK: - Bubble + composer

    @ViewBuilder
    private var bubble: some View {
        if composer != nil, hasSelection, !selectionText.isEmpty {
            Button {
                showingComposer = true
            } label: {
                Image(systemName: "plus.bubble.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(DT.systemAccent))
                    .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
            .help("Comment on the highlighted text")
            // Anchor with padding (a real layout move), NOT `.offset`, so the
            // popover attaches to the bubble's actual frame — see
            // ArtifactCommentLayer for the rationale.
            .popover(
                isPresented: $showingComposer,
                attachmentAnchor: .point(.center),
                arrowEdge: .leading
            ) {
                CommentComposerPopover(
                    sourceLabel: provisionalLabel(),
                    excerpt: selectionText,
                    onCommit: { body in submit(body: body) },
                    isPresented: $showingComposer
                )
            }
            .padding(.leading, max(selectionRect.maxX + 6, 0))
            .padding(.top, max(selectionRect.minY - 2, 0))
        }
    }

    // MARK: - Wiring

    private func wire() {
        // No composer sink → this browser widget opted out of comments; leave
        // the selection seam untouched (no bubble, no dictation publish).
        guard composer != nil else { return }
        live.selectionHandler = { text, rect, domContext in
            if text.isEmpty {
                // The webview reports an empty selection when focus leaves it
                // (e.g. the popover opens). Keep the selection alive while the
                // composer is up; otherwise clear.
                if !showingComposer { clearSelection() }
            } else {
                selectionText = text
                selectionRect = rect
                selectionDomContext = domContext
                selectionPageURL = pageURL()
                selectionPageTitle = pageTitle()
                hasSelection = true
                // ALSO publish for dictate-to-comment: holding push-to-talk
                // drops the transcript straight into the composer as a comment,
                // through the SAME `submit(...)` the dialog uses.
                // Publish the webview's screen frame as the glow LOCATOR (not
                // the inner selection): the dictation resolver expands it to the
                // enclosing widget card via outermostSurfaceScreenFrame. A
                // concrete rect makes this robust to the push-to-talk keyWindow
                // race (the same fix the code editor uses).
                AnnotationRegistry.shared.present(CommentableSelection(
                    sourceLabel: provisionalLabel(),
                    excerpt: text,
                    screenRect: webViewScreenRect(),
                    makeComment: { body in submit(body: body) }
                ))
            }
        }
    }

    // MARK: - Submit (shared by typed + dictated paths)

    private func submit(body: String) {
        guard let composer else { return }
        let fallback = provisionalLabel()
        let selection = WebSelection(
            text: selectionText,
            viewRect: selectionRect,
            pageURL: selectionPageURL,
            pageTitle: selectionPageTitle,
            domContext: selectionDomContext
        )
        let resolver = self.resolver
        Task { @MainActor in
            // Resolve ONCE, right before attaching — the SAME pure path for
            // typed and dictated bodies. A nil result (or no resolver) keeps
            // the plain label + raw text.
            let (label, excerpt) = await resolveSelectionAnnotation(
                selection,
                fallbackLabel: fallback,
                resolver: resolver
            )
            try? await composer.attach(sourceLabel: label, excerpt: excerpt, body: body)
        }
        clearSelection()
    }

    private func clearSelection() {
        hasSelection = false
        selectionText = ""
        selectionRect = .zero
        selectionDomContext = [:]
        selectionPageURL = nil
        selectionPageTitle = nil
        showingComposer = false
        AnnotationRegistry.shared.clear()
    }

    // MARK: - Labels

    /// The webview's frame in Cocoa screen coords — the glow locator. The
    /// dictation resolver expands this to the enclosing widget card. Nil when
    /// the webview isn't in a window (never at selection time).
    private func webViewScreenRect() -> CGRect? {
        let v = live.webView
        guard let window = v.window else { return nil }
        return window.convertToScreen(v.convert(v.bounds, to: nil))
    }

    /// The default (no-resolver) source label — page title, else URL host,
    /// else the widget's fallback, else "Web page".
    private func provisionalLabel() -> String {
        plainSelectionLabel(
            pageTitle: selectionPageTitle,
            pageURL: selectionPageURL,
            fallbackLabel: fallbackLabel
        )
    }
}
