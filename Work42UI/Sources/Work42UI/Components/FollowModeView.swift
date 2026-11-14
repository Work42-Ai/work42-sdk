// FollowModeView.swift — what a personal widget shows while this device follows another device (WOR-796, WOR-808).
//
// Following a device shows its personal widgets as that device sees them: their live picture, framed in their colour, in the widget's own
// chrome. There is no header of its own here: the session's people pill says whom this device follows and stops it, and the widget's pill
// says who is acting. The view is read-only: nothing in it takes a touch, the picture is theirs to move.

import SwiftUI

/// `picture` (the host supplies their live picture with the darts over it) framed in the followed device's colour, read-only.
public struct FollowModeView<Picture: View>: View {
    private let label: String
    private let color: Color
    private let picture: Picture

    /// `label` is what a screen reader says ("Following Alex · iPad").
    public init(label: String, color: Color, @ViewBuilder picture: () -> Picture) {
        self.label = label
        self.color = color
        self.picture = picture()
    }

    public var body: some View {
        picture
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(Rectangle().strokeBorder(color, lineWidth: 2))
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label)
    }
}
