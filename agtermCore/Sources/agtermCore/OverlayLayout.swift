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

/// Per-edge insets (in points) applied to an anchored floating overlay panel so it sits one cell off the
/// pane edge(s) it anchors to, instead of flush against the border. The app maps these onto a SwiftUI
/// `padding(EdgeInsets)` on the panel; the centered axes carry a zero inset.
public struct OverlayInsets: Equatable, Sendable {
    public let leading: Double
    public let top: Double
    public let trailing: Double
    public let bottom: Double

    public init(leading: Double, top: Double, trailing: Double, bottom: Double) {
        self.leading = leading
        self.top = top
        self.trailing = trailing
        self.bottom = bottom
    }

    /// No inset on any edge (`center`, full overlay, or unusable metrics).
    public static let zero = OverlayInsets(leading: 0, top: 0, trailing: 0, bottom: 0)
}

/// Pure resolver turning an `OverlaySize` request into a concrete panel size within a pane. Host-free and
/// unit-tested; the app applies the result as a SwiftUI frame. All sizes are in points.
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

    /// The one-line-height margin a floating overlay panel takes off the pane edge(s) its `anchor` sits
    /// against, so an edge/corner-anchored panel is not flush with the border. BOTH anchored sides — the
    /// horizontal one (`unitX` 0 = leading, 1 = trailing) and the vertical one (`unitY` 0 = top, 1 = bottom)
    /// — inset by one `cell.cellHeight` (the line height), so the left/right gaps equal the top/bottom gaps
    /// and the margin looks uniform; a terminal cell is ~2x taller than wide, so using the cell width for the
    /// horizontal side would read as about half the vertical gap. A centered axis (`0.5`) gets none. Each
    /// inset is capped at the slack on its axis (`min(oneCell, pane - panel)`), so a near-full-pane panel
    /// never overflows, and nil or unusable `cell` metrics yield no inset. `center` (both axes 0.5) always
    /// yields `.zero`.
    public static func anchorInsets(_ anchor: OverlayAnchor, panel: WindowGeometry.Size,
                                    pane: WindowGeometry.Size, cell: OverlayCellMetrics?) -> OverlayInsets {
        guard let cell, cell.isUsable else { return .zero }
        let hInset = Swift.min(cell.cellHeight, Swift.max(0, pane.width - panel.width))
        let vInset = Swift.min(cell.cellHeight, Swift.max(0, pane.height - panel.height))
        return OverlayInsets(leading: anchor.unitX == 0 ? hInset : 0,
                             top: anchor.unitY == 0 ? vInset : 0,
                             trailing: anchor.unitX == 1 ? hInset : 0,
                             bottom: anchor.unitY == 1 ? vInset : 0)
    }
}
