// SharedSelectionTextSurface.swift — a text view's part in sharing highlights (WOR-773 §6).
//
// Any selectable text view of this library (`Work42SelectableProse` on the Mac and the iPad) owns one: it reports the person's
// highlight to `SharedSelectionHub` as quotes, and draws the others' highlights that are in its text, each a box in their colour with
// `PersonDart` at the end they are at (with the typing dots while they write or dictate a comment on it). The marks are an overlay in
// the text view, so they scroll with the text; the person followed is brought into view when they highlight something new.

import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
public typealias SharedSelectionTextView = NSTextView
#else
import UIKit
public typealias SharedSelectionTextView = UITextView
#endif

@MainActor
public final class SharedSelectionTextSurface {
    private weak var textView: SharedSelectionTextView?
    private let overlay = SharedSelectionMarksView()
    private let hub: SharedSelectionHub
    /// The widget the text is in: nothing is shared without one.
    public var place: SharedSelectionPlace? {
        didSet {
            guard place != oldValue else { return }
            if oldValue != nil, place == nil { hub.report(nil, from: self) }
            redraw()
        }
    }
    private var local: SharedSelectionLocal?
    private var drawn: [Mark] = []
    private var revealed: [String: String] = [:]
    private var animation: Timer?

    public init(textView: SharedSelectionTextView, hub: SharedSelectionHub = .shared) {
        self.textView = textView
        self.hub = hub
        hub.observe(self) { [weak self] in self?.redraw() }
    }

    /// The text view's selection changed: the person's highlight goes to the others, or goes away.
    public func selectionChanged() {
        guard let place, let textView else { return }
        let range = Self.selectedRange(of: textView)
        guard range.length > 0, let quotes = SharedSelectionText.quote(range, in: Self.string(of: textView)) else {
            local = nil
            lastRange = range
            hub.report(nil, from: self)
            return
        }
        let backward = SharedSelectionText.backward(from: lastRange, to: range, wasBackward: local?.backward ?? false)
        let selection = SharedSelectionLocal(place: place, start: quotes.start, end: quotes.end, backward: backward)
        local = selection
        lastRange = range
        hub.report(selection, from: self)
    }

    /// The highlight as it last was, which tells which end the person moved.
    private var lastRange: NSRange?

    /// The text changed, or its width did: the marks move with it.
    public func layoutChanged() {
        // A text with nobody's highlight in it (nearly every one) does no work.
        guard !drawn.isEmpty else { return }
        redraw(force: true)
    }

    /// The view went away: its highlight goes for everyone.
    public func detach() {
        hub.report(nil, from: self)
        hub.stopObserving(self)
        animation?.invalidate()
        animation = nil
        overlay.removeFromSuperview()
    }

    // MARK: Drawing

    struct Mark: Equatable {
        var remote: SharedSelectionRemote
        var range: NSRange
    }

    private func redraw(force: Bool = false) {
        guard let textView else { return }
        let text = Self.string(of: textView)
        var marks: [Mark] = []
        if let place {
            for remote in hub.remote(in: place) {
                if let range = SharedSelectionText.range(start: remote.start, end: remote.end, in: text), range.length > 0 {
                    marks.append(Mark(remote: remote, range: range))
                }
            }
        }
        guard force || marks != drawn else { return }
        drawn = marks
        mount(in: textView)
        overlay.shapes = marks.map { mark in
            let focus = mark.remote.backward ? mark.range.location : NSMaxRange(mark.range)
            return SharedSelectionMarksView.Shape(
                color: mark.remote.cgColor, boxes: Self.rects(for: mark.range, in: textView),
                caret: Self.caretRect(at: focus, backward: mark.remote.backward, in: textView), name: mark.remote.name,
                typing: mark.remote.activity != nil)
        }
        animate(marks.contains { $0.remote.activity != nil })
        for mark in marks where mark.remote.followed {
            let key = "\(mark.remote.start)|\(String(describing: mark.remote.end))"
            if revealed[mark.remote.id] != key {
                revealed[mark.remote.id] = key
                Self.reveal(Self.rects(for: mark.range, in: textView).first, in: textView)
            }
        }
    }

    private func mount(in textView: SharedSelectionTextView) {
        #if canImport(AppKit)
        if overlay.superview !== textView { textView.addSubview(overlay, positioned: .above, relativeTo: nil) }
        #else
        if overlay.superview !== textView { textView.addSubview(overlay) }
        textView.bringSubviewToFront(overlay)
        // A text view that does not scroll shows the marks that hang past it (a scrolling one has room in its content).
        if !textView.isScrollEnabled { textView.clipsToBounds = false }
        #endif
        // A margin all round: a dart and its name hang past the text's last line and its edges.
        let margin = SharedSelectionMarksView.margin
        overlay.frame = textView.bounds.insetBy(dx: -margin, dy: -margin)
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

    // MARK: Text geometry, per platform

    private static func string(of textView: SharedSelectionTextView) -> String {
        #if canImport(AppKit)
        textView.string
        #else
        textView.text ?? ""
        #endif
    }

    private static func selectedRange(of textView: SharedSelectionTextView) -> NSRange {
        #if canImport(AppKit)
        textView.selectedRange()
        #else
        textView.selectedRange
        #endif
    }

    /// The boxes a range covers, one per line, in the text view's coordinates.
    private static func rects(for range: NSRange, in textView: SharedSelectionTextView) -> [CGRect] {
        #if canImport(AppKit)
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return [] }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rects: [CGRect] = []
        layout.enumerateEnclosingRects(
            forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container
        ) { rect, _ in rects.append(rect) }
        let origin = textView.textContainerOrigin
        return rects.map { $0.offsetBy(dx: origin.x, dy: origin.y) }.filter { $0.width > 0 }
        #else
        guard let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
              let end = textView.position(from: start, offset: range.length),
              let textRange = textView.textRange(from: start, to: end) else { return [] }
        return textView.selectionRects(for: textRange).map(\.rect).filter { !$0.isNull && $0.width > 0 }
        #endif
    }

    /// Where the person is: the edge of the highlight they moved, the height of its line.
    private static func caretRect(at offset: Int, backward: Bool, in textView: SharedSelectionTextView) -> CGRect {
        let boxes = rects(for: NSRange(location: backward ? offset : max(0, offset - 1), length: 1), in: textView)
        guard let box = boxes.first else { return .zero }
        return CGRect(x: backward ? box.minX : box.maxX, y: box.minY, width: 0, height: box.height)
    }

    /// Brings `rect` of the text into view in whatever scrolls it.
    private static func reveal(_ rect: CGRect?, in textView: SharedSelectionTextView) {
        guard let rect else { return }
        #if canImport(AppKit)
        guard let clip = textView.enclosingScrollView?.contentView else { textView.scrollToVisible(rect); return }
        let target = textView.convert(rect, to: clip.documentView)
        let visible = clip.bounds
        guard !visible.contains(target) else { return }
        let y = max(0, target.midY - visible.height / 2)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(NSPoint(x: visible.origin.x, y: y))
        } completionHandler: {
            MainActor.assumeIsolated { textView.enclosingScrollView?.reflectScrolledClipView(clip) }
        }
        #else
        var view: UIView? = textView.isScrollEnabled ? textView : textView.superview
        while let current = view, !((current as? UIScrollView)?.isScrollEnabled ?? false) { view = current.superview }
        guard let scroller = view as? UIScrollView else { return }
        let target = textView.convert(rect, to: scroller)
        guard !scroller.bounds.contains(target) else { return }
        scroller.scrollRectToVisible(target.insetBy(dx: 0, dy: -scroller.bounds.height / 3), animated: true)
        #endif
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

/// The others' highlights over a text: boxes, darts, names. Never takes a touch or a click.
final class SharedSelectionMarksView: PlatformView {
    struct Shape {
        var color: CGColor
        var boxes: [CGRect]
        var caret: CGRect
        var name: String
        var typing: Bool
    }

    var shapes: [Shape] = [] { didSet { setNeedsDisplayCompat() } }

    func tick() { if shapes.contains(where: \.typing) { setNeedsDisplayCompat() } }

    #if canImport(AppKit)
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private func setNeedsDisplayCompat() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        paint(ctx)
    }
    #else
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        clipsToBounds = false
    }

    required init?(coder: NSCoder) { nil }
    private func setNeedsDisplayCompat() { setNeedsDisplay() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        paint(ctx)
    }
    #endif

    /// How far the view reaches past the text on every side; shapes are in the text's coordinates.
    static let margin: CGFloat = 48

    private func paint(_ ctx: CGContext) {
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
}
