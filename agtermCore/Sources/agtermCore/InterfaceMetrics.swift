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

    /// A default-anchored panel length at the current size: `scaled(520)` gives the palette's panel width,
    /// so a larger font shows the same number of rows and truncates no more titles than at 13pt.
    public func scaled(_ length: Double) -> Double { (length * scale).rounded() }
}
