// PersonDart.swift — the dart: where someone is, in their colour, with their name at its tail (WOR-773).
//
// One look everywhere a person or an agent is shown pointing or standing in something: a pointer over a shared widget, a browser or a
// simulator (and baked into a recording), their place in a file someone is editing, their selection in a shared page. It is the
// locked "filled" style of the cursor design system: a stemless dart, solid in the colour with a thin light edge and a soft shadow, its
// tip exactly at the place, and the name in a pill of the same colour at the tail. Moving it (gliding, pressing in, fading when idle)
// is up to whoever draws it; this only draws it still. Pure CoreGraphics and CoreText, on any platform and any thread.

import CoreGraphics
import CoreText
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

public nonisolated enum PersonDart {
    /// The dart's own coordinates: a 20 × 23 box with its tip at `tip`. One unit is a point on a live screen.
    public static let outline: [CGPoint] = [
        CGPoint(x: 3, y: 2.5), CGPoint(x: 3, y: 20.5), CGPoint(x: 8.8, y: 15.6), CGPoint(x: 16.8, y: 15.2),
    ]
    public static let tip = CGPoint(x: 3, y: 2.5)
    /// Where the name pill's top-left is, from the tip, in units (below and to the right: at the tail).
    public static let tagOffset = CGSize(width: 13, height: 17.5)
    /// The outline as an SVG path in its own coordinates, for a page that draws the dart itself.
    public static let svgPath = "M3 2.5 L3 20.5 L8.8 15.6 L16.8 15.2 Z"
    /// The light edge's width, in units.
    public static let edgeWidth: CGFloat = 1.6

    // MARK: Drawing

    /// The dart and, when `name` is set, its name: the tip at `tip` in `ctx`.
    ///
    /// - Parameter yUp: `true` for a bottom-left, y-up context (a bitmap); `false` for a top-left, y-down one (a flipped view, SwiftUI).
    /// - Parameter scale: a press or an appearance changes the dart's size, never the name's.
    /// - Parameter angle: the dart turned about its tip (an agent thinking wiggles it), in radians.
    public static func draw(
        in ctx: CGContext, tip at: CGPoint, color: CGColor, name: String? = nil, unit: CGFloat = 1, scale: CGFloat = 1,
        angle: CGFloat = 0, yUp: Bool = false
    ) {
        drawDart(in: ctx, tip: at, color: color, unit: unit * scale, angle: angle, yUp: yUp)
        if let name {
            let down: CGFloat = yUp ? -1 : 1
            drawTag(
                in: ctx, text: name, at: CGPoint(x: at.x + tagOffset.width * unit, y: at.y + down * tagOffset.height * unit),
                color: color, unit: unit, yUp: yUp)
        }
    }

    /// The dart alone.
    public static func drawDart(in ctx: CGContext, tip at: CGPoint, color: CGColor, unit: CGFloat = 1, angle: CGFloat = 0, yUp: Bool = false) {
        let down: CGFloat = yUp ? -1 : 1
        ctx.saveGState()
        ctx.translateBy(x: at.x, y: at.y)
        if angle != 0 { ctx.rotate(by: angle) }
        let path = CGMutablePath()
        for (index, point) in outline.enumerated() {
            let p = CGPoint(x: (point.x - tip.x) * unit, y: down * (point.y - tip.y) * unit)
            index == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        path.closeSubpath()
        ctx.setShadow(offset: CGSize(width: 0, height: down * -unit * 0.6), blur: unit * 1.6, color: CGColor(gray: 0, alpha: 0.3))
        ctx.setFillColor(color)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        // The thin light edge that keeps the dart readable on any background.
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.92))
        ctx.setLineWidth(max(0.8, edgeWidth * unit))
        ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// A pill of `color` with white bold `text`: its top-left at `at` (its top-centre when `centered`), below it on the screen.
    public static func drawTag(
        in ctx: CGContext, text: String, at anchor: CGPoint, color: CGColor, unit: CGFloat = 1, centered: Bool = false,
        alpha: CGFloat = 1, yUp: Bool = false
    ) {
        guard alpha > 0 else { return }
        let metrics = tagMetrics(text, unit: unit)
        let left = centered ? anchor.x - metrics.size.width / 2 : anchor.x
        // The pill's rectangle in context coordinates: below the anchor in y-down, below it (smaller y) in y-up.
        let bottom = yUp ? anchor.y - metrics.size.height : anchor.y
        let rect = CGRect(x: left, y: bottom, width: metrics.size.width, height: metrics.size.height)
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.setFillColor(color)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil))
        ctx.fillPath()
        // Text sits on the baseline inside the pill; a y-down context needs the text flipped so it reads upright.
        ctx.textMatrix = yUp ? .identity : CGAffineTransform(scaleX: 1, y: -1)
        let fontSize = metrics.fontSize, padY = fontSize * 0.25
        let baseline = yUp ? rect.minY + padY + fontSize * 0.22 : rect.minY + padY + fontSize * 0.78
        ctx.textPosition = CGPoint(x: rect.minX + fontSize * 0.55 - metrics.bounds.minX, y: baseline)
        CTLineDraw(metrics.line, ctx)
        ctx.restoreGState()
    }

    /// How big a name pill is.
    public static func tagSize(_ text: String, unit: CGFloat = 1) -> CGSize { tagMetrics(text, unit: unit).size }

    /// Everything the dart and its name cover, from the tip, on a y-down screen: what a view holding them has to be.
    public static func bounds(name: String?, unit: CGFloat = 1) -> CGRect {
        let margin = 2 * unit   // the edge and the shadow
        var rect = CGRect(x: -margin, y: -margin, width: (16.8 - tip.x) * unit + 2 * margin, height: (20.5 - tip.y) * unit + 2 * margin)
        if let name {
            let size = tagSize(name, unit: unit)
            rect = rect.union(CGRect(origin: CGPoint(x: tagOffset.width * unit, y: tagOffset.height * unit), size: size))
        }
        return rect
    }

    private static func tagMetrics(_ text: String, unit: CGFloat) -> (line: CTLine, bounds: CGRect, size: CGSize, fontSize: CGFloat) {
        let fontSize = max(9, 4.4 * unit)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        let size = CGSize(width: bounds.width + 2 * fontSize * 0.55, height: fontSize * 1.5)
        return (line, bounds, size, fontSize)
    }
}

/// The dart as a view: the tip at the view's `PersonDart.bounds` origin, so place it with `.offset` or `.position` from there.
public struct PersonDartView: View {
    private let color: Color
    private let name: String?
    private let unit: CGFloat

    public init(color: Color, name: String? = nil, unit: CGFloat = 1) {
        self.color = color
        self.name = name
        self.unit = unit
    }

    public var body: some View {
        let bounds = PersonDart.bounds(name: name, unit: unit)
        Canvas { context, _ in
            context.withCGContext { ctx in
                PersonDart.draw(
                    in: ctx, tip: CGPoint(x: -bounds.minX, y: -bounds.minY), color: color.resolvedCGColor, name: name, unit: unit)
            }
        }
        .frame(width: bounds.width, height: bounds.height)
        .allowsHitTesting(false)
    }
}

private extension Color {
    nonisolated var resolvedCGColor: CGColor {
        #if canImport(UIKit)
        UIColor(self).cgColor
        #else
        NSColor(self).cgColor
        #endif
    }
}
