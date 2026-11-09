// Work42SelectableMarkdown+iOS.swift - The iPadOS prose builder for `Work42MarkdownSegments` (WOR-604).
//
// The Mac builds a reply's prose with TextKit blocks (table cells, the quote bar) that UIKit does not have. This is the same
// split with what UIKit can draw: one `NSAttributedString` per run of prose (paragraphs, headings, lists, quotes, rules, inline
// marks), fenced code blocks apart, and what it does not style (tables, images, raw HTML) as markdown source for
// `Work42MarkdownText`, as the segment model already allows. Nothing is ever dropped. Prose is one text view, so a touch selection
// covers all of it and reports its text and rect, which is what the Comment pill needs.
//
// The Mac's builder is untouched; this file exists only where AppKit does not.

#if !canImport(AppKit)
import SwiftUI
import UIKit
internal import cmark_gfm
internal import cmark_gfm_extensions

private typealias CmarkNode = UnsafeMutablePointer<cmark_node>

enum IOSMarkdownSegments {
    private static let extensionNames = ["autolink", "strikethrough", "tagfilter", "tasklist", "table"]

    static func split(_ markdown: String, bodyFontSize: CGFloat) -> [Work42MarkdownSegment] {
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_SOURCEPOS) else { return fallback(markdown) }
        defer { cmark_parser_free(parser) }
        for name in extensionNames {
            if let syntaxExtension = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, syntaxExtension)
            }
        }
        cmark_parser_feed(parser, markdown, markdown.utf8.count)
        guard let document = cmark_parser_finish(parser) else { return fallback(markdown) }
        defer { cmark_node_free(document) }

        let builder = IOSProseBuilder(markdown: markdown, bodySize: bodyFontSize)
        var child = cmark_node_first_child(document)
        while let node = child {
            builder.appendTopLevel(node)
            child = cmark_node_next(node)
        }
        return builder.finish()
    }

    private static func fallback(_ markdown: String) -> [Work42MarkdownSegment] {
        markdown.isEmpty ? [] : [.markdown(markdown)]
    }
}

private struct InlineStyle {
    var bold = false
    var italic = false
    var mono = false
    var strike = false
    var link: URL?
    var size: CGFloat
    var baseWeight: UIFont.Weight = .regular
    var color: UIColor = .label
}

private struct BlockContext {
    /// Left edge of this block's text.
    var indent: CGFloat = 0
    var color: UIColor = .label
    var spacingAfter: CGFloat = ChatMetrics.paragraphSpacing
}

private final class IOSProseBuilder {
    private let lines: [Substring]
    private let bodySize: CGFloat
    private var segments: [Work42MarkdownSegment] = []
    private let current = NSMutableAttributedString()
    private let accent = UIColor(DT.systemAccent)
    private static let markerWidth: CGFloat = 22
    private static let quoteIndent: CGFloat = 14

    init(markdown: String, bodySize: CGFloat) {
        self.lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        self.bodySize = bodySize
    }

    // MARK: Top level

    func appendTopLevel(_ node: CmarkNode) {
        switch Self.type(node) {
        case "code_block":
            flush()
            var code = Self.literal(node)
            while code.hasSuffix("\n") { code.removeLast() }
            segments.append(.code(language: Self.fenceInfo(node), code: code))
        case "table", "html_block", "footnote_definition":
            // Drawn by `Work42MarkdownText`, which styles tables.
            flush()
            appendSource(of: node)
        default:
            if Self.containsImage(node) {
                flush()
                appendSource(of: node)
            } else {
                appendBlock(node, BlockContext(), marker: nil, markerIndent: 0)
            }
        }
    }

    func finish() -> [Work42MarkdownSegment] {
        flush()
        return segments
    }

    private func flush() {
        guard current.length > 0 else { return }
        while current.length > 0, current.string.hasSuffix("\n") {
            current.deleteCharacters(in: NSRange(location: current.length - 1, length: 1))
        }
        if current.length > 0 { segments.append(.prose(NSAttributedString(attributedString: current))) }
        current.deleteCharacters(in: NSRange(location: 0, length: current.length))
    }

    private func appendSource(of node: CmarkNode) {
        let start = max(Int(cmark_node_get_start_line(node)), 1)
        let end = min(max(Int(cmark_node_get_end_line(node)), start), lines.count)
        guard start <= end else { return }
        segments.append(.markdown(lines[(start - 1)..<end].joined(separator: "\n")))
    }

    // MARK: Blocks

    private func appendBlock(_ node: CmarkNode, _ ctx: BlockContext, marker: String?, markerIndent: CGFloat) {
        switch Self.type(node) {
        case "paragraph":
            appendText(of: node, ctx: ctx, size: bodySize, weight: .regular, before: 0, after: ctx.spacingAfter,
                       marker: marker, markerIndent: markerIndent)
        case "heading":
            let level = Int(cmark_node_get_heading_level(node))
            let (size, weight, before, after): (CGFloat, UIFont.Weight, CGFloat, CGFloat) = {
                switch level {
                case 1: return (24, .bold, 16, 8)
                case 2: return (21, .semibold, 16, 4)
                case 3: return (18, .semibold, 12, 4)
                default: return (16, .semibold, 8, 0)
                }
            }()
            appendText(of: node, ctx: ctx, size: size, weight: weight, before: before, after: after,
                       marker: marker, markerIndent: markerIndent)
        case "list":
            appendList(node, ctx)
        case "block_quote":
            // No bar on iPadOS: the quote is indented and set in the secondary colour.
            var inner = ctx
            inner.indent += Self.quoteIndent
            inner.color = .secondaryLabel
            var first = true
            var child = cmark_node_first_child(node)
            while let c = child {
                appendBlock(c, inner, marker: first ? marker : nil, markerIndent: markerIndent)
                first = false
                child = cmark_node_next(c)
            }
        case "thematic_break":
            let style = paragraphStyle(ctx, before: 10, after: 10)
            style.alignment = .center
            current.append(NSAttributedString(string: "\u{2500}\u{2500}\u{2500}\n", attributes: [
                .font: UIFont.systemFont(ofSize: bodySize), .foregroundColor: UIColor.label.withAlphaComponent(0.25),
                .paragraphStyle: style,
            ]))
        case "code_block":
            // A code block inside a list item or quote stays inline as monospaced text (top-level ones become cards).
            var code = Self.literal(node)
            while code.hasSuffix("\n") { code.removeLast() }
            let style = paragraphStyle(ctx, before: 0, after: ctx.spacingAfter)
            style.lineSpacing = 2
            current.append(NSAttributedString(string: code + "\n", attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: bodySize - 2, weight: .regular),
                .foregroundColor: ctx.color,
                .backgroundColor: UIColor.label.withAlphaComponent(0.06),
                .paragraphStyle: style,
            ]))
        default:
            // Tables, raw HTML and anything else inside a list item or quote: keep the source text, never drop it.
            let start = max(Int(cmark_node_get_start_line(node)), 1)
            let end = min(max(Int(cmark_node_get_end_line(node)), start), lines.count)
            if start <= end {
                current.append(NSAttributedString(string: lines[(start - 1)..<end].joined(separator: "\n") + "\n", attributes: [
                    .font: UIFont.systemFont(ofSize: bodySize), .foregroundColor: ctx.color,
                    .paragraphStyle: paragraphStyle(ctx, before: 0, after: ctx.spacingAfter),
                ]))
            }
        }
    }

    private func appendList(_ node: CmarkNode, _ ctx: BlockContext) {
        let ordered = cmark_node_get_list_type(node) == CMARK_ORDERED_LIST
        var number = Int(cmark_node_get_list_start(node))
        var itemCtx = ctx
        itemCtx.indent = ctx.indent + Self.markerWidth
        itemCtx.spacingAfter = 4
        var child = cmark_node_first_child(node)
        while let item = child {
            let marker: String
            if Self.type(item) == "tasklist" {
                marker = cmark_gfm_extensions_get_tasklist_item_checked(item) ? "\u{2611}" : "\u{2610}"
            } else {
                marker = ordered ? "\(number)." : "\u{2022}"
            }
            number += 1
            var first = true
            var content = cmark_node_first_child(item)
            if content == nil {
                // An empty item still shows its marker.
                current.append(NSAttributedString(string: marker + "\n", attributes: [
                    .font: UIFont.systemFont(ofSize: bodySize), .foregroundColor: ctx.color,
                    .paragraphStyle: paragraphStyle(itemCtx, before: 0, after: 4, markerIndent: ctx.indent),
                ]))
            }
            while let block = content {
                appendBlock(block, itemCtx, marker: first ? marker : nil, markerIndent: ctx.indent)
                first = false
                content = cmark_node_next(block)
            }
            child = cmark_node_next(item)
        }
        // A list is followed by the normal paragraph gap (the last item only had the item gap).
        if ctx.indent == 0 { setTrailingSpacing(ctx.spacingAfter) }
    }

    /// Gives the last paragraph in the run `spacing` points after it.
    private func setTrailingSpacing(_ spacing: CGFloat) {
        guard current.length > 0 else { return }
        let string = current.string as NSString
        var searchEnd = string.length
        if string.hasSuffix("\n") { searchEnd -= 1 }
        let lastNewline = string.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: searchEnd))
        let start = lastNewline.location == NSNotFound ? 0 : lastNewline.location + 1
        let range = NSRange(location: start, length: string.length - start)
        guard range.length > 0,
              let existing = current.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle,
              let style = existing.mutableCopy() as? NSMutableParagraphStyle else { return }
        style.paragraphSpacing = spacing
        current.addAttribute(.paragraphStyle, value: style, range: range)
    }

    // MARK: Text

    private func appendText(
        of node: CmarkNode, ctx: BlockContext, size: CGFloat, weight: UIFont.Weight,
        before: CGFloat, after: CGFloat, marker: String?, markerIndent: CGFloat
    ) {
        let piece = NSMutableAttributedString()
        let style = InlineStyle(size: size, baseWeight: weight, color: ctx.color)
        if let marker {
            piece.append(NSAttributedString(string: marker + "\t", attributes: attributes(for: style)))
        }
        appendInlines(of: node, style: style, into: piece)
        piece.append(NSAttributedString(string: "\n", attributes: attributes(for: style)))
        let paragraph = paragraphStyle(ctx, before: before, after: after, markerIndent: marker == nil ? nil : markerIndent)
        piece.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: piece.length))
        current.append(piece)
    }

    private func appendInlines(of node: CmarkNode, style: InlineStyle, into out: NSMutableAttributedString) {
        var child = cmark_node_first_child(node)
        while let c = child {
            var inner = style
            switch Self.type(c) {
            case "text", "html_inline":
                out.append(NSAttributedString(string: Self.literal(c), attributes: attributes(for: style)))
            case "softbreak":
                out.append(NSAttributedString(string: " ", attributes: attributes(for: style)))
            case "linebreak":
                out.append(NSAttributedString(string: "\u{2028}", attributes: attributes(for: style)))
            case "code":
                inner.mono = true
                // Tagged with its text, so a host can draw chosen spans its own way (`MarkdownInlineCodeSpans`).
                var attrs = attributes(for: inner)
                attrs[.work42InlineCode] = Self.literal(c)
                out.append(NSAttributedString(string: Self.literal(c), attributes: attrs))
            case "emph":
                inner.italic = true
                appendInlines(of: c, style: inner, into: out)
            case "strong":
                inner.bold = true
                appendInlines(of: c, style: inner, into: out)
            case "strikethrough":
                inner.strike = true
                appendInlines(of: c, style: inner, into: out)
            case "link":
                if let url = cmark_node_get_url(c).flatMap({ URL(string: String(cString: $0)) }) { inner.link = url }
                appendInlines(of: c, style: inner, into: out)
            default:
                appendInlines(of: c, style: style, into: out)
            }
            child = cmark_node_next(c)
        }
    }

    private func attributes(for style: InlineStyle) -> [NSAttributedString.Key: Any] {
        var weight = style.baseWeight
        if style.bold { weight = style.baseWeight == .regular ? .semibold : .bold }
        var font: UIFont = style.mono
            ? .monospacedSystemFont(ofSize: max(style.size - 1, 1), weight: weight)
            : .systemFont(ofSize: style.size, weight: weight)
        if style.italic, let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) {
            font = UIFont(descriptor: descriptor, size: font.pointSize)
        }
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: style.color]
        if style.mono { attrs[.backgroundColor] = UIColor.label.withAlphaComponent(0.08) }
        if style.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let link = style.link {
            attrs[.link] = link
            attrs[.foregroundColor] = accent
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attrs
    }

    /// `markerIndent` non-nil marks a list item's first line: the marker sits at `markerIndent`, the text (after a tab) at the
    /// context's indent, and wrapped lines return to the text edge.
    private func paragraphStyle(
        _ ctx: BlockContext, before: CGFloat, after: CGFloat, markerIndent: CGFloat? = nil
    ) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = ChatMetrics.bodyLineSpacing
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.headIndent = ctx.indent
        style.firstLineHeadIndent = markerIndent ?? ctx.indent
        if markerIndent != nil {
            style.tabStops = [NSTextTab(textAlignment: .left, location: ctx.indent)]
            style.defaultTabInterval = Self.markerWidth
        }
        return style
    }

    // MARK: cmark helpers

    private static func type(_ node: CmarkNode) -> String {
        guard let name = cmark_node_get_type_string(node) else { return "" }
        return String(cString: name)
    }

    private static func literal(_ node: CmarkNode) -> String {
        cmark_node_get_literal(node).map { String(cString: $0) } ?? ""
    }

    private static func fenceInfo(_ node: CmarkNode) -> String? {
        guard let raw = cmark_node_get_fence_info(node) else { return nil }
        let word = String(cString: raw).split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "{" }).first
        guard let word, !word.isEmpty else { return nil }
        return word.lowercased()
    }

    private static func containsImage(_ node: CmarkNode) -> Bool {
        guard let iterator = cmark_iter_new(node) else { return false }
        defer { cmark_iter_free(iterator) }
        while true {
            let event = cmark_iter_next(iterator)
            if event == CMARK_EVENT_DONE { return false }
            if event == CMARK_EVENT_ENTER, let current = cmark_iter_get_node(iterator), type(current) == "image" {
                return true
            }
        }
    }
}
#endif
