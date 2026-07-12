import Foundation

/// One entry in a session's file-tree panel: a name plus whether it is a directory.
///
/// Host-free value type. The app target does the actual `FileManager` enumeration and owns the live
/// `NSOutlineView` nodes (icons, lazily-loaded children, expansion state); this carries only the
/// identity bits the ORDERING and hidden-file rules need, so `swift test` can exercise the tree's
/// sort/filter logic without touching disk — the same host-free-logic / app-side-side-effect split the
/// module boundary requires (see `CLAUDE.md` "Module boundary").
public struct FileEntry: Equatable, Sendable {
    /// The last path component (the display name), e.g. `README.md` or `src`.
    public let name: String
    /// Whether this entry is a directory — drives "directories first" ordering and, app-side, whether the
    /// outline row is expandable.
    public let isDirectory: Bool

    public init(name: String, isDirectory: Bool) {
        self.name = name
        self.isDirectory = isDirectory
    }

    /// Hidden by Finder's convention: a leading dot (`.git`, `.env`). The panel drops these unless the
    /// caller opts into showing hidden files.
    public var isHidden: Bool { name.hasPrefix(".") }
}

/// The pure ordering and filtering rules for one file-tree directory listing, lifted out of the app-side
/// `FileManager` enumeration so they are unit-testable host-free.
public enum FileTreeOrder {
    /// Finder-like strict ordering: directories before files, then a case- and locale-insensitive name
    /// compare. A strict weak ordering suitable for `sorted(by:)`: identical entries and case-only twins
    /// (`Foo` vs `foo`, impossible within one real directory) compare "not before" in both directions, so
    /// the sort stays stable on the input order and never traps.
    public static func before(_ a: FileEntry, _ b: FileEntry) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    /// The entries in display order: directories first, then files, each group alphabetized
    /// case-insensitively.
    public static func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted(by: before)
    }

    /// The entries with hidden (dot-prefixed) ones dropped unless `showHidden` is on. Filtering commutes
    /// with sorting, so the call site may apply it before or after `sorted`.
    public static func filtered(_ entries: [FileEntry], showHidden: Bool) -> [FileEntry] {
        showHidden ? entries : entries.filter { !$0.isHidden }
    }
}
