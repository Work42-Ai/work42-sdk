// SharedSelectionTextSurface.swift — a text's part in sharing highlights (WOR-773 §6).
//
// Every surface that lets a person highlight text to comment on it owns one, as part of offering the comment: the prose of chat and
// documents (`Work42SelectableProse`), the iPad's comment host (and the file editor in it), the Mac's file editor. It reports the
// person's highlight to `SharedSelectionHub` as quotes, and draws the others' highlights that are in its text: a box in their colour,
// `PersonDart` at the end they are at, the typing dots while they write or dictate a comment on it. A text someone is typing in shows
// their bare caret too, anchored by the words either side of it. The text is anything that can say what it holds and where its
// characters are (`SharedSelectionTextHost`): an AppKit or UIKit text view as it is, the tree-sitter editor through a small adapter.

import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// A text a highlight can be in, as the shared highlights see it. Rects are in `sharedOverlayParent`'s coordinates.
@MainActor
public protocol SharedSelectionTextHost: AnyObject {
    var sharedText: String { get }
    /// The person's selection (UTF-16); a caret is an empty range.
    var sharedSelectedRange: NSRange { get }
    /// The person is typing in it: their bare caret is shown to the others too.
    var sharedIsEditing: Bool { get }
    /// The boxes `range` covers, one per line fragment.
    func sharedRects(for range: NSRange) -> [CGRect]
    /// The view the marks go in, so they scroll with the text.
    var sharedOverlayParent: PlatformView { get }
    /// Brings `rect` into view, smoothly.
    func sharedReveal(_ rect: CGRect)
}

@MainActor
public final class SharedSelectionTextSurface {
    private weak var host: (any SharedSelectionTextHost)?
    private let overlay = SharedSelectionMarksView()
    private let hub: SharedSelectionHub
    /// The widget the text is in: nothing is shared without one.
    public var place: SharedSelectionPlace? {
        didSet {
            guard place != oldValue else { return }
            if oldValue != nil {
                reportedKey = nil
                hub.report(nil, from: self)
            }
            selectionChanged()
            redraw()
        }
    }
    private var local: SharedSelectionLocal?
    private var lastRange: NSRange?
    /// What was last reported, so a poll reports only a change.
    private var reportedKey: String?
    private var drawn: [Mark] = []
    private var revealed: [String: String] = [:]
    private var animation: Timer?
    private var poller: Timer?

    /// `polls`: the host does not say when its selection changes (an editor that keeps its own delegate): it is read on a short beat.
    public init(host: any SharedSelectionTextHost, place: SharedSelectionPlace? = nil, polls: Bool = false, hub: SharedSelectionHub = .shared) {
        self.host = host
        self.hub = hub
        self.place = place
        hub.observe(self) { [weak self] in self?.redraw() }
        if polls {
            poller = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.selectionChanged() }
            }
        }
        redraw()
    }

    /// The text's selection (or whether the person is typing in it) changed: their highlight goes to the others, or goes away.
    public func selectionChanged() {
        guard let place, let host else { return }
        let range = host.sharedSelectedRange
        let text = host.sharedText
        let editing = host.sharedIsEditing
        // A selection always; a bare caret only while they type here.
        guard range.location != NSNotFound, range.length > 0 || editing,
              let quotes = SharedSelectionText.quote(range, in: text, caret: editing) else {
            lastRange = range
            local = nil
            guard reportedKey != nil else { return }
            reportedKey = nil
            hub.report(nil, from: self)
            return
        }
        let backward = SharedSelectionText.backward(from: lastRange, to: range, wasBackward: local?.backward ?? false)
        lastRange = range
        let selection = SharedSelectionLocal(place: place, start: quotes.start, end: quotes.end, backward: backward)
        let key = "\(place)|\(quotes.start)|\(String(describing: quotes.end))|\(backward)"
        local = selection
        guard key != reportedKey else { return }
        reportedKey = key
        hub.report(selection, from: self)
    }

    /// The text changed, or its width did: the marks move with it.
    public func layoutChanged() {
        // A text with nobody's highlight in it (nearly every one) does no work.
        guard !drawn.isEmpty else { return }
        redraw(force: true)
    }

    /// The text went away: its highlight goes for everyone.
    public func detach() {
        hub.report(nil, from: self)
        hub.stopObserving(self)
        animation?.invalidate()
        animation = nil
        poller?.invalidate()
        poller = nil
        overlay.removeFromSuperview()
    }

    // MARK: Drawing

    struct Mark: Equatable {
        var remote: SharedSelectionRemote
        var range: NSRange
    }

    private func redraw(force: Bool = false) {
        guard let host else { return }
        let text = host.sharedText
        var marks: [Mark] = []
        if let place {
            for remote in hub.remote(in: place) {
                if let range = SharedSelectionText.range(start: remote.start, end: remote.end, in: text) {
                    marks.append(Mark(remote: remote, range: range))
                }
            }
        }
        guard force || marks != drawn else { return }
        drawn = marks
        overlay.mount(in: host.sharedOverlayParent)
        overlay.shapes = marks.map { mark in
            let focus = mark.remote.backward ? mark.range.location : NSMaxRange(mark.range)
            return SharedSelectionMarksView.Shape(
                id: mark.remote.id, color: mark.remote.cgColor,
                boxes: mark.range.length > 0 ? host.sharedRects(for: mark.range) : [],
                caret: Self.caretRect(at: focus, backward: mark.remote.backward && mark.range.length > 0, in: host, text: text),
                name: mark.remote.name, typing: mark.remote.activity != nil)
        }
        animate(marks.contains { $0.remote.activity != nil })
        for mark in marks where mark.remote.followed {
            let key = "\(mark.remote.start)|\(String(describing: mark.remote.end))"
            if revealed[mark.remote.id] != key {
                revealed[mark.remote.id] = key
                let caret = Self.caretRect(at: mark.range.location, backward: true, in: host, text: text)
                host.sharedReveal(host.sharedRects(for: mark.range).first ?? caret)
            }
        }
    }

    /// The dots move about 30 times a second while someone here writes a comment; nothing ticks otherwise.
    private func animate(_ on: Bool) {
        if on, animation == nil {
            animation = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.overlay.tick() }
            }
        } else if !on {
            animation?.invalidate()
            animation = nil
        }
    }

    /// Where the person is: the edge of the highlight they moved (or their caret), the height of its line.
    static func caretRect(at offset: Int, backward: Bool, in host: any SharedSelectionTextHost, text: String) -> CGRect {
        let ns = text as NSString
        func line(_ box: CGRect, atStart: Bool) -> CGRect {
            CGRect(x: atStart ? box.minX : box.maxX, y: box.minY, width: 0, height: box.height)
        }
        // At the start of a line, or at the start of a highlight: the left edge of the character there.
        let startsLine = offset == 0 || (offset <= ns.length && offset > 0 && ns.character(at: offset - 1) == 10)
        if (backward || startsLine), offset < ns.length, let box = host.sharedRects(for: NSRange(location: offset, length: 1)).first {
            return line(box, atStart: true)
        }
        if offset > 0, let box = host.sharedRects(for: NSRange(location: offset - 1, length: 1)).first {
            return line(box, atStart: false)
        }
        return .zero
    }
}

extension SharedSelectionText {
    /// Which end is the person's once a highlight went from `previous` to `range`. Text views do not say, so it is told from the
    /// end that stayed put: dragging or shift-arrowing towards the start keeps the end fixed.
    public static func backward(from previous: NSRange?, to range: NSRange, wasBackward: Bool) -> Bool {
        guard range.length > 0, let previous else { return false }
        let start = previous.location, end = NSMaxRange(previous)
        if previous.length == 0 { return NSMaxRange(range) == start && range.location != start }
        if range.location == end { return false }
        if NSMaxRange(range) == start { return true }
        if range.location == start, NSMaxRange(range) != end { return false }
        if NSMaxRange(range) == end, range.location != start { return true }
        return wasBackward
    }
}

// MARK: The hosts this library knows

#if canImport(AppKit)
extension NSTextView: SharedSelectionTextHost {
    public var sharedText: String { string }
    public var sharedSelectedRange: NSRange { selectedRange() }
    public var sharedIsEditing: Bool { isEditable && window?.isKeyWindow == true && window?.firstResponder === self }
    public var sharedOverlayParent: PlatformView { self }

    public func sharedRects(for range: NSRange) -> [CGRect] {
        guard let layout = layoutManager, let container = textContainer, NSMaxRange(range) <= (string as NSString).length
        else { return [] }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rects: [CGRect] = []
        layout.enumerateEnclosingRects(
            forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container
        ) { rect, _ in rects.append(rect) }
        let origin = textContainerOrigin
        return rects.map { $0.offsetBy(dx: origin.x, dy: origin.y) }.filter { $0.width > 0 }
    }

    public func sharedReveal(_ rect: CGRect) { SharedSelectionReveal.reveal(rect, in: self) }
}
#else
extension UITextView: SharedSelectionTextHost {
    public var sharedText: String { text ?? "" }
    public var sharedSelectedRange: NSRange { selectedRange }
    public var sharedIsEditing: Bool { isEditable && isFirstResponder }
    public var sharedOverlayParent: PlatformView { self }

    public func sharedRects(for range: NSRange) -> [CGRect] {
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length),
              let textRange = textRange(from: start, to: end) else { return [] }
        return selectionRects(for: textRange).map(\.rect).filter { !$0.isNull && !$0.isInfinite && $0.width > 0 }
    }

    public func sharedReveal(_ rect: CGRect) {
        // A text view that scrolls itself scrolls; one inside something else (a chat) asks what holds it.
        var view: UIView? = isScrollEnabled ? self : superview
        while let current = view, !((current as? UIScrollView)?.isScrollEnabled ?? false) { view = current.superview }
        guard let scroller = view as? UIScrollView else { return }
        let target = convert(rect, to: scroller)
        guard !scroller.bounds.contains(target) else { return }
        scroller.scrollRectToVisible(target.insetBy(dx: 0, dy: -scroller.bounds.height / 3), animated: true)
    }
}
#endif

#if canImport(AppKit)
/// Brings a rect of a view into view in the scroll view that holds it, smoothly.
public enum SharedSelectionReveal {
    @MainActor
    public static func reveal(_ rect: CGRect, in view: NSView) {
        guard let scroll = view.enclosingScrollView, let document = scroll.documentView else { view.scrollToVisible(rect); return }
        let clip = scroll.contentView
        let target = view.convert(rect, to: document)
        let visible = clip.bounds
        guard !visible.insetBy(dx: 0, dy: rect.height).contains(target) else { return }
        let maxY = max(0, document.frame.height - visible.height)
        let y = min(maxY, max(0, target.midY - visible.height / 2))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(NSPoint(x: visible.origin.x, y: y))
        } completionHandler: {
            MainActor.assumeIsolated { scroll.reflectScrolledClipView(clip) }
        }
    }
}
#endif

// MARK: The marks

/// The others' highlights over a text: boxes, darts, names. Never takes a touch or a click.
///
/// On the Mac one view over the text draws them all. On the iPad each mark is a small view of its own, so a long scrolling text never
/// needs a backing store the size of its content.
final class SharedSelectionMarksView: PlatformView {
    struct Shape {
        var id: String
        var color: CGColor
        var boxes: [CGRect]
        var caret: CGRect
        var name: String
        var typing: Bool
    }

    var shapes: [Shape] = [] { didSet { layoutShapes() } }

    #if canImport(AppKit)
    /// How far the view reaches past the text on every side; shapes are in the text's coordinates.
    static let margin: CGFloat = 48

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func mount(in parent: NSView) {
        if superview !== parent { parent.addSubview(self, positioned: .above, relativeTo: nil) }
        // A margin all round: a dart and its name hang past the text's last line and its edges.
        frame = parent.bounds.insetBy(dx: -Self.margin, dy: -Self.margin)
    }

    private func layoutShapes() { needsDisplay = true }

    /// Only the names with dots in them are drawn again: over a long file the view is as tall as the document.
    func tick() {
        for shape in shapes where shape.typing {
            let dart = PersonDart.bounds(name: shape.name, typing: true)
                .offsetBy(dx: shape.caret.minX + Self.margin, dy: shape.caret.midY + Self.margin)
            setNeedsDisplay(dart.insetBy(dx: -2, dy: -2))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let time = Date().timeIntervalSinceReferenceDate
        ctx.translateBy(x: Self.margin, y: Self.margin)
        for shape in shapes {
            ctx.setFillColor(shape.color.copy(alpha: 0.25) ?? shape.color)
            for box in shape.boxes { ctx.fill(box) }
            PersonDart.draw(
                in: ctx, tip: CGPoint(x: shape.caret.minX, y: shape.caret.midY), color: shape.color, name: shape.name,
                typing: shape.typing, time: time)
        }
    }
    #else
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { nil }

    func mount(in parent: UIView) {
        if superview !== parent { parent.addSubview(self) }
        parent.bringSubviewToFront(self)
        // A zero-sized holder at the text's origin: the marks are its children, placed in the text's coordinates.
        frame = .zero
        // A text view that does not scroll shows the marks that hang past it (a scrolling one has room in its content).
        if let text = parent as? UITextView, !text.isScrollEnabled { text.clipsToBounds = false }
    }

    private var darts: [DartView] = []

    private func layoutShapes() {
        subviews.forEach { $0.removeFromSuperview() }
        darts = []
        for shape in shapes {
            let fill = UIColor(cgColor: shape.color.copy(alpha: 0.25) ?? shape.color)
            for box in shape.boxes {
                let view = UIView(frame: box)
                view.backgroundColor = fill
                view.isUserInteractionEnabled = false
                addSubview(view)
            }
            let dart = DartView(shape: shape)
            addSubview(dart)
            darts.append(dart)
        }
    }

    func tick() { for dart in darts where dart.shape.typing { dart.setNeedsDisplay() } }

    /// One person's dart and name, in a view just big enough to hold them.
    private final class DartView: UIView {
        let shape: Shape
        private let tip: CGPoint

        init(shape: Shape) {
            self.shape = shape
            let bounds = PersonDart.bounds(name: shape.name, typing: shape.typing)
            tip = CGPoint(x: -bounds.minX, y: -bounds.minY)
            super.init(frame: bounds.offsetBy(dx: shape.caret.minX, dy: shape.caret.midY))
            isOpaque = false
            backgroundColor = .clear
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { nil }

        override func draw(_ rect: CGRect) {
            guard let ctx = UIGraphicsGetCurrentContext() else { return }
            PersonDart.draw(
                in: ctx, tip: tip, color: shape.color, name: shape.name, typing: shape.typing,
                time: Date().timeIntervalSinceReferenceDate)
        }
    }
    #endif
}
