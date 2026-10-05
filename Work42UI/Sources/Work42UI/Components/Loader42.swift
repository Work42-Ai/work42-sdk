// Loader42.swift - The animated 42-mark loader.
//
// The brand mark is a racing circuit: a "pencil" paints the 4 limb by
// limb (top bar → diagonal → crossbar → stem → leaning limb), crosses
// the seam on the middle lane into the 2 (middle bar → curl up → top
// bar, with the bottom straight riding along), then a second lap erases
// the color along the exact same route. The cycle is a closed loop —
// the erase ends where the paint begins — so the restart is invisible.
//
// This is a 1:1 port of the approved SVG artifact (`42-circuit-loader`):
// same glyph outlines (contour-traced from docs/brand/work42-mark.png),
// same per-limb pencil paths/widths, same keyTimes and cubic-bezier
// splines. Keep the two in sync if either changes.
//
// Performance: everything runs as Core Animation keyframe animations on
// CAShapeLayer stroke ends inside mask layers — zero per-frame SwiftUI
// body re-eval, zero TimelineView. Same discipline as ThinkingIndicator
// (see its header for the O(N²) selection-overlay regression story).
//
// Usage:
//
//     Loader42()                          // brand orange/violet
//     Loader42(style: .mono(.white))      // single color (splash, dark HUD)
//     Loader42(style: .mono(DT.cyan))
//         .frame(width: 90, height: 90)   // size via frame; mark keeps aspect
//
// Reduced motion: renders the fully-painted static mark.

import SwiftUI
import AppKit

// MARK: - Public SwiftUI wrapper

public struct Loader42: View {

    public enum Style: Equatable {
        /// Brand orange 4 + violet 2 (adaptive per appearance). ALWAYS use
        /// this in the app — the loader is a brand mark, not a tinted
        /// control, so it keeps the logo's own colors on every theme.
        case brand
        /// Single color for both glyphs. Reserved for surfaces where brand
        /// colors physically can't work (e.g. printed on a solid brand-
        /// colored fill). Not for general theming.
        case mono(Color)
    }

    /// The mark is illegible below this — the component enforces it.
    public static let minimumSize: CGFloat = 26

    private let style: Style

    public init(style: Style = .brand) {
        self.style = style
    }

    public var body: some View {
        Loader42Representable(style: style)
            .frame(minWidth: Self.minimumSize, minHeight: Self.minimumSize)
    }
}

private struct Loader42Representable: NSViewRepresentable {
    let style: Loader42.Style

    func makeNSView(context: Context) -> Loader42View {
        let view = Loader42View()
        view.style = style
        return view
    }

    func updateNSView(_ view: Loader42View, context: Context) {
        view.style = style
    }
}

// MARK: - Layer-backed view

public final class Loader42View: NSView {

    public var style: Loader42.Style = .brand {
        didSet { if style != oldValue { applyColors() } }
    }

    /// One full cycle: paint lap + erase lap.
    public static let cycleDuration: TimeInterval = 3.4

    // Design space of the traced mark (matches the SVG viewBox).
    private static let designSize: CGFloat = 256

    private let container = CALayer()
    private var shadeLayers: [CAShapeLayer] = []
    private var orangeFill = CAShapeLayer()
    private var violetFills: [CAShapeLayer] = []
    private var pencils: [CAShapeLayer] = []

    // MARK: Init

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        buildLayerTree()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        buildLayerTree()
    }

    // MARK: Geometry (glyph outlines + pencil routes, design coords)

    /// The 4. Extends 1pt past the seam (x135) so the abutting fills can
    /// never show an anti-aliased hairline; the 2 renders on top of it.
    private static func orangeGlyphPath() -> CGPath {
        let p = CGMutablePath()
        p.move(to: .init(x: 50, y: 140))
        p.addLine(to: .init(x: 96, y: 140))
        p.addLine(to: .init(x: 96, y: 128))
        p.addLine(to: .init(x: 80, y: 128))
        p.addLine(to: .init(x: 103, y: 103))
        p.addLine(to: .init(x: 135, y: 103))
        p.addLine(to: .init(x: 135, y: 128))
        p.addLine(to: .init(x: 126, y: 128))
        p.addLine(to: .init(x: 126, y: 188))
        p.addLine(to: .init(x: 96, y: 188))
        p.addLine(to: .init(x: 96, y: 166))
        p.addLine(to: .init(x: 8, y: 166))
        p.addLine(to: .init(x: 7, y: 141))
        p.addLine(to: .init(x: 16, y: 134))
        p.addLine(to: .init(x: 80, y: 64))
        p.addLine(to: .init(x: 135, y: 64))
        p.addLine(to: .init(x: 135, y: 90))
        p.addLine(to: .init(x: 100, y: 90))
        p.closeSubpath()
        return p
    }

    /// The 2's top piece (bar + curl + middle bar).
    private static func violetTopPath() -> CGPath {
        let p = CGMutablePath()
        p.move(to: .init(x: 134, y: 64))
        p.addLine(to: .init(x: 222, y: 64))
        p.addCurve(to: .init(x: 249, y: 87),
                   control1: .init(x: 238, y: 64), control2: .init(x: 249, y: 71))
        p.addLine(to: .init(x: 249, y: 107))
        p.addCurve(to: .init(x: 228, y: 128),
                   control1: .init(x: 249, y: 121), control2: .init(x: 240, y: 128))
        p.addLine(to: .init(x: 134, y: 128))
        p.addLine(to: .init(x: 134, y: 103))
        p.addLine(to: .init(x: 213, y: 103))
        p.addQuadCurve(to: .init(x: 218, y: 98.5), control: .init(x: 218, y: 103))
        p.addLine(to: .init(x: 218, y: 94.5))
        p.addQuadCurve(to: .init(x: 213, y: 90), control: .init(x: 218, y: 90))
        p.addLine(to: .init(x: 134, y: 90))
        p.closeSubpath()
        return p
    }

    /// The 2's bottom bar.
    private static func violetBottomPath() -> CGPath {
        CGPath(rect: CGRect(x: 135, y: 139, width: 114, height: 27), transform: nil)
    }

    /// One pencil = one limb of the choreography.
    private struct Pencil {
        let path: CGPath
        let width: CGFloat
        /// Normalized [start, end] of the paint window in the cycle.
        let paint: (Double, Double)
        /// Erase window (mirror of paint at +0.5).
        let erase: (Double, Double)
        /// Timing curve inside both windows.
        let timing: CAMediaTimingFunction
        /// Optional extra clip (design coords) beyond the glyph-side clip.
        let clip: CGRect?
    }

    private static let linearFn = CAMediaTimingFunction(name: .linear)
    /// Violet section curve — the lap easing is cubic-bezier(.2,.7,.6,.82):
    /// a 3.5× launch off the line and a brake that lands at 0.45× — visibly
    /// slowing, NEVER stopping, so the loop reads continuous. The orange
    /// limbs encode the launch via their window sizing (linear inside);
    /// this subdivided curve carries the long brake through the 2.
    private static let violetFn = CAMediaTimingFunction(controlPoints: 0.29, 0.514, 0.645, 0.73)

    private static func line(_ points: [(CGFloat, CGFloat)]) -> CGPath {
        let p = CGMutablePath()
        p.move(to: .init(x: points[0].0, y: points[0].1))
        for pt in points.dropFirst() { p.addLine(to: .init(x: pt.0, y: pt.1)) }
        return p
    }

    /// Orange pencils. Start/end points overshoot past the seam clip so
    /// visible fronts enter and exit at speed (no slow-motion slivers).
    private static func orangePencils() -> [Pencil] {
        // Top bar + diagonal as ONE stroke with a rounded bend — the
        // front rotates smoothly from vertical to 45° through the corner.
        let topAndDiagonal = CGMutablePath()
        topAndDiagonal.move(to: .init(x: 140, y: 77))
        topAndDiagonal.addLine(to: .init(x: 104, y: 77))
        topAndDiagonal.addQuadCurve(to: .init(x: 80.4, y: 87.1), control: .init(x: 90, y: 77))
        topAndDiagonal.addLine(to: .init(x: 16, y: 155))

        return [
            Pencil(path: topAndDiagonal, width: 40,
                   paint: (0, 0.0405), erase: (0.5, 0.5405), timing: linearFn, clip: nil),
            // Crossbar, left → right.
            Pencil(path: line([(7, 153), (126, 153)]), width: 26,
                   paint: (0.0405, 0.0874), erase: (0.5405, 0.5874), timing: linearFn, clip: nil),
            // Stem tip, down.
            Pencil(path: line([(111, 153), (111, 188)]), width: 30,
                   paint: (0.0874, 0.1049), erase: (0.5874, 0.6049), timing: linearFn, clip: nil),
            // Leaning upper limb, up and out toward the seam.
            Pencil(path: line([(100, 142), (122, 96)]), width: 52,
                   paint: (0.1246, 0.1589), erase: (0.6246, 0.6589), timing: linearFn,
                   clip: CGRect(x: 0, y: 96, width: 135, height: 46)),
        ]
    }

    private static func violetPencils() -> [Pencil] {
        // Mid seam → middle bar → curl up → top bar → past the top seam.
        let main = CGMutablePath()
        main.move(to: .init(x: 133, y: 115))
        main.addLine(to: .init(x: 219, y: 115))
        main.addCurve(to: .init(x: 219, y: 77),
                      control1: .init(x: 236, y: 115), control2: .init(x: 236, y: 77))
        main.addLine(to: .init(x: 128, y: 77))

        return [
            Pencil(path: main, width: 46,
                   paint: (0.1589, 0.5), erase: (0.6589, 1.0), timing: violetFn, clip: nil),
            // Bottom straight rides along with the middle-bar sweep.
            Pencil(path: line([(133, 152), (254, 152)]), width: 46,
                   paint: (0.1589, 0.2444), erase: (0.6589, 0.7444), timing: linearFn, clip: nil),
        ]
    }

    // MARK: Layer tree

    private func buildLayerTree() {
        guard let root = layer else { return }
        container.isGeometryFlipped = true // SVG/top-left coordinate space
        container.bounds = CGRect(x: 0, y: 0, width: Self.designSize, height: Self.designSize)
        root.addSublayer(container)

        // Undiscovered circuit: the exact silhouette as a dim shade.
        for path in [Self.orangeGlyphPath(), Self.violetTopPath(), Self.violetBottomPath()] {
            let shade = CAShapeLayer()
            shade.path = path
            shade.frame = container.bounds
            container.addSublayer(shade)
            shadeLayers.append(shade)
        }

        // Painted layers, each revealed only by its own side's pencils.
        orangeFill.path = Self.orangeGlyphPath()
        orangeFill.frame = container.bounds
        orangeFill.mask = Self.makeMask(
            clip: CGRect(x: 0, y: 0, width: 135, height: 256),
            pencils: Self.orangePencils(), into: &pencils
        )
        container.addSublayer(orangeFill)

        let violetGroup = CALayer()
        violetGroup.frame = container.bounds
        for path in [Self.violetTopPath(), Self.violetBottomPath()] {
            let fill = CAShapeLayer()
            fill.path = path
            fill.frame = container.bounds
            violetGroup.addSublayer(fill)
            violetFills.append(fill)
        }
        violetGroup.mask = Self.makeMask(
            clip: CGRect(x: 133, y: 0, width: 123, height: 256),
            pencils: Self.violetPencils(), into: &pencils
        )
        container.addSublayer(violetGroup)

        applyColors()
        restartAnimationsIfNeeded()
    }

    /// A mask layer clipped to one side of the seam, holding that side's
    /// pencil strokes. Mask coverage is alpha-based, so opaque strokes
    /// reveal the fill wherever they've painted.
    private static func makeMask(
        clip: CGRect, pencils specs: [Pencil], into registry: inout [CAShapeLayer]
    ) -> CALayer {
        let mask = CALayer()
        mask.frame = clip
        mask.bounds = clip // keep children in glyph coordinates
        mask.masksToBounds = true
        for spec in specs {
            let pencil = CAShapeLayer()
            pencil.path = spec.path
            pencil.lineWidth = spec.width
            pencil.strokeColor = NSColor.white.cgColor
            pencil.fillColor = nil
            pencil.lineCap = .butt
            pencil.lineJoin = .round
            pencil.strokeStart = 0
            pencil.strokeEnd = 0
            pencil.frame = CGRect(x: 0, y: 0, width: designSize, height: designSize)
            // Stash the choreography on the layer for animation setup.
            pencil.setValue([spec.paint.0, spec.paint.1, spec.erase.0, spec.erase.1],
                            forKey: "loader42.windows")
            pencil.setValue(spec.timing, forKey: "loader42.timing")
            if let clipRect = spec.clip {
                let wrap = CALayer()
                wrap.frame = clipRect
                wrap.bounds = clipRect
                wrap.masksToBounds = true
                wrap.addSublayer(pencil)
                mask.addSublayer(wrap)
            } else {
                mask.addSublayer(pencil)
            }
            registry.append(pencil)
        }
        return mask
    }

    // MARK: Colors

    private func applyColors() {
        let appearance = effectiveAppearance
        var orange = NSColor(srgbRed: 1.0, green: 0.541, blue: 0.239, alpha: 1) // #FF8A3D
        var violet = NSColor(srgbRed: 0.357, green: 0.129, blue: 0.714, alpha: 1) // #5B21B6
        var isDark = false
        appearance.performAsCurrentDrawingAppearance {
            isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
        }
        if isDark {
            orange = NSColor(srgbRed: 1.0, green: 0.627, blue: 0.376, alpha: 1) // #FFA060
            violet = NSColor(srgbRed: 0.478, green: 0.286, blue: 0.882, alpha: 1) // #7A49E1
        }
        if case .mono(let color) = style {
            let mono = NSColor(color)
            orange = mono
            violet = mono
        }
        let shade = NSColor.labelColor.withAlphaComponent(0.14)
        appearance.performAsCurrentDrawingAppearance {
            for layer in shadeLayers { layer.fillColor = shade.cgColor }
            orangeFill.fillColor = orange.cgColor
            for layer in violetFills { layer.fillColor = violet.cgColor }
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    // MARK: Layout

    public override func layout() {
        super.layout()
        let scale = min(bounds.width, bounds.height) / Self.designSize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.position = CGPoint(x: bounds.midX, y: bounds.midY)
        container.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
    }

    // MARK: Animation

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restartAnimationsIfNeeded()
    }

    private func restartAnimationsIfNeeded() {
        guard window != nil else { return }
        if reduceMotion {
            // Static, fully painted mark.
            for pencil in pencils {
                pencil.removeAllAnimations()
                pencil.strokeStart = 0
                pencil.strokeEnd = 1
            }
            return
        }
        // One shared timebase so every limb stays phase-locked.
        let now = container.convertTime(CACurrentMediaTime(), from: nil)
        for pencil in pencils {
            guard
                let windows = pencil.value(forKey: "loader42.windows") as? [Double],
                let timing = pencil.value(forKey: "loader42.timing") as? CAMediaTimingFunction
            else { continue }
            pencil.removeAllAnimations()
            pencil.strokeStart = 0
            pencil.strokeEnd = 0

            // Paint: strokeEnd 0→1 inside the paint window.
            let paint = CAKeyframeAnimation(keyPath: "strokeEnd")
            paint.values = [0, 0, 1, 1]
            paint.keyTimes = [0, NSNumber(value: windows[0]), NSNumber(value: windows[1]), 1]
            paint.timingFunctions = [Self.linearFn, timing, Self.linearFn]
            // Erase: strokeStart 0→1 inside the erase window. Both reset
            // to 0 at the cycle wrap — empty→empty, invisible.
            let erase = CAKeyframeAnimation(keyPath: "strokeStart")
            erase.values = [0, 0, 1, 1]
            erase.keyTimes = [0, NSNumber(value: windows[2]), NSNumber(value: windows[3]), 1]
            erase.timingFunctions = [Self.linearFn, timing, Self.linearFn]

            for (key, anim) in [("loader42.paint", paint), ("loader42.erase", erase)] {
                anim.duration = Self.cycleDuration
                anim.repeatCount = .infinity
                anim.beginTime = now
                anim.isRemovedOnCompletion = false
                pencil.add(anim, forKey: key)
            }
        }
    }
}
