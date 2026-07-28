import Foundation

/// Decides what a surface does with a dynamic background color reported by libghostty
/// (`GHOSTTY_ACTION_COLOR_CHANGE`, kind background). Host-free so the routing is unit-tested; the app
/// target owns only the config push.
///
/// libghostty reports a SET (OSC 11) and a RESET (OSC 111) through the same action, with no flag telling
/// them apart — a reset simply carries the terminal's default background, which is the theme color. So
/// the theme background is what identifies a reset, and a program that deliberately sets OSC 11 to the
/// exact theme color is indistinguishable from one resetting to it. That ambiguity is harmless: both
/// render the theme background.
public enum OSCBackgroundPolicy {
    /// What the surface should do with the reported color.
    public enum Decision: Equatable {
        /// Render this color as the surface's dynamic background.
        case apply(String)
        /// The program reset to the theme default — drop the OSC overlay and fall back to the session's
        /// own config (watermark or plain).
        case reset
        /// Nothing to do: a per-prompt re-emit of the color already applied, a reset with no overlay
        /// live, or a malformed color.
        case ignore
    }

    /// Route a reported `incoming` color, given the theme's background (nil before the first config
    /// resolve) and the color currently applied to this surface (`current`, nil for none).
    ///
    /// Comparison is case- and `#`-insensitive: the callback formats `#rrggbb` lowercase while the theme
    /// color arrives from `NSColor.agtermHexString` as `#RRGGBB`, so a literal compare would miss every
    /// reset.
    public static func decide(incoming: String, themeBackground: String?, current: String?) -> Decision {
        guard WatermarkConfig.isValidColorHex(incoming) else { return .ignore }
        let color = normalized(incoming)
        if let themeBackground, normalized(themeBackground) == color {
            return current == nil ? .ignore : .reset
        }
        // dedupe the per-prompt re-emit storm: a shell re-asserting OSC 11 on every prompt would
        // otherwise drive a full per-surface config rebuild each time.
        if let current, normalized(current) == color { return .ignore }
        return .apply(incoming)
    }

    /// The color a reported change must equal to count as a reset: whatever ghostty last seeded the
    /// terminal's `default` layer from for this surface.
    ///
    /// `surfaceBackground` is the color the surface's OWN config carries (a `.color` session watermark, a
    /// sessionless overlay's `--background-color`), and `themeBackground` the base config's. The catch is
    /// `oscOverlayActive`: the OSC overlay emits no `background` key, so while it is installed the config
    /// in force is the base one and `default` holds the THEME, not the surface's color. Reporting the
    /// surface color then makes a reset look like a set — the overlay is never released and the latch
    /// stays pinned for a program that has already exited.
    public static func baseline(oscOverlayActive: Bool, surfaceBackground: String?,
                                themeBackground: String?) -> String? {
        guard !oscOverlayActive else { return themeBackground }
        return surfaceBackground ?? themeBackground
    }

    /// A hex color reduced to its six lowercase digits, so `#1D1F21`, `1d1f21` and `#1d1f21` compare equal.
    private static func normalized(_ hex: String) -> String {
        let trimmed = hex.trimmingCharacters(in: .whitespaces)
        return (trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed).lowercased()
    }
}
