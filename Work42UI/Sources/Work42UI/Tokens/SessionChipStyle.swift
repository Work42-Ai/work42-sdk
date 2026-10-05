// SessionChipStyle.swift — Reusable chip/badge view modifier built on DT chip tokens.
//
// Usage:
//   Text("In Progress")
//       .sessionChip()                       // capsule (default)
//   Text("Draft")
//       .sessionChip(shape: .rounded)        // rounded rectangle

import SwiftUI

/// Selects the background shape for `.sessionChip()`.
public enum ChipShape {
    /// A fully-rounded capsule (pill) shape.
    case capsule
    /// A rounded rectangle using `DT.rButton` corner radius.
    case rounded
}

/// View modifier that applies chip/badge styling using DT chip tokens.
///
/// - Padding: `DT.chipPadH` horizontal, `DT.chipPadV` vertical.
/// - Fill:
///   - `.capsule` → `DT.chipFill` (`Color.primary.opacity(0.06)`)
///   - `.rounded` → `DT.chipFillSubtle` (`Color.primary.opacity(0.05)`)
/// - Stroke: `DT.chipStroke` (`Color.primary.opacity(0.08)`) at 0.5 pt.
public struct SessionChipModifier: ViewModifier {
    public let shape: ChipShape
    public let fill: Color
    public let stroke: Color

    public init(shape: ChipShape = .capsule, fill: Color? = nil, stroke: Color? = nil) {
        self.shape = shape
        // Default to the neutral DT chip tokens; a caller can pass a tint
        // (e.g. a status color) to color the chip's BACKGROUND instead.
        self.fill = fill ?? (shape == .rounded ? DT.chipFillSubtle : DT.chipFill)
        self.stroke = stroke ?? DT.chipStroke
    }

    public func body(content: Content) -> some View {
        content
            .padding(.horizontal, DT.chipPadH)
            .padding(.vertical, DT.chipPadV)
            .background {
                switch shape {
                case .capsule:
                    Capsule(style: .continuous)
                        .fill(fill)
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(stroke, lineWidth: 0.5)
                        )
                case .rounded:
                    RoundedRectangle(cornerRadius: DT.rButton, style: .continuous)
                        .fill(fill)
                        .overlay(
                            RoundedRectangle(cornerRadius: DT.rButton, style: .continuous)
                                .strokeBorder(stroke, lineWidth: 0.5)
                        )
                }
            }
    }
}

public extension View {
    /// Applies chip/badge styling (padding + fill + stroke) using DT chip tokens.
    ///
    /// - Parameters:
    ///   - shape: `.capsule` (default) for a pill shape; `.rounded` for a
    ///     `DT.rButton`-radius rounded rectangle.
    ///   - fill: optional background fill override (nil → neutral DT token).
    ///   - stroke: optional border override (nil → neutral DT token).
    func sessionChip(shape: ChipShape = .capsule, fill: Color? = nil, stroke: Color? = nil) -> some View {
        modifier(SessionChipModifier(shape: shape, fill: fill, stroke: stroke))
    }
}
