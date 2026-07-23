import Foundation
import Testing
@testable import agtermCore

struct OverlayLayoutTests {
    private func pane(_ width: Double, _ height: Double) -> WindowGeometry.Size {
        WindowGeometry.Size(width: width, height: height)
    }

    private func expectSize(_ size: WindowGeometry.Size, _ width: Double, _ height: Double) {
        #expect(size.width == width)
        #expect(size.height == height)
    }

    // mirrors the app-side px->points conversion: every pixel metric divided by the backing scale.
    private func metrics(cellWpx: Double, cellHpx: Double, padWpx: Double, padHpx: Double,
                         scale: Double) -> OverlayCellMetrics {
        OverlayCellMetrics(cellWidth: cellWpx / scale,
                           cellHeight: cellHpx / scale,
                           padWidth: padWpx / scale,
                           padHeight: padHpx / scale)
    }

    @Test func fullReturnsWholePane() {
        expectSize(OverlayLayout.panelSize(.full, pane: pane(800, 600), cell: nil), 800, 600)
    }

    @Test func percentScalesBothDimensions() {
        expectSize(OverlayLayout.panelSize(.percent(50), pane: pane(800, 600), cell: nil), 400, 300)
    }

    @Test func percentHundredEqualsPane() {
        expectSize(OverlayLayout.panelSize(.percent(100), pane: pane(800, 600), cell: nil), 800, 600)
    }

    @Test func percentOneIsTiny() {
        expectSize(OverlayLayout.panelSize(.percent(1), pane: pane(800, 600), cell: nil), 8, 6)
    }

    @Test func cellsWithinPaneSnapToRequestedGrid() {
        let cell = OverlayCellMetrics(cellWidth: 8, cellHeight: 16, padWidth: 4, padHeight: 6)
        let result = OverlayLayout.panelSize(.cells(cols: 10, rows: 5), pane: pane(800, 600), cell: cell)
        // 10*8+4 = 84 wide, 5*16+6 = 86 tall.
        expectSize(result, 84, 86)
    }

    @Test func cellsWiderThanPaneClampToWholeCells() {
        let cell = OverlayCellMetrics(cellWidth: 8, cellHeight: 16, padWidth: 4, padHeight: 6)
        // pane holds floor((200-4)/8) = 24 whole columns; a 100-col request clamps to 24 -> 24*8+4 = 196.
        let result = OverlayLayout.panelSize(.cells(cols: 100, rows: 5), pane: pane(200, 600), cell: cell)
        expectSize(result, 196, 86)
    }

    @Test func cellsTallerThanPaneClampToWholeCells() {
        let cell = OverlayCellMetrics(cellWidth: 8, cellHeight: 16, padWidth: 4, padHeight: 6)
        // pane holds floor((200-6)/16) = 12 whole rows; a 100-row request clamps to 12 -> 12*16+6 = 198.
        let result = OverlayLayout.panelSize(.cells(cols: 10, rows: 100), pane: pane(800, 200), cell: cell)
        expectSize(result, 84, 198)
    }

    @Test func cellsClampBothDimensionsIndependently() {
        let cell = OverlayCellMetrics(cellWidth: 8, cellHeight: 16, padWidth: 4, padHeight: 6)
        let result = OverlayLayout.panelSize(.cells(cols: 100, rows: 100), pane: pane(200, 200), cell: cell)
        // width floor((200-4)/8) = 24 -> 196; height floor((200-6)/16) = 12 -> 198.
        expectSize(result, 196, 198)
    }

    @Test func retina2xAndNonRetina1xYieldSamePointSize() {
        // a surface at 1x: 8px/16px cells, 4px/2px total padding.
        let oneX = metrics(cellWpx: 8, cellHpx: 16, padWpx: 4, padHpx: 2, scale: 1)
        // the same physical surface at 2x: pixel metrics double, backing scale is 2.
        let twoX = metrics(cellWpx: 16, cellHpx: 32, padWpx: 8, padHpx: 4, scale: 2)
        #expect(oneX == twoX)

        let request = OverlaySize.cells(cols: 10, rows: 5)
        let paneSize = pane(800, 600)
        let sizeOneX = OverlayLayout.panelSize(request, pane: paneSize, cell: oneX)
        let sizeTwoX = OverlayLayout.panelSize(request, pane: paneSize, cell: twoX)
        #expect(sizeOneX == sizeTwoX)
        // in points both resolve to 10*8+4 = 84 wide, 5*16+2 = 82 tall.
        expectSize(sizeOneX, 84, 82)
    }

    @Test func subPixelCellMetricsProduceExactPointSize() {
        // 15px cells on a 2x display convert to 7.5pt; padding 3px -> 1.5pt.
        let cell = OverlayCellMetrics(cellWidth: 7.5, cellHeight: 7.5, padWidth: 1.5, padHeight: 1.5)
        let result = OverlayLayout.panelSize(.cells(cols: 4, rows: 4), pane: pane(800, 600), cell: cell)
        // 4*7.5+1.5 = 31.5 in each dimension.
        expectSize(result, 31.5, 31.5)
    }

    @Test func subPixelAvailableFloorsFitCount() {
        // available 100, pad 1.5, cell 7.5 -> floor((100-1.5)/7.5) = floor(13.133) = 13 columns.
        let cell = OverlayCellMetrics(cellWidth: 7.5, cellHeight: 7.5, padWidth: 1.5, padHeight: 1.5)
        let result = OverlayLayout.panelSize(.cells(cols: 50, rows: 50), pane: pane(100, 100), cell: cell)
        // 13*7.5+1.5 = 99, both dimensions.
        expectSize(result, 99, 99)
    }

    @Test func nilCellMetricsFallBackToPane() {
        expectSize(OverlayLayout.panelSize(.cells(cols: 10, rows: 5), pane: pane(800, 600), cell: nil), 800, 600)
    }

    @Test func unusableCellMetricsFallBackToPane() {
        let zeroWidth = OverlayCellMetrics(cellWidth: 0, cellHeight: 16, padWidth: 4, padHeight: 6)
        expectSize(OverlayLayout.panelSize(.cells(cols: 10, rows: 5), pane: pane(800, 600), cell: zeroWidth), 800, 600)
        let negative = OverlayCellMetrics(cellWidth: -8, cellHeight: -16, padWidth: 0, padHeight: 0)
        expectSize(OverlayLayout.panelSize(.cells(cols: 10, rows: 5), pane: pane(800, 600), cell: negative), 800, 600)
    }

    @Test func paneSmallerThanOneCellFloorsToOneCellButNeverExceedsPane() {
        let cell = OverlayCellMetrics(cellWidth: 8, cellHeight: 16, padWidth: 4, padHeight: 6)
        // pane too small to hold even one cell + padding: floor at one cell yet capped at the pane size.
        let result = OverlayLayout.panelSize(.cells(cols: 10, rows: 5), pane: pane(5, 10), cell: cell)
        expectSize(result, 5, 10)
    }

    @Test func minOneCellFloorWhenRequestIsZeroFit() {
        let cell = OverlayCellMetrics(cellWidth: 8, cellHeight: 16, padWidth: 4, padHeight: 6)
        // a pane that fits exactly one cell + padding still yields one whole cell.
        let result = OverlayLayout.panelSize(.cells(cols: 100, rows: 100), pane: pane(12, 22), cell: cell)
        // width 1*8+4 = 12, height 1*16+6 = 22.
        expectSize(result, 12, 22)
    }

    @Test func isUsableReflectsPositiveCellDimensions() {
        #expect(OverlayCellMetrics(cellWidth: 8, cellHeight: 16, padWidth: 0, padHeight: 0).isUsable)
        #expect(!OverlayCellMetrics(cellWidth: 0, cellHeight: 16, padWidth: 0, padHeight: 0).isUsable)
        #expect(!OverlayCellMetrics(cellWidth: 8, cellHeight: 0, padWidth: 0, padHeight: 0).isUsable)
        #expect(!OverlayCellMetrics(cellWidth: -1, cellHeight: -1, padWidth: 0, padHeight: 0).isUsable)
    }

    @Test func anchorHasNineCasesWithDefaultCenter() {
        #expect(OverlayAnchor.allCases.count == 9)
        #expect(OverlayAnchor(rawValue: "center") == .center)
    }

    @Test(arguments: [
        (OverlayAnchor.topLeft, 0.0, 0.0), (.top, 0.5, 0.0), (.topRight, 1.0, 0.0),
        (.left, 0.0, 0.5), (.center, 0.5, 0.5), (.right, 1.0, 0.5),
        (.bottomLeft, 0.0, 1.0), (.bottom, 0.5, 1.0), (.bottomRight, 1.0, 1.0)
    ])
    func anchorUnitPoints(anchor: OverlayAnchor, unitX: Double, unitY: Double) {
        #expect(anchor.unitX == unitX)
        #expect(anchor.unitY == unitY)
    }

    @Test func anchorRawValuesUseHyphenatedCornerNames() {
        #expect(OverlayAnchor.topLeft.rawValue == "top-left")
        #expect(OverlayAnchor.topRight.rawValue == "top-right")
        #expect(OverlayAnchor.bottomLeft.rawValue == "bottom-left")
        #expect(OverlayAnchor.bottomRight.rawValue == "bottom-right")
        #expect(OverlayAnchor.top.rawValue == "top")
        #expect(OverlayAnchor(rawValue: "diagonal") == nil)
    }

    // MARK: - anchorInsets (1-cell anchor margin)

    private func insetsCell() -> OverlayCellMetrics {
        OverlayCellMetrics(cellWidth: 8, cellHeight: 16, padWidth: 0, padHeight: 0)
    }

    @Test func cornerAnchorInsetsBothAnchoredSidesOneCell() {
        // top-left: one cell off the leading edge AND one cell off the top; trailing/bottom untouched.
        let insets = OverlayLayout.anchorInsets(.topLeft, panel: pane(200, 200), pane: pane(800, 600), cell: insetsCell())
        #expect(insets == OverlayInsets(leading: 8, top: 16, trailing: 0, bottom: 0))

        // bottom-right: one cell off the trailing edge AND one cell off the bottom.
        let br = OverlayLayout.anchorInsets(.bottomRight, panel: pane(200, 200), pane: pane(800, 600), cell: insetsCell())
        #expect(br == OverlayInsets(leading: 0, top: 0, trailing: 8, bottom: 16))
    }

    @Test func edgeAnchorInsetsOnlyTheAnchoredAxis() {
        // top edge: inset the top only, the centered horizontal axis gets nothing.
        let top = OverlayLayout.anchorInsets(.top, panel: pane(200, 200), pane: pane(800, 600), cell: insetsCell())
        #expect(top == OverlayInsets(leading: 0, top: 16, trailing: 0, bottom: 0))

        // left edge: inset the leading only, the centered vertical axis gets nothing.
        let left = OverlayLayout.anchorInsets(.left, panel: pane(200, 200), pane: pane(800, 600), cell: insetsCell())
        #expect(left == OverlayInsets(leading: 8, top: 0, trailing: 0, bottom: 0))

        // right edge: inset the trailing only.
        let right = OverlayLayout.anchorInsets(.right, panel: pane(200, 200), pane: pane(800, 600), cell: insetsCell())
        #expect(right == OverlayInsets(leading: 0, top: 0, trailing: 8, bottom: 0))

        // bottom edge: inset the bottom only.
        let bottom = OverlayLayout.anchorInsets(.bottom, panel: pane(200, 200), pane: pane(800, 600), cell: insetsCell())
        #expect(bottom == OverlayInsets(leading: 0, top: 0, trailing: 0, bottom: 16))
    }

    @Test func centerAnchorHasNoInset() {
        let insets = OverlayLayout.anchorInsets(.center, panel: pane(200, 200), pane: pane(800, 600), cell: insetsCell())
        #expect(insets == .zero)
    }

    @Test func anchorInsetsCapAtAvailableSlack() {
        // a near-full-pane panel: only 3pt of horizontal slack and 5pt of vertical slack remain, so the
        // one-cell (8x16) inset is capped to that slack and the panel never overflows the pane.
        let insets = OverlayLayout.anchorInsets(.topLeft, panel: pane(797, 595), pane: pane(800, 600), cell: insetsCell())
        #expect(insets == OverlayInsets(leading: 3, top: 5, trailing: 0, bottom: 0))
    }

    @Test func anchorInsetsCapAtZeroWhenPanelFillsPane() {
        // a panel exactly the pane size (or larger) has no slack, so an anchored inset is clamped to zero.
        let insets = OverlayLayout.anchorInsets(.bottomRight, panel: pane(800, 600), pane: pane(800, 600), cell: insetsCell())
        #expect(insets == .zero)
    }

    @Test func anchorInsetsAreZeroWithoutUsableMetrics() {
        #expect(OverlayLayout.anchorInsets(.topLeft, panel: pane(200, 200), pane: pane(800, 600), cell: nil) == .zero)
        let zeroWidth = OverlayCellMetrics(cellWidth: 0, cellHeight: 16, padWidth: 0, padHeight: 0)
        #expect(OverlayLayout.anchorInsets(.topLeft, panel: pane(200, 200), pane: pane(800, 600), cell: zeroWidth) == .zero)
    }
}
