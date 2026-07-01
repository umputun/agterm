import Foundation

/// Host-free helpers that turn a `BackgroundWatermark` into the ghostty config-overlay TEXT applied to
/// one surface, plus the `fit`/`position` enum validation shared by the CLI and the control server. No
/// AppKit: the `.text` rasterization lives in the app target; this only formats the `background-image*`
/// lines once a PNG path is known.
public enum WatermarkConfig {
    /// The libghostty `background-image-fit` values, derived from the `BackgroundWatermark.Fit` enum
    /// (single source of truth) — used for the CLI/server error messages.
    public static var validFits: [String] { BackgroundWatermark.Fit.allCases.map(\.rawValue) }
    /// The libghostty `background-image-position` values, derived from `BackgroundWatermark.Position`.
    public static var validPositions: [String] { BackgroundWatermark.Position.allCases.map(\.rawValue) }

    /// Upper bound on watermark text length accepted at the control boundary. `WatermarkRenderer`
    /// rasterizes the string at a fixed 256pt font with a bitmap sized to the glyph run, so the canvas
    /// width grows linearly with character count — an uncapped string would drive a multi-GB allocation.
    /// A watermark is a word or two; 256 is far beyond any real use and keeps the bitmap small.
    public static let maxTextLength = 256

    public static func isValidFit(_ fit: String) -> Bool { BackgroundWatermark.Fit(rawValue: fit) != nil }
    public static func isValidPosition(_ position: String) -> Bool { BackgroundWatermark.Position(rawValue: position) != nil }

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

    /// Valid `.image` watermark path: no ASCII control character (any scalar `< 0x20`). `imagePath` is the
    /// ONLY free-text field that reaches a ghostty config line, and it is emitted RAW/unquoted as
    /// `background-image = <path>` (`overlayText`) — so an embedded newline would split the value and let
    /// the line's tail inject an arbitrary ghostty key (e.g. `clipboard-read = allow`) into the per-surface
    /// overlay, which wins on that surface. The owner-only socket + the `fileExists` gate keep it well short
    /// of RCE, but the spec is persisted and re-applied on restore from semi-trusted (agent) input, so the
    /// injection vector is closed at the boundary. Shared by the control server and the CLI `validate()`.
    public static func isValidImagePath(_ path: String) -> Bool {
        !path.unicodeScalars.contains { $0.value < 0x20 }
    }

    /// The per-surface ghostty config overlay (loaded LAST, so it wins) for `watermark` pointed at
    /// `resolvedImagePath` (the user's file for `.image`, the rendered PNG for `.text`, nil for `.color`):
    ///
    /// - for `.color`: a `background = <hex>` line plus `background-opacity = <windowOpacity>` so the color
    ///   honors the window translucency the user set in Settings (the base config pins the global
    ///   `background-opacity` to 0 under translucency, which would otherwise make the color invisible;
    ///   `windowOpacity` = 1 when translucency is off = a solid color) — no image keys, and the window
    ///   blur is composited at the AppKit level, so it shows through a translucent color unchanged;
    /// - for `.image`/`.text`: the `background-image*` lines, plus `background-opacity = 1` so the image is
    ///   visible even when window translucency pins the global `background-opacity` to 0 (image opacity is
    ///   RELATIVE to it, so `0 × anything = 0` = invisible) — the user-chosen "auto-raise" behavior;
    /// - a `font-size` line preserving the session's cmd-+/- zoom (a per-surface `update_config` otherwise
    ///   resets font size to the config default).
    ///
    /// A nil `watermark` (or an `.image`/`.text` whose `resolvedImagePath` is missing) yields ONLY the
    /// font-size line — clearing the image while keeping zoom; a `.color` still emits its `background`
    /// lines (it needs no `resolvedImagePath`). Returns "" when there is nothing to override (no watermark, no zoom).
    /// Values are emitted RAW (no quotes): ghostty takes the whole line remainder as the value, so a path
    /// with spaces works unquoted — matching `AppSettings.ghosttyConfigLines()`.
    public static func overlayText(watermark: BackgroundWatermark?, resolvedImagePath: String?,
                                   fontSize: Double?, windowOpacity: Double = 1) -> String {
        var lines: [String] = []
        // re-validate the free-text fields on EMIT, not just at the control boundary: `AppStore.restore`
        // assigns a persisted spec raw, so a hand-edited `workspaces.json` could carry a control-char path
        // or a malformed color that would inject a ghostty key here. A poisoned value drops the background
        // entirely (font-size still emitted). `fit`/`position` are typed enums, so they can't inject.
        if let watermark, watermark.kind == .color, let hex = watermark.colorHex, isValidColorHex(hex) {
            let opacity = windowOpacity.isFinite ? min(max(windowOpacity, 0), 1) : 1
            lines.append("background = \(hex)")
            lines.append("background-opacity = \(formatted(opacity))")
        } else if let watermark, watermark.kind != .color, let path = resolvedImagePath, isValidImagePath(path) {
            lines.append("background-opacity = 1")
            lines.append("background-image = \(path)")
            if let opacity = watermark.opacity { lines.append("background-image-opacity = \(formatted(opacity))") }
            lines.append("background-image-fit = \((watermark.fit ?? .contain).rawValue)")
            lines.append("background-image-position = \((watermark.position ?? .center).rawValue)")
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
