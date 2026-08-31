import Foundation

/// Reads and writes the app `Snapshot` as JSON on disk. The storage directory is an init parameter
/// (defaulting to `~/Library/Application Support/agterm`) so tests can point it at a temp dir.
///
/// Recovery contract: a missing file, corrupt JSON, or a version mismatch all resolve to a default empty
/// `Snapshot` — `load()` never throws out to the caller. `save(_:)` writes atomically (temp then replace).
public struct PersistenceStore {
    public enum LoadError: Error, Equatable {
        case versionMismatch
    }
    private let directory: URL
    private let fileName: String

    private var fileURL: URL { directory.appendingPathComponent(fileName) }

    /// Creates a store rooted at `directory`, defaulting to the app's Application Support directory.
    /// `fileName` defaults to `workspaces.json`; a per-window store overrides it to `windows/<id>.json`.
    public init(directory: URL = PersistenceStore.defaultDirectory, fileName: String = "workspaces.json") {
        self.directory = directory
        self.fileName = fileName
    }

    /// `~/Library/Application Support/agterm`.
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("agterm", isDirectory: true)
    }

    /// Loads the snapshot, recovering a default empty one on any failure (missing file, unreadable data,
    /// corrupt JSON, or version mismatch).
    public func load() -> Snapshot {
        (try? loadChecked()) ?? Snapshot()
    }

    /// Strict launch-inventory read. Unlike `load()`, every read/decode/version failure reaches the caller,
    /// which must not reap daemons against a partial persisted-name set.
    public func loadChecked() throws -> Snapshot {
        let data = try Data(contentsOf: fileURL)
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        guard snapshot.version == Snapshot.currentVersion else { throw LoadError.versionMismatch }
        return snapshot
    }

    /// Writes the snapshot atomically: `Data.write(options: .atomic)` writes an auxiliary temp file in the
    /// same directory and renames it into place, so a crashed write never leaves a half-written destination.
    /// Creates the directory if needed.
    public func save(_ snapshot: Snapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }
}
