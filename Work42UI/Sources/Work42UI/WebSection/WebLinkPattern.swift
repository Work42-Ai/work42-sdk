// WebLinkPattern.swift — URL patterns the in-page link interceptor tests hrefs against.
//
// Widgets claim URLs with ICU regular expressions (NSRegularExpression), the dialect Open Link resolves
// with. The interceptor runs inside the page, where a link is tested with a JavaScript RegExp. The two
// dialects agree on everything widgets realistically write except inline flag groups: Jira and GitHub
// claim with `(?i)^https?://…`, which JavaScript rejects. `WebLinkPatternTranslator` moves a leading
// `(?i)`-style group into JS flags and returns nil for anything JavaScript cannot express, so an
// untranslatable claim is simply not intercepted in-page rather than matching something it shouldn't.

import Foundation

/// A pattern in the form `new RegExp(source, flags)` accepts.
public struct WebLinkPattern: Equatable, Sendable {
    public let source: String
    public let flags: String

    public init(source: String, flags: String) {
        self.source = source
        self.flags = flags
    }
}

public enum WebLinkPatternTranslator {

    /// The JavaScript form of an ICU `pattern`, or nil when JavaScript can't express it: inline flag
    /// groups other than a leading `(?i)` / `(?s)` / `(?m)` combination (e.g. `(?x)`, `(?-i)`, a group
    /// in the middle), the ICU-only escapes `\A \z \Z \G \h \H \R \X \Q`, and possessive quantifiers.
    public static func javascript(fromICU pattern: String) -> WebLinkPattern? {
        var chars = Array(pattern)
        var flags = ""

        // A leading inline flag group made only of i / s / m becomes JS flags.
        if chars.count > 2, chars[0] == "(", chars[1] == "?",
           let close = chars.firstIndex(of: ")") {
            let inner = chars[2..<close]
            if !inner.isEmpty, inner.allSatisfy({ "ism".contains($0) }) {
                for flag in inner where !flags.contains(flag) { flags.append(flag) }
                chars.removeSubrange(0...close)
            }
        }

        let icuOnlyEscapes: Set<Character> = ["A", "z", "Z", "G", "h", "H", "R", "X", "Q"]
        let quantifiers: Set<Character> = ["+", "*", "?", "}"]
        var inClass = false
        var previousIsQuantifier = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                guard i + 1 < chars.count, !icuOnlyEscapes.contains(chars[i + 1]) else { return nil }
                previousIsQuantifier = false
                i += 2
                continue
            }
            if inClass {
                if c == "]" { inClass = false }
                i += 1
                continue
            }
            switch c {
            case "[":
                inClass = true
                previousIsQuantifier = false
            case "(":
                if i + 1 < chars.count, chars[i + 1] == "?" {
                    // `(?:` `(?=` `(?!` `(?<=` `(?<!` `(?<name>` are shared; `(?i)` `(?-i:` `(?x)` are not.
                    var j = i + 2
                    var letters = 0
                    while j < chars.count, chars[j].isLetter || chars[j] == "-" { letters += 1; j += 1 }
                    if letters > 0, j < chars.count, chars[j] == ")" || chars[j] == ":" { return nil }
                }
                previousIsQuantifier = false
            case "+":
                if previousIsQuantifier { return nil }   // possessive: a++  a*+  a?+  a{2}+
                previousIsQuantifier = true
            default:
                previousIsQuantifier = quantifiers.contains(c)
            }
            i += 1
        }
        return WebLinkPattern(source: String(chars), flags: flags)
    }
}
