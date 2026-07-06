import Foundation

/// Resolves a ghostty `theme` config value to the single theme name active for a given appearance.
///
/// ghostty accepts two forms (https://ghostty.org/docs/config/reference#theme): a plain name
/// (`theme = Gruvbox Dark Hard`), or an appearance-split `theme = light:NameA,dark:NameB` that follows
/// the system light/dark mode (order-independent, whitespace-trimmed). libghostty resolves
/// `background`/`foreground` for both forms, but agterm parses the optional `selection-*` colors by hand
/// from the theme file — so the split form must be reduced to ONE name before that file lookup, else the
/// whole `light:…,dark:…` string is used as a filename, no theme file matches, and the sidebar selection
/// pill falls back to an unreadable wash. Host-free (Foundation-only) so it is unit-tested; the app passes
/// in the current appearance.
public enum ThemeName {
    /// The theme name to load for `value` under the given appearance. A plain value is returned trimmed.
    /// For the `light:…,dark:…` form the matching variant is returned, falling back to the other variant,
    /// then to the trimmed raw value, if a side is missing.
    public static func resolved(from value: String, isDark: Bool) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        var light: String?
        var dark: String?
        var sawPrefix = false
        for segment in trimmed.split(separator: ",") {
            let part = segment.trimmingCharacters(in: .whitespaces)
            if let name = variant("light:", in: part) {
                light = name
                sawPrefix = true
            } else if let name = variant("dark:", in: part) {
                dark = name
                sawPrefix = true
            }
        }
        guard sawPrefix else { return trimmed }
        return (isDark ? dark : light) ?? dark ?? light ?? trimmed
    }

    /// The name after a `light:`/`dark:` prefix (case-insensitive), trimmed; nil when the prefix is absent.
    private static func variant(_ prefix: String, in part: String) -> String? {
        guard part.lowercased().hasPrefix(prefix) else { return nil }
        return String(part.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
}
