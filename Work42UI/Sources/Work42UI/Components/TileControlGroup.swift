// TileControlGroup.swift - the one surface for a group of controls in a widget tile's header.
//
// A flat capsule (the chip fill and hairline stroke) 28pt high, holding 28pt buttons. The browser row's groups (back / refresh /
// forward, the address capsule, picker and record), a tile's "···" and close, and every other header control on the Mac and the
// iPad wear it, so they read as one family at one size.

import SwiftUI

/// The measurements of a widget tile, once. Every header and every widget on the Mac and the iPad reads these and nothing else
/// (the Mac's `WidgetCard`, the iPad's `WidgetTile`, the browser's address row, the control groups), so a tile looks the same
/// wherever it is drawn. Change a number here, not at a call site.
public enum TileMetrics {
    /// The card's corner radius.
    public static let cardCorner: CGFloat = 18
    /// The corner of the area a widget's content is clipped to when it sits inset in the card, and that inset from the card's edge.
    public static let contentCorner: CGFloat = 12
    public static let contentInset: CGFloat = 8
    /// A name header's height, and its leading and trailing padding.
    public static let headerHeight: CGFloat = 44
    public static let headerLeading: CGFloat = 14
    public static let headerTrailing: CGFloat = 10
    /// The height of every control group in a header (and of the buttons in one), and the width of a button in a menu/close group.
    public static let controlHeight: CGFloat = 28
    public static let controlButtonWidth: CGFloat = 34
}

public struct TileControlGroup<Content: View>: View {
    /// The height of every control group in a tile header, and the side of the square buttons inside one.
    public static var height: CGFloat { TileMetrics.controlHeight }

    private let content: Content
    private let tint: Color?

    /// - Parameter tint: when non-nil the WHOLE capsule takes this colour (red while a recording runs) instead of the chip fill.
    public init(tint: Color? = nil, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: 0) { content }
            .frame(height: Self.height)
            .tileControlSurface(tint: tint)
            .animation(.easeInOut(duration: 0.2), value: tint)
    }
}

extension View {
    /// The tile control surface behind any content: the capsule of a `TileControlGroup`, for a control (the address field)
    /// that lays itself out.
    public func tileControlSurface(tint: Color? = nil) -> some View {
        background(Capsule().fill(tint.map { AnyShapeStyle($0.opacity(0.85)) } ?? AnyShapeStyle(DT.chipFill)))
            .overlay(Capsule().strokeBorder(tint == nil ? DT.chipStroke : (tint ?? .clear).opacity(0.35), lineWidth: 1))
            .clipShape(Capsule())
    }
}
