// WebAppCatalog.swift - The "add a web-app integration = a new WebSectionSpec" registry pattern.
//
// ============================================================================
// HOW TO ADD A NEW EMBEDDED WEB-APP INTEGRATION  (read this first)
// ============================================================================
//
// The embedded-web-section feature is deliberately structured so that
// integrating a NEW web app is a DATA change, not a code change:
//
//     adding a new web-app integration  ==  constructing a new WebSectionSpec
//
// There is exactly ONE WebKit-touching component — `WebSectionView`
// (NSViewRepresentable over WKWebView) — and it is web-app-agnostic: it
// never branches on the specific site. Everything site-specific is carried
// by the `WebSectionSpec` value type:
//
//     • url          — the page to load
//     • selector     — the single CSS element to isolate + pin to fill
//                       the viewport (the rest of the page chrome is hidden)
//     • dataStoreKey — identity of the persistent WKWebsiteDataStore, so a
//                       login done once inside the webview survives restarts
//                       (and distinct keys keep distinct apps isolated)
//     • title        — optional, presentational only
//
// So to embed, say, Linear or Notion or a Confluence page next to a task,
// you do NOT write any new WebKit / WKWebView / WKUserScript / delegate
// code. You construct a `WebSectionSpec` with that app's URL + the CSS
// selector for the region you want, hand it to a `WebSectionView`, and
// you're done. The selector isolation (T-005.2), SPA-navigation + SSO
// handling (T-005.3), and the optional JS->Swift signal seam (T-005.4) all
// work unchanged because they are driven entirely by the spec.
//
// This file is the in-code ANCHOR for that pattern. It is intentionally a
// thin set of `WebSectionSpec` FACTORIES — one per integration — so the
// list of "known web apps" lives in one discoverable place and each entry
// visibly proves the rule (each is just a spec, no WebKit code). The full
// developer-facing write-up is a later subtask (T-005.9 / AC9); this is the
// code-level pattern + example it will point at.
//
// To register a new integration: add ONE factory here returning a
// `WebSectionSpec`. That's the whole extension surface.

import Foundation

/// Registry of known embedded-web-app integrations, expressed purely as
/// `WebSectionSpec` factories.
///
/// This enum is the single, discoverable home for "which web apps can we
/// embed and how". Each `case`/factory is just a `WebSectionSpec` — proof
/// that adding an integration requires NO new WebKit code, only a new spec
/// (url + selector + data-store identity). See the file header for the full
/// pattern.
///
/// Jira is the first (and currently only) consumer. New integrations are a
/// new static factory below — nothing in `WebSectionView` changes.
public enum WebAppCatalog {

    // MARK: - Jira (first consumer)

    /// CSS selector for Jira's issue body container — the region we isolate
    /// so the embedded section shows the real Jira issue UI with the
    /// surrounding Jira chrome (nav, sidebars, banners) hidden. Validated
    /// in-browser against Jira Cloud.
    public static let jiraIssueSelector = "[data-vc=\"issue-body-container\"]"

    /// Model-cache identity key for Jira widgets.
    ///
    /// Used as the `forKey:` argument in `SessionDetailPanel.browserModel(for:tabId:)`
    /// to give Jira widgets their own independent tab and navigation state.
    ///
    /// NOTE: The persistent `WKWebsiteDataStore` (cookie jar) is no longer
    /// keyed on this value. `jiraIssue(url:)` now builds its spec with
    /// `dataStoreKey: browserDataStoreKey` so Jira shares the same on-disk
    /// web store as the generic Browser and GitHub PR widgets, enabling a
    /// single login to work across all three. This constant is retained
    /// exclusively as the in-memory model-cache key and must stay distinct
    /// from `githubDataStoreKey` and `browserDataStoreKey` so each preset
    /// keeps independent tab/navigation state.
    public static let jiraDataStoreKey = "jira"

    /// Build the `WebSectionSpec` for an embedded Jira issue.
    ///
    /// This is the canonical EXAMPLE of the registry pattern: a whole
    /// integration expressed as one spec. The Jira widget constructs its
    /// `WebSectionView` from this — passing the task's assigned Jira URL —
    /// and optionally an `onSignal` callback to learn when the issue has
    /// loaded / its title.
    ///
    /// CSS isolation is NOT applied (`selector: ""`): the full Jira page
    /// renders, including its native nav and sidebar chrome. The
    /// `jiraIssueSelector` constant is retained for reference and potential
    /// future selector-toggle work.
    ///
    /// - Parameter url: The Jira issue URL assigned to the task.
    /// - Returns: A spec that loads that issue as a full page (no isolation).
    public static func jiraIssue(url: URL) -> WebSectionSpec {
        WebSectionSpec(
            url: url,
            selector: "",
            dataStoreKey: browserDataStoreKey,
            title: "Jira"
        )
    }

    // MARK: - GitHub PR (second consumer)

    /// CSS selector for GitHub's main content region, GATED ON AUTH.
    ///
    /// GitHub wraps a PR page's primary content in
    /// `<div class="application-main">`, so isolating it shows the live PR
    /// UI with the global GitHub top nav, repo header chrome, and footer
    /// hidden. But `.application-main` also exists on GitHub's logged-out
    /// and 404 pages — and a PRIVATE repo's PR returns a 404 when you're
    /// not signed in. Cropping to bare `.application-main` would therefore
    /// hide GitHub's top header (which carries the "Sign in" link) on those
    /// pages, leaving the user with no way to authenticate.
    ///
    /// We gate the crop on auth with the descendant selector
    /// `.logged-in .application-main`: GitHub tags `<body>` with
    /// `logged-in` only when signed in (and `logged-out` otherwise). So:
    ///   • Logged out / 404 → the selector matches NOTHING →
    ///     `WebSectionScript.isolation`'s `if (!target) return;` leaves the
    ///     FULL GitHub page visible (header + "Sign in") so the user can
    ///     authenticate.
    ///   • After sign-in → `<body>` gains `logged-in` → the selector
    ///     matches and the crop to `.application-main` kicks in as before.
    /// The MutationObserver / SPA-navigation re-injection already re-runs
    /// isolation, so the crop applies automatically once the logged-in PR
    /// renders. The persistent `github` data store (below) then keeps that
    /// session across restarts. Configurable in the spec; validated
    /// in-browser against github.com, as with Jira.
    public static let githubPRSelector = ".logged-in .application-main"

    /// Model-cache identity key for GitHub PR widgets.
    ///
    /// Used as the `forKey:` argument in `SessionDetailPanel.browserModel(for:tabId:)`
    /// (and as the per-PR tab cache key prefix `"github:<owner>/<repo>#<number>"`)
    /// to give GitHub PR widgets their own independent tab and navigation state,
    /// distinct from Jira and the generic browser.
    ///
    /// NOTE: The persistent `WKWebsiteDataStore` (cookie jar) is no longer
    /// keyed on this value. `githubPR(url:)` now builds its spec with
    /// `dataStoreKey: browserDataStoreKey` so GitHub PR shares the same
    /// on-disk web store as the generic Browser and Jira widgets, enabling
    /// a single login to work across all three. This constant is retained
    /// exclusively as the in-memory model-cache key and must stay distinct
    /// from `jiraDataStoreKey` and `browserDataStoreKey` so each preset
    /// keeps independent tab/navigation state.
    public static let githubDataStoreKey = "github"

    /// Build the `WebSectionSpec` for an embedded GitHub pull request.
    ///
    /// The SECOND worked example of the registry pattern: a whole
    /// integration expressed as one spec, no WebKit code. The PR widget
    /// constructs its `WebSectionView` from this — passing the task's
    /// stored PR URL (`tasks.pr`) — and SPA-nav (GitHub Turbo) and SSO
    /// handling work unchanged.
    ///
    /// CSS isolation is NOT applied (`selector: ""`): the full GitHub page
    /// renders, including the top nav (which carries the "Sign in" link when
    /// logged out). The `githubPRSelector` constant is retained for
    /// reference and potential future selector-toggle work.
    ///
    /// - Parameter url: The GitHub pull-request URL stored on the task.
    /// - Returns: A spec that loads that PR as a full page (no isolation).
    public static func githubPR(url: URL) -> WebSectionSpec {
        WebSectionSpec(
            url: url,
            selector: "",
            dataStoreKey: browserDataStoreKey,
            title: "Pull Request"
        )
    }

    // MARK: - Figma (design files)

    /// In-memory model-cache key for the Figma preset. Like `jiraDataStoreKey` /
    /// `githubDataStoreKey`, retained ONLY to keep independent tab/navigation
    /// state; must stay distinct. The on-disk web store is `browserDataStoreKey`
    /// (below) so one Figma sign-in works across every browser-based widget.
    public static let figmaDataStoreKey = "figma"

    /// Build the `WebSectionSpec` for an embedded Figma file
    /// (figma-plugin-mcp-registry-and-usage .10). Same shape as
    /// `jiraIssue`/`githubPR`: a full-page render (`selector: ""`, since an
    /// isolation selector blanks a logged-out page) on the shared `"browser"`
    /// cookie jar (`browserDataStoreKey`).
    ///
    /// - Parameter url: A figma.com file/design/board/proto URL.
    /// - Returns: A spec that loads that file as a full page (no isolation).
    public static func figmaFile(url: URL) -> WebSectionSpec {
        WebSectionSpec(
            url: url,
            selector: "",
            dataStoreKey: browserDataStoreKey,
            title: "Figma"
        )
    }

    // MARK: - Artifact (agent's live HTML surfaces)

    /// Stable data-store key for the artifact webview. Unlike Jira/GitHub
    /// this is paired with an EPHEMERAL store (see `artifact(url:)`), so it
    /// never maps to an on-disk identity — it exists only to keep the spec
    /// shape uniform and to give the gallery widget a stable cache key for
    /// `LiveWidgetBackends`. Distinct from `"jira"`/`"github"`.
    public static let artifactDataStoreKey = "artifact"

    /// Build the `WebSectionSpec` for a session artifact (feat/spec-as-html.8).
    ///
    /// The THIRD worked example of the registry pattern — and the first to
    /// exercise two generic seams without any artifact-specific WebKit code:
    ///
    ///   • `selector: ""` — an EMPTY selector makes
    ///     `WebSectionScript.isolation` a no-op, so the WHOLE composed
    ///     document renders. The artifact server already returns a complete
    ///     themed page; there is no surrounding chrome to crop, unlike
    ///     Jira/GitHub.
    ///   • `ephemeral: true` — a non-persistent data store. The artifact
    ///     server serves app-authored local content over loopback and needs
    ///     no cookie/login persistence, so nothing is written to disk for it.
    ///
    /// The `.artifacts` gallery widget constructs its `CachedWebSectionView`
    /// from this, passing the loopback URL from
    /// `ArtifactRuntime.url(sessionId:artifactId:)`, and drives live reload
    /// via `WebSectionLiveView.reload()` when `index.html` changes.
    ///
    /// - Parameter url: The loopback artifact URL for the session + artifact
    ///   (`http://127.0.0.1:<port>/<sessionId>-<token>/<artifactId>/`).
    /// - Returns: A spec that renders the whole composed artifact document
    ///   with an ephemeral store.
    public static func artifact(url: URL) -> WebSectionSpec {
        WebSectionSpec(
            url: url,
            selector: "",
            dataStoreKey: artifactDataStoreKey,
            title: "Artifact",
            ephemeral: true
        )
    }

    // MARK: - Generic browser

    /// Stable persistent-store key for the generic browser widget. All browser
    /// widget instances share this key so the user's logins (e.g. a private wiki
    /// they sign into) survive app restarts. Distinct from "jira" and "github".
    public static let browserDataStoreKey = "browser"

    /// Build the `WebSectionSpec` for the generic browser widget.
    ///
    /// The FOURTH worked example of the registry pattern — and the first with
    /// a caller-supplied selector: the browser widget lets the user optionally
    /// apply CSS isolation by passing a non-empty `selector`. An empty selector
    /// (the default) is a no-op in `WebSectionScript.isolation`, so the whole
    /// page renders. A non-empty selector crops to that element exactly like
    /// the former Jira/PR specs did.
    ///
    /// - Parameters:
    ///   - url: Any URL the user wants to embed.
    ///   - selector: Optional CSS selector for isolation. Defaults to `""`
    ///     (no isolation — full page renders).
    /// - Returns: A spec that loads the URL with optional isolation and a
    ///   persistent data store.
    public static func browser(url: URL, selector: String = "") -> WebSectionSpec {
        WebSectionSpec(
            url: url,
            selector: selector,
            dataStoreKey: browserDataStoreKey,
            title: "Browser"
        )
    }

    // MARK: - Debug web view (curly-lynx.g)

    /// Stable data-store key for the debug web-view widget. Uses an ephemeral
    /// store (no cookies or session data persisted to disk) because the target
    /// is a locally-served Flutter web app that does not require authentication.
    /// Distinct from `"browser"` so a user's browser logins are never shared
    /// with a transient debug target.
    public static let debugWebDataStoreKey = "debugWeb"

    /// Build the `WebSectionSpec` for an embedded Flutter web debug target.
    ///
    /// The spec renders the full page (empty selector = no isolation) via an
    /// ephemeral store — the target is a loopback dev server that needs no
    /// persistent session. The caller passes the URL emitted by the Flutter web
    /// runner (typically `http://127.0.0.1:<port>/`).
    ///
    /// - Parameter url: The localhost URL where the Flutter web app is serving.
    /// - Returns: A spec that renders the whole debug target with an ephemeral store.
    public static func debugWeb(url: URL) -> WebSectionSpec {
        WebSectionSpec(
            url: url,
            selector: "",
            dataStoreKey: debugWebDataStoreKey,
            title: "Web View",
            ephemeral: true
        )
    }

    // MARK: - Jira URL detection

    /// Returns `true` when `url` looks like a Jira issue URL on Atlassian Cloud.
    ///
    /// Criteria (all must hold; case-insensitive host + path comparison):
    /// - Scheme is `http` or `https`.
    /// - Host ends with `.atlassian.net`.
    /// - The first non-empty path segment is exactly `browse`
    ///   (e.g. `acme.atlassian.net/browse/PROJ-1`).
    ///
    /// Non-issue Atlassian URLs — dashboards, boards, settings, anything
    /// whose first path segment is not `browse` — return `false` and fall
    /// through to generic in the resolver. This matches the app's Jira URL
    /// convention (AC19).
    ///
    /// Pure and `nonisolated`: no I/O, no state; unit-testable in isolation.
    ///
    /// - Parameter url: The URL to classify.
    /// - Returns: `true` if `url` is an Atlassian Cloud Jira issue URL.
    public nonisolated static func isJiraIssueURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host?.lowercased(),
              host.hasSuffix(".atlassian.net") else { return false }
        let firstSegment = url.pathComponents
            .filter { !$0.isEmpty && $0 != "/" }
            .first
        return firstSegment?.lowercased() == "browse"
    }

    // MARK: - Adding a new integration
    //
    // Copy the Jira example: add a `static func <app>(...) -> WebSectionSpec`
    // returning a spec with that app's URL, the CSS selector for the region
    // to isolate, and a data-store key. No WebKit code, no changes to
    // `WebSectionView`. That single factory IS the integration.
}
