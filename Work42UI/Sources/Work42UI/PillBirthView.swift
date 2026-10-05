// PillBirthView.swift — the system-owned, content-agnostic BIRTH animation for
// a `PillAccessory`. A single `progress` (0→1) drives the whole gesture, and
// because the view is `Animatable` on `progress` it interpolates AND reverses
// cleanly (1→0) for dismissal.
//
// The MOTION is a 1:1 port of the LOCKED sandbox (Yan-approved 2026-09-02; the
// `pill-system` Birth Lab + memory `pill-accessory-design-system`): the pill
// squash-stretches (push), a capillary pinch-off drip emerges from it, and the
// pinched-off surface grows to the accessory's fixed size; content reveals last.
//
// Rendering (feat/pill-liquid-glass-look-feel-and-animations): the bottom
// pill and the emerging top shape are two REAL Liquid Glass shapes merged by
// `GlassEffectContainer` + `glassEffectID` — the liquid necking during the
// pinch-off IS the system's own glass blending, wide during the capillary
// thread and collapsing during the snap. The top shape's corners continuously
// resolve from a capsule into the accessory radius; only content overlays the
// glass. The old Canvas alphaThreshold+blur metaball was deleted outright —
// pre-macOS-26 (where `.glassEffect` doesn't exist and the pill feature never
// ships anyway) renders minimal crisp fills purely so this file compiles
// against Work42UI's macOS 15 deployment target.

import Foundation
import SwiftUI

public enum PillBirthDebugMode: Equatable, Sendable {
    case normal
    case layers
}

// MARK: - Locked constants (motion; do not retune without re-locking the Lab)

public enum PillBirthGeom {
    // Bottom pill: FIXED idle size + a push target it interpolates to, then back.
    // idleW/idleH MUST equal the live menu pill's idle nub (`Work42PillUI`'s
    // `DictationPill` idle width 46 / `Mitosis.nubW = 46`, height 10) — this is
    // the nub the birth reverses to and hands off to the live pill. They drifted
    // (52 vs 46), so the reverse landed a hair WIDER than the live pill it handed
    // to, reading as "the idle state comes back slightly different." Keep them
    // identical so every idle end-state is pixel-for-pixel the same nub. (This
    // module can't import Work42PillUI — the dependency runs the other way — so
    // the value is mirrored here, same as PillGlassToken.)
    static let idleW: CGFloat = 46, idleH: CGFloat = 10
    static let pushW: CGFloat = 60, pushH: CGFloat = 14
    static let pushStart = 0.10, pushPeak = 0.28, pushBack = 0.61
    // Capillary pinch (top).
    static let pinchW: CGFloat = 34, pinchH: CGFloat = 59
    static let neck: CGFloat = 0, reach: CGFloat = 26
    static let seedShare = 0.07, elongDamp = 0.29
    // Phase windows.
    static let pinchStart = 0.15, pinchLen = 0.50
    static let growStart = 0.58, growLen = 0.13
    static let contentStart = 0.86
    static let cardCorner: CGFloat = 20
    // Timing.
    static let durBase = 0.66, durScale = 0.24
    // Layout.
    static let gap: CGFloat = 18
    static let nubH: CGFloat = 10
    static let sideMargin: CGFloat = 60   // goo bleed L/R
    static let topMargin: CGFloat = 60    // goo bleed above the accessory
    // The real pill centre is 35pt above the visible-frame bottom. Keeping that
    // full space inside the panel prevents the goo kernel from being clipped.
    static let bottomMargin: CGFloat = 35

    static var neckStart: Double { pinchStart + 0.30 * pinchLen }

    public static func duration(forHeight h: CGFloat) -> Double {
        durBase + Double(h) / 210.0 * durScale
    }

    /// The full stage the birth renders into for a given accessory size. The pill
    /// sits `bottomMargin` above the window's bottom edge; the accessory grows up.
    public static func stageSize(for target: CGSize) -> CGSize {
        let w = target.width + 2 * sideMargin
        let h = topMargin + target.height + gap + nubH / 2 + bottomMargin
        return CGSize(width: w, height: h)
    }

    /// The pill centre sits this far above the window's BOTTOM edge — the host
    /// anchors the window bottom at `livePillCenterY - this` (kept small so the
    /// window never extends off the screen bottom and gets bumped up by macOS).
    public static var pillCenterFromWindowBottom: CGFloat { bottomMargin }

    /// The rectangle (in WINDOW-BASE coords — bottom-left origin, matching
    /// `NSWindow.convertPoint(fromScreen:)`) that the accessory's actually-
    /// VISIBLE assembly occupies: the pill + gap + card, centered. Everything
    /// outside it — the `sideMargin`/`topMargin` goo-bleed that renders
    /// nothing — is empty and should be click-through (bug/pill-push-to-talk
    /// dogfooding: "absorb ONLY the elements that are visible"). Used by
    /// `PillClickThrough` to toggle `ignoresMouseEvents`. Geometry (not pixel
    /// alpha or `hitTest`) because those proved unreliable here: `cacheDisplay`
    /// can't see SwiftUI `Canvas`/material layers, and `NSHostingView.hitTest`
    /// claims every in-bounds point. A small inset is added for shadow/
    /// antialiasing slop.
    public static func accessoryInteractiveRect(for target: CGSize) -> CGRect {
        let stage = stageSize(for: target)
        let slop: CGFloat = 8
        // The card's bottom edge sits this far above the window bottom (the
        // pill lives below it, in the gap): pillCentre + half the nub + gap.
        let cardBottomFromWindowBottom = bottomMargin + nubH / 2 + gap
        let width = target.width + 2 * slop
        // From the window bottom (y = 0, covers the pill) up to the card's top.
        let height = cardBottomFromWindowBottom + target.height + slop
        return CGRect(x: (stage.width - width) / 2, y: 0, width: width, height: height)
    }
}

// MARK: - Curves (identical to the shipped Swift + the Birth Lab)

enum PillBirthCurves {
    static func clampd(_ x: Double) -> Double { min(1, max(0, x)) }
    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
    static func smoothstep(_ x: Double) -> Double { let t = clampd(x); return t * t * (3 - 2 * t) }
    static func settle(_ x: Double) -> Double {
        if x <= 0 { return 0 }; if x >= 1 { return 1 }
        return x * x * x * (x * (x * 6 - 15) + 10)
    }
    static func springB(_ x: Double) -> Double {
        if x <= 0 { return 0 }; if x >= 1 { return 1 }
        let z = 0.6, w = 9.2, wd = w * (1 - z * z).squareRoot()
        return 1 - exp(-z * w * x) * (cos(wd * x) + (z * w / wd) * sin(wd * x))
    }
    static func profile(_ t: Double, W: Double, neck: Double, reach: Double) -> (sx: Double, sy: Double, dist: Double) {
        var g = 0.0, sx = 0.0, sy = 0.0
        if t < 0.30 {
            let u = t / 0.30, e = u * u
            g = -W * (1 - e); sx = 1 + 0.05 * e; sy = 1 - 0.03 * e
        } else if t < 0.58 {
            let u = (t - 0.30) / 0.28
            g = neck * u; sx = 1.05 + 0.14 * u; sy = 0.97 - 0.11 * u
        } else {
            let u = (t - 0.58) / 0.42
            let approach = 1 - pow(1 - u, 3), decay = exp(-5 * u), wob = exp(-6 * u) * sin(13 * u)
            g = neck + (reach - neck) * approach
            sx = 1 + 0.19 * decay - 0.16 * wob
            sy = 1 - 0.14 * decay + 0.16 * wob
        }
        return (sx, sy, g + W * sx)
    }
    static func pushSize(_ te: Double) -> (w: CGFloat, h: CGFloat) {
        let iw = PillBirthGeom.idleW, ih = PillBirthGeom.idleH
        let pw = PillBirthGeom.pushW, ph = PillBirthGeom.pushH
        let t0 = PillBirthGeom.pushStart, tp = PillBirthGeom.pushPeak, tb = PillBirthGeom.pushBack
        if te <= t0 || tb <= t0 { return (iw, ih) }
        if te < tp {
            let u = settle((te - t0) / max(0.001, tp - t0))
            return (lerp(iw, pw, u), lerp(ih, ph, u))
        }
        if te < tb {
            let v = springB((te - tp) / max(0.001, tb - tp))
            return (lerp(pw, iw, v), lerp(ph, ih, v))
        }
        return (iw, ih)
    }
}

// MARK: - The birth view

public struct PillBirthView<Content: View>: View, Animatable {
    public var progress: Double
    private let targetSize: CGSize
    private let debugMode: PillBirthDebugMode
    private let showBottomPill: Bool
    /// The birth surface's fill color — content-agnostic by design (this view
    /// has no opinion on WHO is being born), so a caller supplies its own
    /// theme instead of the view guessing from system appearance. Defaults to
    /// `PillGlassToken.fill(for:)` — the SAME shared token
    /// `Work42PillUI.DictationPill`'s `pillFill` resolves (this module can't
    /// import `Work42PillUI` — the dependency runs the other way — but both
    /// now reference the one token that lives here in `Work42UI` instead of
    /// each carrying its own literal, which is exactly how the two drifted
    /// apart before: `white: 0.16` there vs. `white: 0.06` here).
    private let pillColor: Color
    /// The `colorScheme` `content()` renders under — independent of
    /// `pillColor` ("accessories can do their own colors") so a caller with
    /// a light `pillColor` can still get dark-on-light content. Defaults to
    /// `.dark` to match the default black `pillColor` (light content reads
    /// on a dark fill).
    private let contentColorScheme: ColorScheme
    /// Whether the "solid" surface style is active — an always-active vibrancy
    /// floor sits behind the glass so the accessory holds its tint off-focus.
    /// Passed in as an EXPLICIT input (not read internally from `PillSurfaceState`)
    /// so a Settings change flips this prop and SwiftUI is guaranteed to re-render
    /// this view; reading the config internally let SwiftUI skip re-evaluating the
    /// body when only the config changed (its `progress`/size inputs were unchanged).
    private let solidSurface: Bool
    private let content: () -> Content
    /// Stable identity for `GlassEffectContainer`'s `glassEffectID` merging
    /// between the nub and the emerging card (macOS 26+ only; unused on the
    /// pre-26 Canvas fallback path).
    @Namespace private var ns

    public init(
        progress: Double,
        targetSize: CGSize,
        debugMode: PillBirthDebugMode = .normal,
        showBottomPill: Bool = true,
        pillColor: Color = PillGlassToken.fill(for: .dark),
        contentColorScheme: ColorScheme = .dark,
        solidSurface: Bool = PillSurfaceState.config.isSolid,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.progress = progress
        self.targetSize = targetSize
        self.debugMode = debugMode
        // Once the accessory has settled, the HOST can take the base pill back over
        // as a live, interactive nub (hover → capabilities). Passing false then
        // stops the birth from drawing its own (non-interactive) bottom pill so the
        // two never overlap or peek through a split.
        self.showBottomPill = showBottomPill
        self.pillColor = pillColor
        self.contentColorScheme = contentColorScheme
        self.solidSurface = solidSurface
        self.content = content
    }

    public var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    private var w: CGFloat { targetSize.width }
    private var h: CGFloat { targetSize.height }
    private var stageW: CGFloat { w + 2 * PillBirthGeom.sideMargin }
    private var stageH: CGFloat { PillBirthGeom.topMargin + h + PillBirthGeom.gap + PillBirthGeom.nubH / 2 + PillBirthGeom.bottomMargin }
    private var pillCy: CGFloat { stageH - PillBirthGeom.bottomMargin }
    /// The hard floor for the accessory's CONTENT layer — bug/pill-push-
    /// to-talk dogfooding: "the accessory cannot go lower [than] the
    /// bottom of the pill... whatever pixel we're using for padding, that
    /// should be position 0 for them... they render from there to the
    /// top... they cannot access the lower [space]." Content is
    /// bottom-anchored AT this Y (see `body`'s `.frame(alignment: .bottom)`
    /// below) — its bottom edge coincides with this line no matter how
    /// tall the content naturally wants to be, so growth can ONLY ever
    /// extend upward, never down into the gap/pill zone below.
    private var bottomAnchorY: CGFloat { pillCy - PillBirthGeom.nubH / 2 - PillBirthGeom.gap }

    public var body: some View {
        let C = PillBirthCurves.self
        let P = PillBirthGeom.self
        let te = progress

        // Motion (1:1 with the locked renderBirthRefined) — shared by both
        // the native-glass and legacy-Canvas render paths below; only the
        // SURFACE technique differs, never this math.
        let ps = C.pushSize(te)
        let growP = C.settle(C.clampd((te - P.growStart) / P.growLen))
        let contentP = C.settle(C.clampd((te - P.contentStart) / max(0.02, 1 - P.contentStart)))
        let pinchT = C.clampd((te - P.pinchStart) / P.pinchLen)
        let pr = C.profile(pinchT, W: Double(P.pinchH), neck: Double(P.neck), reach: Double(P.reach))
        let elong = 1 + (pr.sx - 1) * P.elongDamp
        let seedW = Double(P.pinchW) * pr.sy
        let seedH = Double(P.pinchH) * elong
        let emerge = C.smoothstep(C.clampd((te - P.neckStart) / max(0.02, P.growStart - P.neckStart)))
        let lift = pr.dist * P.seedShare * emerge
        let curW = C.lerp(CGFloat(seedW * emerge), w, growP)
        let curH = C.lerp(CGFloat(seedH * emerge), h, growP)
        let aBottom = C.lerp(pillCy - CGFloat(lift), bottomAnchorY, growP)
        let accCy = aBottom - curH / 2
        let capsuleCorner = min(curW, curH) / 2
        let topCorner = min(capsuleCorner, C.lerp(capsuleCorner, P.cardCorner, growP))

        if #available(macOS 26.0, *) {
            nativeGlassBody(ps: ps, curW: curW, curH: curH, accCy: accCy, topCorner: topCorner, growP: growP, contentP: contentP)
        } else {
            legacyCrispBody(ps: ps, curW: curW, curH: curH, accCy: accCy, topCorner: topCorner, contentP: contentP)
        }
    }

    // MARK: - Native Liquid Glass (macOS 26+)

    /// Ported 1:1 from the confirmed `PillBirthDemo` in `PillGlassLab`: the
    /// nub and the emerging card are two REAL glass shapes merged by
    /// `GlassEffectContainer`, not a Canvas metaball. The blend distance
    /// mirrors the legacy path's blur-fade window (`growP` 0.45→0.9): wide
    /// while the capillary thread is still stretching (one bridging liquid
    /// mass), collapsing as the snap-grow completes so the resting state is
    /// two crisp, fully separated glass pieces. Content stays an
    /// INDEPENDENT overlay exactly as before — never clipped to the card's
    /// animating bounds, so a live resize can still reveal overflow via the
    /// real window growing (see the doc comment on the content layer below).
    @available(macOS 26.0, *)
    @ViewBuilder
    private func nativeGlassBody(
        ps: (w: CGFloat, h: CGFloat), curW: CGFloat, curH: CGFloat, accCy: CGFloat,
        topCorner: CGFloat, growP: Double, contentP: Double
    ) -> some View {
        let bridgeStrength = 1 - PillBirthCurves.smoothstep((growP - 0.45) / 0.45)
        let spacing = PillBirthCurves.lerp(6, 70, bridgeStrength)
        let blobs: [PillGooBlob] = {
            var result: [PillGooBlob] = []
            if showBottomPill {
                result.append(PillGooBlob(
                    rect: CGRect(x: stageW / 2 - ps.w / 2, y: pillCy - ps.h / 2, width: ps.w, height: ps.h),
                    cornerRadius: min(ps.w, ps.h) / 2))
            }
            if curW > 0.75, curH > 0.75 {
                result.append(PillGooBlob(
                    rect: CGRect(x: stageW / 2 - curW / 2, y: accCy - curH / 2, width: curW, height: curH),
                    cornerRadius: topCorner))
            }
            return result
        }()

        ZStack(alignment: .topLeading) {
            // "Solid" style: the vibrancy + tint surface IS the render — the
            // glass container below is NOT drawn at all in this style. A floor
            // behind the glass was tried and failed on-device: inactive Liquid
            // Glass composites its own brighter frost IN FRONT of anything
            // behind it, so any stack that still includes glass shifts with
            // focus. Every layer here renders identically regardless of window
            // key / app active state. (Trade-off: no liquid neck merge between
            // nub and card during the birth — geometry still animates.)
            if solidSurface {
                // ONE union-masked surface for nub + card (not two stacked
                // translucent shapes — overlaps would compound the alpha and
                // read as separate pills while the seed emerges from the nub).
                // The blur+threshold necking mirrors the glass container's
                // liquid bridge (strongest while bridging, crisp at rest —
                // same 4.5 kernel the pre-glass Canvas goo used).
                PillGooSolidSurface(
                    tint: pillColor,
                    goo: 4.5 * CGFloat(bridgeStrength),
                    blobs: blobs
                )
                .frame(width: stageW, height: stageH)
                .allowsHitTesting(false)
            } else {
                GlassEffectContainer(spacing: spacing) {
                    ZStack {
                        if showBottomPill {
                            Color.clear
                                .frame(width: ps.w, height: ps.h)
                                .glassEffect(.regular.tint(pillColor), in: Capsule(style: .continuous))
                                .glassEffectID("birth-nub", in: ns)
                                .position(x: stageW / 2, y: pillCy)
                        }

                        // Genuinely ABSENT below a hair's-width — a degenerate
                        // near-zero shape handed to `.glassEffect` merges with
                        // mismatched corner styling against the nub's capsule,
                        // producing a jagged/scalloped blob at rest (found live
                        // in the PillGlassLab tuning session).
                        if curW > 0.75, curH > 0.75 {
                            Color.clear
                                .frame(width: curW, height: curH)
                                .glassEffect(.regular.tint(pillColor), in: RoundedRectangle(cornerRadius: topCorner, style: .continuous))
                                .glassEffectID("birth-card", in: ns)
                                .position(x: stageW / 2, y: accCy)
                        }
                    }
                }
                .frame(width: stageW, height: stageH)
                .allowsHitTesting(false)
                PillGooTintOverlay(
                    tint: pillColor,
                    goo: 4.5 * CGFloat(bridgeStrength),
                    blobs: blobs
                )
            }

            if debugMode == .layers {
                if showBottomPill {
                    Capsule(style: .continuous)
                        .stroke(.red, lineWidth: 1)
                        .frame(width: ps.w, height: ps.h)
                        .position(x: stageW / 2, y: pillCy)
                }
                RoundedRectangle(cornerRadius: topCorner, style: .continuous)
                    .stroke(.green, lineWidth: 1)
                    .frame(width: max(0, curW), height: max(0, curH))
                    .position(x: stageW / 2, y: accCy)
            }

            contentOverlay(contentP: contentP)
        }
        .frame(width: stageW, height: stageH)
    }

    // MARK: - Pre-macOS-26 fallback (no `.glassEffect` available)

    /// Minimal crisp fill-based render — NO goo. The pill feature is gated
    /// macOS 26+ (see the project QA guide), so in practice this path never
    /// ships; it exists only so this file compiles against Work42UI's
    /// macOS 15 deployment target. The old Canvas alphaThreshold+blur
    /// metaball was deleted outright per feat/pill-liquid-glass-look-feel-
    /// and-animations — the native GlassEffectContainer morph above is THE
    /// birth animation, with no legacy effect left to accidentally render.
    private func legacyCrispBody(
        ps: (w: CGFloat, h: CGFloat), curW: CGFloat, curH: CGFloat, accCy: CGFloat,
        topCorner: CGFloat, contentP: Double
    ) -> some View {
        ZStack(alignment: .topLeading) {
            if showBottomPill {
                Capsule(style: .continuous)
                    .fill(pillColor)
                    .frame(width: ps.w, height: ps.h)
                    .position(x: stageW / 2, y: pillCy)
                    .allowsHitTesting(false)
            }
            if curW > 0.75, curH > 0.75 {
                RoundedRectangle(cornerRadius: topCorner, style: .continuous)
                    .fill(pillColor)
                    .frame(width: curW, height: curH)
                    .position(x: stageW / 2, y: accCy)
                    .allowsHitTesting(false)
            }
            contentOverlay(contentP: contentP)
        }
        .frame(width: stageW, height: stageH)
    }

    // MARK: - Content (shared by both render paths)

    /// Scales up from the bottom and fades in only after the shape layer has
    /// resolved to the final card. Bottom-anchored, NOT center-positioned-
    /// and-clipped (bug/pill-push-to-talk dogfooding correction: a symmetric
    /// `.frame(height:).clipped()` around a CENTER point hard-cut BOTH the
    /// excess top AND the excess bottom whenever the content's natural size
    /// briefly exceeded `h` — visibly jarring, and it still let half the
    /// overflow bleed downward before the clip caught it. Bottom-alignment
    /// makes downward growth structurally impossible instead of merely
    /// clipping it after the fact: the outer `.frame(alignment: .bottom)`
    /// pins the content's bottom edge to `bottomAnchorY` regardless of its
    /// actual height, so ANY extra height can only extend upward. No top
    /// clip either — content is free to render past the CURRENT window
    /// bounds while a live resize is catching up; the real AppKit window
    /// edge (not an artificial SwiftUI clip) is what naturally, smoothly
    /// reveals it as the window grows, rather than presenting a sudden cut
    /// the instant a new target size lands. Deliberately an INDEPENDENT
    /// overlay, not nested inside the glass/goo card's own animating frame —
    /// preserved unchanged across both render paths.
    private func contentOverlay(contentP: Double) -> some View {
        content()
            .environment(\.colorScheme, contentColorScheme)
            .frame(width: w)
            .scaleEffect(PillBirthCurves.lerp(0.94, 1, contentP), anchor: .bottom)
            .opacity(contentP)
            .allowsHitTesting(progress > 0.98)
            .frame(width: stageW, height: bottomAnchorY, alignment: .bottom)
    }
}
