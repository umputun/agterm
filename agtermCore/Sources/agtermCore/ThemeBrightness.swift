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
}
