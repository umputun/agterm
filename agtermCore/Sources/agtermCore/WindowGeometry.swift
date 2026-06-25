import Foundation

/// Pure geometry clamps for the `window.resize`/`window.move` control commands. Host-free —
/// `WindowRegistry` (the only place with the live `NSWindow` and its `NSScreen`) supplies the
/// actual display bounds and window min/size, this just does the arithmetic so it can be unit-tested.
///
/// `CGSize`/`CGPoint`/`CGRect` are Foundation-provided on Darwin (CoreGraphics, not AppKit/Metal),
/// so they stay within the host-free boundary.
public enum WindowGeometry {
    /// Minimum visible strip (points) kept on the target display when clamping an origin, so a window
    /// pushed off-screen still exposes enough of itself to grab and drag back.
    public static let visibleMargin: CGFloat = 80

    /// Clamps each dimension of `requested` into `[min, max]`: an oversized request shrinks to `max`,
    /// an undersized one grows to `min`, an in-range one is returned unchanged.
    public static func clampSize(_ requested: CGSize, min: CGSize, max: CGSize) -> CGSize {
        CGSize(width: clamp(requested.width, min.width, max.width),
               height: clamp(requested.height, min.height, max.height))
    }

    /// Clamps a window's origin so the window rect (`[origin, origin + windowSize]`) stays at least
    /// `visibleMargin` points overlapping `displayFrame` in each axis — a window dragged off-screen
    /// keeps a grabbable strip visible. Coordinate-system agnostic: `requested`, `windowSize`, and
    /// `displayFrame` must share one space (the caller works in AppKit y-up screen coords).
    ///
    /// The rule per axis (x shown; y identical): origin.x is clamped to
    /// `[displayFrame.minX + visibleMargin - windowSize.width, displayFrame.maxX - visibleMargin]`,
    /// so the window's right edge can't fall left of `minX + margin` and its left edge can't fall
    /// right of `maxX - margin`. An already-on-screen origin is returned unchanged.
    public static func clampOrigin(_ requested: CGPoint, windowSize: CGSize, displayFrame: CGRect) -> CGPoint {
        // compute edges from origin/size directly — the CGRect.minX/maxX accessors are CoreGraphics
        // overlay extensions not visible under host-free Foundation (displayFrame has non-negative size).
        let displayMinX = displayFrame.origin.x
        let displayMaxX = displayFrame.origin.x + displayFrame.size.width
        let displayMinY = displayFrame.origin.y
        let displayMaxY = displayFrame.origin.y + displayFrame.size.height
        let minX = displayMinX + visibleMargin - windowSize.width
        let maxX = displayMaxX - visibleMargin
        let minY = displayMinY + visibleMargin - windowSize.height
        let maxY = displayMaxY - visibleMargin
        return CGPoint(x: clamp(requested.x, minX, maxX), y: clamp(requested.y, minY, maxY))
    }

    /// Clamps `value` into `[lo, hi]`. If `lo > hi` (a degenerate range) the upper bound wins.
    private static func clamp(_ value: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, lo), hi)
    }
}
