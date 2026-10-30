// Work42SelectableMarkdown.swift - Markdown a user can select across paragraphs.
//
// MarkdownUI draws one SwiftUI `Text` per block, and SwiftUI cannot select across separate `Text` views, so a drag
// in a chat reply never covered more than one paragraph. This file is the host-app alternative for settled chat
// replies:
//
//   * `Work42MarkdownSegments.split` parses markdown with cmark-gfm (the parser the Markdown preview already uses)
//     and returns a short list of segments: ONE `NSAttributedString` for each run of prose (paragraphs, headings,
//     lists, quotes, rules, tables, inline marks), the fenced code blocks apart (the host draws them as cards), and
//     the blocks it does not style natively (images, raw HTML) as their markdown source, which the host draws with
//     `Work42MarkdownText` as before. Nothing is ever dropped. A table is a real text table inside the prose run
//     (`NSTextTable`), so a drag selects across its cells and rows and on into the prose around it (WOR-478).
//   * `Work42SelectableProse` shows one prose segment in a read-only `NSTextView`, so a drag selects across all of it.
//   * `Work42MarkdownSegmentCache` keeps the parsed segments so a row that scrolls back into view does not re-parse.
//
// All of it is `@_spi(Work42Host)`: plugins render prose with `Work42MarkdownText` and never see these types.

import AppKit
import SwiftUI
internal import cmark_gfm
internal import cmark_gfm_extensions

// MARK: - Segments

@_spi(Work42Host)
public enum Work42MarkdownSegment: Equatable {
    /// A run of prose, ready for `Work42SelectableProse`.
    case prose(NSAttributedString)
    /// A fenced or indented code block: the lower-cased first word of the info string (nil when untagged) and the
    /// code without its trailing newline.
    case code(language: String?, code: String)
    /// A block rendered by `Work42MarkdownText` (an image, raw HTML): its markdown source.
    case markdown(String)
}

@_spi(Work42Host)
public enum Work42MarkdownSegments {

    private static let extensionNames = ["autolink", "strikethrough", "tagfilter", "tasklist", "table"]

    /// Splits `markdown` into segments. Prose is styled for `bodyFontSize` the way `MarkdownUI.Theme.work42` styles it.
    public static func split(_ markdown: String, bodyFontSize: CGFloat) -> [Work42MarkdownSegment] {
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

        let builder = ProseBuilder(markdown: markdown, bodySize: bodyFontSize)
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

// MARK: - Building

private typealias CmarkNode = UnsafeMutablePointer<cmark_node>

private struct InlineStyle {
    var bold = false
    var italic = false
    var mono = false
    var strike = false
    var link: URL?
    var size: CGFloat
    var baseWeight: NSFont.Weight = .regular
    var color: NSColor = .labelColor
}

private struct BlockContext {
    /// Left edge of this block's text.
    var indent: CGFloat = 0
    var color: NSColor = .labelColor
    var textBlocks: [NSTextBlock] = []
    var spacingAfter: CGFloat = ChatMetrics.paragraphSpacing
}

private final class ProseBuilder {
    private let lines: [Substring]
    private let bodySize: CGFloat
    private var segments: [Work42MarkdownSegment] = []
    private let current = NSMutableAttributedString()
    private let accent = NSColor(DT.systemAccent)
    private static let markerWidth: CGFloat = 22

    init(markdown: String, bodySize: CGFloat) {
        self.lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        self.bodySize = bodySize
    }

    // MARK: Top level

    func appendTopLevel(_ node: CmarkNode) {
        switch Self.type(node) {
        case "code_block":
            flush()
            let info = Self.fenceInfo(node)
            var code = Self.literal(node)
            while code.hasSuffix("\n") { code.removeLast() }
            segments.append(.code(language: info, code: code))
        case "table":
            appendTable(node)
        case "html_block", "footnote_definition":
            flush()
            appendSource(of: node)
        default:
            if Self.containsImage(node) {
                flush()
                appendSource(of: node)
            } else {
                appendBlock(node, BlockContext(color: .labelColor), marker: nil, markerIndent: 0)
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

    // MARK: Tables

    /// A GFM table as a text table in the current prose run: a bordered cell per paragraph, the header row semibold.
    /// Cells hold their inline marks (code, links, emphasis). The run goes on after the table with a normal gap.
    private func appendTable(_ node: CmarkNode) {
        var rows: [[CmarkNode]] = []
        var row = cmark_node_first_child(node)
        while let r = row {
            var cells: [CmarkNode] = []
            var cell = cmark_node_first_child(r)
            while let c = cell { cells.append(c); cell = cmark_node_next(c) }
            rows.append(cells)
            row = cmark_node_next(r)
        }
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else { return }

        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false

        let border = NSColor.labelColor.withAlphaComponent(0.18)
        for (r, cells) in rows.enumerated() {
            for c in 0..<columns {
                let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setBorderColor(border)
                block.setWidth(6, type: .absoluteValueType, for: .padding, edge: .minY)
                block.setWidth(6, type: .absoluteValueType, for: .padding, edge: .maxY)
                block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
                block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .maxX)
                if r == 0 { block.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06) }

                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                style.lineSpacing = 2
                let inline = InlineStyle(size: bodySize, baseWeight: r == 0 ? .semibold : .regular)
                let piece = NSMutableAttributedString()
                if c < cells.count { appendInlines(of: cells[c], style: inline, into: piece) }
                if piece.length == 0 { piece.append(NSAttributedString(string: " ", attributes: attributes(for: inline))) }
                piece.append(NSAttributedString(string: "\n", attributes: attributes(for: inline)))
                piece.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: piece.length))
                current.append(piece)
            }
        }
        // The gap after the table: a thin empty paragraph, outside the table.
        let gap = NSMutableParagraphStyle()
        gap.paragraphSpacing = ChatMetrics.paragraphSpacing - 2
        current.append(NSAttributedString(string: "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 2), .paragraphStyle: gap,
        ]))
    }

    // MARK: Blocks

    /// Appends `node` (a block) to the current prose run. `marker` is the list marker to put before its first line.
    private func appendBlock(_ node: CmarkNode, _ ctx: BlockContext, marker: String?, markerIndent: CGFloat) {
        switch Self.type(node) {
        case "paragraph":
            appendText(of: node, ctx: ctx, size: bodySize, weight: .regular, before: 0, after: ctx.spacingAfter,
                       marker: marker, markerIndent: markerIndent)
        case "heading":
            let level = Int(cmark_node_get_heading_level(node))
            let (size, weight, before, after): (CGFloat, NSFont.Weight, CGFloat, CGFloat) = {
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
            var inner = ctx
            let block = Self.quoteBlock(accent: accent)
            inner.textBlocks.append(block)
            inner.color = .secondaryLabelColor
            var first = true
            var child = cmark_node_first_child(node)
            while let c = child {
                appendBlock(c, inner, marker: first ? marker : nil, markerIndent: markerIndent)
                first = false
                child = cmark_node_next(c)
            }
        case "thematic_break":
            let rule = NSTextBlock()
            rule.setWidth(1, type: .absoluteValueType, for: .border, edge: .minY)
            rule.setBorderColor(NSColor.labelColor.withAlphaComponent(0.10))
            let style = paragraphStyle(ctx, before: 12, after: 12)
            style.textBlocks = ctx.textBlocks + [rule]
            current.append(NSAttributedString(string: " \n", attributes: [
                .font: NSFont.systemFont(ofSize: 2), .paragraphStyle: style,
            ]))
        case "code_block":
            // A code block inside a list item or quote stays inline as monospaced text (top-level ones become cards).
            var code = Self.literal(node)
            while code.hasSuffix("\n") { code.removeLast() }
            let style = paragraphStyle(ctx, before: 0, after: ctx.spacingAfter)
            style.lineSpacing = 2
            current.append(NSAttributedString(string: code + "\n", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: bodySize - 2, weight: .regular),
                .foregroundColor: ctx.color,
                .backgroundColor: NSColor.labelColor.withAlphaComponent(0.06),
                .paragraphStyle: style,
            ]))
        default:
            // Tables, raw HTML and anything else inside a list item or quote: keep the source text, never drop it.
            let start = max(Int(cmark_node_get_start_line(node)), 1)
            let end = min(max(Int(cmark_node_get_end_line(node)), start), lines.count)
            if start <= end {
                let source = lines[(start - 1)..<end].joined(separator: "\n")
                current.append(NSAttributedString(string: source + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: bodySize), .foregroundColor: ctx.color,
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
                marker = cmark_gfm_extensions_get_tasklist_item_checked(item) ? "☑" : "☐"
            } else {
                marker = ordered ? "\(number)." : "•"
            }
            number += 1
            var first = true
            var content = cmark_node_first_child(item)
            if content == nil {
                // An empty item still shows its marker.
                current.append(NSAttributedString(string: marker + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: bodySize), .foregroundColor: ctx.color,
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
        of node: CmarkNode, ctx: BlockContext, size: CGFloat, weight: NSFont.Weight,
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
            case "text":
                out.append(NSAttributedString(string: Self.literal(c), attributes: attributes(for: style)))
            case "softbreak":
                out.append(NSAttributedString(string: " ", attributes: attributes(for: style)))
            case "linebreak":
                out.append(NSAttributedString(string: "\u{2028}", attributes: attributes(for: style)))
            case "code":
                inner.mono = true
                out.append(NSAttributedString(string: Self.literal(c), attributes: attributes(for: inner)))
            case "html_inline":
                out.append(NSAttributedString(string: Self.literal(c), attributes: attributes(for: style)))
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
        var font: NSFont = style.mono
            ? .monospacedSystemFont(ofSize: max(style.size - 1, 1), weight: weight)
            : .systemFont(ofSize: style.size, weight: weight)
        if style.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: style.color]
        // A little letter spacing for an airier reply (WOR-510); inline code keeps its own spacing.
        if !style.mono { attrs[.kern] = ChatMetrics.bodyTracking }
        if style.mono { attrs[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.08) }
        if style.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let link = style.link {
            attrs[.link] = link
            attrs[.foregroundColor] = accent
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attrs
    }

    /// `markerIndent` non-nil marks a list item's first line: the marker sits at `markerIndent`, the text (after a
    /// tab) at the context's indent, and wrapped lines return to the text edge.
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
        style.textBlocks = ctx.textBlocks
        return style
    }

    private static func quoteBlock(accent: NSColor) -> NSTextBlock {
        let block = NSTextBlock()
        block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
        block.setBorderColor(accent.withAlphaComponent(0.5), for: .minX)
        block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(4, type: .absoluteValueType, for: .padding, edge: .minY)
        block.setWidth(4, type: .absoluteValueType, for: .padding, edge: .maxY)
        return block
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
        let info = String(cString: raw)
        let word = info.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "{" }).first
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

// MARK: - Cache

/// Parsed segments by message id + text + size, so a row that scrolls back into view does not re-parse.
@_spi(Work42Host)
public final class Work42MarkdownSegmentCache {
    public static let shared = Work42MarkdownSegmentCache(capacity: 512)

    private struct Key: Hashable {
        let id: String
        let textHash: Int
        let size: CGFloat
    }

    private let capacity: Int
    private var entries: [Key: [Work42MarkdownSegment]] = [:]
    private var order: [Key] = []

    public init(capacity: Int = 512) { self.capacity = max(capacity, 1) }

    /// `prepare`, when given, rewrites the markdown before it is split (the chat links bare file paths with it). It
    /// runs only on a cache miss, so a row that scrolls back into view pays for neither the rewrite nor the parse.
    public func segments(
        id: String, text: String, bodyFontSize: CGFloat, prepare: ((String) -> String)? = nil
    ) -> [Work42MarkdownSegment] {
        let key = Key(id: id, textHash: text.hashValue, size: bodyFontSize)
        if let hit = entries[key] {
            if let index = order.lastIndex(of: key) { order.remove(at: index); order.append(key) }
            return hit
        }
        let parsed = Work42MarkdownSegments.split(prepare?(text) ?? text, bodyFontSize: bodyFontSize)
        entries[key] = parsed
        order.append(key)
        while order.count > capacity { entries[order.removeFirst()] = nil }
        return parsed
    }

    /// Number of cached documents (for tests).
    public var count: Int { entries.count }
}

// MARK: - Selectable prose view

// MARK: - Copy text

/// The plain text of a selection in a prose run. Prose copies as it reads; table cells copy as a spreadsheet would:
/// a tab between the cells of a row and a newline between rows (WOR-478).
@_spi(Work42Host)
public enum ProseCopyText {
    public static func plainText(of text: NSAttributedString, range: NSRange) -> String {
        let full = text.string as NSString
        let range = NSIntersectionRange(range, NSRange(location: 0, length: full.length))
        guard range.length > 0 else { return "" }
        var out = ""
        var lastCell: (table: ObjectIdentifier, row: Int)?
        var location = range.location
        while location < NSMaxRange(range) {
            let paragraph = full.paragraphRange(for: NSRange(location: location, length: 0))
            let part = NSIntersectionRange(paragraph, range)
            location = NSMaxRange(paragraph)
            guard part.length > 0 else { continue }
            var piece = full.substring(with: part)
            let style = text.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
            if let cell = style?.textBlocks.last as? NSTextTableBlock {
                if piece.hasSuffix("\n") { piece.removeLast() }
                let key = ObjectIdentifier(cell.table)
                if let last = lastCell {
                    out += (last.table == key && last.row == cell.startingRow) ? "\t" : "\n"
                }
                out += piece
                lastCell = (key, cell.startingRow)
            } else {
                if lastCell != nil { out += "\n"; lastCell = nil }
                out += piece
            }
        }
        return out
    }
}

/// One run of prose in a read-only text view: a drag selects across all of it, ⌘C copies it.
@_spi(Work42Host)
public struct Work42SelectableProse: NSViewRepresentable {
    private let text: NSAttributedString
    private let onOpenLink: ((URL) -> Void)?
    private let onSelectionChange: ((String, CGRect) -> Void)?

    /// - Parameters:
    ///   - onOpenLink: called for a clicked link; with nil the system opens it.
    ///   - onSelectionChange: the selected text and the rect of its first line in this view's top-left coordinates;
    ///     `("", .zero)` when the selection is cleared.
    public init(
        _ text: NSAttributedString,
        onOpenLink: ((URL) -> Void)? = nil,
        onSelectionChange: ((String, CGRect) -> Void)? = nil
    ) {
        self.text = text
        self.onOpenLink = onOpenLink
        self.onSelectionChange = onSelectionChange
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> SelectableProseTextView {
        let view = SelectableProseTextView()
        view.delegate = context.coordinator
        context.coordinator.view = view
        configure(view, context: context)
        view.setProse(text)
        return view
    }

    public func updateNSView(_ view: SelectableProseTextView, context: Context) {
        configure(view, context: context)
        view.setProse(text)
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView view: SelectableProseTextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 600
        return CGSize(width: width, height: view.height(forWidth: width))
    }

    private func configure(_ view: SelectableProseTextView, context: Context) {
        context.coordinator.onOpenLink = onOpenLink
        context.coordinator.onSelectionChange = onSelectionChange
        view.linkOpener = onOpenLink
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        weak var view: SelectableProseTextView?
        var onOpenLink: ((URL) -> Void)?
        var onSelectionChange: ((String, CGRect) -> Void)?

        public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url else { return false }
            if let onOpenLink { onOpenLink(url) } else { NSWorkspace.shared.open(url) }
            return true
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard let view, let report = onSelectionChange else { return }
            let selection = view.selectedFirstLine()
            report(selection.text, selection.rect)
        }
    }
}

/// The `NSTextView` behind `Work42SelectableProse`: TextKit 1 (so quote bars and rules draw), no scrolling, no insets,
/// sized by the width SwiftUI proposes.
@_spi(Work42Host)
public final class SelectableProseTextView: NSTextView {
    private var lastWidth: CGFloat = -1
    private var lastHeight: CGFloat = 0
    private var content = NSAttributedString()
    /// What "Open Link" in the context menu does; nil falls back to the system.
    var linkOpener: ((URL) -> Void)?

    public init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 20), textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        allowsUndo = false
        isAutomaticLinkDetectionEnabled = false
        let accent = NSColor(DT.systemAccent)
        selectedTextAttributes = [.backgroundColor: accent.withAlphaComponent(0.28)]
        linkTextAttributes = [
            .foregroundColor: accent, .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setProse(_ text: NSAttributedString) {
        guard !content.isEqual(to: text) else { return }
        content = text
        textStorage?.setAttributedString(text)
        lastWidth = -1
        invalidateIntrinsicContentSize()
    }

    /// Height of the content laid out `width` points wide; the last answer is reused for the same width.
    func height(forWidth width: CGFloat) -> CGFloat {
        if width == lastWidth { return lastHeight }
        guard let container = textContainer, let layout = layoutManager else { return 0 }
        // A text view that is not horizontally resizable keeps its container as wide as its own frame, so the
        // frame has to take the width too (SwiftUI sets the same width right after measuring).
        if frame.width != width { setFrameSize(NSSize(width: width, height: frame.height)) }
        container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        lastWidth = width
        lastHeight = ceil(layout.usedRect(for: container).height)
        return lastHeight
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let container = textContainer, newSize.width > 0, container.size.width != newSize.width {
            container.size = NSSize(width: newSize.width, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    /// The link under `point` (in this view's coordinates), if the point is on linked text.
    func link(at point: NSPoint) -> URL? {
        guard let layout = layoutManager, let container = textContainer, content.length > 0 else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: local, in: container, fractionOfDistanceThroughGlyph: nil)
        guard layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local) else {
            return nil
        }
        let index = layout.characterIndexForGlyph(at: glyph)
        guard index < content.length else { return nil }
        let value = content.attribute(.link, at: index, effectiveRange: nil)
        return (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
    }

    /// ⌘C: the selection as rich text, with the plain text laid out for pasting (tab-separated table rows).
    public override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0, range.location + range.length <= content.length else { super.copy(sender); return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([content.attributedSubstring(from: range)])
        pasteboard.setString(ProseCopyText.plainText(of: content, range: range), forType: .string)
    }

    /// The standard text menu, with "Open Link" and "Open Externally" first when the click is on a link.
    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let url = link(at: convert(event.locationInWindow, from: nil)) else { return menu }
        let open = NSMenuItem(title: "Open Link", action: #selector(openLinkFromMenu(_:)), keyEquivalent: "")
        let external = NSMenuItem(title: "Open Externally", action: #selector(openLinkExternally(_:)), keyEquivalent: "")
        for item in [open, external] { item.target = self; item.representedObject = url }
        menu.insertItem(open, at: 0)
        menu.insertItem(external, at: 1)
        menu.insertItem(.separator(), at: 2)
        return menu
    }

    @objc private func openLinkFromMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        if let linkOpener { linkOpener(url) } else { NSWorkspace.shared.open(url) }
    }

    @objc private func openLinkExternally(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    /// The selected text and the rect of its first line, from the start of the selection to the end of that line.
    func selectedFirstLine() -> (text: String, rect: CGRect) {
        let range = selectedRange()
        guard range.length > 0, let layout = layoutManager, let container = textContainer,
              range.location + range.length <= content.length else { return ("", .zero) }
        let text = ProseCopyText.plainText(of: content, range: range)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return (text, .zero) }
        let first = layout.boundingRect(forGlyphRange: NSRange(location: glyphs.location, length: 1), in: container)
        let line = layout.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let origin = textContainerOrigin
        let rect = CGRect(x: first.minX, y: line.minY, width: max(line.maxX - first.minX, 1), height: line.height)
        return (text, rect.offsetBy(dx: origin.x, dy: origin.y))
    }
}
