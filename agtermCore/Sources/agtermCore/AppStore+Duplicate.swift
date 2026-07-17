import Foundation

extension AppStore {
    /// Duplicates a session: a fresh shell in the SAME workspace, inserted directly after the source, rooted
    /// at the source's focused-pane cwd (`focusedCwd` — the directory the sidebar row shows and the one
    /// "Reveal in Finder" opens, so a duplicate lands where the row says it will).
    ///
    /// ONLY the directory carries over. The duplicate is a plain new session — auto basename (no inherited
    /// `customName`), no split, no scratch, no status, unflagged, no `initialCommand` — i.e. exactly `New
    /// Session` seeded with the source's cwd, not a clone of its state. Returns nil if no session matches.
    ///
    /// Backs the sidebar row's "Duplicate" and the `session.duplicate` control command.
    @discardableResult
    public func duplicateSession(_ id: UUID) -> Session? {
        guard let session = session(withID: id), let location = sessionLocation(ofSession: id) else { return nil }
        return addSession(toWorkspace: location.workspace, cwd: session.focusedCwd, at: location.index + 1)
    }
}
