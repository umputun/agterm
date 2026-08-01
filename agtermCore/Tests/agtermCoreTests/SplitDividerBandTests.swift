import Testing
@testable import agtermCore

struct SplitDividerBandTests {
    private func band(leftPaneMaxX: Double = 300, rightPaneMinX: Double = 301, dividerThickness: Double = 1,
                      grabSlop: Double = 3, visibleTop: Double = 0,
                      visibleHeight: Double = 500) -> SplitDividerBand {
        SplitDividerBand(leftPaneMaxX: leftPaneMaxX, rightPaneMinX: rightPaneMinX,
                         dividerThickness: dividerThickness, grabSlop: grabSlop,
                         visibleTop: visibleTop, visibleHeight: visibleHeight)
    }

    @Test func spansTheGapPlusSlopOnBothSides() {
        let hairline = band()
        #expect(hairline.contains(x: 300.5, y: 250))
        #expect(hairline.contains(x: 297, y: 250))
        #expect(hairline.contains(x: 304, y: 250))
        #expect(!hairline.contains(x: 296.9, y: 250))
        #expect(!hairline.contains(x: 304.1, y: 250))
    }

    @Test func panesLaidOutEdgeToEdgeStillLeaveTheDividerClickable() {
        let noGap = band(rightPaneMinX: 300, dividerThickness: 1)
        #expect(noGap.contains(x: 300.5, y: 250))
        #expect(noGap.maxX == 304)
    }

    @Test func aThickDividerWidensTheBandByItsOwnGap() {
        let thick = band(rightPaneMinX: 309, dividerThickness: 9)
        #expect(thick.contains(x: 308, y: 250))
        #expect(!thick.contains(x: 312.1, y: 250))
    }

    @Test func zeroSlopLeavesOnlyTheDividerItself() {
        let bare = band(grabSlop: 0)
        #expect(bare.contains(x: 300.5, y: 250))
        #expect(!bare.contains(x: 299.9, y: 250))
    }

    @Test func theMaskedTitlebarStripIsOutsideTheBand() {
        let compact = band(visibleTop: 30, visibleHeight: 470)
        #expect(!compact.contains(x: 300.5, y: 29))
        #expect(compact.contains(x: 300.5, y: 30))
        #expect(compact.contains(x: 300.5, y: 500))
        #expect(!compact.contains(x: 300.5, y: 501))
    }

    @Test func aFullyMaskedDividerAnswersNothing() {
        let collapsed = band(visibleTop: 30, visibleHeight: -10)
        #expect(!collapsed.contains(x: 300.5, y: 25))
        #expect(!collapsed.contains(x: 300.5, y: 31))
    }
}
