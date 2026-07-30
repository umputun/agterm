import Foundation

/// Host-free: formats a `BackgroundWatermark` into one surface's ghostty config-overlay text, plus the
/// `fit`/`position` validation the CLI and control server share. No AppKit — `.text` rasterization lives in
/// the app target, so this only emits the `background-image*` lines once a PNG path is known.
public enum WatermarkConfig {
    /// The libghostty `background-image-fit` values, from `BackgroundWatermark.Fit`, for error messages.
    public static var validFits: [String] { BackgroundWatermark.Fit.allCases.map(\.rawValue) }
    /// The libghostty `background-image-position` values, from `BackgroundWatermark.Position`.
    public static var validPositions: [String] { BackgroundWatermark.Position.allCases.map(\.rawValue) }

    /// Upper bound on watermark text at the control boundary: `WatermarkRenderer` rasterizes at a fixed
    /// 256pt font into a bitmap sized to the glyph run, so an uncapped string would allocate multiple GB.
    public static let maxTextLength = 256

    public static func isValidFit(_ fit: String) -> Bool { BackgroundWatermark.Fit(rawValue: fit) != nil }
    public static func isValidPosition(_ position: String) -> Bool { BackgroundWatermark.Position(rawValue: position) != nil }

    /// Valid `background-image-opacity`: finite and within `0...1`. NaN/Inf would otherwise reach the
    /// config as `nan`/`inf` via `formatted`.
    public static func isValidOpacity(_ opacity: Double) -> Bool {
        opacity.isFinite && opacity >= 0 && opacity <= 1
    }

    /// Valid watermark text: non-empty and within `maxTextLength`, so the rasterized bitmap stays bounded.
    public static func isValidText(_ text: String) -> Bool {
        !text.isEmpty && text.count <= maxTextLength
    }

    /// Valid `#rrggbb` hex — exactly `NSColor(agtermHex:)`'s grammar (optional leading `#`, six hex digits);
    /// malformed is rejected here, not silently fallen back to the terminal foreground. ASCII-only: bare
    /// `isHexDigit` accepts fullwidth forms (`ＦＦ００００`) that `UInt32(radix:)` cannot parse and would then
    /// render the default color.
    public static func isValidColorHex(_ hex: String) -> Bool {
        var s = Substring(hex)
        if s.first == "#" { s = s.dropFirst() }
        return s.count == 6 && s.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    /// Valid `.image` watermark path: no ASCII control character (scalar `< 0x20`). The ONLY free-text field
    /// reaching a ghostty config line, emitted RAW/unquoted, so an embedded newline splits the value and lets
    /// the tail inject an arbitrary ghostty key (`clipboard-read = allow`) into the per-surface overlay, which
    /// wins there. Short of RCE (owner-only socket, `fileExists` gate), but the spec is persisted and
    /// re-applied on restore from semi-trusted agent input. Shared by the server and CLI `validate()`.
    public static func isValidImagePath(_ path: String) -> Bool {
        !path.unicodeScalars.contains { $0.value < 0x20 }
    }

    /// The per-surface ghostty config overlay (loaded LAST, so it wins) for `watermark` pointed at
    /// `resolvedImagePath` (the user's file for `.image`, the rendered PNG for `.text`, nil for `.color`):
    ///
    /// - `.color`: `background = <hex>` plus `background-opacity = <windowOpacity>` (1 when translucency is
    ///   off) — the base config pins the global opacity to 0 under translucency, hiding the color. No image
    ///   keys; the window blur composites in AppKit and shows through unchanged.
    /// - `.image`/`.text`: the `background-image*` lines plus `background-opacity = 1` (the user-chosen
    ///   "auto-raise"), since image opacity is RELATIVE to it (`0 × anything = 0`).
    /// - a `font-size` line preserving the session's cmd-+/- zoom, which a per-surface `update_config`
    ///   otherwise resets to the config default.
    ///
    /// A nil `watermark` (or `.image`/`.text` with no `resolvedImagePath`) yields ONLY the font-size line,
    /// clearing the image while keeping zoom; `.color` needs no path. Returns "" with nothing to override.
    /// Values are emitted RAW: ghostty takes the whole line remainder as the value, so a path with spaces
    /// works unquoted, matching `AppSettings.ghosttyConfigLines()`.
    public static func overlayText(watermark: BackgroundWatermark?, resolvedImagePath: String?,
                                   fontSize: Double?, windowOpacity: Double = 1) -> String {
        var lines: [String] = []
        // re-validate free text on EMIT: `AppStore.restore` assigns a persisted spec raw, so a hand-edited
        // `workspaces.json` could carry a control-char path or a malformed color. a poisoned value drops the
        // background entirely, font-size still emitted; `fit`/`position` are typed enums and can't inject.
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

    /// The per-surface overlay that makes a program's LIVE OSC 11 background visible: a
    /// `background-opacity = <windowOpacity>` line plus the usual `font-size` zoom preservation.
    ///
    /// NO `background` key, unlike the `.color` overlay above: libghostty holds the OSC color in the
    /// terminal's dynamic `override` layer and draws `override orelse default`, so only the opacity needs
    /// restating (the base config pins it to 0 under translucency, hiding the tint). Writing the color into
    /// `background` would reach `Termio.changeConfig`, which reseeds the `default` layer from the config on
    /// every surface update; OSC 111 resets the override TO that default, so the reset would no-op and
    /// strand the pane on the program's color after it exits.
    public static func oscBackgroundOverlayText(fontSize: Double?, windowOpacity: Double) -> String {
        let opacity = windowOpacity.isFinite ? min(max(windowOpacity, 0), 1) : 1
        var lines = ["background-opacity = \(formatted(opacity))"]
        if let fontSize { lines.append("font-size = \(formatted(fontSize))") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Format a `Double` for a ghostty config value: integral without a trailing `.0` (`14.0` → `14`), else
    /// the minimal decimal. Locale-independent (always `.`) — `String(format:)` uses the C locale.
    /// Fixed-point, NOT `String(Double)`, whose scientific notation for tiny magnitudes (`1e-05`) ghostty's
    /// config parser rejects, silently dropping the line back to the default opacity.
    static func formatted(_ value: Double) -> String {
        // `Int(value)` TRAPS on .infinity or |value| ≥ ~9.2e18, so guard the integral fast-path: a validated
        // opacity or live font size never gets there, but `fontSize` comes from a hand-editable snapshot.
        if value == value.rounded(), value.isFinite, abs(value) < Double(Int.max) { return String(Int(value)) }
        var s = String(format: "%.6f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
