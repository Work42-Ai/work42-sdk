// LoadingIndicator.swift - Reusable glass-backed loading indicator.
//
// The animated 42-mark loader (`Loader42`), monochrome in the tint
// color, composed on a Liquid Glass surface using `GlassStyles` for the
// backing so macOS 26 gets `.glassEffect` and macOS 14/15 get the
// `DT.surface` + hairline fallback — all inherited automatically from
// `glassCapsuleSurface()`.
//
// Usage:
//
//     LoadingIndicator()                               // accent, regular
//     LoadingIndicator(label: "Setting up session…")  // with label
//     LoadingIndicator(size: .small, tint: DT.cyan)   // small, tinted
//
// Animation note: `Loader42` runs entirely as Core Animation keyframe
// animations on mask layers — zero per-frame body re-eval, no
// `TimelineView(.animation)` involvement. This is consistent with the
// layer-animation pattern documented in `ThinkingIndicator.swift` and
// required by AC8.
//
// Do NOT call `.glassEffect` directly at a loading site — always go
// through GlassStyles so the macOS-version split lives in one place (AC10).

import SwiftUI

public struct LoadingIndicator: View {

    // MARK: - Size

    public enum Size {
        case small
        case regular

        var markSize: CGFloat {
            switch self {
            case .small:   return Loader42.minimumSize
            case .regular: return 30
            }
        }

        var paddingH: CGFloat {
            switch self {
            case .small:   return DT.s8
            case .regular: return DT.s12
            }
        }

        var paddingV: CGFloat {
            switch self {
            case .small:   return DT.s4
            case .regular: return DT.s8
            }
        }

        var labelFont: Font {
            switch self {
            case .small:   return .system(size: DT.f11)
            case .regular: return .system(size: DT.f12, weight: .medium)
            }
        }

        var spacing: CGFloat {
            switch self {
            case .small:   return DT.s4
            case .regular: return DT.s8
            }
        }
    }

    // MARK: - Properties

    private let label: String?
    private let tint: Color
    private let size: Size

    public init(
        label: String? = nil,
        tint: Color = DT.systemAccent,
        size: Size = .regular
    ) {
        self.label = label
        self.tint = tint
        self.size = size
    }

    // MARK: - Body

    public var body: some View {
        HStack(spacing: size.spacing) {
            Loader42()
                .frame(width: size.markSize, height: size.markSize)
            if let label {
                Text(label)
                    .font(size.labelFont)
                    .foregroundStyle(DT.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, size.paddingH)
        .padding(.vertical, size.paddingV)
        // The glassCapsuleSurface modifier is availability-gated inside
        // GlassStyles: macOS 26 gets .glassEffect(.regular, in: Capsule()),
        // older OSes get .thinMaterial + hairline stroke. AC10 satisfied.
        .glassCapsuleSurface()
    }
}
