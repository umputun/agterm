import Foundation

/// A per-session background watermark composited behind the terminal grid by libghostty's
/// `background-image*` config keys: either a user-supplied image file (`.image`) or a string agterm
/// rasterizes to a PNG (`.text`). Stored on `Session`, persisted in `SessionSnapshot`, and carried on
/// the control wire. Host-free + `Codable`: the app target turns it into a per-surface ghostty config
/// overlay (see `WatermarkConfig`) and, for `.text`, renders the PNG (the only step that needs AppKit).
///
/// libghostty re-fits the image to the surface on every resize (`background-image-fit`), so the
/// "auto-resize to the window" behavior needs no app-side resize handling.
public struct BackgroundWatermark: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// `imagePath` points at a user-supplied PNG/JPEG (the only formats libghostty reads).
        case image
        /// `text` is rasterized to a PNG by the app target; `colorHex` tints it.
        case text
    }

    /// libghostty `background-image-fit` (Config.zig `BackgroundImageFit`). A typed enum (like `Kind`)
    /// so an invalid value can't reach a config line and the raw `validFits` array is unneeded — the raw
    /// values match ghostty's keys exactly, so it serializes identically to the former `String`.
    public enum Fit: String, Codable, Sendable, CaseIterable {
        case contain, cover, stretch, none
    }

    /// libghostty `background-image-position` (Config.zig `BackgroundImagePosition`) — `center` plus the
    /// 8 edge/corner anchors. Typed like `Fit`; raw values match ghostty's keys, so it serializes identically.
    public enum Position: String, Codable, Sendable, CaseIterable {
        case topLeft = "top-left", topCenter = "top-center", topRight = "top-right"
        case centerLeft = "center-left", center, centerRight = "center-right"
        case bottomLeft = "bottom-left", bottomCenter = "bottom-center", bottomRight = "bottom-right"
    }

    public var kind: Kind
    /// For `.image`: the user-supplied image file path. nil for `.text` (the PNG is generated).
    public var imagePath: String?
    /// For `.text`: the watermark string.
    public var text: String?
    /// For `.text`: the text color as `#rrggbb`; nil = the terminal foreground color at render time.
    public var colorHex: String?
    /// `background-image-opacity` (relative to `background-opacity`); nil = ghostty's 1.0 default.
    public var opacity: Double?
    /// `background-image-fit`: nil = `contain`.
    public var fit: Fit?
    /// `background-image-position`: nil = `center`.
    public var position: Position?
    /// `background-image-repeat` (tile to fill blank space). nil = false.
    public var repeats: Bool?

    public init(kind: Kind, imagePath: String? = nil, text: String? = nil, colorHex: String? = nil,
                opacity: Double? = nil, fit: Fit? = nil, position: Position? = nil, repeats: Bool? = nil) {
        self.kind = kind
        self.imagePath = imagePath
        self.text = text
        self.colorHex = colorHex
        self.opacity = opacity
        self.fit = fit
        self.position = position
        self.repeats = repeats
    }
}
