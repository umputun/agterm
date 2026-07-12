import Testing
@testable import agtermCore

struct DashboardLayoutTests {
    @Test func gridDimensionsFollowCeilSqrt() {
        // (count, cols, rows) for the full 1...9 range: cols = ceil(sqrt(n)), rows = ceil(n / cols).
        let table: [(count: Int, cols: Int, rows: Int)] = [
            (1, 1, 1), (2, 2, 1), (3, 2, 2), (4, 2, 2), (5, 3, 2),
            (6, 3, 2), (7, 3, 3), (8, 3, 3), (9, 3, 3),
        ]
        for row in table {
            let g = DashboardLayout.grid(count: row.count)
            #expect(g.cols == row.cols, "cols for n=\(row.count)")
            #expect(g.rows == row.rows, "rows for n=\(row.count)")
        }
    }

    @Test func gridClampsDegenerateAndOversizedCounts() {
        #expect(DashboardLayout.grid(count: 0) == (1, 1))
        #expect(DashboardLayout.grid(count: -3) == (1, 1))
        #expect(DashboardLayout.grid(count: 12) == (3, 3))
    }

    @Test func cellPlacementIsRowMajor() {
        // 3-wide grid: indices lay out row by row.
        #expect(DashboardLayout.cell(index: 0, cols: 3) == (0, 0))
        #expect(DashboardLayout.cell(index: 2, cols: 3) == (2, 0))
        #expect(DashboardLayout.cell(index: 3, cols: 3) == (0, 1))
        #expect(DashboardLayout.cell(index: 5, cols: 3) == (2, 1))
        #expect(DashboardLayout.cell(index: 6, cols: 3) == (0, 2))
        // 2-wide grid.
        #expect(DashboardLayout.cell(index: 0, cols: 2) == (0, 0))
        #expect(DashboardLayout.cell(index: 1, cols: 2) == (1, 0))
        #expect(DashboardLayout.cell(index: 2, cols: 2) == (0, 1))
    }

    @Test func moveInFullTwoWideGrid() {
        // n=2, cols=2, single row: 0 1
        #expect(DashboardLayout.move(from: 0, direction: .right, cols: 2, count: 2) == 1)
        #expect(DashboardLayout.move(from: 1, direction: .left, cols: 2, count: 2) == 0)
        #expect(DashboardLayout.move(from: 0, direction: .left, cols: 2, count: 2) == 0)
        #expect(DashboardLayout.move(from: 1, direction: .right, cols: 2, count: 2) == 1)
        #expect(DashboardLayout.move(from: 0, direction: .up, cols: 2, count: 2) == 0)
        #expect(DashboardLayout.move(from: 0, direction: .down, cols: 2, count: 2) == 0)
    }

    @Test func moveInFullFourGrid() {
        // n=4, cols=2, rows=2:
        //   0 1
        //   2 3
        #expect(DashboardLayout.move(from: 0, direction: .right, cols: 2, count: 4) == 1)
        #expect(DashboardLayout.move(from: 0, direction: .down, cols: 2, count: 4) == 2)
        #expect(DashboardLayout.move(from: 3, direction: .up, cols: 2, count: 4) == 1)
        #expect(DashboardLayout.move(from: 3, direction: .left, cols: 2, count: 4) == 2)
        // edges stay put.
        #expect(DashboardLayout.move(from: 1, direction: .right, cols: 2, count: 4) == 1)
        #expect(DashboardLayout.move(from: 2, direction: .down, cols: 2, count: 4) == 2)
        #expect(DashboardLayout.move(from: 0, direction: .up, cols: 2, count: 4) == 0)
        #expect(DashboardLayout.move(from: 0, direction: .left, cols: 2, count: 4) == 0)
    }

    @Test func moveInFullNineGrid() {
        // n=9, cols=3, rows=3 — full 3×3.
        //   0 1 2
        //   3 4 5
        //   6 7 8
        #expect(DashboardLayout.move(from: 4, direction: .up, cols: 3, count: 9) == 1)
        #expect(DashboardLayout.move(from: 4, direction: .down, cols: 3, count: 9) == 7)
        #expect(DashboardLayout.move(from: 4, direction: .left, cols: 3, count: 9) == 3)
        #expect(DashboardLayout.move(from: 4, direction: .right, cols: 3, count: 9) == 5)
        // corner clamps.
        #expect(DashboardLayout.move(from: 0, direction: .up, cols: 3, count: 9) == 0)
        #expect(DashboardLayout.move(from: 0, direction: .left, cols: 3, count: 9) == 0)
        #expect(DashboardLayout.move(from: 8, direction: .down, cols: 3, count: 9) == 8)
        #expect(DashboardLayout.move(from: 8, direction: .right, cols: 3, count: 9) == 8)
    }

    @Test func moveInFullSixGrid() {
        // n=6, cols=3, rows=2 — a FULL 3×2 grid (both rows filled).
        //   0 1 2
        //   3 4 5
        #expect(DashboardLayout.move(from: 1, direction: .down, cols: 3, count: 6) == 4)
        #expect(DashboardLayout.move(from: 4, direction: .up, cols: 3, count: 6) == 1)
        #expect(DashboardLayout.move(from: 5, direction: .left, cols: 3, count: 6) == 4)
        #expect(DashboardLayout.move(from: 3, direction: .right, cols: 3, count: 6) == 4)
        // edges stay put.
        #expect(DashboardLayout.move(from: 2, direction: .right, cols: 3, count: 6) == 2)
        #expect(DashboardLayout.move(from: 5, direction: .down, cols: 3, count: 6) == 5)
    }

    @Test func cellAndMoveDefendAgainstZeroCols() {
        // cols:0 must not divide/modulo by zero — the width clamps to 1 (a single column).
        #expect(DashboardLayout.cell(index: 2, cols: 0) == (0, 2))
        // in a 1-wide grid: left/right stay put, up/down step by one within range.
        #expect(DashboardLayout.move(from: 1, direction: .right, cols: 0, count: 3) == 1)
        #expect(DashboardLayout.move(from: 1, direction: .up, cols: 0, count: 3) == 0)
        #expect(DashboardLayout.move(from: 1, direction: .down, cols: 0, count: 3) == 2)
        #expect(DashboardLayout.move(from: 2, direction: .down, cols: 0, count: 3) == 2)
    }

    @Test func moveClampsRaggedLastRowThree() {
        // n=3, cols=2, rows=2:
        //   0 1
        //   2
        #expect(DashboardLayout.move(from: 0, direction: .down, cols: 2, count: 3) == 2)
        // no cell below index 1 (would be index 3, out of range).
        #expect(DashboardLayout.move(from: 1, direction: .down, cols: 2, count: 3) == 1)
        // no cell right of index 2.
        #expect(DashboardLayout.move(from: 2, direction: .right, cols: 2, count: 3) == 2)
        #expect(DashboardLayout.move(from: 2, direction: .up, cols: 2, count: 3) == 0)
    }

    @Test func moveClampsRaggedLastRowFive() {
        // n=5, cols=3, rows=2:
        //   0 1 2
        //   3 4
        #expect(DashboardLayout.move(from: 4, direction: .right, cols: 3, count: 5) == 4)
        #expect(DashboardLayout.move(from: 2, direction: .down, cols: 3, count: 5) == 2)
        #expect(DashboardLayout.move(from: 4, direction: .down, cols: 3, count: 5) == 4)
        #expect(DashboardLayout.move(from: 3, direction: .up, cols: 3, count: 5) == 0)
        #expect(DashboardLayout.move(from: 1, direction: .down, cols: 3, count: 5) == 4)
    }

    @Test func moveClampsRaggedLastRowSeven() {
        // n=7, cols=3, rows=3:
        //   0 1 2
        //   3 4 5
        //   6
        #expect(DashboardLayout.move(from: 6, direction: .right, cols: 3, count: 7) == 6)
        #expect(DashboardLayout.move(from: 3, direction: .down, cols: 3, count: 7) == 6)
        // no cell below index 4 (would be index 7, out of range).
        #expect(DashboardLayout.move(from: 4, direction: .down, cols: 3, count: 7) == 4)
        #expect(DashboardLayout.move(from: 6, direction: .up, cols: 3, count: 7) == 3)
    }

    @Test func moveClampsRaggedLastRowEight() {
        // n=8, cols=3, rows=3:
        //   0 1 2
        //   3 4 5
        //   6 7
        #expect(DashboardLayout.move(from: 7, direction: .right, cols: 3, count: 8) == 7)
        #expect(DashboardLayout.move(from: 5, direction: .down, cols: 3, count: 8) == 5)
        #expect(DashboardLayout.move(from: 4, direction: .down, cols: 3, count: 8) == 7)
        #expect(DashboardLayout.move(from: 7, direction: .up, cols: 3, count: 8) == 4)
    }

    @Test func moveClampsOutOfRangeStart() {
        #expect(DashboardLayout.move(from: -2, direction: .right, cols: 3, count: 5) == 0)
        #expect(DashboardLayout.move(from: 9, direction: .left, cols: 3, count: 5) == 4)
    }

    @Test func dashboardFontSizeScalesFactorsAtBaseThirteen() {
        // base 13 = the shared ghostty default (the `.auto` base when Settings has no explicit size).
        #expect(DashboardLayout.ghosttyDefaultFontSize == 13)
        #expect(DashboardLayout.dashboardFontSize(cols: 1, rows: 1, base: 13) == 13)
        #expect(DashboardLayout.dashboardFontSize(cols: 2, rows: 1, base: 13) == 11)
        #expect(DashboardLayout.dashboardFontSize(cols: 2, rows: 2, base: 13) == 10)
        #expect(DashboardLayout.dashboardFontSize(cols: 3, rows: 2, base: 13) == 8)
        #expect(DashboardLayout.dashboardFontSize(cols: 3, rows: 3, base: 13) == 7)
    }

    @Test func dashboardFontSizeScalesFactorsAtBaseSixteen() {
        #expect(DashboardLayout.dashboardFontSize(cols: 1, rows: 1, base: 16) == 16)
        #expect(DashboardLayout.dashboardFontSize(cols: 2, rows: 1, base: 16) == 14)
        #expect(DashboardLayout.dashboardFontSize(cols: 2, rows: 2, base: 16) == 12)
        #expect(DashboardLayout.dashboardFontSize(cols: 3, rows: 2, base: 16) == 10)
        #expect(DashboardLayout.dashboardFontSize(cols: 3, rows: 3, base: 16) == 9)
    }

    @Test func dashboardFontSizeFloorsAtSmallBase() {
        // base 8, densest 3×3: 8 * 0.55 = 4.4 → 4, floored to minFontSize (6).
        #expect(DashboardLayout.dashboardFontSize(cols: 3, rows: 3, base: 8) == DashboardLayout.minFontSize)
        // base 6, 2×2: 6 * 0.75 = 4.5 → 5, still below the floor.
        #expect(DashboardLayout.dashboardFontSize(cols: 2, rows: 2, base: 6) == DashboardLayout.minFontSize)
        // base 6, 1×1 stays at base (above the floor).
        #expect(DashboardLayout.dashboardFontSize(cols: 1, rows: 1, base: 6) == 6)
    }
}
