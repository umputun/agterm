import Foundation

/// The requested size mode for a session overlay panel. Host-free; the app resolves it to a concrete
/// panel size via `OverlayLayout.panelSize`. Replaces the stored `Session.overlaySizePercent: Int?`.
public enum OverlaySize: Equatable, Sendable {
    /// Fill the whole pane.
    case full
    /// A uniform fraction of the pane in both dimensions; the caller pre-validates `1...100`.
    case percent(Int)
    /// An exact terminal grid; the caller pre-validates `cols >= 1, rows >= 1`.
    case cells(cols: Int, rows: Int)
}

/// One of nine positions a floating overlay panel anchors to within its pane. `unitX`/`unitY` express the
/// anchor as unit coordinates — 0 (leading/top), 0.5 (center), 1 (trailing/bottom) — which the app maps
/// to a SwiftUI `Alignment`. The default (`.center`) reproduces today's centered placement.
public enum OverlayAnchor: String, CaseIterable, Sendable {
    case topLeft = "top-left"
    case top
    case topRight = "top-right"
    case left
    case center
    case right
    case bottomLeft = "bottom-left"
    case bottom
    case bottomRight = "bottom-right"

    /// Horizontal unit position: 0 (leading), 0.5 (center), or 1 (trailing).
    public var unitX: Double {
        switch self {
        case .topLeft, .left, .bottomLeft: return 0
        case .top, .center, .bottom: return 0.5
        case .topRight, .right, .bottomRight: return 1
        }
    }

    /// Vertical unit position: 0 (top), 0.5 (center), or 1 (bottom).
    public var unitY: Double {
        switch self {
        case .topLeft, .top, .topRight: return 0
        case .left, .center, .right: return 0.5
        case .bottomLeft, .bottom, .bottomRight: return 1
        }
    }
}

/// Live cell + padding metrics for an overlay surface, in POINTS (not backing pixels). The app reads the
/// pixel metrics from `ghostty_surface_size()` and divides by the window's backing scale before
/// constructing this, so the host-free resolver works in the same point space as the SwiftUI pane size.
/// `padWidth`/`padHeight` are the total non-cell remainder (an estimate, per the padding-drift note).
public struct OverlayCellMetrics: Equatable, Sendable {
    public let cellWidth: Double
    public let cellHeight: Double
    public let padWidth: Double
    public let padHeight: Double

    public init(cellWidth: Double, cellHeight: Double, padWidth: Double, padHeight: Double) {
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.padWidth = padWidth
        self.padHeight = padHeight
    }

    /// Whether the metrics can drive a cells-mode layout — both cell dimensions must be positive.
    public var isUsable: Bool { cellWidth > 0 && cellHeight > 0 }
}

/// Pure resolver turning an `OverlaySize` request into a concrete panel rect within a pane. Host-free and
/// unit-tested; the app applies the result as a SwiftUI frame + placement. All sizes are in points.
public enum OverlayLayout {
    /// Resolves `size` against `pane` and (for cells mode) the live `cell` metrics.
    ///
    /// - `.full` returns the full pane.
    /// - `.percent(p)` returns `pane * p/100` (always <= pane for a valid `1...100` percent).
    /// - `.cells(cols, rows)` snaps each dimension to whole cells that fit the pane: at least one cell, at
    ///   most the whole cells the pane holds after padding, and never larger than the pane. With nil or
    ///   unusable `cell` metrics it falls back to the full pane.
    public static func panelSize(_ size: OverlaySize, pane: WindowGeometry.Size,
                                 cell: OverlayCellMetrics?) -> WindowGeometry.Size {
        switch size {
        case .full:
            return pane
        case .percent(let percent):
            let fraction = Double(percent) / 100
            return WindowGeometry.Size(width: pane.width * fraction, height: pane.height * fraction)
        case .cells(let cols, let rows):
            guard let cell, cell.isUsable else { return pane }
            let width = cellExtent(count: cols, cellSize: cell.cellWidth, pad: cell.padWidth, available: pane.width)
            let height = cellExtent(count: rows, cellSize: cell.cellHeight, pad: cell.padHeight, available: pane.height)
            return WindowGeometry.Size(width: width, height: height)
        }
    }

    /// Snaps a requested cell count to a whole-cell extent that fits `available`: floors at one cell, caps
    /// at the whole cells that fit after `pad`, and never exceeds `available` (so a pane smaller than one
    /// cell + padding still yields a panel no larger than the pane).
    private static func cellExtent(count: Int, cellSize: Double, pad: Double, available: Double) -> Double {
        let fitCount = Int(((available - pad) / cellSize).rounded(.down))
        let usedCount = Swift.max(1, Swift.min(count, fitCount))
        return Swift.min(Double(usedCount) * cellSize + pad, available)
    }

    /// The concrete panel RECT (origin + size, in points) for `size` within `pane`, anchored by `anchor`
    /// inside a uniform SAFE AREA — the pane inset by a base-level margin `m` on ALL FOUR sides. `m` is one
    /// line-height (`cell.cellHeight`) when the cell metrics are usable, else 0. The margin is a DEFAULT on
    /// every side, symmetric and independent of the anchor: a full-usable-size band carries an equal margin
    /// on every edge (a full-width top band is inset left/right exactly like the top).
    ///
    /// - `.full` fills the whole pane at origin `(0, 0)` with NO margin (the translucent session-hiding cover).
    /// - a FLOATING size (`.percent`/`.cells`) is sized by `panelSize`, then CLAMPED to the safe area per axis
    ///   (`panelW = min(requestedW, paneW - 2m)`, same for height), and PLACED at the anchor's unit position
    ///   within the safe area (`originX = m + anchor.unitX * (usableW - panelW)`, same for y) — so the panel is
    ///   never closer than `m` to any edge, a full-usable-size panel fills the safe area with an `m` margin all
    ///   around, and the anchor positions a smaller panel within it.
    public static func panelRect(_ size: OverlaySize, pane: WindowGeometry.Size,
                                 cell: OverlayCellMetrics?, anchor: OverlayAnchor) -> WindowGeometry.Rect {
        if case .full = size {
            return WindowGeometry.Rect(origin: WindowGeometry.Point(x: 0, y: 0), size: pane)
        }
        let margin: Double
        if let cell, cell.isUsable {
            margin = cell.cellHeight
        } else {
            margin = 0
        }
        let usableWidth = Swift.max(0, pane.width - 2 * margin)
        let usableHeight = Swift.max(0, pane.height - 2 * margin)
        let requested = panelSize(size, pane: pane, cell: cell)
        let width = Swift.min(requested.width, usableWidth)
        let height = Swift.min(requested.height, usableHeight)
        let originX = margin + anchor.unitX * (usableWidth - width)
        let originY = margin + anchor.unitY * (usableHeight - height)
        return WindowGeometry.Rect(origin: WindowGeometry.Point(x: originX, y: originY),
                                   size: WindowGeometry.Size(width: width, height: height))
    }

    /// Whole-cell column count spanning a side-by-side split's full detail WIDTH, measured from the two
    /// panes' backing-pixel widths at ONE cell size (the primary pane's) and floored ONCE. This is the
    /// true single full-detail grid a floating overlay's `--cols` fills — it avoids the double-floor and the
    /// mixed-font error of summing each pane's already-floored column count (the panes can carry different
    /// live font sizes). The thin divider between the panes is uncounted, so it underestimates the whole
    /// detail width by a fraction of a cell. Unitless (px / px), so no Retina conversion. nil when the
    /// primary cell width or the total width is non-positive.
    public static func splitCanvasCols(primaryWidthPx: Double, splitWidthPx: Double,
                                       primaryCellWidthPx: Double) -> Int? {
        guard primaryCellWidthPx > 0 else { return nil }
        let totalWidthPx = primaryWidthPx + splitWidthPx
        guard totalWidthPx > 0 else { return nil }
        return Int((totalWidthPx / primaryCellWidthPx).rounded(.down))
    }
}
