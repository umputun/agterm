import Foundation

/// User-facing appearance settings, persisted independently of the workspace tree.
///
/// Every field is optional: nil means "use the ghostty default", and a settings file written
/// before a field existed still decodes — that optionality IS the forward-compat mechanism, so
/// there is no version field (a version bump would only add a discard-on-mismatch path that wipes
/// the user's settings).
public struct AppSettings: Codable, Equatable, Sendable {
    /// Where a new (⌘T) session opens. Stored as the `newSessionDirectory` raw string so an unknown
    /// future value decodes tolerantly to `home` (the AppSettings forward-compat rule) instead of
    /// failing the whole decode. `home` is also the nil case (the default), so picking it clears the
    /// field and keeps `settings.json` minimal.
    public enum NewSessionDirectory: String, CaseIterable, Sendable {
        case home
        case currentSession
        case custom
    }

    /// The app's out-of-the-box theme — a bundled theme applied on a fresh install (no saved
    /// settings), seeded by `SettingsStore.load()`. Distinct from `theme == nil`, which means
    /// ghostty's built-in default (the "default ghostty" entry in the theme picker).
    public static let defaultTheme = "agterm"

    /// The out-of-the-box inactive-split-pane mute strength on the 0...10 scale (0 = no mute, 10 =
    /// extreme), used when `inactivePaneMuteStrength` is nil. 5 maps to the historical 0.4 opacity.
    public static let defaultInactivePaneMuteStrength = 5

    /// The out-of-the-box sidebar background shift on the 0...10 scale, used when
    /// `sidebarBackgroundShift` is nil. 5 is the neutral center (sidebar matches the terminal
    /// background); below 5 lightens it, above 5 darkens it.
    public static let defaultSidebarBackgroundShift = 5

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
    /// Mouse scroll speed multiplier (ghostty `mouse-scroll-multiplier`), applied as a bare value to
    /// both the notched wheel and the trackpad. nil means agterm's default of 3. UNLIKE the other
    /// fields, this key is ALWAYS emitted (nil emits `= 3`), so the default is effective rather than
    /// deferring to ghostty's per-device defaults (discrete 3 / precision 1) — a fresh install scrolls
    /// at 3, which speeds the trackpad up out of the box. Consequence: it overrides any
    /// `mouse-scroll-multiplier` set in the user's own `~/.config/ghostty/config`.
    public var mouseScrollMultiplier: Double?
    /// How strongly the inactive split pane's text is muted, on a 0...10 scale (0 = no mute, 10 =
    /// extreme); nil means the default (`defaultInactivePaneMuteStrength`). Applied as a SwiftUI
    /// overlay opacity in the app target (see `muteOpacity(strength:)`), NOT a ghostty key — it never
    /// appears in `ghosttyConfigLines()`.
    public var inactivePaneMuteStrength: Int?
    /// How much darker or lighter the sidebar background is than the terminal background, on a 0...10
    /// scale where 5 is neutral (identical to the terminal); below 5 lightens, above 5 darkens. nil
    /// means the default (`defaultSidebarBackgroundShift`, neutral). Applied in the app target as a
    /// SwiftUI wash behind the sidebar (see `sidebarShiftAmount`), NOT a ghostty key — it never appears
    /// in `ghosttyConfigLines()`.
    public var sidebarBackgroundShift: Int?
    /// Whether, on app restart, each pane re-runs the command it was running at the last clean quit: a
    /// captured foreground command (`SessionSnapshot.foregroundCommand`) and a `session.new --command`
    /// session's persisted `initialCommand`. nil means the default (off). An app-level behavior flag, NOT a
    /// ghostty key — it never appears in `ghosttyConfigLines()`.
    public var restoreRunningCommand: Bool?
    /// Whether agterm also loads the user's GLOBAL ghostty config (`~/.config/ghostty/config`) on top of
    /// its bundled defaults. nil means the default (off): agterm is self-contained, so a config written
    /// for the standalone Ghostty.app does NOT silently change agterm. Opt in to share one config across
    /// both. The agterm-scoped `~/.config/agterm/ghostty.conf` is ALWAYS loaded regardless and is the
    /// place for agterm overrides/customizations. An app-level flag read at config-load time (NOT a
    /// ghostty key, so it never appears in `ghosttyConfigLines()`), gating which files `loadConfig` reads.
    public var inheritGlobalGhosttyConfig: Bool?
    /// Whether the window title bar shows the attention bell icon (window-wide non-idle session status at
    /// a glance). nil means the default (off). An app-level chrome flag, NOT a ghostty key — it never
    /// appears in `ghosttyConfigLines()`; it only gates whether the titlebar builds the icon.
    public var attentionButtonEnabled: Bool?
    /// Name of the system sound played when a session enters the `blocked` status (e.g. `Glass`, resolved by
    /// `NSSound(named:)`), or nil/empty for no sound (the default). A per-call `session.status --sound`
    /// overrides this. An app-level value played at the AppKit level, NOT a ghostty key — it never appears
    /// in `ghosttyConfigLines()`.
    public var blockedStatusSoundName: String?
    /// Whether a right-click pastes the clipboard (ghostty `right-click-action`). nil means the default
    /// (on): agterm forwards right-/middle-click to libghostty, so a right-click pastes out of the box.
    /// UNLIKE most flags this IS a ghostty key — `ghosttyConfigLines()` emits `right-click-action = paste`
    /// when on and `= ignore` when off, so the UI owns the key (the settings conf loads last and wins over
    /// a `right-click-action` in the user's own `ghostty.conf`). agterm has no terminal context menu, so
    /// paste-or-off is the whole meaningful choice.
    public var rightClickPaste: Bool?
    /// Which directory a new (⌘T) session opens in, as a `NewSessionDirectory` raw value; nil means the
    /// default (`home`). `currentSession` inherits the active session's focused-pane cwd, `custom` uses
    /// `newSessionCustomDirectory`. An app-level behavior value read by `AppActions.newSession()`, NOT a
    /// ghostty key — it never appears in `ghosttyConfigLines()`. Resolved by `resolveNewSessionCwd(...)`.
    public var newSessionDirectory: String?
    /// The fixed directory a new session opens in when `newSessionDirectory` is `custom`; nil/empty falls
    /// back to home. Ignored for the `home`/`currentSession` modes. Set by the Settings directory picker.
    public var newSessionCustomDirectory: String?

    public init(fontFamily: String? = nil, fontSize: Double? = nil, theme: String? = nil,
                backgroundOpacity: Double? = nil, backgroundBlur: Int? = nil, notificationsEnabled: Bool? = nil,
                compactToolbar: Bool? = nil, notificationBadgeEnabled: Bool? = nil,
                activeStatusColorHex: String? = nil, blockedStatusColorHex: String? = nil,
                completedStatusColorHex: String? = nil, configDirectory: String? = nil,
                mouseScrollMultiplier: Double? = nil, inactivePaneMuteStrength: Int? = nil,
                sidebarBackgroundShift: Int? = nil, restoreRunningCommand: Bool? = nil,
                inheritGlobalGhosttyConfig: Bool? = nil, attentionButtonEnabled: Bool? = nil,
                blockedStatusSoundName: String? = nil, rightClickPaste: Bool? = nil,
                newSessionDirectory: String? = nil, newSessionCustomDirectory: String? = nil) {
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
        self.mouseScrollMultiplier = mouseScrollMultiplier
        self.inactivePaneMuteStrength = inactivePaneMuteStrength
        self.sidebarBackgroundShift = sidebarBackgroundShift
        self.restoreRunningCommand = restoreRunningCommand
        self.inheritGlobalGhosttyConfig = inheritGlobalGhosttyConfig
        self.attentionButtonEnabled = attentionButtonEnabled
        self.blockedStatusSoundName = blockedStatusSoundName
        self.rightClickPaste = rightClickPaste
        self.newSessionDirectory = newSessionDirectory
        self.newSessionCustomDirectory = newSessionCustomDirectory
    }

    /// The working directory a new session should open in, resolving the `newSessionDirectory` mode
    /// against the active session's focused-pane cwd and the home directory. An unknown/nil mode, a
    /// nil/blank `currentSessionCwd`, or a nil/blank custom path all fall back to `home`: `home` → home;
    /// `currentSession` → `currentSessionCwd` (else home); `custom` → `newSessionCustomDirectory` (else
    /// home). Host-free so `AppActions.newSession()` and the tests share one resolution.
    public func resolveNewSessionCwd(currentSessionCwd: String?, home: String) -> String {
        switch NewSessionDirectory(rawValue: newSessionDirectory ?? "") ?? .home {
        case .home:
            return home
        case .currentSession:
            guard let cwd = currentSessionCwd, !cwd.isEmpty else { return home }
            return cwd
        case .custom:
            guard let dir = newSessionCustomDirectory, !dir.isEmpty else { return home }
            return dir
        }
    }

    /// The SwiftUI overlay opacity for a given inactive-pane mute strength: the strength is clamped to
    /// 0...10 and scaled by 0.08, so 0 → 0 (no mute), 5 → 0.4 (the historical default), 10 → 0.8
    /// (extreme). The overlay is the terminal background color, so a higher opacity blends the pane's
    /// text further toward the background (less bright) while leaving background pixels unchanged.
    public static func muteOpacity(strength: Int) -> Double {
        Double(min(10, max(0, strength))) * 0.08
    }

    /// The signed sidebar background shift for a given strength: the strength is clamped to 0...10 and
    /// measured from the neutral center (5), so 5 → 0 (no shift), 0 → -0.30 (full lighten), 10 → +0.30
    /// (full darken). A positive amount darkens (a black wash over the sidebar), a negative one lightens
    /// (a white wash); the magnitude is the wash opacity. Compositing that wash over the window
    /// background is what the app target's sidebar tint does (`WindowContentView.sidebarTintWash`).
    public static func sidebarShiftAmount(strength: Int) -> Double {
        Double(min(10, max(0, strength)) - 5) * 0.06
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
        // always emitted (nil = agterm's default of 3), so the default speed is effective rather than
        // ghostty's per-device defaults. a bare value sets both the wheel and the trackpad.
        lines.append("mouse-scroll-multiplier = \(Self.format(mouseScrollMultiplier ?? 3))")
        // always emitted (nil = on): agterm forwards right-/middle-click to libghostty, so a right-click
        // pastes by default. off emits `ignore` so the toggle hard-disables it (the settings conf loads
        // last, so the UI owns the key over any `right-click-action` in the user's own ghostty.conf).
        lines.append("right-click-action = \((rightClickPaste ?? true) ? "paste" : "ignore")")
        return lines
    }

    /// Integer sizes render without a trailing `.0` (`14`, not `14.0`); fractional sizes keep it.
    private static func format(_ size: Double) -> String {
        size == size.rounded() ? String(Int(size)) : String(size)
    }
}
