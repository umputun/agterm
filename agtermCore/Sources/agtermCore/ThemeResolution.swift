import Foundation

/// Parses and composes ghostty's dual `theme = light:NAME,dark:NAME` syntax — the value form that
/// means "track the macOS appearance". Host-free so the parsing is unit-tested without an app host.
public enum ThemeResolution {
    /// The light/dark sides of a ghostty `theme` value, nil for an absent (or empty) side. A plain
    /// name (`"TokyoNight"`) has neither prefix and parses as `(nil, nil)`. Sides are order-independent
    /// and whitespace-tolerant; names may contain spaces.
    public static func components(_ raw: String) -> (light: String?, dark: String?) {
        var light: String?
        var dark: String?
        for part in raw.split(separator: ",") {
            let token = part.trimmingCharacters(in: .whitespaces)
            if token.hasPrefix("light:") {
                light = nonEmpty(String(token.dropFirst("light:".count)))
            } else if token.hasPrefix("dark:") {
                dark = nonEmpty(String(token.dropFirst("dark:".count)))
            }
        }
        return (light, dark)
    }

    /// Whether `raw` is the dual form (at least one `light:`/`dark:` side present) — the
    /// "sync with macOS appearance" state. A plain name or an empty string is not dual.
    public static func isDual(_ raw: String) -> Bool {
        let (light, dark) = components(raw)
        return light != nil || dark != nil
    }

    /// Compose the canonical dual value. Both sides are required — the dual form cannot carry an
    /// unnamed side (an "unset" side is expressed by collapsing to a plain single theme instead).
    public static func dualValue(light: String, dark: String) -> String {
        "light:\(light),dark:\(dark)"
    }

    /// The active theme name for `raw` given the appearance: the matching side of the dual form,
    /// falling back to whichever side is present; a plain value (no `light:`/`dark:` prefix) is
    /// returned unchanged.
    public static func activeThemeName(_ raw: String, isDark: Bool) -> String {
        let (light, dark) = components(raw)
        guard light != nil || dark != nil else { return raw }
        return (isDark ? dark : light) ?? light ?? dark ?? raw
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
