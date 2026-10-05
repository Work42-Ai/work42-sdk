// GitHubPRRef.swift — a pure, tested reference to a GitHub pull request (T-006.2).
//
// task42's `.pr` widget embeds the live GitHub PR page in a `WebSectionView`. Before
// embedding, the stored PR URL (`tasks.pr`) must be validated so a non-PR or
// malformed URL falls back to the empty state instead of loading a broken page
// (see spec AC6 / AC10). This type is that validator: a pure, Sendable value type
// plus a static parser that extracts owner / repo / number from a
// `https://github.com/<owner>/<repo>/pull/<n>` URL.
//
// Mirrors the conventions of `Task42Core/JiraTicket.parseKey(from:)`: a regex /
// Foundation-only, deterministic, no-I/O static func, unit-testable in isolation.
// `parse` returning non-nil *is* the validity check — there is no separate
// `isValid` flag.

import Foundation

/// A validated reference to a GitHub pull request, extracted from a PR URL.
///
/// Pure value type — no I/O, no networking. Constructed only via
/// `GitHubPRRef.parse(_:)`, which returns nil for anything that isn't a
/// recognised `github.com` PR URL.
public nonisolated struct GitHubPRRef: Equatable, Sendable {
    /// The repository owner (the first path segment), e.g. `apple` in
    /// `github.com/apple/swift/pull/1`.
    public let owner: String
    /// The repository name (the second path segment), e.g. `swift`.
    public let repo: String
    /// The pull-request number (the integer after `/pull/`), e.g. `1`.
    public let number: Int

    public init(owner: String, repo: String, number: Int) {
        self.owner = owner
        self.repo = repo
        self.number = number
    }

    // MARK: - URL → ref parsing

    /// Extracts a GitHub PR reference from a URL string.
    ///
    /// Pure and deterministic — no I/O — so it's unit-testable (T-006.6).
    /// Accepts URLs shaped like `https://github.com/<owner>/<repo>/pull/<n>`:
    ///   - `https://github.com/apple/swift/pull/123`
    ///   - `http://github.com/apple/swift/pull/123` (http or https)
    ///   - `https://www.github.com/apple/swift/pull/123` (optional `www.`)
    ///   - `https://github.com/apple/swift/pull/123?diff=split#r1` (query/fragment)
    ///   - `https://github.com/apple/swift/pull/123/files` (trailing segments:
    ///     `/files`, `/commits`, …)
    ///
    /// Returns nil for:
    ///   - non-PR GitHub URLs (issues, repo home, `/tree/…`, …),
    ///   - non-`github.com` hosts (including GitHub Enterprise — out of scope),
    ///   - malformed strings, or a non-numeric / missing PR number.
    public static func parse(_ urlString: String) -> GitHubPRRef? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed) else { return nil }

        // Scheme must be http/https. URLComponents lowercases the scheme.
        guard let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }

        // Host must be exactly github.com (or www.github.com). Reject GitHub
        // Enterprise and any other host — out of scope.
        guard let host = components.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else { return nil }

        // Split the path into non-empty segments. A PR path is:
        //   /<owner>/<repo>/pull/<n>[/<extra>…]
        // so we need at least four segments with `pull` as the third.
        let segments = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard segments.count >= 4 else { return nil }

        let owner = segments[0]
        let repo = segments[1]
        guard segments[2] == "pull" else { return nil }

        // The PR number must be a non-negative integer. `Int(_:)` rejects
        // empty strings, signs, whitespace, and trailing junk.
        guard let number = Int(segments[3]), number > 0 else { return nil }

        // owner/repo must be non-empty (guaranteed by omittingEmptySubsequences,
        // but assert intent for clarity).
        guard !owner.isEmpty, !repo.isEmpty else { return nil }

        return GitHubPRRef(owner: owner, repo: repo, number: number)
    }
}
