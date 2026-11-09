// MarkdownInlineCodeStyle.swift - Lets a host draw chosen inline `code` spans of a reply its own way (WOR-723).
//
// The chat names a workflow stage in backticks ("Moved from `Planning` to `In-Progress`"). The host knows which strings are
// stages; this package knows nothing about stages. The host answers one question through the environment: "does this inline
// code string get a custom look?" and the selectable prose views (Work42SelectableMarkdown*.swift) apply the answer.
//
//   * The prose builders tag every inline code span with `.work42InlineCode` (its text) and draw it as a plain code chip.
//   * `Work42SelectableProse` asks the environment's styler about each tagged span (`MarkdownInlineCodeSpans.runs`, pure, so it
//     is testable) and, for the spans that get a style, tints them and puts the style's SF Symbol in front (`styled`).
//   * The symbol is an attachment tagged `.work42InlineCodeDecoration`; copying, and the selected text the comment tools
//     receive, leave decoration out (`plain`), so a stage copies as its plain name.
//
// A span the styler answers nil for keeps the plain code chip.

import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// How a host wants one inline code string drawn: an SF Symbol and a tint per appearance (`#rrggbb`).
public struct MarkdownInlineCodeStyle: Equatable, Sendable {
    public var icon: String?
    public var colorLight: String?
    public var colorDark: String?

    public init(icon: String? = nil, colorLight: String? = nil, colorDark: String? = nil) {
        self.icon = icon
        self.colorLight = colorLight
        self.colorDark = colorDark
    }

    /// The tint for an appearance: its own colour, else the other one's.
    func hex(dark: Bool) -> String? {
        let own = dark ? colorDark : colorLight
        let other = dark ? colorLight : colorDark
        return [own, other].compactMap { $0 }.first { !$0.isEmpty }
    }

    /// `#rrggbb` (the `#` is optional) as 0...1 components; nil for anything else.
    public static func rgb(hex: String) -> (red: Double, green: Double, blue: Double)? {
        var digits = Substring(hex)
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }
}

/// Maps the text of an inline code span to a custom look, or nil to keep the plain code chip. Equatable on `id` alone, so a
/// host that sets one on every refresh does not change the environment (and re-evaluate its rows) unless `id` changes: the
/// host makes `id` change exactly when its answers can.
public struct MarkdownInlineCodeStyler: Equatable, Sendable {
    public var id: String
    public var resolve: @MainActor @Sendable (String) -> MarkdownInlineCodeStyle?

    public init(id: String, resolve: @escaping @MainActor @Sendable (String) -> MarkdownInlineCodeStyle?) {
        self.id = id
        self.resolve = resolve
    }

    /// Answers nil for everything.
    public static let none = MarkdownInlineCodeStyler(id: "") { _ in nil }

    public static func == (lhs: MarkdownInlineCodeStyler, rhs: MarkdownInlineCodeStyler) -> Bool { lhs.id == rhs.id }
}

private struct MarkdownInlineCodeStylerKey: EnvironmentKey {
    static let defaultValue = MarkdownInlineCodeStyler.none
}

public extension EnvironmentValues {
    /// How inline code spans of a chat reply are drawn, when the host wants some its own way. The default answers nil.
    var markdownInlineCodeStyler: MarkdownInlineCodeStyler {
        get { self[MarkdownInlineCodeStylerKey.self] }
        set { self[MarkdownInlineCodeStylerKey.self] = newValue }
    }
}

extension NSAttributedString.Key {
    /// On an inline code span: its text. Set by the prose builders on every inline code span.
    static let work42InlineCode = NSAttributedString.Key("work42.inlineCode")
    /// On what `MarkdownInlineCodeSpans.styled` inserts (the icon and its space): never part of the text.
    static let work42InlineCodeDecoration = NSAttributedString.Key("work42.inlineCodeDecoration")
}

@_spi(Work42Host)
public enum MarkdownInlineCodeSpans {

    /// An inline code span the styler gave a style.
    public struct Run: Equatable {
        public var range: NSRange
        public var name: String
        public var style: MarkdownInlineCodeStyle
    }

    /// The tagged spans of `text` the styler answers a style for, in order. Spans it answers nil for are left out (they
    /// stay plain code chips).
    @MainActor
    public static func runs(
        in text: NSAttributedString, styler: @MainActor @Sendable (String) -> MarkdownInlineCodeStyle?
    ) -> [Run] {
        var found: [Run] = []
        text.enumerateAttribute(.work42InlineCode, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let name = value as? String, let style = styler(name) else { return }
            found.append(Run(range: range, name: name, style: style))
        }
        return found
    }

    /// Identifies what `styled` would draw, so a view re-applies only when it changed (re-setting a text view's text drops
    /// the selection).
    public static func signature(_ runs: [Run], dark: Bool) -> String {
        guard !runs.isEmpty else { return "" }
        return (dark ? "d" : "l") + runs.map { "\($0.range.location):\($0.range.length):\($0.style.icon ?? "-"):\($0.style.hex(dark: dark) ?? "-")" }
            .joined(separator: "|")
    }

    // MARK: Plain text

    /// The text of `range` without decoration: a stage copies as its name.
    public static func plain(_ text: NSAttributedString, in range: NSRange) -> String {
        let range = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
        guard range.length > 0 else { return "" }
        var out = ""
        text.enumerateAttribute(.work42InlineCodeDecoration, in: range) { value, part, _ in
            if value == nil { out += (text.string as NSString).substring(with: part) }
        }
        return out
    }

    /// `text` with the decoration taken out (for the rich copy).
    public static func withoutDecoration(_ text: NSAttributedString) -> NSAttributedString {
        var ranges: [NSRange] = []
        text.enumerateAttribute(.work42InlineCodeDecoration, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value != nil { ranges.append(range) }
        }
        guard !ranges.isEmpty else { return text }
        let out = NSMutableAttributedString(attributedString: text)
        for range in ranges.reversed() { out.deleteCharacters(in: range) }
        return out
    }

    public static func hasDecoration(_ text: NSAttributedString, in range: NSRange) -> Bool {
        let range = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
        guard range.length > 0 else { return false }
        var found = false
        text.enumerateAttribute(.work42InlineCodeDecoration, in: range) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    // MARK: Styling

    #if canImport(AppKit)
    private typealias PlatformColor = NSColor
    private typealias PlatformFont = NSFont
    private static var primaryTextColor: PlatformColor { .labelColor }
    #else
    private typealias PlatformColor = UIColor
    private typealias PlatformFont = UIFont
    private static var primaryTextColor: PlatformColor { .label }
    #endif

    /// `text` with each run tinted in its colour (semibold, on a soft tint of it) and its SF Symbol in front, as an
    /// attachment. Everything else is untouched.
    public static func styled(_ text: NSAttributedString, runs: [Run], dark: Bool) -> NSAttributedString {
        guard !runs.isEmpty else { return text }
        let out = NSMutableAttributedString(attributedString: text)
        // Back to front, so the earlier ranges stay valid while symbols are inserted.
        for run in runs.reversed() {
            guard NSMaxRange(run.range) <= out.length else { continue }
            let tint = run.style.hex(dark: dark).flatMap(color(hex:))
            let oldFont = out.attribute(.font, at: run.range.location, effectiveRange: nil) as? PlatformFont
            let font = PlatformFont.systemFont(ofSize: (oldFont?.pointSize ?? 15) + 1, weight: .semibold)
            out.addAttribute(.font, value: font, range: run.range)
            if let tint {
                out.addAttribute(.foregroundColor, value: tint, range: run.range)
                out.addAttribute(.backgroundColor, value: tint.withAlphaComponent(0.16), range: run.range)
            }
            guard let icon = run.style.icon, !icon.isEmpty,
                  let image = symbol(icon, pointSize: font.pointSize, color: tint ?? primaryTextColor) else { continue }
            var attributes = out.attributes(at: run.range.location, effectiveRange: nil)
            attributes[.work42InlineCode] = nil
            let attachment = NSTextAttachment()
            attachment.image = image
            let height = ceil(font.pointSize)
            let width = image.size.height > 0 ? image.size.width * height / image.size.height : height
            attachment.bounds = CGRect(x: 0, y: (font.capHeight - height) / 2, width: width, height: height)
            let decoration = NSMutableAttributedString(attachment: attachment)
            decoration.append(NSAttributedString(string: " "))
            decoration.addAttributes(attributes, range: NSRange(location: 0, length: decoration.length))
            decoration.addAttribute(
                .work42InlineCodeDecoration, value: true, range: NSRange(location: 0, length: decoration.length))
            out.insert(decoration, at: run.range.location)
        }
        return out
    }

    private static func color(hex: String) -> PlatformColor? {
        guard let c = MarkdownInlineCodeStyle.rgb(hex: hex) else { return nil }
        #if canImport(AppKit)
        return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
        #else
        return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1)
        #endif
    }

    private static func symbol(_ name: String, pointSize: CGFloat, color: PlatformColor) -> PlatformImage? {
        #if canImport(AppKit)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return base.withSymbolConfiguration(configuration)
        #else
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        return UIImage(systemName: name, withConfiguration: configuration)?
            .withTintColor(color, renderingMode: .alwaysOriginal)
        #endif
    }

    #if canImport(AppKit)
    private typealias PlatformImage = NSImage
    #else
    private typealias PlatformImage = UIImage
    #endif
}
