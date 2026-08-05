/// One pane's terminal theme, overriding the app-wide one from Settings. A `dark` side makes the pane
/// track the macOS appearance exactly as the global theme does; without it the pane is pinned to `light`.
/// Stored per pane on `Session`, persisted in `SessionSnapshot`, carried on the control wire. Host-free:
/// the app target turns `configValue` into a per-surface ghostty config overlay (see `WatermarkConfig`)
/// and validates the names against the bundled theme catalog, which only it can locate.
public struct ThemeOverride: Codable, Sendable, Equatable {
    /// The light/single theme name — always present, so an override never resolves to "no theme".
    public var light: String
    /// The dark-appearance theme name; nil pins the pane to `light` whatever the system appearance is.
    public var dark: String?

    public init(light: String, dark: String? = nil) {
        self.light = light
        self.dark = dark
    }

    /// The raw ghostty `theme` value: a bare name, or the `light:…,dark:…` conditional libghostty resolves
    /// itself from the surface's color scheme (see `.claude/rules/libghostty.md`). The inverse of
    /// `ThemeName.resolved(from:isDark:)`.
    public var configValue: String {
        guard let dark else { return light }
        return "light:\(light),dark:\(dark)"
    }

    /// Rejects a name that would be re-read as a conditional pair or split the config line. Theme names may
    /// contain spaces (`3024 Day`), so only the grammar's own separators and control characters are barred.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains(",") && !name.contains(":")
            && !name.unicodeScalars.contains { $0.value < 0x20 }
    }
}
