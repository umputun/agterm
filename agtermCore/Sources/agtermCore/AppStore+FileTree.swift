import Foundation

// MARK: - File-tree panel

extension AppStore {
    /// The file-tree panel width default and drag/restore bounds, shared by the view's divider drag and the
    /// `restore()` clamp so the two can't drift (and a hand-edited snapshot can't drive an out-of-range frame).
    public static let fileTreeWidthDefault: Double = 260
    public static let fileTreeWidthMin: Double = 180
    public static let fileTreeWidthMax: Double = 560

    /// Shows or hides a session's file-tree panel and persists the visibility. On every SHOW edge the root
    /// is re-seeded from the session's current `effectiveCwd`, so re-opening the panel after the shell has
    /// `cd`'d elsewhere re-roots at wherever it is now rather than the stale directory it first opened at.
    /// Clean no-op (no write) for an unknown id or when the visibility already matches, so the delta-computed
    /// menu/toolbar/control callers stay idempotent.
    public func setFileTreeVisible(_ visible: Bool, forSession id: UUID) {
        guard let session = session(withID: id), session.fileTreeVisible != visible else { return }
        if visible { session.fileTreeRoot = session.effectiveCwd }
        session.fileTreeVisible = visible
        save()
    }

    /// Flips a session's file-tree panel visibility, seeding the root on the show edge (via
    /// `setFileTreeVisible`). No-op for an unknown id.
    public func toggleFileTree(_ id: UUID) {
        guard let session = session(withID: id) else { return }
        setFileTreeVisible(!session.fileTreeVisible, forSession: id)
    }

    /// Re-roots a session's file-tree panel AND forces a refresh (bumps `fileTreeRefreshToken`), so the panel
    /// re-reads the directory from disk even when the root path is unchanged. `path` is the target directory;
    /// nil re-roots at the session's current `effectiveCwd` (the refresh/menu form). Existence + is-directory
    /// validation is the caller's (app-side, FileManager) — this just sets the root. No-op for an unknown id.
    /// Not persisted (both fields are in-memory and re-derive on restore).
    public func rerootFileTree(_ id: UUID, to path: String? = nil) {
        guard let session = session(withID: id) else { return }
        session.fileTreeRoot = path ?? session.effectiveCwd
        session.fileTreeRefreshToken &+= 1
    }
}
