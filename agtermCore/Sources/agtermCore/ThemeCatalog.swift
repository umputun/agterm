import Foundation

/// Host-free facts for agterm's theme picker and control API. The app target still owns locating the
/// bundled ghostty themes directory; this catalog owns ordering, display rows, ids, and default-theme
/// resolution so the Settings picker, palette, and control path stay aligned.
public struct ThemeCatalog: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let id: String
        public let name: String?
        public let title: String

        public var isDefault: Bool { name == nil }
    }

    public static let defaultTitle = "default ghostty"
    public static let defaultID = "theme:__default__"

    public let names: [String]

    public init(names: [String]) {
        self.names = Self.sorted(names)
    }

    /// The theme names in `directory` (one file per theme), sorted case-insensitively. Empty when the
    /// directory is absent or empty.
    public static func names(in directory: String) -> [String] {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: directory), !items.isEmpty else {
            return []
        }
        return sorted(items)
    }

    public var entries: [Entry] {
        [Entry(id: Self.defaultID, name: nil, title: Self.defaultTitle)] + names.map {
            Entry(id: Self.id(for: $0), name: $0, title: $0)
        }
    }

    public static func id(for name: String?) -> String {
        name.map { "theme:\($0)" } ?? defaultID
    }

    /// A nil or whitespace-only input selects ghostty's built-in default; otherwise the trimmed theme
    /// name is returned for exact matching against `names`.
    public static func resolvedName(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    public func contains(name: String) -> Bool {
        names.contains(name)
    }

    private static func sorted(_ names: [String]) -> [String] {
        names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
