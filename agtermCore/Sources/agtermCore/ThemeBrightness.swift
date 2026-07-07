import Foundation

/// Classifies a terminal theme's background as dark or light by perceived luminance.
///
/// Used to pin AppKit-drawn chrome (the sidebar's disclosure triangle) to the terminal theme's
/// brightness instead of the macOS system light/dark setting: a light theme under macOS dark mode
/// otherwise draws a light-gray triangle that vanishes on the light sidebar. Host-free so it is
/// unit-tested; the app target reads the sRGB components off the theme's `NSColor` and calls in.
public enum ThemeBrightness {
    /// Whether an sRGB background (each component 0...1) reads as dark, by Rec. 601 perceived luminance
    /// against a 0.5 midpoint. A nil/unknown background should default to dark at the call site.
    public static func isDark(red: Double, green: Double, blue: Double) -> Bool {
        let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
        return luminance < 0.5
    }

    /// Whether the sidebar reads as dark once the sidebar-tint wash is composited over the sRGB theme
    /// background. `shiftAmount` is the signed wash from `AppSettings.sidebarShiftAmount`: negative
    /// lightens (white wash toward 1), positive darkens (black wash toward 0), magnitude = wash opacity.
    /// The disclosure triangle sits on this washed color, not the raw background, so this is what the
    /// appearance pin classifies — a near-threshold theme plus a strong tint can cross the midpoint.
    public static func isDark(red: Double, green: Double, blue: Double, shiftAmount: Double) -> Bool {
        let opacity = min(1, abs(shiftAmount))
        // compositing Color(white: w).opacity(o) over c gives c*(1-o) + w*o; lighten washes white (w=1),
        // darken washes black (w=0), so the added term is `opacity` when lightening and 0 when darkening.
        let added = shiftAmount < 0 ? opacity : 0
        func wash(_ c: Double) -> Double { c * (1 - opacity) + added }
        return isDark(red: wash(red), green: wash(green), blue: wash(blue))
    }
}
