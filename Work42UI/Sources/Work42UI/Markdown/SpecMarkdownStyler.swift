// SpecMarkdownStyler.swift - Pure markdown line/span classifier for
// the commentable spec editor (`SpecCommentableEditor`).
//
// WHY THIS EXISTS
// ===============
// The spec widget is a `CodeEditor` (CodeEditorView package) mounted in
// plain-text mode so the drag-select → "Comment" gesture can pin a
// review comment to a 1-based `startLine`/`endLine` range. We want the
// spec to READ as a structured document (heading hierarchy, bold,
// italic, inline code, fenced code) WITHOUT touching the buffer text
// or the line numbering the comment anchors depend on.
//
// This type is the brains of that: a PURE, dependency-free function
// that takes the raw spec text and returns, per 1-based line:
//
//   - the heading level (1...4) if the line is an ATX heading, else nil
//   - whether the line lives inside a fenced ``` code region
//   - the inline emphasis spans (bold / italic / inline-code) with
//     UTF-16 offsets relative to the START of the line
//
// It deliberately has NO dependency on CodeEditorView, AppKit, or any
// UI type so it can be unit-tested in isolation (see Work42UITests).
// The editor layer (`SpecCommentableEditor`) is responsible for
// turning this classification into actual on-screen styling; how far
// that styling can go is a CodeEditorView limitation, documented at
// the call site — the classifier itself is exact and complete.
//
// LINE MODEL
// ==========
// Line numbering is 1-based and lines are split on `\n` (LF), matching
// `SelectionRangeUtils.lineRange(for:in:)` exactly. This is critical:
// the styler must agree with the comment-anchor line math down to the
// number, or styling could appear to drift relative to a pinned
// comment. Inline-span offsets are UTF-16 code-unit offsets from the
// first character of the line, because that is the index space
// `NSRange` / TextKit uses.

import Foundation

/// The kind of inline emphasis a span carries.
public enum SpecInlineKind: Equatable, Sendable {
    /// `**bold**` (also `__bold__`).
    case bold
    /// `*italic*` (also `_italic_`).
    case italic
    /// `` `inline code` ``.
    case code
}

/// An inline emphasis span on a single line, addressed in UTF-16
/// code units relative to the START of that line. `range` covers the
/// FULL markdown construct including its delimiters (e.g. the `**` on
/// each side of a bold run) — the editor styles the whole run; we do
/// not strip delimiters because the buffer text must stay intact.
public struct SpecInlineSpan: Equatable, Sendable {
    public let kind: SpecInlineKind
    /// UTF-16 offset of the first delimiter character within the line.
    public let start: Int
    /// UTF-16 length of the whole construct (delimiters included).
    public let length: Int

    public init(kind: SpecInlineKind, start: Int, length: Int) {
        self.kind = kind
        self.start = start
        self.length = length
    }
}

/// The classification of a single 1-based line of the spec.
public struct SpecLineStyle: Equatable, Sendable {
    /// 1-based line number, matching `SelectionRangeUtils`.
    public let line: Int
    /// ATX heading level 1...4 if this is a heading line, else nil.
    /// Levels deeper than 4 (`#####`+) are clamped to 4 to match the
    /// `.work42` MarkdownUI theme, which only styles h1...h4.
    public let headingLevel: Int?
    /// True when the line sits inside a fenced ``` code region
    /// (including the fence lines themselves).
    public let isFencedCode: Bool
    /// Inline emphasis spans on this line, in ascending `start` order.
    /// Always empty for heading and fenced-code lines (their whole
    /// line is styled as a unit, so inline marks inside them are not
    /// separately classified).
    public let inlineSpans: [SpecInlineSpan]

    public init(line: Int,
                headingLevel: Int?,
                isFencedCode: Bool,
                inlineSpans: [SpecInlineSpan]) {
        self.line = line
        self.headingLevel = headingLevel
        self.isFencedCode = isFencedCode
        self.inlineSpans = inlineSpans
    }
}

/// Pure markdown classifier for the spec editor. Stateless — the
/// single entry point `classify(_:)` is a deterministic function of
/// its input text.
public enum SpecMarkdownStyler {

    /// Highest heading level we style. Mirrors `.work42`'s h1...h4.
    public static let maxHeadingLevel = 4

    /// Classify every line of `text`.
    ///
    /// - Parameter text: the full spec buffer.
    /// - Returns: one `SpecLineStyle` per line, in line order. A
    ///   document of N lines (N-1 `\n` separators) yields N entries,
    ///   1-based, matching `SelectionRangeUtils.lineRange`.
    public static func classify(_ text: String) -> [SpecLineStyle] {
        // Split on LF keeping empty lines so line numbers line up with
        // the comment-anchor model. A trailing `\n` yields a final
        // empty line, which is exactly how the editor counts lines.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        var result: [SpecLineStyle] = []
        result.reserveCapacity(lines.count)

        var insideFence = false

        for (index, raw) in lines.enumerated() {
            let lineNumber = index + 1
            let line = String(raw)

            if isFenceDelimiter(line) {
                // The fence line itself is part of the code region; it
                // toggles the state for SUBSEQUENT lines.
                result.append(SpecLineStyle(line: lineNumber,
                                            headingLevel: nil,
                                            isFencedCode: true,
                                            inlineSpans: []))
                insideFence.toggle()
                continue
            }

            if insideFence {
                result.append(SpecLineStyle(line: lineNumber,
                                            headingLevel: nil,
                                            isFencedCode: true,
                                            inlineSpans: []))
                continue
            }

            if let level = headingLevel(of: line) {
                result.append(SpecLineStyle(line: lineNumber,
                                            headingLevel: level,
                                            isFencedCode: false,
                                            inlineSpans: []))
                continue
            }

            result.append(SpecLineStyle(line: lineNumber,
                                        headingLevel: nil,
                                        isFencedCode: false,
                                        inlineSpans: inlineSpans(in: line)))
        }

        return result
    }

    // MARK: - Heading detection

    /// ATX heading level for a line, or nil. Requires the leading
    /// `#`...`####` to be followed by a space (CommonMark rule), so a
    /// bare `#tag` or `#!shebang` is NOT treated as a heading. Levels
    /// beyond 4 clamp to 4. Up to three leading spaces are allowed
    /// (CommonMark) before the run of `#`.
    static func headingLevel(of line: String) -> Int? {
        var scalars = Substring(line)
        // Allow up to 3 leading spaces.
        var leadingSpaces = 0
        while let first = scalars.first, first == " ", leadingSpaces < 3 {
            scalars = scalars.dropFirst()
            leadingSpaces += 1
        }
        var hashes = 0
        while let first = scalars.first, first == "#" {
            scalars = scalars.dropFirst()
            hashes += 1
        }
        guard hashes >= 1 else { return nil }
        // A heading marker must be followed by a space or be the whole
        // line (`#` alone). `#foo` is not a heading.
        if let next = scalars.first, next != " " { return nil }
        return min(hashes, maxHeadingLevel)
    }

    // MARK: - Fenced code detection

    /// True for a ``` (or longer) fence delimiter, optionally indented
    /// up to three spaces and optionally carrying an info string
    /// (e.g. ```` ```swift ````). We intentionally treat both opening
    /// and closing fences identically — the toggle in `classify`
    /// pairs them.
    static func isFenceDelimiter(_ line: String) -> Bool {
        var s = Substring(line)
        var leading = 0
        while let first = s.first, first == " ", leading < 3 {
            s = s.dropFirst()
            leading += 1
        }
        var ticks = 0
        while let first = s.first, first == "`" {
            s = s.dropFirst()
            ticks += 1
        }
        return ticks >= 3
    }

    // MARK: - Inline spans

    /// Find bold / italic / inline-code spans on a single line. Offsets
    /// are UTF-16 code units from the line start. Scanning is
    /// left-to-right and non-overlapping: an inline-code span wins over
    /// emphasis inside it (matching CommonMark precedence where code
    /// spans are recognised first), and `**` is matched before `*` so a
    /// bold run isn't mis-read as two italics.
    static func inlineSpans(in line: String) -> [SpecInlineSpan] {
        let units = Array(line.utf16)
        var spans: [SpecInlineSpan] = []
        var i = 0
        let n = units.count

        func unit(_ idx: Int) -> UInt16? { idx < n ? units[idx] : nil }

        let backtick: UInt16 = 0x60   // `
        let asterisk: UInt16 = 0x2A   // *
        let underscore: UInt16 = 0x5F // _

        while i < n {
            let c = units[i]

            // Inline code: `...` (single backtick runs only — the spec
            // editor doesn't need multi-backtick code spans).
            if c == backtick {
                if let close = indexOf(backtick, in: units, from: i + 1) {
                    spans.append(SpecInlineSpan(kind: .code,
                                                start: i,
                                                length: close - i + 1))
                    i = close + 1
                    continue
                }
                // Unterminated — treat as plain text.
                i += 1
                continue
            }

            // Bold: ** ... ** or __ ... __ (check the doubled marker
            // BEFORE the single-marker italic case).
            if (c == asterisk || c == underscore), unit(i + 1) == c {
                let marker = c
                if let close = indexOfDouble(marker, in: units, from: i + 2) {
                    spans.append(SpecInlineSpan(kind: .bold,
                                                start: i,
                                                length: close + 2 - i))
                    i = close + 2
                    continue
                }
                // Fall through: a lone `**` with no close is plain.
            }

            // Italic: * ... * or _ ... _ (single marker, non-empty,
            // not immediately doubled).
            if c == asterisk || c == underscore {
                let marker = c
                if unit(i + 1) != marker, let close = indexOfSingle(marker, in: units, from: i + 1) {
                    spans.append(SpecInlineSpan(kind: .italic,
                                                start: i,
                                                length: close - i + 1))
                    i = close + 1
                    continue
                }
            }

            i += 1
        }

        return spans
    }

    /// First index of `target` at or after `from`.
    private static func indexOf(_ target: UInt16, in units: [UInt16], from: Int) -> Int? {
        var j = from
        while j < units.count {
            if units[j] == target { return j }
            j += 1
        }
        return nil
    }

    /// First index of a single `target` that is NOT part of a doubled
    /// run, at or after `from`. Used to close an italic run. Skips a
    /// doubled marker (which belongs to bold).
    private static func indexOfSingle(_ target: UInt16, in units: [UInt16], from: Int) -> Int? {
        var j = from
        while j < units.count {
            if units[j] == target {
                // A doubled marker isn't a single-italic close.
                if j + 1 < units.count, units[j + 1] == target {
                    j += 2
                    continue
                }
                return j
            }
            j += 1
        }
        return nil
    }

    /// First index of a doubled `target` (the first of the pair), at or
    /// after `from`. Used to close a bold run.
    private static func indexOfDouble(_ target: UInt16, in units: [UInt16], from: Int) -> Int? {
        var j = from
        while j + 1 < units.count {
            if units[j] == target, units[j + 1] == target { return j }
            j += 1
        }
        return nil
    }
}
