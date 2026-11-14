// TileHeaderControls.swift — how a custom header takes the tile's controls pill into its own first row.
//
// A tile's controls pill (people, "···", close) normally sits beside a custom header's content, as a column. A header that has more
// than one row, the Browser with its tab bar, would then have every row narrower than the tile by the pill's width. Such a header
// reads the pill from the environment, draws it at the end of its first row, and says so with `TileHeaderHostsControlsKey`; the tile
// then leaves its own copy out, so every row of the header runs the full width.

import SwiftUI

private struct TileHeaderControlsKey: EnvironmentKey {
    static let defaultValue: AnyView? = nil
}

extension EnvironmentValues {
    /// The tile's controls pill, offered to a custom header that wants to place it itself (WOR-807).
    public var tileHeaderControls: AnyView? {
        get { self[TileHeaderControlsKey.self] }
        set { self[TileHeaderControlsKey.self] = newValue }
    }
}

/// Set by a header that drew the controls pill in its own first row, so the tile does not draw it again beside the header.
public struct TileHeaderHostsControlsKey: PreferenceKey {
    public static let defaultValue = false
    public static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
