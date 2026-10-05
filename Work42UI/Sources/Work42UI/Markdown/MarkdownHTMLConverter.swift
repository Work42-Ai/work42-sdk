// MarkdownHTMLConverter.swift - Markdown → GFM HTML via cmark-gfm.
//
// Used by the WebView-based `MarkdownPreview` so docs render as real HTML the
// user can select/copy freely and navigate between (which the block-based
// MarkdownUI renderer can't do). cmark-gfm is already resolved transitively via
// swift-markdown-ui; we just render HTML directly instead of MarkdownUI's AST.

import Foundation
import cmark_gfm
import cmark_gfm_extensions

public enum MarkdownHTMLConverter {

    /// The GFM syntax extensions to enable (tables, task lists, strikethrough, …).
    private static let extensionNames = ["autolink", "strikethrough", "tagfilter", "tasklist", "table"]

    /// Render `markdown` to a GFM HTML fragment. Returns "" on failure.
    ///
    /// When `sourcePositions` is true, every block element carries a
    /// `data-sourcepos="startLine:col-endLine:col"` attribute (cmark's
    /// `CMARK_OPT_SOURCEPOS`). The preview's comment layer reads these to map a
    /// browser text selection back to 1-based source line ranges — the same
    /// anchor the native editor gutter uses — so a comment left in Preview lands
    /// on the identical `.file` line span as one left in Source.
    public static func html(from markdown: String, sourcePositions: Bool = false) -> String {
        cmark_gfm_core_extensions_ensure_registered()

        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { return "" }
        defer { cmark_parser_free(parser) }

        for name in extensionNames {
            if let syntaxExtension = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, syntaxExtension)
            }
        }

        cmark_parser_feed(parser, markdown, markdown.utf8.count)
        guard let document = cmark_parser_finish(parser) else { return "" }
        defer { cmark_node_free(document) }

        let extensions = cmark_parser_get_syntax_extensions(parser)
        // UNSAFE renders raw HTML embedded in the doc (these are the user's own
        // trusted local files); the `tagfilter` extension still strips the
        // dangerous script/style/iframe tags. SOURCEPOS adds the per-block
        // `data-sourcepos` line anchors the comment layer needs.
        let options = CMARK_OPT_UNSAFE | (sourcePositions ? CMARK_OPT_SOURCEPOS : 0)
        guard let cString = cmark_render_html(document, options, extensions) else { return "" }
        defer { free(cString) }
        return String(cString: cString)
    }
}
