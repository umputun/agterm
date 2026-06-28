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

    public var kind: Kind
    /// For `.image`: the user-supplied image file path. nil for `.text` (the PNG is generated).
    public var imagePath: String?
    /// For `.text`: the watermark string.
    public var text: String?
    /// For `.text`: the text color as `#rrggbb`; nil = the terminal foreground color at render time.
    public var colorHex: String?
    /// `background-image-opacity` (relative to `background-opacity`); nil = ghostty's 1.0 default.
    public var opacity: Double?
    /// `background-image-fit`: `contain` (default) | `cover` | `stretch` | `none`. nil = `contain`.
    public var fit: String?
    /// `background-image-position`: `center` (default) and the 8 edge/corner anchors. nil = `center`.
    public var position: String?
    /// `background-image-repeat` (tile to fill blank space). nil = false.
    public var repeats: Bool?

    public init(kind: Kind, imagePath: String? = nil, text: String? = nil, colorHex: String? = nil,
                opacity: Double? = nil, fit: String? = nil, position: String? = nil, repeats: Bool? = nil) {
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
