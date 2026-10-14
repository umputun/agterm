import Foundation

/// Reduces a ghostty `theme` value to the name active for the current appearance. The `light:…,dark:…`
/// form must collapse to one name before agterm's by-hand `selection-*` lookup: the raw form matches no
/// theme file, so the selected sidebar row loses the theme's selection colors. Host-free, so unit-tested.
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
        guard let light, let dark else { return trimmed }
        return isDark ? dark : light
    }

    /// candidatePaths lists the theme files to try, in libghostty's order, for a value already passed through
    /// `expandingHome`. A relative value with a slash yields none, as ghostty rejects it.
    public static func candidatePaths(for name: String, userThemesDirectory: String,
                                      bundledThemesDirectory: String?) -> [String] {
        if name.hasPrefix("/") { return [name] }
        guard !name.isEmpty, !name.contains("/") else { return [] }
        return [userThemesDirectory, bundledThemesDirectory].compactMap { dir in
            dir.map { ($0 as NSString).appendingPathComponent(name) }
        }
    }

    /// expandingHome replaces a leading `~/` with `home`, as libghostty does to a theme value before lookup;
    /// `~` alone and `~user` are left as they are.
    public static func expandingHome(_ value: String, home: String) -> String {
        guard value.hasPrefix("~/") else { return value }
        return (home as NSString).appendingPathComponent(String(value.dropFirst(2)))
    }

    /// userThemesDirectory is ghostty's user themes directory; an empty `XDG_CONFIG_HOME` counts as unset.
    public static func userThemesDirectory(environment: [String: String], home: String) -> String {
        let configHome = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (home as NSString).appendingPathComponent(".config")
        return (configHome as NSString).appendingPathComponent("ghostty/themes")
    }

    /// variant returns the trimmed, unquoted name after a case-insensitive `light:`/`dark:` prefix, or nil if
    /// absent or empty.
    private static func variant(_ prefix: String, in part: String) -> String? {
        guard part.lowercased().hasPrefix(prefix) else { return nil }
        let name = GhosttyConfigText.unquoted(String(part.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces))
        return name.isEmpty ? nil : name
    }
}
