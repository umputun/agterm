import Foundation

/// The text sizes derived from the user's interface font size, plus the scale its panels resize by. One
/// source for the palette/picker and the session switcher so the two cannot drift. The sidebar is NOT one
/// of these surfaces: it has its own `sidebarFontSize` and its own row-height derivation.
///
/// Every size is proportional to `base`, anchored so the 13pt default reproduces what the views hardcoded
/// before the setting reached them: macOS `.caption`/`.caption2` (10pt) for `secondary` and `.callout`
/// (12pt) for `shortcut`. Text stops shrinking at `minimumTextSize` — a strict proportion would put a
/// subtitle at 7pt on a 9pt base.
public struct InterfaceMetrics: Equatable, Sendable {
    /// Row title and search-field point size — the setting's own clamped value.
    public let base: Double
    /// Subtitle and badge point size.
    public let secondary: Double
    /// Keyboard-shortcut hint point size.
    public let shortcut: Double
    /// `base` over the default, for scaling panel geometry the views own.
    public let scale: Double

    /// The floor for derived text, below which a subtitle stops being readable.
    public static let minimumTextSize: Double = 8

    private static let secondaryAtDefault: Double = 10
    private static let shortcutAtDefault: Double = 12

    public init(fontSize: Double) {
        let clamped = AppSettings.clampInterfaceFontSize(fontSize)
        let scale = clamped / AppSettings.defaultInterfaceFontSize
        base = clamped
        secondary = max(Self.minimumTextSize, (Self.secondaryAtDefault * scale).rounded())
        shortcut = max(Self.minimumTextSize, (Self.shortcutAtDefault * scale).rounded())
        self.scale = scale
    }

    /// A default-anchored panel length at the current size: `scaled(520)` gives the palette's panel width
    /// before it is fitted to the window, so a larger font shows the same number of rows and truncates no
    /// more titles than at 13pt — as far as `fittedPanelWidth` can grant.
    public func scaled(_ length: Double) -> Double { (length * scale).rounded() }

    /// Clearance kept between a panel edge and the window edge.
    public static let panelMargin: Double = 16
    /// The width a panel prefers not to shrink below when the sidebar crowds it. The window itself still
    /// wins: a window narrower than this plus both margins yields less, since overflowing is worse.
    public static let minimumPanelWidth: Double = 280

    /// The panel width that actually fits: the scaled ideal, shrunk to what the terminal area leaves once
    /// the sidebar and the margins are taken out, and never past the window itself. Both the scaled width
    /// and the centering offset grow without bound on their own, and they compound — at the 13pt default a
    /// 220pt sidebar clips the 520pt panel in any window under 741pt, which the 640pt window minimum
    /// allows.
    public func fittedPanelWidth(idealAtDefault: Double, windowWidth: Double, terminalAreaInset: Double) -> Double {
        let ceiling = max(0, windowWidth - 2 * Self.panelMargin)
        let fitsTerminalArea = windowWidth - terminalAreaInset - 2 * Self.panelMargin
        return min(min(scaled(idealAtDefault), max(Self.minimumPanelWidth, fitsTerminalArea)), ceiling)
    }

    /// How far right to shift a panel of `width` so it centers over the terminal area instead of the whole
    /// window. Half the inset, except where that would push the right edge past the window: the panel is
    /// centered, so its right edge sits at `(windowWidth + width) / 2 + offset`, and capping the offset at
    /// `(windowWidth - width) / 2` is exactly the condition that keeps it inside. A too-narrow window
    /// therefore degrades to the old whole-window centering rather than to a clipped panel.
    public func panelOffset(width: Double, windowWidth: Double, terminalAreaInset: Double) -> Double {
        max(0, min(terminalAreaInset / 2, (windowWidth - width) / 2))
    }

    /// The height a panel may occupy below its top inset, so a scaled panel cannot run off the bottom.
    /// The palette's result list is a `ScrollView` and absorbs this by scrolling; the switcher's row stack
    /// needs its own scroll container to do the same.
    public func fittedPanelHeight(windowHeight: Double, topFraction: Double) -> Double {
        max(Self.minimumPanelHeight, windowHeight * (1 - topFraction) - Self.panelMargin)
    }

    /// The height below which a panel stops shrinking; roughly three default rows plus the search field.
    public static let minimumPanelHeight: Double = 160

    /// The height a MEASURED row stack should render at: its own content height, capped by what the window
    /// leaves, and nil until the measurement arrives so the first layout pass stays unconstrained.
    ///
    /// This exists because the cap cannot be handed to the container directly. `.frame(maxHeight:)` around a
    /// `ScrollView` makes every panel that tall — a scroll view accepts the height it is offered instead of
    /// sizing to its rows — and around a stack it centers the content, dropping the panel down the window.
    /// Measure, then set an exact height; where an exact height will not do, pass `alignment: .top`.
    public func measuredPanelHeight(rowsHeight: Double, maxRowsHeight: Double) -> Double? {
        guard rowsHeight > 0 else { return nil }
        return min(rowsHeight, max(0, maxRowsHeight))
    }
}
