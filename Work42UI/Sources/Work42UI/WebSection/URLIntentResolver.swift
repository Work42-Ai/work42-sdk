// URLIntentResolver.swift — Pure URL → web-preset classification (AC19/AC21).
//
// The SINGLE source of truth for routing an arbitrary http(s) URL to the
// right embedded-web preset: a GitHub pull request, an Atlassian Jira issue,
// or a generic web page. Every surface that opens a URL internally — the
// browser address bar, a Home bookmark open, the session/chat/palette open
// paths — classifies through this one seam so that a typed or clicked PR/Jira
// URL upgrades IN PLACE to its preset spec (shared login + PR diff-anchoring /
// auth-gated Jira selector), cached under a stable per-item slot.
//
// Surfaces MUST NOT re-derive this routing — always go through
// `classify` → `spec(for:url:)` / `cacheKey(for:url:)`.
//
// `classify` and `cacheKey` are pure and `nonisolated` (no I/O, no state,
// unit-testable in isolation). `spec(for:url:)` builds a `WebSectionSpec` via
// the MainActor-isolated `WebAppCatalog` factories, so it inherits the module's
// default MainActor isolation — every caller (SwiftUI surfaces) is already on
// the main actor.

import Foundation

/// The web preset an http(s) URL resolves to.
public enum WebURLIntent: Equatable, Sendable {
    /// A GitHub pull-request URL — carries the parsed owner/repo/number.
    case githubPR(GitHubPRRef)
    /// An Atlassian Cloud Jira issue URL (`<tenant>.atlassian.net/browse/KEY`).
    case jira
    /// Anything else — a plain web page (includes any non-http(s) URL).
    case generic
}

/// Classifies an http(s) URL to a `WebURLIntent` and maps that intent to the
/// `WebSectionSpec` + in-memory cache key the surfaces consume. The one place
/// URL→preset routing is derived.
public enum URLIntentResolver {

    // MARK: - Classify

    /// Classify `url`, in priority order:
    ///   1. a GitHub PR URL (via `GitHubPRRef.parse`) → `.githubPR(ref)`
    ///   2. else an Atlassian Jira issue URL (via `WebAppCatalog.isJiraIssueURL`) → `.jira`
    ///   3. else `.generic`.
    ///
    /// Non-http(s) URLs classify as `.generic` — both `GitHubPRRef.parse` and
    /// `WebAppCatalog.isJiraIssueURL` reject any non-http(s) scheme.
    public nonisolated static func classify(_ url: URL) -> WebURLIntent {
        if let ref = GitHubPRRef.parse(url.absoluteString) {
            return .githubPR(ref)
        }
        if WebAppCatalog.isJiraIssueURL(url) {
            return .jira
        }
        return .generic
    }

    // MARK: - Preset spec

    /// The `WebSectionSpec` for `intent` at `url`:
    ///   - `.githubPR` → `WebAppCatalog.githubPR(url:)` (PR preset: diff-anchoring,
    ///     auth-gated `.logged-in .application-main` selector)
    ///   - `.jira`     → `WebAppCatalog.jiraIssue(url:)` (Jira issue preset)
    ///   - `.generic`  → `WebAppCatalog.browser(url:selector:)` (plain page, no selector)
    ///
    /// MainActor-isolated (module default) because it calls the `WebAppCatalog`
    /// factories; all surfaces call it from the main actor.
    public static func spec(for intent: WebURLIntent, url: URL) -> WebSectionSpec {
        switch intent {
        case .githubPR:
            return WebAppCatalog.githubPR(url: url)
        case .jira:
            return WebAppCatalog.jiraIssue(url: url)
        case .generic:
            return WebAppCatalog.browser(url: url, selector: "")
        }
    }

    // MARK: - Cache key

    /// The in-memory cache slot key for `intent` at `url` — the identity under
    /// which a surface caches this item's live `WebSectionView` so tabs coexist
    /// without stealing each other's webview:
    ///   - `.githubPR` → `"github:<owner>/<repo>#<number>"` — the SAME format as
    ///     `PRWidgetCoordinator.githubCacheKey`, so a PR opened in the browser and
    ///     the same PR in the `.pr` widget share nothing by accident yet each is
    ///     stable per-PR.
    ///   - `.jira`     → `"jira:<host>/<KEY>"` where `KEY` is the last non-empty
    ///     path segment (the issue key, e.g. `PROJ-1`).
    ///   - `.generic`  → `WebAppCatalog.browserDataStoreKey` (the shared browser slot).
    ///
    /// MainActor-isolated (module default) because `.generic` reads
    /// `WebAppCatalog.browserDataStoreKey`; all surfaces call it from the main actor.
    public static func cacheKey(for intent: WebURLIntent, url: URL) -> String {
        switch intent {
        case .githubPR(let ref):
            return "github:\(ref.owner)/\(ref.repo)#\(ref.number)"
        case .jira:
            let host = url.host?.lowercased() ?? ""
            let key = url.pathComponents.last { !$0.isEmpty && $0 != "/" } ?? ""
            return "jira:\(host)/\(key)"
        case .generic:
            return WebAppCatalog.browserDataStoreKey
        }
    }
}
