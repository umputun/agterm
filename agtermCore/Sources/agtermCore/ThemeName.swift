import Foundation

/// Reduces a ghostty `theme` value to the theme name active for the current appearance.
///
/// The `light:…,dark:…` form must collapse to one name before agterm's by-hand `selection-*` lookup:
/// the raw form matches no theme file, so the selected sidebar row falls back to an unreadable wash.
/// Host-free so it is unit-tested.
public enum ThemeName {
    /// The theme name for `value` under the appearance. Only a well-formed `light:…,dark:…` (both sides
    /// present) resolves to a variant; a plain or malformed value is returned as-is.
    public static func resolved(from value: String, isDark: Bool) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        var light: String?
        var dark: String?
        for segment in trimmed.split(separator: ",") {
            let part = segment.trimmingCharacters(in: .whitespaces)
            if let name = variant("light:", in: part) {
                light = name
            } else if let name = variant("dark:", in: part) {
                dark = name
            }
        }
        // The split form needs both sides; one-sided or malformed is a plain name.
        guard let light, let dark else { return trimmed }
        return isDark ? dark : light
    }

    /// The trimmed name after a case-insensitive `light:`/`dark:` prefix; nil if absent or empty.
    private static func variant(_ prefix: String, in part: String) -> String? {
        guard part.lowercased().hasPrefix(prefix) else { return nil }
        let name = String(part.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
