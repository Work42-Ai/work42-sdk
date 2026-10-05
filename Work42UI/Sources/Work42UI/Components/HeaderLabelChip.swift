// HeaderLabelChip.swift — the ONE chip renderer for header labels.
//
// Renders a (text, optional SF Symbol, tint role, optional link) label in the
// session-header chip language. Built ON `.sessionChip()` (SessionChipStyle) —
// extends the defined chip behavior rather than introducing a parallel look.
// Used by the session header's metadata strips to render widget-contributed
// labels (Work42PluginKit.WidgetHeaderLabel) after the session-provided ones;
// reusable anywhere a chip row needs the same language.

import AppKit
import SwiftUI

/// The tint role vocabulary, mirrored from the widget SDK so Work42UI stays
/// free of a Work42PluginKit dependency. Callers map their own role enums
/// onto this one.
public enum HeaderLabelChipTint: Sendable, Hashable {
    case neutral
    case success
    case warning
    case failure
    case accent

    /// The role's base color, on DT tokens so the chip matches the session
    /// pills in light + dark mode.
    ///
    /// - `.success` uses `DT.done` — the SAME green as a completed task's
    ///   status pill, so "all done" reads identically across the app.
    /// - `.accent` uses `DT.systemAccent` (the work42 theme accent via
    ///   `ThemeRuntime.current`), NOT SwiftUI's `.accentColor`, which follows
    ///   the macOS system accent and ignores the active theme.
    var color: Color {
        switch self {
        case .neutral: return .secondary
        case .success: return DT.done
        case .warning: return DT.orange
        case .failure: return DT.red
        case .accent:  return DT.systemAccent
        }
    }

    /// (fill, foreground, stroke) for this role — nil fill/stroke for
    /// `.neutral` (default DT chip, muted secondary text); otherwise resolved
    /// through `DT.resolveChipTint` so tinted roles pick up the same
    /// appearance-aware opacity (and near-black-in-dark-mode handling) as
    /// brand-colored chips.
    func resolvedStyle(colorScheme: ColorScheme) -> (fill: Color?, foreground: Color, stroke: Color?) {
        guard self != .neutral else { return (nil, .secondary, nil) }
        let resolved = DT.resolveChipTint(color, colorScheme: colorScheme)
        return (resolved.fill, resolved.foreground, resolved.stroke)
    }
}

/// One header label chip: `[icon] text` inside the standard `.sessionChip()`
/// capsule. With a `url`, the chip is a link whose host decides how to open it
/// through SwiftUI's `openURL` environment; without, it renders inert.
public struct HeaderLabelChip: View {
    public let text: String
    public let systemIcon: String?
    public let iconURL: URL?
    public let iconImageData: Data?
    public let brandColorHex: String?
    public let tint: HeaderLabelChipTint
    public let url: URL?
    /// When set, the chip renders as a Button firing this instead of a Link —
    /// e.g. to focus the owning widget rather than open a URL. Takes precedence
    /// over `url`.
    public let onActivate: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    public init(
        text: String,
        systemIcon: String? = nil,
        iconURL: URL? = nil,
        iconImageData: Data? = nil,
        brandColorHex: String? = nil,
        tint: HeaderLabelChipTint = .neutral,
        url: URL? = nil,
        onActivate: (() -> Void)? = nil
    ) {
        self.text = text
        self.systemIcon = systemIcon
        self.iconURL = iconURL
        self.iconImageData = iconImageData
        self.brandColorHex = brandColorHex
        self.tint = tint
        self.url = url
        self.onActivate = onActivate
    }

    /// The brand color parsed from a `#RRGGBB` (or `RRGGBB`) `brandColorHex`;
    /// nil when unset or malformed (the chip then falls back to the tint).
    private var brandColor: Color? { headerLabelBrandColor(brandColorHex) }

    /// The chip's (fill, foreground, stroke) resolved as ONE unit, both
    /// translucent tints of the same hue so they never diverge. A valid
    /// brand color wins — via `DT.resolveChipTint` (so a near-black FIXED
    /// brand hex, e.g. GitHub's `#1F2328`, stays legible in dark mode
    /// instead of collapsing into the dark chrome); otherwise the semantic
    /// tint decides the same way. Neutral keeps the default DT chip (no
    /// fill, muted secondary text) and full-color image marks
    /// (`iconImageData`) are untouched by the tint.
    private var resolvedStyle: (fill: Color?, foreground: Color, stroke: Color?) {
        if let brandColor {
            let resolved = DT.resolveChipTint(brandColor, colorScheme: colorScheme)
            return (resolved.fill, resolved.foreground, resolved.stroke)
        }
        return tint.resolvedStyle(colorScheme: colorScheme)
    }

    public var body: some View {
        if let onActivate {
            Button(action: onActivate) { chipBody }
                .buttonStyle(.plain)
        } else if let url {
            Link(destination: url) { chipBody }
                .buttonStyle(.plain)
        } else {
            chipBody
        }
    }

    private var chipBody: some View {
        let style = resolvedStyle
        return HStack(spacing: DT.s4) {
            HeaderLabelLeadingIcon(
                systemIcon: systemIcon,
                iconURL: iconURL,
                iconImageData: iconImageData,
                // On a brand color, draw the mark as a same-hue silhouette so
                // it reads as part of the translucent tint, not its own colors.
                monochromeTint: brandColor == nil ? nil : style.foreground
            )
            Text(text)
                .font(.system(size: DT.f11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(style.foreground)
        .sessionChip(fill: style.fill, stroke: style.stroke)
        // Make the WHOLE capsule (incl. padding) hittable so an onActivate/url
        // click registers anywhere on the chip, not just on the text/icon.
        .contentShape(Capsule())
    }
}

// MARK: - Shared helpers (chip + segmented group)

/// Parse a `#RRGGBB` (or `RRGGBB`) brand hex into a Color; nil when unset or
/// malformed. Shared by `HeaderLabelChip` and `SegmentedHeaderLabelGroup`.
public func headerLabelBrandColor(_ hex: String?) -> Color? {
    guard let hex else { return nil }
    let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard s.count == 6, let rgb = UInt32(s, radix: 16) else { return nil }
    return Color(
        .sRGB,
        red: Double((rgb >> 16) & 0xFF) / 255,
        green: Double((rgb >> 8) & 0xFF) / 255,
        blue: Double(rgb & 0xFF) / 255,
        opacity: 1
    )
}

/// The leading icon shared by `HeaderLabelChip` and segmented-group segments.
/// Precedence: a raw brand image (`iconImageData`, rounded-rect, own colors) →
/// a remote avatar (`iconURL`, circle-clipped) → an SF Symbol (`systemIcon`).
struct HeaderLabelLeadingIcon: View {
    let systemIcon: String?
    let iconURL: URL?
    let iconImageData: Data?
    /// When set, a brand image mark is rendered as a `.template` silhouette in
    /// this color instead of its own colors — used when the chip fill is the
    /// same brand color the mark is drawn in (else it vanishes). nil keeps the
    /// mark's original colors (neutral chips).
    var monochromeTint: Color? = nil

    var body: some View {
        if let iconImageData, let nsImage = NSImage(data: iconImageData) {
            markImage(nsImage)
        } else if let iconURL {
            AsyncImage(url: iconURL) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                fallbackIcon
            }
            .frame(width: 14, height: 14)
            .clipShape(Circle())
        } else {
            fallbackIcon
        }
    }

    @ViewBuilder
    private var fallbackIcon: some View {
        if let systemIcon {
            Image(systemName: systemIcon)
                .font(.system(size: DT.f10, weight: .semibold))
        }
    }

    /// Builds the tinted (or original-color) image view for a decoded brand
    /// mark. NOT `@ViewBuilder` — a plain function, so it can mutate `nsImage`
    /// before returning the view (a `@ViewBuilder` context can't hold a bare
    /// statement ahead of its view expression).
    ///
    /// SwiftUI's `.renderingMode(.template)` only reliably recolors an image
    /// whose backing `NSImage` reports `isTemplate == true` — for a raw
    /// `NSImage(data:)` decode (never template-flagged), the modifier alone is
    /// unreliable and can render nothing at all. Setting the flag explicitly
    /// makes the tint apply consistently.
    private func markImage(_ nsImage: NSImage) -> some View {
        nsImage.isTemplate = monochromeTint != nil
        return Image(nsImage: nsImage)
            .renderingMode(monochromeTint == nil ? .original : .template)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .foregroundStyle(monochromeTint ?? .primary)
            .frame(width: 15, height: 15)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}

// MARK: - Segmented group

/// One segment of a `SegmentedHeaderLabelGroup` — Work42UI-native (mirrors
/// `HeaderLabelChip`'s inputs), so Work42UI stays free of a Work42PluginKit
/// dependency. The host maps each `WidgetHeaderLabel` in a group onto one of
/// these.
public struct HeaderLabelSegment: Identifiable {
    public let id: String
    public let text: String
    public let systemIcon: String?
    public let iconURL: URL?
    public let iconImageData: Data?
    public let brandColorHex: String?
    public let tint: HeaderLabelChipTint
    public let url: URL?
    /// Fires instead of opening `url` (e.g. focus the owning widget); takes
    /// precedence over `url`. A segment with neither is inert.
    public let onActivate: (() -> Void)?

    public init(
        id: String,
        text: String,
        systemIcon: String? = nil,
        iconURL: URL? = nil,
        iconImageData: Data? = nil,
        brandColorHex: String? = nil,
        tint: HeaderLabelChipTint = .neutral,
        url: URL? = nil,
        onActivate: (() -> Void)? = nil
    ) {
        self.id = id
        self.text = text
        self.systemIcon = systemIcon
        self.iconURL = iconURL
        self.iconImageData = iconImageData
        self.brandColorHex = brandColorHex
        self.tint = tint
        self.url = url
        self.onActivate = onActivate
    }
}

/// Renders several `HeaderLabelSegment`s joined into ONE capsule — a segmented
/// pill. Each segment keeps its own fill, icon, and independent hit area (its
/// `url`/`onActivate`); the group rounds only the outer ends and draws a
/// hairline separator between segments. Used for per-item labels (a PR/issue
/// whose id segment opens the item and whose status segment deep-links
/// elsewhere).
public struct SegmentedHeaderLabelGroup: View {
    public let segments: [HeaderLabelSegment]

    public init(segments: [HeaderLabelSegment]) {
        self.segments = segments
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { idx, seg in
                segmentButton(seg)
                    // Hairline separator between segments, drawn as an overlay so
                    // it matches the segment's height exactly. A Rectangle sibling
                    // in the HStack would be vertically greedy (no intrinsic
                    // height) and stretch the whole capsule to fill any tall
                    // container — the giant-empty-pill bug.
                    .overlay(alignment: .leading) {
                        if idx > 0 {
                            Rectangle()
                                .fill(DT.chipStroke)
                                .frame(width: 0.5)
                        }
                    }
            }
        }
        // Size to content on BOTH axes so the group never expands to fill the
        // metadata strip's available height.
        .fixedSize()
        .clipShape(Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous).strokeBorder(DT.chipStroke, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func segmentButton(_ seg: HeaderLabelSegment) -> some View {
        let content = SegmentBody(seg: seg)
        if let onActivate = seg.onActivate {
            Button(action: onActivate) { content }.buttonStyle(.plain)
        } else if let url = seg.url {
            Link(destination: url) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }
}

/// One segment's inner content: icon + text over its fill, padded to match
/// `.sessionChip`. No outer shape — the enclosing group applies the capsule
/// clip. A neutral segment (e.g. an id) uses the default DT chip fill; a
/// tinted/brand segment (e.g. a status) uses a low-opacity hue fill with
/// hue-colored text, matching the single-chip translucent language. A brand
/// segment resolves through `DT.resolveChipTint` so a near-black FIXED brand
/// hex stays legible in dark mode instead of collapsing into the dark chrome.
private struct SegmentBody: View {
    let seg: HeaderLabelSegment

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let brand = headerLabelBrandColor(seg.brandColorHex)
        let resolvedBrand = brand.map { DT.resolveChipTint($0, colorScheme: colorScheme) }
        let tintStyle = seg.tint.resolvedStyle(colorScheme: colorScheme)
        let fill = resolvedBrand?.fill ?? tintStyle.fill ?? DT.chipFill
        let fg = resolvedBrand?.foreground ?? tintStyle.foreground
        return HStack(spacing: DT.s4) {
            HeaderLabelLeadingIcon(
                systemIcon: seg.systemIcon,
                iconURL: seg.iconURL,
                iconImageData: seg.iconImageData,
                monochromeTint: brand == nil ? nil : fg
            )
            Text(seg.text)
                .font(.system(size: DT.f11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(fg)
        .padding(.horizontal, DT.chipPadH)
        .padding(.vertical, DT.chipPadV)
        .background(fill)
        .contentShape(Rectangle())
    }
}
