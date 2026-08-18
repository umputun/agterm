/// The quick-terminal panel's size on the screen it is summoned onto. Host-free so the arithmetic is
/// testable: `QuickTerminalController` owns the `NSScreen` and the `NSPanel` and converts at the call
/// site. Uses `WindowGeometry.Size` for the same reason it exists — see that file on why these are
/// Double-backed rather than `CGSize`.
public enum QuickTerminalMetrics {
    /// The share of the screen the panel takes when the user has set no size of his own.
    public static let defaultShare: Double = 0.9

    /// Where the default share stops growing, in points. The in-window overlay this replaced needed no
    /// ceiling, a window already being a modest size; 90% of a large display is a wall of terminal rather
    /// than a quick aside.
    public static let defaultMaxSize = WindowGeometry.Size(width: 1100, height: 700)

    /// The sizes offered in Settings. Discrete rather than a slider: the panel is summoned and dismissed,
    /// so the choice is which of a few shapes it should have, not a value worth tuning by the point.
    public static let sizePercentChoices = [40, 50, 60, 70, 80, 90]

    /// Bounds for a user-set percentage. The ceiling is `defaultShare`, which is as large as the panel was
    /// ever meant to get; the floor is roughly what `defaultMaxSize` already yields on a large display, so
    /// every offered value is a real choice rather than a smaller version of what the default gives.
    public static let sizePercentRange: ClosedRange<Int> = 40 ... 90

    /// Bounds a raw percentage to `sizePercentRange`, so a hand-edited `settings.json` cannot produce a
    /// panel too small to read or one covering the screen.
    public static func clampSizePercent(_ percent: Int) -> Int {
        min(sizePercentRange.upperBound, max(sizePercentRange.lowerBound, percent))
    }

    /// The panel's size on a screen whose visible frame measures `visible`. The single read point, and it
    /// clamps, so callers pass the stored value straight through.
    ///
    /// A set percentage REPLACES both the default share and its points ceiling rather than raising the
    /// ceiling: a size in points is what ages badly across displays in the first place, so configuring one
    /// would move the same problem to the next screen size instead of removing it. `nil` keeps the built-in
    /// pair exactly, which no single percentage can reproduce — the ceiling binds above roughly 1222x780
    /// points and the share binds below it, so the two yield different fractions of different screens.
    public static func panelSize(visible: WindowGeometry.Size, sizePercent: Int?) -> WindowGeometry.Size {
        guard let sizePercent else {
            return WindowGeometry.Size(width: min(visible.width * defaultShare, defaultMaxSize.width),
                                       height: min(visible.height * defaultShare, defaultMaxSize.height))
        }
        let share = Double(clampSizePercent(sizePercent)) / 100
        return WindowGeometry.Size(width: visible.width * share, height: visible.height * share)
    }
}
