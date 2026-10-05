// DesignTokens.swift - The single source of truth for spacing, radii,
// typography, animations, and color across both apps.
//
// Lives in Flow42Core because both Flow42Menu (the floating panel +
// recording overlays) and Flow42App (the main window) consume them.
// One place to edit the visual language.
//
// Naming: short for legibility at call sites — `DT.s12`, `DT.rCard`,
// `DT.aMode`. Long names like `Tokens.spacingMedium` get noisy.
//
// Light/dark colors: each color is built from hand-tuned light + dark
// hex pairs via `NSColor(name:dynamicProvider:)`. We do NOT directly
// invert RGB values for dark mode — accents stay the same hue, only
// luminance shifts to keep them readable in both contexts.
//
// Theme-aware tokens (feat/theme-customization.8):
// The themable color tokens (`backdrop`, `surface`, `elevated`, `sidebar`,
// `titlebar`, `textPrimary`, `textSecondary`, `textTertiary`, `systemAccent`)
// are `static var` computed properties whose `NSColor(name:nil,dynamicProvider:)`
// closures read `ThemeRuntime.current` on every draw pass, so a theme
// switch re-resolves every surface token without any call-site changes.
// Non-themable tokens (status: green/red/amber; brand: orange/magenta/cyan)
// remain `static let` adaptive pairs — they carry fixed semantic meaning.

import AppKit
import SwiftUI

public enum DT {

    // MARK: - Spacing (4-pt grid)

    public static let s4: CGFloat = 4    // tight icon gaps
    public static let s8: CGFloat = 8    // chip / compact row gaps
    public static let s12: CGFloat = 12  // row internal padding
    public static let s16: CGFloat = 16  // group spacing
    public static let s20: CGFloat = 20  // panel edge padding
    public static let s24: CGFloat = 24  // section internal
    public static let s32: CGFloat = 32  // header → content
    public static let s40: CGFloat = 40  // major sections

    // MARK: - Chip tokens

    public static let chipPadV: CGFloat = 3
    public static let chipPadH: CGFloat = 8
    public static let chipFill: Color = Color.primary.opacity(0.06)
    public static let chipFillSubtle: Color = Color.primary.opacity(0.05)
    public static let chipStroke: Color = Color.primary.opacity(0.08)

    // MARK: - Corner radii
    //
    // 10/8/6/4 hierarchy from the macOS-design discipline:
    // windows/panels > cards > buttons > inputs.

    public static let rWindow: CGFloat = 10
    public static let rPanel: CGFloat = 12   // glass panels feel slightly softer
    public static let rCard: CGFloat = 8
    public static let rButton: CGFloat = 6
    public static let rInput: CGFloat = 4
    public static let rPill: CGFloat = 999   // capsule

    // MARK: - Type scale

    // Type scale bumped +2 across the board (was +1; the additional
    // +1 brings body to 15pt for better legibility at typical macOS
    // viewing distances). Token NAMES kept identical for back-compat
    // across hundreds of call sites — only the values shift.
    public static let f9: CGFloat = 11    // micro-eyebrow / count badges
    public static let f10: CGFloat = 12   // eyebrow
    public static let f11: CGFloat = 13   // caption
    public static let f12: CGFloat = 14   // small body
    public static let f13: CGFloat = 15   // body
    public static let f14: CGFloat = 16   // body emphasis
    public static let f15: CGFloat = 17   // subtitle
    public static let f17: CGFloat = 19   // section title
    public static let f22: CGFloat = 24   // page title
    public static let f30: CGFloat = 32   // display
    public static let f32: CGFloat = 34   // hero

    // MARK: - Animation curves

    /// Hover, press, light feedback. Snappy, not springy.
    public static let aHover = Animation.easeOut(duration: 0.12)
    /// Mode swaps: panel chat-only ↔ compact, card expand, segmented
    /// control crossfade. The "default" curve.
    public static let aMode = Animation.easeInOut(duration: 0.18)
    /// Larger entrances: window appears, dock slides in, palette opens.
    public static let aEntrance = Animation.easeInOut(duration: 0.24)

    // MARK: - Brand palette
    //
    // The THREE canonical Flow42 colors are the ones the edge-glow
    // overlay uses to signal session state. Treat them as the app's
    // primary palette; reach for them before any system gray. Each one
    // ties to a specific user mental model:
    //
    //   ORANGE   — driving (agent in control of the screen)
    //   MAGENTA  — recording (we're capturing user actions)
    //   CYAN     — watching (user is in control / guide-me mode)
    //
    // Each brand color has three gradient stops (`core` / `mid` /
    // `edge`) so we can build proper depth — light center, mid body,
    // dark fringe — instead of flat fills. Use the `Gradient(stops:)`
    // helpers below to build glowing pills, hero backdrops, etc.

    /// Default accent for chrome, chips, hairlines, button tints, and
    /// every "click me" affordance across the main app.
    ///
    /// For the built-in System palette (`accent: .system`), this follows
    /// `NSColor.controlAccentColor` — the color the user picked in
    /// System Settings → Appearance → Accent — matching the rest of
    /// macOS instead of imposing a brand violet.
    ///
    /// For custom palettes (Ocean, Sunset, user themes), this returns
    /// the theme's pinned accent hex, resolved dynamically per light/dark
    /// mode from `ThemeRuntime.current`.
    ///
    /// The hand-tuned violet that previously lived here remains in the
    /// `magentaCore/Mid/Edge` gradient triplet below — those are
    /// reserved for state-signal visuals (recording edge-glow, menu-bar
    /// orb) where the brand identity carries a specific meaning.
    public static var systemAccent: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            let snap = ThemeRuntime.current
            let tokens = isDark ? snap.spec.dark : snap.spec.light
            switch tokens.accent {
            case .system:   return NSColor.controlAccentColor
            case .hex(let h): return NSColor(hexString: h)
            }
        })
    }
    /// Orange — driving / agent in control. Used when the agent is
    /// actively touching the screen.
    public static let orange  = adaptive(light: 0xFF8A3D, dark: 0xFFA060)
    /// Cyan — watching / guide-me / user-in-control. Calm interaction.
    public static let cyan    = adaptive(light: 0x3DB6FF, dark: 0x66C8FF)

    // Brand gradient stops (core / mid / edge) — same triplet pattern
    // OrbStateTokens already uses for the menu-bar orb, lifted into the
    // shared design system so both apps draw on the same well.

    public static let magentaCore = adaptive(light: 0xC4B5FD, dark: 0xD8C7FF)
    /// Hardcoded violet (the value `DT.systemAccent` used to hold). Lives
    /// on as the middle stop of the brand gradient so the menu-bar
    /// orb + recording edge-glow keep their identity even though the
    /// generic `magenta` accent now follows the system accent color.
    public static let magentaMid  = adaptive(light: 0x7C3AED, dark: 0x9D6BFF)
    public static let magentaEdge = adaptive(light: 0x4C1D95, dark: 0x5B21B6)

    public static let orangeCore = adaptive(light: 0xFFD4A8, dark: 0xFFE3C2)
    public static let orangeMid  = orange
    public static let orangeEdge = adaptive(light: 0x7C2D12, dark: 0x9A3A18)

    public static let cyanCore   = adaptive(light: 0xA8E7FF, dark: 0xC2EEFF)
    public static let cyanMid    = cyan
    public static let cyanEdge   = adaptive(light: 0x12527C, dark: 0x1A6796)

    // MARK: - Brand gradients
    //
    // Linear-gradient helpers for the three brand colors. Pass these
    // straight to `.fill(DT.orangeGradient)` etc. The default angle is
    // top-leading → bottom-trailing which feels like light coming from
    // the top-left (matches macOS native conventions).

    public static let orangeGradient = LinearGradient(
        colors: [orangeCore, orangeMid],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    public static let cyanGradient = LinearGradient(
        colors: [cyanCore, cyanMid],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    public static let magentaGradient = LinearGradient(
        colors: [magentaCore, magentaMid],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Three-color sweep across the brand palette (orange → magenta →
    /// cyan). Used for hero backdrops + the app's "everything-at-once"
    /// brand moments (loading-from-empty, splash, the command palette
    /// header).
    public static let brandSweep = LinearGradient(
        colors: [orange, systemAccent, cyan],
        startPoint: .leading,
        endPoint: .trailing
    )

    // MARK: - Status palette (sparingly — reserve real estate for brand)

    public static let green   = adaptive(light: 0x36C85B, dark: 0x4CDB73)
    public static let red     = adaptive(light: 0xFF5C5C, dark: 0xFF7A7A)
    public static let amber   = adaptive(light: 0xFFB640, dark: 0xFFC766)
    /// "Done / complete" green — the deeper light-mode hue used by every
    /// completed-state surface (task status pill, etc.).
    /// The single source so status chips match completed tasks exactly.
    public static let done    = adaptive(light: 0x15803D, dark: 0x4CDB73)

    // Aliases for compatibility — the chat code already uses these
    // names. Maps onto the brand palette where it makes sense.
    public static let blue    = cyan        // chat user bubbles, watching state
    public static let purple  = systemAccent // tool calls (lean into accent)

    // MARK: - Surface palette
    //
    // Darker than macOS defaults in dark mode — the app is meant to
    // feel cinematic / Cursor-Linear-Arc-like rather than pale grey.
    // Five independent tiers (plus sidebar and titlebar) so cards still
    // read as elevated against the page, and the left rail / top chrome
    // can each carry their own distinct surface color.
    //
    // All surface tokens are `static var` computed properties that read
    // `ThemeRuntime.current` inside an `NSColor(name:nil,dynamicProvider:)`
    // closure. The System palette hard-codes the same hex values the old
    // `static let adaptive(...)` calls used, so AC1 (zero visual change
    // on first launch) holds exactly.

    /// L0 — page backdrop. Near-black in dark mode with a faint cool
    /// cast so it doesn't go fully neutral. Light mode keeps a clean
    /// off-white so vibrancy still works behind the chrome.
    public static var backdrop: Color {
        themeColor(\.backdrop)
    }
    /// The collapsible left sidebar rail. System palette defaults to
    /// the same value as `backdrop`, preserving today's single-fill look.
    public static var sidebar: Color {
        themeColor(\.sidebar)
    }
    /// The top chrome / titlebar strip. System palette defaults to
    /// the same value as `backdrop`, preserving today's single-fill look.
    public static var titlebar: Color {
        themeColor(\.titlebar)
    }
    /// L1 — card / surface above the page. ~RGB 26 in dark mode so
    /// cards have a clear elevation read against the backdrop without
    /// looking grey.
    public static var surface: Color {
        themeColor(\.surface)
    }
    /// L2 — popover / interactive surface (input fields, raised
    /// menus). Slightly lifted above L1.
    public static var elevated: Color {
        themeColor(\.elevated)
    }

    // MARK: - Text palette
    //
    // Adaptive text tokens that fix the "too-grey" problem the
    // SwiftUI defaults (`.secondary`, `.tertiary`) produce in light
    // mode. Apple's secondary on a white backdrop is ~60% black,
    // tertiary is ~25% — at body font sizes that fails WCAG AA on
    // anything but the largest text. These tokens push the
    // luminance contrast back up to roughly 7:1 / 4.5:1 in light
    // mode while staying close to the system defaults in dark
    // mode (dark backgrounds already give plenty of contrast at
    // those lighter grays).

    /// Primary text — body labels, list rows, headings. Near-black
    /// on light, near-white on dark.
    public static var textPrimary: Color {
        themeColor(\.textPrimary)
    }
    /// Secondary text — supporting labels, inactive list rows,
    /// breadcrumbs, "N tasks" subtitles. Distinctly darker than
    /// Apple's `.secondary` in light mode.
    public static var textSecondary: Color {
        themeColor(\.textSecondary)
    }
    /// Tertiary text — section eyebrows ("WORKSPACE"),
    /// least-important metadata, placeholders. Brighter than
    /// `textSecondary` but still passes AA at 13pt+ on light.
    public static var textTertiary: Color {
        themeColor(\.textTertiary)
    }

    // MARK: - Contrast helpers
    //
    // Anywhere chrome paints text on a colored fill (accent
    // capsules, badges, brand buttons) the foreground choice
    // shouldn't be eyeballed — it should fall out of WCAG
    // luminance math. Use these instead of hardcoding
    // `.white` / `.black` / `.primary` for on-color text.

    /// WCAG relative luminance (Rec. 709) for an NSColor. 0 = black,
    /// 1 = white. Used to decide whether the foreground should be
    /// light or dark on top of a given background.
    public static func relativeLuminance(of color: NSColor) -> Double {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        func channel(_ c: CGFloat) -> Double {
            let v = Double(c)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let r = channel(resolved.redComponent)
        let g = channel(resolved.greenComponent)
        let b = channel(resolved.blueComponent)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// THE single foreground-contrast primitive: pure black or pure white,
    /// whichever has the higher WCAG contrast ratio against `background`.
    ///
    /// This is a **pure function of the background's own luminance** — the ONLY
    /// input Yan's rule allows. It takes a concrete, already-resolved sRGB
    /// NSColor and does plain arithmetic: no appearance argument, no drawing
    /// context, no dynamic `NSColor(name:)` provider. That is deliberate. The
    /// old `contrastingForeground` wrapped this decision in a dynamic provider
    /// that AppKit/SwiftUI re-resolved against whatever drawing appearance was
    /// in effect, so a transient appearance during a view/tab transition could
    /// flip a label black↔white even though its background never changed. By
    /// returning a concrete color computed once from the concrete background,
    /// the result is stable across tab switches, focus, and re-mounts.
    ///
    /// Black wins ties (`>=`), matching the standard L ≈ 0.179 crossover.
    public static func foreground(on background: NSColor) -> Color {
        let l = relativeLuminance(of: background)
        let contrastVsWhite = 1.05 / (l + 0.05)
        let contrastVsBlack = (l + 0.05) / 0.05
        return contrastVsBlack >= contrastVsWhite ? .black : .white
    }

    /// SwiftUI-friendly overload. Resolves the SwiftUI `Color` into its concrete
    /// NSColor **once, eagerly** (at the call site, not inside a dynamic
    /// provider), then decides. The returned color is a plain `.black`/`.white`
    /// that never re-resolves on a later drawing-appearance change.
    public static func foreground(on background: Color) -> Color {
        foreground(on: NSColor(background))
    }

    /// Below this WCAG relative luminance, a tint reads as "black" rather than
    /// a distinguishable hue — GitHub's `#1F2328` (≈0.017) and Codex's
    /// `#1A1A1C` (≈0.011) both fall well under it, ordinary brand/status hues
    /// (oranges, blues, greens, even deep purples) don't.
    private static let nearBlackLuminance = 0.05

    /// THE single resolution rule for the app's translucent own-hue chip
    /// language (`StatusKindLabel`, `HeaderLabelChip`, `HeaderLabelSegment`):
    /// text/icon in the tint's own hue over a translucent fill of that same
    /// hue with a slightly-stronger hairline stroke.
    ///
    /// Both appearances use the same soft `0.16`/`0.24` fill/stroke
    /// treatment. The foreground, rather than a heavier background, provides
    /// the extra light-mode contrast.
    ///
    /// In light mode the foreground is deepened and lightly saturated, rather
    /// than using the raw tint verbatim. This lets an ordinary role hue retain
    /// the rich contrast it has against dark chrome when drawn over a pale
    /// tint. The fill and stroke remain the original hue so the chip's color
    /// identity does not drift.
    ///
    /// That formula reads fine for ordinary hues in both appearances, but a
    /// near-black FIXED brand tint (a hardcoded provider color, a widget's
    /// own brand hex — never derived from the current appearance) collapses
    /// into the dark chrome behind it: near-black text over a near-invisible
    /// near-black fill. Literal black is still correct on a light backdrop,
    /// so light mode is untouched; in dark mode a near-black tint is instead
    /// rendered as a light neutral (white text/mark over a white-tinted fill
    /// + stroke, same dark-mode opacities) so the chip stays legible without
    /// the caller (GitHub, Codex, any future near-black brand) special-casing
    /// itself.
    public static func resolveChipTint(
        _ tint: Color, colorScheme: ColorScheme
    ) -> (fill: Color, foreground: Color, stroke: Color) {
        if colorScheme == .dark {
            if relativeLuminance(of: NSColor(tint)) < nearBlackLuminance {
                return (Color.white.opacity(0.16), .white, Color.white.opacity(0.24))
            }
            return (tint.opacity(0.16), tint, tint.opacity(0.24))
        }
        return (tint.opacity(0.16), lightChipForeground(for: tint), tint.opacity(0.24))
    }

    /// Produces a richer foreground for a role hue on the light appearance's
    /// pale translucent chip fill. This mirrors `accentForeground`'s
    /// light-mode rule: preserve hue, increase saturation slightly, and lower
    /// brightness with a cap that keeps light yellows/cyans from washing out.
    private static func lightChipForeground(for tint: Color) -> Color {
        let raw = NSColor(tint)
        let color = raw.usingColorSpace(.sRGB) ?? raw
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(nsColor: NSColor(
            hue: hue,
            saturation: min(1.0, saturation * 1.12),
            brightness: max(0.0, min(0.62, brightness * 0.72)),
            alpha: alpha
        ))
    }

    /// The ACTIVE THEME's accent as a concrete NSColor for one mode —
    /// the theme's pinned hex, or the live macOS accent when the palette
    /// declares `accent: system` (built-in System palette only). This is
    /// the single accent source for every derived-accent helper below;
    /// deriving from `NSColor.controlAccentColor` directly is a theming
    /// bug (the app would follow the macOS accent even under a custom
    /// theme — observed live as purple chat-bubble text under Ayu).
    public nonisolated static func resolvedAccent(isDark: Bool) -> NSColor {
        let snap = ThemeRuntime.current
        let tokens = isDark ? snap.spec.dark : snap.spec.light
        switch tokens.accent {
        case .system:     return NSColor.controlAccentColor
        case .hex(let h): return NSColor(hexString: h)
        }
    }

    /// Pre-computed readable foreground for `DT.systemAccent` fills.
    /// Chrome that tints itself with the accent (tab pills, primary
    /// CTAs, badges) should bind text and icons to this token so
    /// contrast follows the ACTIVE THEME's accent (which is the macOS
    /// accent under the System palette).
    public static var onAccent: Color {
        // Dynamic ONLY because the accent itself has a light/dark hex pair
        // (`resolvedAccent(isDark:)`) — the appearance selects WHICH accent,
        // then the black/white decision is the same pure-luminance primitive as
        // everywhere else (`foreground(on:)`). This is the sanctioned
        // theme/appearance-follows path: a dark-mode toggle can change the
        // accent (hence its foreground), but nothing about tab/view lifecycle
        // does, so accent chrome does not flicker on tab switches.
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            let accent = resolvedAccent(isDark: isDark)
            let l = relativeLuminance(of: accent)
            return (l + 0.05) / 0.05 >= 1.05 / (l + 0.05) ? .black : .white
        })
    }

    /// Reusable accent-foreground for **tint-on-tint accent surfaces** —
    /// text/icons drawn in the user's accent *hue* on top of a low-alpha
    /// accent tint (e.g. `DT.systemAccent.opacity(0.12)`), where `onAccent`'s
    /// near-white/near-black answer would be wrong because there is no
    /// opaque fill underneath.
    ///
    /// Unlike `adaptive(light:dark:)`, the accent has no light/dark hex
    /// pair — it's whatever `controlAccentColor` the user picked. So this
    /// behaves like a **macOS dynamic system color**: a name-based
    /// `NSColor` dynamic provider resolves at draw-time against the
    /// current appearance, takes the live accent, and shifts only its
    /// **luminance** (via HSB) while keeping the hue:
    ///
    ///   * **Dark Mode → a LIGHTER / brighter shade** of the accent, so
    ///     it reads as background-darker-than-text over a dark tint.
    ///   * **Light Mode → a DEEPER / darker / richer shade**, so it reads
    ///     as background-lighter-than-text over a pale tint.
    ///
    /// The brightness/saturation shifts mirror the magnitude of the
    /// `DT.blue = adaptive(light: 0x3DB6FF, dark: 0x66C8FF)` pair
    /// (darker in light, lighter in dark). Clamps keep it visibly the
    /// accent hue and readable on a ~0.12 tint in both modes.
    ///
    /// Yan's direction: *all* accent surfaces should eventually adopt
    /// this dynamic-system-color behavior; for now only the user
    /// message bubble is wired to it.
    public static var accentForeground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            let raw = resolvedAccent(isDark: isDark)
            let accent = raw.usingColorSpace(.sRGB) ?? raw
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            accent.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            if isDark {
                // Brighten + slightly desaturate so the hue lifts off a
                // dark tint without going neon. Floor on brightness keeps
                // very dark accents (deep blues) legible.
                b = min(1.0, max(0.80, b * 1.25))
                s = max(0.0, s * 0.85)
            } else {
                // Deepen: darken and push saturation up so the hue stays
                // rich and readable on a pale tint. Cap on brightness
                // keeps light accents (Yellow) from washing out.
                b = max(0.0, min(0.62, b * 0.72))
                s = min(1.0, s * 1.12)
            }
            return NSColor(hue: h, saturation: s, brightness: b, alpha: 1)
        })
    }

    // MARK: - Helpers

    /// Builds a SwiftUI `Color` that resolves to the right hex per the
    /// current system appearance. Uses NSColor's name-based dynamic
    /// provider so the choice happens at draw-time, not init-time —
    /// users toggling Dark Mode mid-session see colors update without
    /// us having to rebuild views.
    public static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return NSColor(rgb: isDark ? dark : light)
        })
    }

    /// Builds a theme-aware SwiftUI `Color` that reads the field at
    /// `keyPath` on the active `ThemeTokenSet` (light or dark) from
    /// `ThemeRuntime.current` on every draw pass.
    ///
    /// The closure runs inside `NSColor(name:nil,dynamicProvider:)` which
    /// AppKit calls on the draw thread — NOT on the main actor. Only
    /// nonisolated state (`ThemeRuntime.current`, `NSColor(hexString:)`,
    /// and the captured key-path) is accessed inside the closure.
    private static func themeColor(_ keyPath: KeyPath<ThemeTokenSet, String>) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            let snap = ThemeRuntime.current
            let tokens = isDark ? snap.spec.dark : snap.spec.light
            return NSColor(hexString: tokens[keyPath: keyPath])
        })
    }
}

// MARK: - Contrast

public extension Color {
    /// Pure black or white — whichever has the higher WCAG contrast ratio when
    /// THIS color is used as a solid background. A caller can leave a chip/badge's
    /// foreground "empty" and get a legible label automatically.
    ///
    /// Thin sugar over the single `DT.foreground(on:)` primitive: the background
    /// is resolved to a concrete sRGB NSColor once, then the black/white decision
    /// is plain luminance arithmetic. Unlike the former implementation, this is
    /// NOT a dynamic `NSColor(name:)` provider — so it cannot flip black↔white on
    /// a tab switch, focus change, or re-mount. The foreground follows ONLY the
    /// background color's luminance, exactly as intended.
    var contrastingForeground: Color {
        DT.foreground(on: self)
    }
}

// MARK: - NSColor hex helpers

private extension NSColor {
    /// `0xRRGGBB` → NSColor (sRGB, alpha 1).
    convenience init(rgb hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1
        )
    }

    /// `"#rrggbb"` hex string → NSColor (sRGB, alpha 1).
    ///
    /// The `#` prefix is optional; letters may be upper- or lower-case.
    /// Falls back to magenta on malformed input so any theme token
    /// validation gap is visually obvious during development.
    ///
    /// All hex strings stored in `ThemeTokenSet` are pre-validated and
    /// normalised by `ThemeYAML.validateHex` at load time, so the
    /// fallback should never fire in production.
    ///
    /// Called from `NSColor(name:nil,dynamicProvider:)` closures on the
    /// draw thread — no actor isolation required (pure arithmetic + init).
    nonisolated convenience init(hexString hex: String) {
        let stripped = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if stripped.count == 6, let rgb = UInt32(stripped, radix: 16) {
            self.init(
                srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255.0,
                green:   CGFloat((rgb >> 8)  & 0xFF) / 255.0,
                blue:    CGFloat(rgb         & 0xFF) / 255.0,
                alpha:   1
            )
        } else {
            // Magenta fallback — visible in debug; should never hit in production.
            self.init(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        }
    }
}
