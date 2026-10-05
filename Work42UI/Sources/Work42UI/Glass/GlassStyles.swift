// GlassStyles.swift - Liquid-Glass view modifiers + button styles
// with graceful fallbacks for macOS 14 / 15.
//
// macOS 26 ("Tahoe") introduced the Liquid Glass design system in
// SwiftUI: `.buttonStyle(.glass)`, `.buttonStyle(.glassProminent)`,
// and the `.glassEffect()` modifier for custom surfaces. We adopt
// those wherever we previously rolled our own capsule + material
// treatments. Older macOS versions get the previous fallback so the
// app still looks polished there.
//
// The wrappers here are availability-gated at the lowest level so
// every callsite can write a single `.glassCard()` or
// `.glassPill()` without scattering `#available` checks through the
// view layer.

import SwiftUI

// MARK: - Buttons

/// Page-primary CTA. Uses the system `.buttonStyle(.glass)` class
/// with a CLEAR background — the brand colour is applied only to
/// the foreground (text + icon), not to a `.tint(...)` that would
/// flood the capsule. This keeps the glass material reading as
/// pure macOS chrome while the colour signals which action is
/// which.
///
/// Older OSes get `.bordered` with a coloured foreground (no
/// tinted fill) so the same "colour lives on text, not on
/// background" rule holds across versions.
struct GlassProminentCapsule: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .controlSize(.extraLarge)
                .buttonStyle(.glass)
                .foregroundStyle(tint)
        } else {
            content
                .controlSize(.large)
                .buttonStyle(.bordered)
                .foregroundStyle(tint)
        }
    }
}

/// Secondary CTA / toolbar action. Same `.buttonStyle(.glass)` as
/// the prominent variant with the same coloured-foreground rule;
/// only the colour changes per call site (cyan vs orange vs
/// magenta) so the CTAs read as siblings differentiated by hue.
struct GlassSubtleCapsule: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .controlSize(.extraLarge)
                .buttonStyle(.glass)
                .foregroundStyle(tint)
        } else {
            content
                .controlSize(.large)
                .buttonStyle(.bordered)
                .foregroundStyle(tint)
        }
    }
}

/// Neutral glass CTA — the SAME `.buttonStyle(.glass)` capsule as
/// `GlassProminentCapsule`/`GlassSubtleCapsule`, but PLAIN: the
/// foreground stays the default primary text/icon colour with NO
/// accent tint. Use for a button that should read as the same
/// component family as the page's primary CTA (matching size + glass
/// material) while signalling a quieter, non-accented action — e.g.
/// the Overview widget's "Plan my day now" / "View planning session"
/// footer action sitting beside the accented New Session button
/// (T-003.26). Older OSes mirror the bordered fallback, also primary.
struct GlassPlainCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .controlSize(.extraLarge)
                .buttonStyle(.glass)
                .foregroundStyle(.primary)
        } else {
            content
                .controlSize(.large)
                .buttonStyle(.bordered)
                .foregroundStyle(.primary)
        }
    }
}

/// Glass icon-only button — matches the size + padding of the
/// system title-bar toolbar buttons (`.buttonStyle(.glass)` with
/// a circular border shape) so toolbar clusters across the app
/// read as one consistent family of medallions.
struct GlassIconButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .frame(minWidth: 18, minHeight: 18)
                .controlSize(.extraLarge)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
        } else {
            content
                .frame(width: 36, height: 36)
                .background(.regularMaterial, in: Circle())
                .overlay(
                    Circle().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                )
                .buttonStyle(.plain)
        }
    }
}

// MARK: - Surfaces

/// Main card surface — overview / events / runs / status / tip /
/// recording-handoff cards. macOS 26+ gets the new `.glassEffect`
/// material so cards pick up live blurring of whatever is behind
/// them; older OSes fall back to `controlBackgroundColor` + a
/// hairline stroke (the previous treatment).
struct GlassCardSurface: ViewModifier {
    var cornerRadius: CGFloat = DT.rPanel

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.clear)
                )
                .glassEffect(
                    .regular,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(DT.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
                )
        }
    }
}

/// Pill / badge surface — meta pills (duration, date, process,
/// timestamp). Always cheap because pills appear in dense clusters
/// (a 20-card grid carries 60+ meta pills) and glass on each one
/// pushed the compositor past 60fps.
struct GlassPillSurface: ViewModifier {
    /// Optional tint. Drives the capsule's fill + border opacity.
    /// Nil = neutral material-ish.
    var tint: Color?

    func body(content: Content) -> some View {
        content
            .background(
                Capsule().fill((tint ?? .primary).opacity(tint == nil ? 0.06 : 0.85))
            )
            .overlay(
                Capsule()
                    .strokeBorder((tint ?? .primary).opacity(tint == nil ? 0.10 : 0.35), lineWidth: 0.5)
            )
    }
}

/// Showcase pill — uses Liquid Glass on macOS 26+ with a TINT so
/// the surface reads as "polished material" rather than "ghostly
/// pure transparency". Reserved for the few high-impact spots
/// where one pill per card is OK (DRAFT, phase badge, byline pills
/// on the detail hero). Falls back to a tinted capsule on older
/// OSes.
///
/// Cost note: this calls `.glassEffect()` per instance, so DON'T
/// use it for meta pills or anything that renders 10+ times on a
/// page. For dense usage stick with `.glassPillSurface`.
struct GlassShowcasePillSurface: ViewModifier {
    /// Tint. Required because tinted glass is less transparent than
    /// `.regular` glass and reads as more solid. Pass a brand colour
    /// for "owned" pills (DRAFT) or `.secondary` for neutral chrome.
    let tint: Color

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(tint), in: Capsule())
        } else {
            content
                .background(Capsule().fill(tint.opacity(0.85)))
                .overlay(
                    Capsule().strokeBorder(tint.opacity(0.45), lineWidth: 0.5)
                )
        }
    }
}

/// Capsule glass medallion *surface* — the neutral, untinted
/// counterpart to `GlassShowcasePillSurface` (which carries a tint).
/// A clear Liquid-Glass capsule sized by its content, applied BEHIND
/// a pill's content (HStack with padding) rather than as a button
/// style. Use for compact neutral capsule chips that keep their own
/// `.contentShape(Capsule())` + menu/button styling — e.g. the chat
/// composer's model + mode selector pills. On macOS 26 the chip is
/// real `.glassEffect(.regular)` in a `Capsule()`; older OSes fall
/// back to a thin-material capsule with a hairline stroke so the pill
/// still reads as a tappable chip.
struct GlassCapsuleSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
                .background { Capsule().fill(.thinMaterial) }
                .overlay { Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5) }
        }
    }
}

// MARK: - Convenience entry points

public extension View {
    /// Apply prominent glass styling to a button (or button-like
    /// view). Use for the page's primary CTA.
    func glassProminentCapsule(tint: Color) -> some View {
        modifier(GlassProminentCapsule(tint: tint))
    }

    /// Subtle glass button — secondary CTAs, toolbar actions.
    func glassSubtleCapsule(tint: Color) -> some View {
        modifier(GlassSubtleCapsule(tint: tint))
    }

    /// Neutral glass button — the same glass capsule as the prominent /
    /// subtle CTAs but with the default primary foreground and NO accent
    /// tint. Use when a button should read as the same component family
    /// as the primary CTA while staying visually quiet.
    func glassPlainCapsule() -> some View {
        modifier(GlassPlainCapsule())
    }

    /// Compact glass icon button — back chevron, copy buttons.
    func glassIconButton() -> some View {
        modifier(GlassIconButton())
    }

    /// Card-shaped glass surface for the page's content sections.
    func glassCardSurface(cornerRadius: CGFloat = DT.rPanel) -> some View {
        modifier(GlassCardSurface(cornerRadius: cornerRadius))
    }

    /// Pill / badge glass surface — apply AFTER you've laid out the
    /// pill's content (HStack with padding). Cheap path; safe to
    /// repeat dozens of times on a single page.
    func glassPillSurface(tint: Color? = nil) -> some View {
        modifier(GlassPillSurface(tint: tint))
    }

    /// Showcase pill — real Liquid Glass with a tint on macOS 26+.
    /// Use sparingly (DRAFT pill, phase badge, hero byline pills);
    /// avoid for anything that renders 10+ times on a page.
    func glassShowcasePillSurface(tint: Color) -> some View {
        modifier(GlassShowcasePillSurface(tint: tint))
    }

    /// Capsule glass surface — the neutral, untinted counterpart to
    /// `glassShowcasePillSurface(tint:)`. Apply BEHIND a pill's content
    /// (HStack with padding) for compact neutral capsule chips like the
    /// chat composer's model + mode selector pills.
    func glassCapsuleSurface() -> some View {
        modifier(GlassCapsuleSurface())
    }
}
