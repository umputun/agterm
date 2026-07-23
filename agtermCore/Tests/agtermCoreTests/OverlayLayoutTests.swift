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

    private func expectRect(_ rect: WindowGeometry.Rect, x: Double, y: Double, width: Double, height: Double) {
        #expect(rect.origin.x == x)
        #expect(rect.origin.y == y)
        #expect(rect.size.width == width)
        #expect(rect.size.height == height)
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

    // guards ONLY that the resolver is scale-agnostic — it works in POINT space, so a 1x surface and the
    // same physical surface at 2x, once BOTH are converted to points (the app divides pixels by the backing
    // scale before constructing the metrics, mirrored by `metrics(scale:)`), produce identical point
    // metrics and thus an identical panel. The resolver itself takes no scale, so this cannot catch a bug in
    // the actual px÷backingScaleFactor conversion — that is app-side and is guarded end to end by the e2e
    // `stty size` check (`testOverlayColsRowsRealizedGridMatchesRequest`).
    @Test func equalPointMetricsFromDifferentPixelScalesResolveIdentically() {
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

    // MARK: - panelRect (uniform base-level safe-area size + placement)

    // margin = cellHeight = 16, so a 800x600 pane has a usable safe area of 768x568 (16pt inset per side).
    private func marginCell() -> OverlayCellMetrics {
        OverlayCellMetrics(cellWidth: 8, cellHeight: 16, padWidth: 0, padHeight: 0)
    }

    @Test func fullOverlayFillsWholePaneNoMarginOnEveryAnchor() {
        // a full overlay ignores the safe-area margin on every anchor: origin (0,0), size == pane.
        for anchor in OverlayAnchor.allCases {
            let rect = OverlayLayout.panelRect(.full, pane: pane(800, 600), cell: marginCell(), anchor: anchor)
            expectRect(rect, x: 0, y: 0, width: 800, height: 600)
        }
    }

    @Test func floatingFullSizeRequestFillsSafeAreaOnEveryAnchor() {
        // a >= usable request (100%) clamps to the safe area (768x568) and, with no slack left, lands at
        // origin (m, m) = (16, 16) regardless of the anchor — an equal margin on all four sides.
        for anchor in OverlayAnchor.allCases {
            let rect = OverlayLayout.panelRect(.percent(100), pane: pane(800, 600), cell: marginCell(), anchor: anchor)
            expectRect(rect, x: 16, y: 16, width: 768, height: 568)
        }
    }

    @Test func cornerAnchorPlacesSmallPanelAtMargin() {
        // top-left: a small floating panel sits exactly one line-height off the leading + top edges.
        let tl = OverlayLayout.panelRect(.percent(10), pane: pane(800, 600), cell: marginCell(), anchor: .topLeft)
        expectRect(tl, x: 16, y: 16, width: 80, height: 60)

        // bottom-right: one line-height off the trailing + bottom edges (mirrored via the anchor unit point).
        // originX = 16 + (768-80) = 704, originY = 16 + (568-60) = 524; the right + bottom margins are both 16.
        let br = OverlayLayout.panelRect(.percent(10), pane: pane(800, 600), cell: marginCell(), anchor: .bottomRight)
        expectRect(br, x: 704, y: 524, width: 80, height: 60)
        #expect(800 - (br.origin.x + br.size.width) == 16)
        #expect(600 - (br.origin.y + br.size.height) == 16)
    }

    @Test func centerAnchorCentersWithinSafeArea() {
        // center: a small panel is centered, so the left/right and top/bottom margins are symmetric.
        let rect = OverlayLayout.panelRect(.percent(10), pane: pane(800, 600), cell: marginCell(), anchor: .center)
        expectRect(rect, x: 360, y: 270, width: 80, height: 60)
        #expect(rect.origin.x == 800 - (rect.origin.x + rect.size.width)) // left margin == right margin
        #expect(rect.origin.y == 600 - (rect.origin.y + rect.size.height)) // top margin == bottom margin
    }

    @Test func fullWidthBandIsInsetOnAllFourSides() {
        // a full-usable-width top band (cols far exceeding the pane, few rows) is clamped to the safe-area
        // WIDTH and, anchored top, carries an EQUAL one-line-height margin on the left, right, AND top (the
        // maintainer fix: a full-width band is inset left/right exactly like the top, independent of anchor),
        // with the bottom free.
        let rect = OverlayLayout.panelRect(.cells(cols: 200, rows: 5), pane: pane(800, 600), cell: marginCell(), anchor: .top)
        let leftMargin = rect.origin.x
        let rightMargin = 800 - (rect.origin.x + rect.size.width)
        let topMargin = rect.origin.y
        #expect(leftMargin == 16)
        #expect(rightMargin == 16)
        #expect(topMargin == 16)
        #expect(leftMargin == rightMargin) // symmetric horizontal margins for a full-width band
        #expect(leftMargin == topMargin)   // horizontal margin equals the vertical margin (uniform)
        #expect(rect.size.width == 768)    // the band fills the whole safe-area width
    }

    @Test func nilCellMetricsYieldNoMarginPanelMayFillPane() {
        // nil cell metrics -> m = 0: a 100% floating panel fills the pane (no safe-area inset).
        let rect = OverlayLayout.panelRect(.percent(100), pane: pane(800, 600), cell: nil, anchor: .center)
        expectRect(rect, x: 0, y: 0, width: 800, height: 600)
    }

    @Test func unusableCellMetricsYieldNoMargin() {
        // a zero-width cell is unusable -> m = 0, no inset, panel may fill the pane.
        let zeroWidth = OverlayCellMetrics(cellWidth: 0, cellHeight: 16, padWidth: 0, padHeight: 0)
        let rect = OverlayLayout.panelRect(.percent(100), pane: pane(800, 600), cell: zeroWidth, anchor: .topLeft)
        expectRect(rect, x: 0, y: 0, width: 800, height: 600)
    }

    @Test func cellsBandInsetFromEverySideEvenAnchoredTopLeft() {
        // a cells band that exactly fills the safe area sits at (m, m) with an m margin on all sides, even at
        // top-left: originX = m + 0*(usableW - panelW) = m, and panelW == usableW leaves an m gap on the right.
        let cell = OverlayCellMetrics(cellWidth: 8, cellHeight: 16, padWidth: 0, padHeight: 0)
        let rect = OverlayLayout.panelRect(.cells(cols: 200, rows: 200), pane: pane(800, 600), cell: cell, anchor: .topLeft)
        // usableW = 768 (96 whole cells of 8pt), usableH = 568.
        expectRect(rect, x: 16, y: 16, width: 768, height: 568)
        #expect(800 - (rect.origin.x + rect.size.width) == 16) // right margin present despite top-left anchor
        #expect(600 - (rect.origin.y + rect.size.height) == 16) // bottom margin present too
    }

    @Test func splitCanvasColsFloorsCombinedWidthOnce() {
        // two 800px panes at an 8px cell: 1600/8 = 200 columns spanning the whole detail width.
        #expect(OverlayLayout.splitCanvasCols(primaryWidthPx: 800, splitWidthPx: 800, primaryCellWidthPx: 8) == 200)
    }

    @Test func splitCanvasColsFloorsOnceNotPerPane() {
        // each pane holds 12.5 cells (100/8); summing per-pane floored counts gives 12+12 = 24, but the whole
        // detail width is 200/8 = 25 — flooring ONCE recovers the cell straddling the (uncounted) divider.
        #expect(OverlayLayout.splitCanvasCols(primaryWidthPx: 100, splitWidthPx: 100, primaryCellWidthPx: 8) == 25)
    }

    @Test func splitCanvasColsUsesPrimaryCellSizeIgnoringSplitFont() {
        // the split pane's own (larger) font is irrelevant — the combined width is measured at the PRIMARY
        // cell size: (400 + 320) / 8 = 90, not a mix of 8px and 16px cells.
        #expect(OverlayLayout.splitCanvasCols(primaryWidthPx: 400, splitWidthPx: 320, primaryCellWidthPx: 8) == 90)
    }

    @Test func splitCanvasColsNilForNonPositiveInputs() {
        #expect(OverlayLayout.splitCanvasCols(primaryWidthPx: 800, splitWidthPx: 800, primaryCellWidthPx: 0) == nil)
        #expect(OverlayLayout.splitCanvasCols(primaryWidthPx: 0, splitWidthPx: 0, primaryCellWidthPx: 8) == nil)
    }
}
