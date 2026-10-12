// Work42MarkdownText.swift - The markdown view plugins and the app render
// prose with, so MarkdownUI never appears in Work42UI's public interface.
//
// MarkdownUI is an `internal import` of this module: plugin binaries link
// only Work42-owned types, and MarkdownUI can be upgraded without breaking
// plugins built against an earlier SDK. The app's chat needs two extras a
// plugin has no use for (a pre-parsed document cache and the body-size /
// local-image options); they live behind `@_spi(Work42Host)`, which is
// printed only to the private module interface the app ships no copy of.

internal import MarkdownUI
import SwiftUI
import AppKit

/// The markdown themes Work42 ships. Both render identically today; `.flow42`
/// is the pre-redesign name kept for the app's existing call sites.
public enum Work42MarkdownTheme: Sendable {
    case work42
    case flow42
}

extension Work42MarkdownTheme {
    fileprivate var markdownUITheme: MarkdownUI.Theme {
        switch self {
        case .work42: .work42
        case .flow42: .flow42
        }
    }
}

/// A markdown document parsed once, so a lazily rebuilt row does not re-run the
/// cmark parse each time its body builds. Host-app only.
@_spi(Work42Host)
public struct Work42ParsedMarkdown: @unchecked Sendable {
    fileprivate let content: MarkdownContent

    public init(_ markdown: String) {
        content = MarkdownContent(markdown)
    }
}

/// Renders markdown with the Work42 theme.
///
///     Work42MarkdownText(report)                       // plugin default
///     Work42MarkdownText(report, theme: .flow42)
public struct Work42MarkdownText: View {
    private enum Source {
        case text(String)
        case parsed(MarkdownContent)
    }

    private let source: Source
    private let theme: Work42MarkdownTheme
    private let bodyFontSize: CGFloat?
    private let resolvesLocalFileImages: Bool

    public init(_ markdown: String, theme: Work42MarkdownTheme = .work42) {
        self.source = .text(markdown)
        self.theme = theme
        self.bodyFontSize = nil
        self.resolvesLocalFileImages = false
    }

    /// Host-app form: a pre-parsed document, an optional body size (also forces
    /// primary-colour body text) and `file://` image resolution.
    @_spi(Work42Host)
    public init(
        parsed: Work42ParsedMarkdown,
        theme: Work42MarkdownTheme,
        bodyFontSize: CGFloat? = nil,
        resolvesLocalFileImages: Bool = false
    ) {
        self.source = .parsed(parsed.content)
        self.theme = theme
        self.bodyFontSize = bodyFontSize
        self.resolvesLocalFileImages = resolvesLocalFileImages
    }

    @ViewBuilder
    private var base: some View {
        switch source {
        case .text(let text): Markdown(text).markdownTheme(theme.markdownUITheme)
        case .parsed(let content): Markdown(content).markdownTheme(theme.markdownUITheme)
        }
    }

    public var body: some View {
        if let size = bodyFontSize {
            if resolvesLocalFileImages {
                base
                    .markdownImageProvider(LocalFileImageProvider())
                    .markdownTextStyle {
                        FontSize(size)
                        ForegroundColor(.primary)
                    }
            } else {
                base.markdownTextStyle {
                    FontSize(size)
                    ForegroundColor(.primary)
                }
            }
        } else if resolvesLocalFileImages {
            base.markdownImageProvider(LocalFileImageProvider())
        } else {
            base
        }
    }
}

// MARK: - LocalFileImageProvider

/// A MarkdownUI `ImageProvider` that resolves `file://` URLs to local
/// disk images via `NSImage`, enabling inline image rendering in agent
/// messages and error rows.
///
/// Non-`file://` URLs (http, https, etc.) render as `Color.clear` — this
/// provider is intentionally local-only. Work42 sessions don't fetch
/// external images at render time.
struct LocalFileImageProvider: ImageProvider {

    init() {}

    nonisolated func makeImage(url: URL?) -> some View {
        localImage(url: url)
    }

    @ViewBuilder
    nonisolated private func localImage(url: URL?) -> some View {
        if let url, url.isFileURL, let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            // Unknown scheme or unreadable file: render nothing.
            Color.clear.frame(width: 0, height: 0)
        }
    }
}
