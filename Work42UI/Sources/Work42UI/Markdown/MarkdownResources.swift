// MarkdownResources.swift — local-media + mermaid support for the WebView
// markdown renderer (MarkdownWebView / MarkdownPreview).
//
// WKWebView's `loadHTMLString(_:baseURL:)` refuses local-file sub-resource
// loads even when `baseURL` is a `file://` URL, so every `![](image.png)` /
// `![](./assets/x.png)` / `file://…` reference in a spec, testing plan, or file
// preview silently broke. This file adds:
//
//   1. `MarkdownResourceSchemeHandler` — a `WKURLSchemeHandler` for the
//      `w42res://` scheme that serves (a) local image bytes from disk and
//      (b) the bundled mermaid library.
//   2. `MarkdownImageRewriter` — rewrites LOCAL `<img>` srcs in the rendered
//      HTML to `w42res://media/img?p=<abs-path>` (relative paths resolved
//      against the markdown file's own directory). `http(s)` and `data:` srcs
//      are left untouched (WebKit already loads those).
//
// http/https images keep working as before; misses degrade to the browser's
// broken-image glyph (a clean placeholder), never an error that takes down the
// whole document.

import Foundation
import WebKit
import UniformTypeIdentifiers

// MARK: - Scheme handler

/// Serves `w42res://` resources for the markdown WebView:
///   • `w42res://media/img?p=<percent-encoded-absolute-path>` → the file's bytes
///   • `w42res://asset/mermaid.min.js`                        → the bundled lib
///
/// A plain (non-isolated) class so it satisfies WebKit's non-isolated
/// `WKURLSchemeHandler` requirements cleanly. The mermaid library bytes are
/// fetched on the main actor by the caller and handed in at init, so nothing
/// here touches `@MainActor` state.
public final class MarkdownResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    public static let scheme = "w42res"

    private let mermaidLibrary: Data?
    private let highlightLibrary: Data?

    public init(mermaidLibrary: Data?, highlightLibrary: Data? = nil) {
        self.mermaidLibrary = mermaidLibrary
        self.highlightLibrary = highlightLibrary
        super.init()
    }

    public func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(Self.notFound); return
        }
        switch url.host {
        case "asset":
            let data: Data?
            switch url.path {
            case "/mermaid.min.js":   data = mermaidLibrary
            case "/highlight.min.js": data = highlightLibrary
            default:                  data = nil
            }
            guard let data else {
                task.didFailWithError(Self.notFound); return
            }
            Self.respond(task, url: url, data: data, mime: "application/javascript")

        case "media":
            guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let path = comps.queryItems?.first(where: { $0.name == "p" })?.value,
                  !path.isEmpty,
                  let data = FileManager.default.contents(atPath: path) else {
                // Graceful miss: 404 → the <img> shows the broken-image glyph,
                // the rest of the document renders fine.
                task.didFailWithError(Self.notFound); return
            }
            Self.respond(task, url: url, data: data, mime: Self.mime(forPath: path))

        default:
            task.didFailWithError(Self.notFound)
        }
    }

    public func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private static let notFound = NSError(domain: "MarkdownResource", code: 404)

    private static func respond(_ task: WKURLSchemeTask, url: URL, data: Data, mime: String) {
        let response = URLResponse(
            url: url, mimeType: mime,
            expectedContentLength: data.count, textEncodingName: nil
        )
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private static func mime(forPath path: String) -> String {
        let ext = (path as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }
}

// MARK: - Image src rewriting

public enum MarkdownImageRewriter {
    /// The `w42res://asset/mermaid.min.js` URL the markdown template loads the
    /// bundled mermaid library from (served by `MarkdownResourceSchemeHandler`).
    public static let mermaidScriptURL = "\(MarkdownResourceSchemeHandler.scheme)://asset/mermaid.min.js"

    /// The `w42res://asset/highlight.min.js` URL the markdown template loads the
    /// bundled highlight.js library from (served by `MarkdownResourceSchemeHandler`).
    public static let highlightScriptURL = "\(MarkdownResourceSchemeHandler.scheme)://asset/highlight.min.js"

    /// Rewrite LOCAL `<img>` srcs in `html` to the `w42res://media` scheme so
    /// the scheme handler can serve them (WebKit blocks direct file loads under
    /// `loadHTMLString`). `http`/`https`/`data`/already-`w42res` srcs pass
    /// through untouched. Relative paths resolve against `baseURL`'s directory.
    public static func rewrite(html: String, baseURL: URL?) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "(<img\\b[^>]*?\\bsrc=\")([^\"]*)(\")",
            options: [.caseInsensitive]
        ) else { return html }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return html }
        let mutable = NSMutableString(string: html)
        // Reverse order so earlier ranges stay valid as we mutate.
        for match in matches.reversed() {
            let srcRange = match.range(at: 2)
            guard srcRange.location != NSNotFound else { continue }
            let src = ns.substring(with: srcRange)
            guard let rewritten = rewriteSrc(src, baseURL: baseURL) else { continue }
            mutable.replaceCharacters(in: srcRange, with: rewritten)
        }
        return mutable as String
    }

    /// Returns the rewritten src, or nil to leave the original untouched.
    static func rewriteSrc(_ src: String, baseURL: URL?) -> String? {
        let lower = src.lowercased()
        // Web + inline + already-rewritten: leave as-is.
        if lower.hasPrefix("http://") || lower.hasPrefix("https://")
            || lower.hasPrefix("data:") || lower.hasPrefix("\(MarkdownResourceSchemeHandler.scheme):") {
            return nil
        }
        // cmark HTML-escapes `&` in attribute values.
        let unescaped = src.replacingOccurrences(of: "&amp;", with: "&")
        let absPath: String?
        if lower.hasPrefix("file://") {
            absPath = URL(string: unescaped)?.path ?? unescaped.removingPercentEncoding
        } else {
            let decoded = unescaped.removingPercentEncoding ?? unescaped
            if decoded.hasPrefix("/") {
                absPath = decoded
            } else if decoded.hasPrefix("~") {
                absPath = (decoded as NSString).expandingTildeInPath
            } else if let baseDir = baseURL?.deletingLastPathComponent() {
                absPath = URL(fileURLWithPath: decoded, relativeTo: baseDir)
                    .standardizedFileURL.path
            } else {
                absPath = nil   // relative but no base to resolve against
            }
        }
        guard let path = absPath, !path.isEmpty,
              let encoded = path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            return nil
        }
        return "\(MarkdownResourceSchemeHandler.scheme)://media/img?p=\(encoded)"
    }
}
