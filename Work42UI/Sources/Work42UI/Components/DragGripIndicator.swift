// DragGripIndicator.swift - iOS-style drag-handle pill.
//
// The flat, slightly-translucent pill that appears on every
// resizable seam in the app — between widget columns, between
// stacked widgets, between chat and the side container. Mirrors the
// affordance iOS uses on sheets, the macOS sidebar splitter, and
// most modern desktop apps so users recognise "this is draggable"
// without a tooltip.
//
// Two orientations:
//   .vertical   — a tall pill (drawn on a vertical bar between two
//                 horizontal panes). Drag is along X.
//   .horizontal — a wide pill (drawn on a horizontal bar between
//                 two vertical panes). Drag is along Y.
//
// Dimensions are chosen to read as "iOS drag indicator" rather
// than "macOS divider hairline": 5pt thick, 44pt long is the iOS
// sheet-handle default; we adopt it directly because it scales
// well to both axes and works at high pixel density.

import SwiftUI

public struct DragGripIndicator: View {
    public enum Orientation { case vertical, horizontal }

    public let orientation: Orientation
    public let prominence: Double

    public init(
        orientation: Orientation,
        prominence: Double = 1
    ) {
        self.orientation = orientation
        self.prominence = max(0, min(prominence, 1))
    }

    public var body: some View {
        Capsule(style: .continuous)
            .fill(Color.primary.opacity(0.55 * prominence))
            .frame(
                width:  orientation == .vertical   ? 5  : 44,
                height: orientation == .vertical   ? 44 : 5
            )
    }
}
