import Foundation

/// The area a split's divider answers clicks in, in the split view's own coordinate space: horizontally the
/// gap between the two panes widened by the pointer's grab slop, vertically only the part that is on screen
/// (a compact titlebar masks the divider's top strip away, and a click up there belongs to the title bar).
public struct SplitDividerBand: Equatable, Sendable {
    public let minX: Double
    public let maxX: Double
    public let minY: Double
    public let maxY: Double

    /// A hairline divider lays its panes out edge to edge, so the gap can be narrower than the divider
    /// itself; `dividerThickness` is the floor. Slop widens the band into both panes because the 1pt line is
    /// not a clickable target — keep it no wider than the band AppKit already starts a drag in, or the extra
    /// columns steal double-clicks from the terminal text beside the divider.
    public init(leftPaneMaxX: Double, rightPaneMinX: Double, dividerThickness: Double, grabSlop: Double,
                visibleTop: Double, visibleHeight: Double) {
        minX = leftPaneMaxX - grabSlop
        maxX = leftPaneMaxX + max(rightPaneMinX - leftPaneMaxX, dividerThickness) + grabSlop
        minY = visibleTop
        maxY = visibleTop + max(0, visibleHeight)
    }

    public func contains(x: Double, y: Double) -> Bool {
        x >= minX && x <= maxX && y >= minY && y <= maxY
    }
}
