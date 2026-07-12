import Foundation

/// Pure grid geometry, keyboard navigation, and auto-size font math for the dashboard overlay.
/// Host-free (Foundation-only, `Int`/`Double` — no CoreGraphics/AppKit) so `swift test` covers it with
/// no app host. The dashboard shows up to `maxCells` live session surfaces in a `ceil(sqrt(n))`-wide grid;
/// a keyboard highlight walks the cells and the auto-size math shrinks the font as the grid grows so a
/// dense grid stays readable.
public enum DashboardLayout {
    /// Largest number of cells the grid holds; the call site caps a bigger request to this.
    public static let maxCells = 9

    /// Smallest font size (points) the auto-size math applies, so a dense grid floors at a legible size
    /// instead of collapsing to an unreadable one.
    public static let minFontSize: Double = 6

    /// libghostty's built-in terminal font size (points) — the `.auto` base when the user has not set an
    /// explicit Settings font size (`AppSettings.fontSize == nil`). ghostty exposes no constant for it, so
    /// this mirrors ghostty's default and is the single source for the app-side wiring and the tests.
    public static let ghosttyDefaultFontSize: Double = 13

    /// A one-step highlight move in the 2-D grid; no wraparound.
    public enum Direction: String, Sendable, CaseIterable {
        case up, down, left, right
    }

    /// grid returns the grid dimensions for `count` cells: `cols = ceil(sqrt(count))`,
    /// `rows = ceil(count / cols)`. `count` is clamped into `1...maxCells` so a degenerate 0 or an
    /// oversized request never produces an empty or too-large grid.
    public static func grid(count: Int) -> (cols: Int, rows: Int) {
        let n = min(max(count, 1), maxCells)
        let cols = Int(Double(n).squareRoot().rounded(.up))
        let rows = Int((Double(n) / Double(cols)).rounded(.up))
        return (cols, rows)
    }

    /// cell returns the row-major (col, row) of the cell at `index` in a `cols`-wide grid.
    public static func cell(index: Int, cols: Int) -> (col: Int, row: Int) {
        let width = max(cols, 1)
        return (index % width, index / width)
    }

    /// move returns the highlighted index after a one-step `direction` move from `from` in a `cols`-wide
    /// grid holding `count` cells. Clamped: a move off an edge, or into an empty slot of the ragged last
    /// row, stays put (returns `from`). No wraparound.
    public static func move(from: Int, direction: Direction, cols: Int, count: Int) -> Int {
        let width = max(cols, 1)
        let total = max(count, 1)
        guard from >= 0, from < total else { return min(max(from, 0), total - 1) }
        let (col, row) = cell(index: from, cols: width)
        switch direction {
        case .left:
            return col > 0 ? from - 1 : from
        case .right:
            let candidate = from + 1
            return col + 1 < width && candidate < total ? candidate : from
        case .up:
            return row > 0 ? from - width : from
        case .down:
            let candidate = (row + 1) * width + col
            return candidate < total ? candidate : from
        }
    }

    /// dashboardFontSize returns the auto-size font (points) for a `cols × rows` grid relative to `base`:
    /// `max(minFontSize, (base * factor(cols, rows)).rounded())`. The factor shrinks as the grid grows so
    /// a denser grid gets smaller text, floored at `minFontSize`.
    public static func dashboardFontSize(cols: Int, rows: Int, base: Double) -> Double {
        max(minFontSize, (base * fontFactor(cols: cols, rows: rows)).rounded())
    }

    /// per-grid-shape shrink factor — tunable, eyeballed at a couple of Settings base sizes. denser than
    /// 3×3 is never produced by `grid` (count caps at 9), so the default just mirrors the densest case.
    private static func fontFactor(cols: Int, rows: Int) -> Double {
        switch (cols, rows) {
        case (1, 1): return 1.00
        case (2, 1): return 0.85
        case (2, 2): return 0.75
        case (3, 2): return 0.62
        case (3, 3): return 0.55
        default: return 0.55
        }
    }
}
