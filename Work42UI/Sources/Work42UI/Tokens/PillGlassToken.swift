// PillGlassToken.swift — the single shared color token for the dictation
// pill family (feat/pill-liquid-glass-look-feel-and-animations).
//
// Lives in Work42UI (not Work42PillUI) so BOTH `Work42PillUI.DictationPill`
// (which already depends on Work42UI) and `Work42UI.PillBirthView` (which
// cannot depend on Work42PillUI — the dependency only runs the other way)
// can reference the exact same value. Before this token, `PillBirthView`
// carried its own independently duplicated near-black literal precisely
// because of that dependency direction, and the two constants had already
// drifted apart once (`Color(white: 0.06)` vs. `Color(white: 0.16)`).
//
// Values were tuned live and confirmed by Yan in the `PillGlassLab` dev
// harness (`app/Sources/PillGlassLab/`): dark mode needed to go UP from the
// shipped 0.16 to 0.30 once rendered as real Liquid Glass instead of an
// opaque fill (0.16 read too faint through actual glass translucency);
// light mode is new — the shipped pill had no light-specific shade at all.

import SwiftUI

public enum PillGlassToken {
    /// The tint's greyscale value for a given appearance — now LIVE-TUNABLE from
    /// Settings (see `PillSurfaceStore`). Read from the nonisolated
    /// `PillSurfaceState` snapshot so it's safe on the draw path; SwiftUI views
    /// observe `PillSurfaceRuntime.shared` to re-render when the user slides.
    public static func tintWhite(for scheme: ColorScheme) -> Double {
        PillSurfaceState.config.tintWhite(for: scheme)
    }

    /// The tint color, fully opaque — pass to `.glassEffect(_:tint:)`.
    public static func tint(for scheme: ColorScheme) -> Color {
        Color(white: tintWhite(for: scheme))
    }

    /// The tint at the pill family's translucency — opacity is the live-tunable,
    /// PER-APPEARANCE `darkTransparency`/`lightTransparency`
    /// unless a caller passes an explicit value.
    public static func fill(for scheme: ColorScheme, opacity: Double? = nil) -> Color {
        tint(for: scheme).opacity(opacity ?? PillSurfaceState.config.transparency(for: scheme))
    }

    /// Icons / text / waveform — light, appearance-independent (pops against
    /// the tint at either shade).
    public static let ink: Color = .white

    /// Hairline stroke on every pill-family surface — appearance-independent.
    public static let hairline: Color = Color.white.opacity(0.12)
}
