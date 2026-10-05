// MarkdownArtifactRewriter.swift — Preprocess standalone [[artifact:<id>]] token
// lines in a markdown string before it is converted to HTML by cmark-gfm.
//
// A line whose TRIMMED content is exactly `[[artifact:<id>]]` (id charset
// ^[a-z0-9][a-z0-9-]*$) is replaced with a raw HTML div that cmark passes
// through unchanged (CMARK_OPT_UNSAFE handles raw HTML blocks; the `tagfilter`
// extension only affects INLINE HTML, not block-level HTML). The parent
// MarkdownDocumentTemplate injects a bridge script that converts the placeholder
// divs to live iframes auto-sized by the ArtifactServer's built-in height-post
// IIFE.
//
// MODULE BOUNDARY
// ═══════════════
// Work42UI must remain free of Flow42Core. The URL resolver closure
// `(String) -> URL?` is supplied by the caller (Work42App /
// SessionDetailPanel) where ArtifactRuntime is available. This file only
// knows about the resolver's signature — it never imports or references
// ArtifactRuntime directly.

import Foundation

public enum MarkdownArtifactRewriter {

    /// Matches lines whose TRIMMED content is exactly [[artifact:<id>]].
    /// Capture group 1 = the artifact id.
    /// id charset: first char [a-z0-9], remainder [a-z0-9-]*.
    private static let tokenRegex: NSRegularExpression = {
        // Force-unwrap is safe — the pattern is a compile-time constant.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"^\[\[artifact:([a-z0-9][a-z0-9-]*)\]\]$"#,
            options: []
        )
    }()

    /// Preprocess `markdown`, replacing each standalone `[[artifact:<id>]]`
    /// line with a raw HTML block.
    ///
    /// - Parameters:
    ///   - markdown: The raw markdown source.
    ///   - artifactURLResolver: Maps an artifact id to its ArtifactServer URL.
    ///     - `nil` resolver → the function is a no-op (fast path, returns
    ///       the original string and sets `foundAny = false`).
    ///     - non-nil resolver returning a URL for an id → emits a
    ///       `.w42-artifact-ref` div carrying the absolute server URL.
    ///     - non-nil resolver returning `nil` for an id → emits a fail-loud
    ///       `.w42-artifact-unavailable` paragraph.
    ///   - foundAny: Set to `true` when at least one token was replaced, so
    ///     the caller can decide to inject the artifact bridge script/CSS.
    /// - Returns: The preprocessed markdown (or the original when nothing
    ///   changed).
    public static func preprocess(
        markdown: String,
        artifactURLResolver: ((String) -> URL?)?,
        artifactTitleResolver: ((String) -> String?)? = nil,
        foundAny: inout Bool
    ) -> String {
        guard let resolver = artifactURLResolver else {
            foundAny = false
            return markdown
        }

        let lines = markdown.components(separatedBy: "\n")
        var result: [String] = []
        result.reserveCapacity(lines.count + 16) // extra room for blank-line padding
        foundAny = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Fast path: empty lines can never match the token pattern.
            guard !trimmed.isEmpty else {
                result.append(line)
                continue
            }

            let ns = trimmed as NSString
            let fullRange = NSRange(location: 0, length: ns.length)
            if let match = tokenRegex.firstMatch(in: trimmed, range: fullRange),
               match.range(at: 1).location != NSNotFound {

                let id = ns.substring(with: match.range(at: 1))
                foundAny = true

                // Surround with blank lines so cmark treats the div as a
                // standalone HTML block (type 6 block, ends at blank line),
                // never absorbing the adjacent markdown line into the block.
                result.append("")

                if let url = resolver(id) {
                    // Sanitise the absolute loopback URL — the only character
                    // that would break the HTML attribute value is `"`.
                    let src = url.absoluteString.replacingOccurrences(of: "\"", with: "%22")
                    // Human title from meta.json (falls back to the id in the
                    // bridge script) so the embed header matches the artifact
                    // card exactly instead of showing the raw id.
                    let titleAttr = artifactTitleResolver?(id).map {
                        " data-w42-title=\"\(htmlEscapeAttr($0))\""
                    } ?? ""
                    result.append(
                        "<div class=\"w42-artifact-ref\" data-w42-id=\"\(id)\" data-w42-src=\"\(src)\"\(titleAttr)></div>"
                    )
                } else {
                    // ArtifactRuntime returned nil — server not running or id
                    // unregistered. Fail loud: show a visible error paragraph.
                    result.append(
                        "<p class=\"w42-artifact-unavailable\">artifact <code>\(id)</code> unavailable</p>"
                    )
                }

                result.append("")
            } else {
                // Non-matching line (mid-line token, wrong charset, etc.) →
                // pass through untouched so cmark renders it as literal text.
                result.append(line)
            }
        }

        return result.joined(separator: "\n")
    }

    /// Escape a string for safe use inside a double-quoted HTML attribute.
    private static func htmlEscapeAttr(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
