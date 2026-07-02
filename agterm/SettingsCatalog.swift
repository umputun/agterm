import AppKit
import agtermCore

/// Read-only catalogs for the Appearance settings pickers: the bundled ghostty themes and the
/// system's monospaced font families. Pure lookups against the bundle / font manager.
enum SettingsCatalog {
    /// ghostty theme names = the file names in the bundled `ghostty/themes` directory, sorted
    /// case-insensitively. Empty if the directory is missing.
    static func themeNames() -> [String] {
        guard let themesDir = Bundle.main.url(forResource: "ghostty", withExtension: nil)?
            .appendingPathComponent("themes", isDirectory: true),
            let names = try? FileManager.default.contentsOfDirectory(atPath: themesDir.path)
        else { return [] }
        return ThemeCatalog(names: names).names
    }

    /// Monospaced font family names available on the system, sorted. Filters to families whose
    /// regular face reports the fixed-pitch trait.
    static func monospacedFontFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies
            .filter { family in
                guard let font = NSFont(name: family, size: 12) else { return false }
                return font.fontDescriptor.symbolicTraits.contains(.monoSpace)
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
