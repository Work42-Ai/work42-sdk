// SharedSelections.swift — everyone's highlight, shown to everyone in the session (WOR-773 §6).
//
// The sibling of `AnnotationRegistry`, at the same root and for the same reason: every surface that lets a person highlight text
// (to comment on it or dictate a comment) says so here too, so every widget shares its highlights without doing anything of its own.
// A highlight travels as what was highlighted, the quote with a little text before and after it, which finds the same words again in
// anyone's copy (at their width, their scroll, their device): the way web annotations are anchored, and the way a shared page does
// it (`SharedPageSelections`). The selectable primitives of this library report a person's highlight here and draw the others' with
// `PersonDart`; the app plugs in how highlights go to the others and come back (`connect`, `update`), and which widget a surface is
// in (`\.sharedSelectionPlace`, set by the widget's tile). While a person writes or dictates a comment on their highlight, their
// dart shows it (`activity`).

import Foundation
import SwiftUI

/// Where a highlight is: a session's widget (its layout id), and the thing inside it when the widget shows one of several (an
/// artifact's id). Two people see each other's highlights only in the same place.
public struct SharedSelectionPlace: Hashable, Sendable {
    public var session: String
    public var widget: String
    public var surface: String?

    public init(session: String, widget: String, surface: String? = nil) {
        self.session = session
        self.widget = widget
        self.surface = surface
    }

    /// The same widget, narrowed to one thing in it.
    public func surface(_ surface: String?) -> SharedSelectionPlace {
        SharedSelectionPlace(session: session, widget: widget, surface: surface)
    }
}

public extension EnvironmentValues {
    /// The widget a surface is in, set by the widget's tile; nil outside a session's widget (nothing is shared).
    @Entry var sharedSelectionPlace: SharedSelectionPlace? = nil
}

/// What a person is doing with their highlight, shown on their dart.
public enum SharedSelectionActivity: String, Codable, Sendable {
    /// Writing a comment on it (the note box is open).
    case typing
    /// Dictating a comment on it.
    case speaking
}

/// This person's highlight.
public struct SharedSelectionLocal: Equatable, Sendable {
    public var place: SharedSelectionPlace
    public var start: PageQuote
    /// For a long highlight, its last words: the highlight runs from `start` to here.
    public var end: PageQuote?
    /// Selected from the end back to the start: the person is at its start.
    public var backward: Bool

    public init(place: SharedSelectionPlace, start: PageQuote, end: PageQuote? = nil, backward: Bool = false) {
        self.place = place
        self.start = start
        self.end = end
        self.backward = backward
    }
}

/// Someone else's highlight, ready to draw.
public struct SharedSelectionRemote: Equatable, Sendable, Identifiable {
    /// Who: the same id while it is them.
    public var id: String
    public var name: String
    /// Their colour, 0…1.
    public var red: Double
    public var green: Double
    public var blue: Double
    public var place: SharedSelectionPlace
    public var start: PageQuote
    public var end: PageQuote?
    public var backward: Bool
    /// The person the reader follows: their new highlights are brought into view.
    public var followed: Bool
    public var activity: SharedSelectionActivity?

    public init(
        id: String, name: String, red: Double, green: Double, blue: Double, place: SharedSelectionPlace, start: PageQuote,
        end: PageQuote? = nil, backward: Bool = false, followed: Bool = false, activity: SharedSelectionActivity? = nil
    ) {
        self.id = id
        self.name = name
        self.red = red
        self.green = green
        self.blue = blue
        self.place = place
        self.start = start
        self.end = end
        self.backward = backward
        self.followed = followed
        self.activity = activity
    }

    public var cgColor: CGColor { CGColor(red: red, green: green, blue: blue, alpha: 1) }

    public func css(alpha: Double = 1) -> String {
        String(format: "rgba(%d, %d, %d, %.2f)", Int(red * 255), Int(green * 255), Int(blue * 255), alpha)
    }

    /// As a shared page draws it.
    public var page: SharedPageSelection {
        SharedPageSelection(
            name: name, color: css(), fill: css(alpha: 0.3), start: start, end: end, followed: followed, backward: backward,
            activity: activity)
    }
}

/// The one place highlights are shared through. Surfaces report this person's and observe the others'; the app connects a session
/// to its transport.
@MainActor
public final class SharedSelectionHub {
    public static let shared = SharedSelectionHub()

    /// A hub of its own: tests use one; the app uses `shared`.
    public init() {}

    // MARK: This person's highlight

    /// This person's highlight: one at a time, as a person highlights in one place at a time.
    public private(set) var local: SharedSelectionLocal?
    /// What they are doing with it.
    public private(set) var activity: SharedSelectionActivity?
    /// The surface that reported `local`: only it can clear it, so one surface clearing never takes another's highlight away.
    private weak var localOwner: AnyObject?

    /// A surface's highlight changed: `selection` is it now, nil when it was cleared.
    public func report(_ selection: SharedSelectionLocal?, from owner: AnyObject) {
        if let selection {
            guard selection != local || localOwner !== owner || clearWhenDone else { return }
            local = selection
            localOwner = owner
        } else {
            guard localOwner === owner, local != nil else { return }
            // Writing a comment takes the focus from the text (a page then says nothing is selected): the highlight being commented
            // on stays until the comment is done.
            if activity != nil {
                clearWhenDone = true
                return
            }
            local = nil
            localOwner = nil
        }
        clearWhenDone = false
        localChanged()
    }

    /// The highlight's surface cleared it while a comment on it was being written.
    private var clearWhenDone = false

    /// The person started or stopped writing or dictating a comment on their highlight.
    public func setActivity(_ activity: SharedSelectionActivity?) {
        guard activity != self.activity else { return }
        self.activity = activity
        if activity == nil, clearWhenDone {
            clearWhenDone = false
            local = nil
            localOwner = nil
        }
        if local != nil || activity == nil { localChanged() }
    }

    /// `activity` is over: nothing changes when another has taken its place (dictating after the note box closed).
    public func endActivity(_ activity: SharedSelectionActivity) {
        if self.activity == activity { setActivity(nil) }
    }

    private var connections: [String: (SharedSelectionLocal?, SharedSelectionActivity?) -> Void] = [:]

    /// The app's transport for `session`: it hears this person's highlight in that session (nil when there is none there) each time
    /// it or its activity changes, and once now.
    public func connect(session: String, _ send: @escaping (SharedSelectionLocal?, SharedSelectionActivity?) -> Void) {
        connections[session] = send
        send(local?.place.session == session ? local : nil, local?.place.session == session ? activity : nil)
    }

    public func disconnect(session: String) {
        connections[session] = nil
        remote[session] = nil
        remoteChanged()
    }

    /// The session the last report was sent for, so leaving it says so there.
    private var sentSession: String?

    private func localChanged() {
        let session = local?.place.session
        if let sentSession, sentSession != session { connections[sentSession]?(nil, nil) }
        sentSession = session
        if let session { connections[session]?(local, activity) }
    }

    // MARK: The others' highlights

    private var remote: [String: [SharedSelectionRemote]] = [:]
    private var observers: [ObjectIdentifier: (weak: Observer, handler: @MainActor () -> Void)] = [:]

    private final class Observer {
        weak var owner: AnyObject?
        init(_ owner: AnyObject) { self.owner = owner }
    }

    /// The others' highlights in `session` now, from the transport.
    public func update(_ selections: [SharedSelectionRemote], in session: String) {
        guard remote[session] != selections else { return }
        remote[session] = selections
        remoteChanged()
    }

    /// The others' highlights in `place`'s widget: those in the same thing inside it when `place` names one.
    public func remote(in place: SharedSelectionPlace) -> [SharedSelectionRemote] {
        (remote[place.session] ?? []).filter {
            $0.place.widget == place.widget && (place.surface == nil || $0.place.surface == place.surface)
        }
    }

    /// `handler` runs when the others' highlights change, for as long as `owner` lives (or until `stopObserving`).
    public func observe(_ owner: AnyObject, _ handler: @escaping @MainActor () -> Void) {
        observers[ObjectIdentifier(owner)] = (Observer(owner), handler)
    }

    public func stopObserving(_ owner: AnyObject) { observers[ObjectIdentifier(owner)] = nil }

    private func remoteChanged() {
        for (key, entry) in observers {
            if entry.weak.owner == nil { observers[key] = nil } else { entry.handler() }
        }
    }
}

// MARK: Quoting text

/// A highlight in a text as quotes, and quotes found in a text again, as the page script does it (so a quote made in a text view and
/// one made in a page agree): whitespace collapsed, 32 characters of context each side, and a long highlight sent as its first and
/// last 96 characters.
public enum SharedSelectionText {
    static let context = 32
    static let maxQuote = 200
    static let half = 96

    /// `range` of `text` (UTF-16) as quotes; nil for an empty highlight, unless `caret`: a caret is quoted as the words either side
    /// of it, with no quote of its own.
    public static func quote(_ range: NSRange, in text: String, caret: Bool = false) -> (start: PageQuote, end: PageQuote?)? {
        let ns = text as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= ns.length else { return nil }
        let before = norm(ns.substring(to: range.location))
        let after = norm(ns.substring(from: NSMaxRange(range)))
        if range.length == 0 {
            // Exact context, not trimmed: where the caret is inside the spaces matters.
            guard caret, !(before.isEmpty && after.isEmpty) else { return nil }
            return (PageQuote(quote: "", prefix: String(before.suffix(context)), suffix: String(after.prefix(context))), nil)
        }
        let selected = norm(ns.substring(with: range)).trimmingCharacters(in: .whitespaces)
        guard !selected.isEmpty else { return nil }
        let prefix = String(before.suffix(context)).trimmingLeading()
        let suffix = String(after.prefix(context)).trimmingTrailing()
        if selected.count <= maxQuote { return (PageQuote(quote: selected, prefix: prefix, suffix: suffix), nil) }
        return (
            PageQuote(quote: String(selected.prefix(half)).trimmingCharacters(in: .whitespaces), prefix: prefix, suffix: ""),
            PageQuote(quote: String(selected.suffix(half)).trimmingCharacters(in: .whitespaces), prefix: "", suffix: suffix))
    }

    /// Where a highlight is in `text` (UTF-16), nil when its words are not there.
    public static func range(start: PageQuote, end: PageQuote?, in text: String) -> NSRange? {
        if start.quote.isEmpty { return caret(start, in: text).map { NSRange(location: $0, length: 0) } }
        guard let first = find(start, in: text, from: 0) else { return nil }
        var upper = NSMaxRange(first)
        if let end {
            guard let last = find(end, in: text, from: first.location) else { return nil }
            upper = NSMaxRange(last)
        }
        return NSRange(location: first.location, length: max(0, upper - first.location))
    }

    /// Where a caret is: between its prefix and its suffix. The words after it are looked for (the words before it at the end of the
    /// text), and the match whose other side agrees wins.
    static func caret(_ quote: PageQuote, in text: String) -> Int? {
        let ns = text as NSString
        let after = quote.suffix.trimmingCharacters(in: .whitespaces)
        let before = quote.prefix.trimmingCharacters(in: .whitespaces)
        if after.isEmpty {
            guard !before.isEmpty, let match = find(PageQuote(quote: before, prefix: "", suffix: ""), in: text, from: 0) else {
                return nil
            }
            // Nothing after it: the caret is at the end of the text, after the words before it and the spaces that follow them.
            let trailing = quote.prefix.count - quote.prefix.trimmingTrailing().count
            return min(ns.length, NSMaxRange(match) + trailing)
        }
        guard let match = find(PageQuote(quote: after, prefix: quote.prefix, suffix: ""), in: text, from: 0) else { return nil }
        // Spaces between the caret and the words after it were part of the suffix.
        let leading = quote.suffix.count - quote.suffix.trimmingLeading().count
        return max(0, min(ns.length, match.location - leading))
    }

    /// The best match of `quote`'s words in `text` at or after `from`: the one whose surroundings agree most, the first among equals.
    static func find(_ quote: PageQuote, in text: String, from: Int) -> NSRange? {
        let words = quote.quote.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty, let pattern = try? NSRegularExpression(pattern: words.joined(separator: "\\s+")) else { return nil }
        let ns = text as NSString
        guard from <= ns.length else { return nil }
        var best: (range: NSRange, score: Int)?
        for match in pattern.matches(in: text, range: NSRange(location: from, length: ns.length - from)).prefix(500) {
            let score = self.score(match.range, in: ns, prefix: quote.prefix, suffix: quote.suffix)
            if best == nil || score > best!.score { best = (match.range, score) }
        }
        return best?.range
    }

    private static func score(_ range: NSRange, in ns: NSString, prefix: String, suffix: String) -> Int {
        let lower = max(0, range.location - context * 3)
        let before = norm(ns.substring(with: NSRange(location: lower, length: range.location - lower))).trimmingCharacters(in: .whitespaces)
        let upper = min(ns.length, NSMaxRange(range) + context * 3)
        let after = norm(ns.substring(with: NSRange(location: NSMaxRange(range), length: upper - NSMaxRange(range))))
            .trimmingCharacters(in: .whitespaces)
        var points = 0
        let p = prefix.trimmingCharacters(in: .whitespaces), s = suffix.trimmingCharacters(in: .whitespaces)
        if !p.isEmpty { points += before.hasSuffix(p) ? 2 : (before.hasSuffix(String(p.suffix(8))) ? 1 : 0) }
        if !s.isEmpty { points += after.hasPrefix(s) ? 2 : (after.hasPrefix(String(s.prefix(8))) ? 1 : 0) }
        return points
    }

    static func norm(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}

private extension String {
    func trimmingLeading() -> String { String(drop(while: { $0 == " " })) }
    func trimmingTrailing() -> String {
        var copy = self
        while copy.last == " " { copy.removeLast() }
        return copy
    }
}
