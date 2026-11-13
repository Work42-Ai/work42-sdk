import CoreGraphics
import Testing

@testable import Work42UI

@Suite("One header metric for every widget header (SDK 2.14.0)")
struct TileMetricsTests {
    @Test("controls are 28 pt with 34 pt buttons on the Mac and 32 pt with 38 pt buttons on a touch screen")
    func controls() {
        #expect(TileMetrics.controlHeight(touch: false) == 28 && TileMetrics.buttonWidth(touch: false) == 34)
        #expect(TileMetrics.controlHeight(touch: true) == 32 && TileMetrics.buttonWidth(touch: true) == 38)
    }

    @Test("a header row is a control's height plus 12 pt above and below: 52 pt on the Mac, 56 pt on a touch screen")
    func rows() {
        #expect(TileMetrics.rowInset == 12 && TileMetrics.rowSpacing == 8)
        #expect(TileMetrics.rowHeight(touch: false) == 52 && TileMetrics.rowHeight(touch: true) == 56)
        for touch in [false, true] {
            #expect(TileMetrics.rowHeight(touch: touch) == TileMetrics.controlHeight(touch: touch) + 24)
        }
    }

    @Test("a control is centred in the row: 12 pt above and below, a smaller one more, a taller one none")
    func centred() {
        for touch in [false, true] {
            let control = TileMetrics.controlHeight(touch: touch)
            #expect(TileMetrics.verticalInset(controlHeight: control, touch: touch) == 12)
        }
        #expect(TileMetrics.verticalInset(controlHeight: 24, touch: false) == 14)
        #expect(TileMetrics.verticalInset(controlHeight: 80, touch: true) == 0)
    }

    @Test("the title block is 14 over 10 pt on the Mac, a step up on a touch screen")
    func titles() {
        #expect(TileMetrics.titleSize(touch: false) == 14 && TileMetrics.subtitleSize(touch: false) == 10)
        #expect(TileMetrics.titleSize(touch: true) == 15 && TileMetrics.subtitleSize(touch: true) == 11)
    }

    @Test("this build uses the sizes of its platform, so the Browser chrome and the tile's pill are one height")
    func thisBuild() {
        #expect(TileMetrics.controlHeight == TileMetrics.controlHeight(touch: TileMetrics.isTouch))
        #expect(TileMetrics.controlButtonWidth == TileMetrics.buttonWidth(touch: TileMetrics.isTouch))
        #expect(TileControlGroup<EmptyViewForTests>.height == TileMetrics.controlHeight)
        #if os(macOS)
        #expect(!TileMetrics.isTouch && TileMetrics.controlHeight == 28 && TileMetrics.rowHeight == 52)
        #endif
    }
}

import SwiftUI

/// Any view, to name `TileControlGroup`'s generic in a test.
private typealias EmptyViewForTests = EmptyView
