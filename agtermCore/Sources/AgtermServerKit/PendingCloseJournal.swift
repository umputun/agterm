import Foundation
import agtermCore

/// PendingCloseJournal is the on-disk list of sessions an undoable close holds, with their panes. A pending close
/// lives only in memory and the saved catalog may or may not still hold its rows, so after a crash inside the grace
/// this list is what lets the next start finish the close: a row the catalog still holds closes with no second history
/// entry, and the panes of one it lacks are ended.
@MainActor
final class PendingCloseJournal {
    struct Entry: Codable, Equatable {
        let session: UUID
        let panes: [UUID]
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static let fileName = "pending-closes.json"

    private let url: URL
    private var written: [Entry]?

    init(directory: URL) {
        url = directory.appendingPathComponent(Self.fileName)
    }

    /// load reads the entries a previous run left; a missing file has none, and one that does not read is an error
    /// rather than none, since clearing it would drop the only record of those closes.
    func load() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            return try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))
        } catch {
            throw Failure(description: "\(Self.fileName) cannot be read, left untouched: \(error)")
        }
    }

    /// record writes the store's pending closes when they differ from the last write; false when the write failed. It
    /// writes nothing while the store's last catalog save failed: the journal is then the only record of closes the
    /// saved catalog may not reflect.
    @discardableResult
    func record(_ store: AppStore) -> Bool {
        guard !store.snapshotUnsaved else { return false }
        return write(store.pendingCloseMembers().map { Entry(session: $0.session.id, panes: PaneIdentityInventory.identities(in: [$0.session])) })
    }

    private func write(_ entries: [Entry]) -> Bool {
        guard entries != written else { return true }
        do {
            try JSONEncoder().encode(entries).write(to: url, options: .atomic)
            written = entries
            return true
        } catch {
            FileHandle.standardError.write(Data("agterm-server: could not save pending closes: \(error)\n".utf8))
            return false
        }
    }

    /// recover finishes every close a previous run left pending. The journal empties only once the catalog without
    /// those rows is saved, and a failure of either write throws, so the server never serves against stale entries.
    func recover(into store: AppStore, panes: ServerPanes) throws {
        let entries = try load()
        guard !entries.isEmpty else { return }
        for entry in entries {
            if store.session(withID: entry.session) != nil {
                store.discardSession(entry.session)
            } else {
                panes.end(entry.panes)
            }
        }
        guard store.saveChecked() else { throw Failure(description: "the catalog without the closed sessions could not be saved") }
        guard write([]) else { throw Failure(description: "\(Self.fileName) could not be cleared") }
    }
}
