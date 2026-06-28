import Foundation

/// Host-free helpers that turn a `BackgroundWatermark` into the ghostty config-overlay TEXT applied to
/// one surface, plus the `fit`/`position` enum validation shared by the CLI and the control server. No
/// AppKit: the `.text` rasterization lives in the app target; this only formats the `background-image*`
/// lines once a PNG path is known.
public enum WatermarkConfig {
    /// The libghostty `background-image-fit` values (Config.zig `BackgroundImageFit`).
    public static let validFits = ["contain", "cover", "stretch", "none"]
    /// The libghostty `background-image-position` values (Config.zig `BackgroundImagePosition`).
    public static let validPositions = [
        "top-left", "top-center", "top-right",
        "center-left", "center", "center-right",
        "bottom-left", "bottom-center", "bottom-right",
    ]

    /// Upper bound on watermark text length accepted at the control boundary. `WatermarkRenderer`
    /// rasterizes the string at a fixed 256pt font with a bitmap sized to the glyph run, so the canvas
    /// width grows linearly with character count — an uncapped string would drive a multi-GB allocation.
    /// A watermark is a word or two; 256 is far beyond any real use and keeps the bitmap small.
    public static let maxTextLength = 256

    public static func isValidFit(_ fit: String) -> Bool { validFits.contains(fit) }
    public static func isValidPosition(_ position: String) -> Bool { validPositions.contains(position) }

    /// Valid `background-image-opacity`: a finite value in `0...1` (the documented range). Rejects NaN/Inf
    /// (which `formatted` would otherwise emit as `nan`/`inf` into the config) and out-of-range values.
    public static func isValidOpacity(_ opacity: Double) -> Bool {
        opacity.isFinite && opacity >= 0 && opacity <= 1
    }

    /// Valid watermark text: non-empty and within `maxTextLength`, so the rasterized bitmap stays bounded.
    public static func isValidText(_ text: String) -> Bool {
        !text.isEmpty && text.count <= maxTextLength
    }

    /// Valid `#rrggbb` hex color — exactly what `NSColor(agtermHex:)` parses (an optional leading `#` then
    /// six hex digits). A malformed value is rejected at the boundary rather than silently falling back to
    /// the terminal foreground, matching the fit/position rejection.
    public static func isValidColorHex(_ hex: String) -> Bool {
        var s = Substring(hex)
        if s.first == "#" { s = s.dropFirst() }
        return s.count == 6 && s.allSatisfy(\.isHexDigit)
    }

    /// The per-surface ghostty config overlay (loaded LAST, so it wins) for `watermark` pointed at
    /// `resolvedImagePath` (the user's file for `.image`, the rendered PNG for `.text`):
    ///
    /// - the `background-image*` lines for the watermark, plus `background-opacity = 1` so the image is
    ///   visible even when window translucency pins the global `background-opacity` to 0 (image opacity is
    ///   RELATIVE to it, so `0 × anything = 0` = invisible) — the user-chosen "auto-raise" behavior;
    /// - a `font-size` line preserving the session's cmd-+/- zoom (a per-surface `update_config` otherwise
    ///   resets font size to the config default).
    ///
    /// A nil `watermark` (or a missing `resolvedImagePath`) yields ONLY the font-size line — clearing the
    /// image while keeping zoom. Returns "" when there is nothing to override (no watermark, no zoom).
    /// Values are emitted RAW (no quotes): ghostty takes the whole line remainder as the value, so a path
    /// with spaces works unquoted — matching `AppSettings.ghosttyConfigLines()`.
    public static func overlayText(watermark: BackgroundWatermark?, resolvedImagePath: String?,
                                   fontSize: Double?) -> String {
        var lines: [String] = []
        if let watermark, let path = resolvedImagePath {
            lines.append("background-opacity = 1")
            lines.append("background-image = \(path)")
            if let opacity = watermark.opacity { lines.append("background-image-opacity = \(formatted(opacity))") }
            lines.append("background-image-fit = \(watermark.fit ?? "contain")")
            lines.append("background-image-position = \(watermark.position ?? "center")")
            lines.append("background-image-repeat = \(watermark.repeats == true)")
        }
        if let fontSize { lines.append("font-size = \(formatted(fontSize))") }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// Format a `Double` for a ghostty config value: an integral value without a trailing `.0`
    /// (`14.0` → `14`), else the minimal decimal (`0.15` → `0.15`). Locale-independent (always `.`):
    /// `String(format:)` uses the C locale. Uses fixed-point, NOT `String(Double)`, because the latter
    /// emits scientific notation for tiny magnitudes (`0.00001` → `1e-05`) which ghostty's config parser
    /// rejects — it would silently drop the line and fall back to the default opacity.
    static func formatted(_ value: Double) -> String {
        // guard the integral fast-path against non-finite / out-of-Int-range values: `Int(value)` TRAPS on
        // .infinity or |value| ≥ ~9.2e18. Those never arise from a validated opacity or a live font size,
        // but `fontSize` is read straight from a (possibly hand-edited) snapshot, so stay total.
        if value == value.rounded(), value.isFinite, abs(value) < Double(Int.max) { return String(Int(value)) }
        var s = String(format: "%.6f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
