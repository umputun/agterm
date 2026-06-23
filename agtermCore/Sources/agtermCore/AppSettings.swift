import Foundation

/// User-facing appearance settings, persisted independently of the workspace tree.
///
/// Every field is optional: nil means "use the ghostty default", and a settings file written
/// before a field existed still decodes — that optionality IS the forward-compat mechanism, so
/// there is no version field (a version bump would only add a discard-on-mismatch path that wipes
/// the user's settings).
public struct AppSettings: Codable, Equatable, Sendable {
    /// Terminal font family name (e.g. `SF Mono`), or nil for the ghostty default.
    public var fontFamily: String?
    /// Default terminal font size in points, or nil for the ghostty default.
    public var fontSize: Double?
    /// ghostty theme name (e.g. `Adwaita Dark`), or nil for the ghostty default.
    public var theme: String?
    /// Window background opacity in 0...1 (1 = fully opaque), or nil for opaque. Composited at the
    /// AppKit window level, NOT by the ghostty renderer: when < 1, `ghosttyConfigLines()` pins the
    /// renderer fully transparent so the window's tinted background is the single translucent layer
    /// (otherwise the surface and the window would stack two tints).
    public var backgroundOpacity: Double?
    /// Background blur radius (private CGS window blur, 0...100), or nil for no blur. Only has a
    /// visible effect when `backgroundOpacity` < 1. Applied in the app target, NOT a ghostty key.
    public var backgroundBlur: Int?
    /// Whether to post macOS notification banners for terminal desktop notifications. nil means the
    /// default (on). Only gates the OS banner — the sidebar unseen-count badge tracks notifications
    /// either way.
    public var notificationsEnabled: Bool?
    /// Whether the sidebar shows the red unseen-notification count badge (the count pill on session
    /// rows and the collapsed-workspace roll-up). nil means the default (on). Render-only: the
    /// unseen count keeps tracking, so turning it back on instantly shows the current counts.
    /// Distinct from `notificationsEnabled`, which gates the OS banner.
    public var notificationBadgeEnabled: Bool?
    /// Whether the window uses the compact title bar (a single short row with smaller icons) instead
    /// of the tall default that stacks the session name over the working-directory subtitle. nil
    /// means the default (off). Applied at the AppKit window level, NOT a ghostty key; in compact
    /// mode the cwd subtitle is dropped so the bar is a single line.
    public var compactToolbar: Bool?
    /// Hex colors (`#RRGGBB`) for the agent-status glyph's three states; nil for each means the system
    /// default (active = blue, blocked = amber, completed = green). Applied at the AppKit level when the
    /// glyph is drawn, NOT ghostty keys, so they never appear in `ghosttyConfigLines()`.
    public var activeStatusColorHex: String?
    public var blockedStatusColorHex: String?
    public var completedStatusColorHex: String?
    /// Directory holding the user-editable keymap config (`keymap.conf`), or nil for the default
    /// (`~/.config/agterm`). Resolved by `ConfigPaths.configDirectory(setting:stateDir:home:)`; an
    /// app-level path, never a ghostty key.
    public var configDirectory: String?

    public init(fontFamily: String? = nil, fontSize: Double? = nil, theme: String? = nil,
                backgroundOpacity: Double? = nil, backgroundBlur: Int? = nil, notificationsEnabled: Bool? = nil,
                compactToolbar: Bool? = nil, notificationBadgeEnabled: Bool? = nil,
                activeStatusColorHex: String? = nil, blockedStatusColorHex: String? = nil,
                completedStatusColorHex: String? = nil, configDirectory: String? = nil) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.theme = theme
        self.backgroundOpacity = backgroundOpacity
        self.backgroundBlur = backgroundBlur
        self.notificationsEnabled = notificationsEnabled
        self.compactToolbar = compactToolbar
        self.notificationBadgeEnabled = notificationBadgeEnabled
        self.activeStatusColorHex = activeStatusColorHex
        self.blockedStatusColorHex = blockedStatusColorHex
        self.completedStatusColorHex = completedStatusColorHex
        self.configDirectory = configDirectory
    }

    /// The ghostty config lines for the set fields, one `key = value` per line, suitable for a
    /// file loaded via `ghostty_config_load_file`. Unset (or blank) fields are omitted. Values are
    /// written raw — ghostty takes the whole line remainder as the value, so names with spaces
    /// (`3024 Night`, `SF Mono`) are NOT quoted (quoting would become part of the value).
    public func ghosttyConfigLines() -> [String] {
        var lines: [String] = []
        if let fontFamily, !fontFamily.isEmpty { lines.append("font-family = \(fontFamily)") }
        if let fontSize { lines.append("font-size = \(Self.format(fontSize))") }
        if let theme, !theme.isEmpty { lines.append("theme = \(theme)") }
        // a translucent window composites its tint at the AppKit level, so the renderer must draw a
        // fully transparent terminal — else the surface and the window stack two tints. At full
        // opacity (or unset) ghostty paints its own background as usual and these are omitted.
        if let backgroundOpacity, backgroundOpacity < 1 {
            lines.append("background-opacity = 0")
            lines.append("background-blur = 0")
        }
        return lines
    }

    /// Integer sizes render without a trailing `.0` (`14`, not `14.0`); fractional sizes keep it.
    private static func format(_ size: Double) -> String {
        size == size.rounded() ? String(Int(size)) : String(size)
    }
}
