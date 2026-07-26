import Foundation

/// The sidebar focus filter: which workspaces the tree renders, the session set navigation and the
/// palettes derive from it, and the mutators/lifecycle guards that keep the filter in step with the
/// selection. Split out of the main `AppStore` declaration to keep each file focused; the stored
/// filter state itself stays on the class, since an extension cannot hold stored properties.
extension AppStore {
    /// Clears focus when the newly selected session lives outside the focused workspace, so an explicit
    /// cross-set select (`session.select <id>` of a hidden session, a notification reveal, a move/close
    /// that reselects elsewhere) reveals its target — the active session is then always inside the
    /// visible set. Session navigation (`navigateSession`/`session.go`, Ctrl-Tab, attention-nav) is now
    /// scoped to the filtered set (`navigableSessions`), so its targets are always in-set and never
    /// trip this — it stays the safety net only for the explicit cross-set cases. No-op when unfocused,
    /// when nothing is selected, or when the selection is inside the focused workspace. Persistence
    /// rides the caller's `selectSession` save.
    func autoUnfocusIfOutsideFocus(_ sessionID: UUID?) {
        guard let focusedWorkspaceID, let sessionID else { return }
        if workspace(forSession: sessionID)?.id != focusedWorkspaceID { self.focusedWorkspaceID = nil }
    }

    /// Sets (or clears) the focused workspace and persists it. Clean no-op (no write) when unchanged, so
    /// the delta-computed control/menu callers stay idempotent. Passing nil unfocuses.
    public func setFocusedWorkspace(_ id: UUID?) {
        guard focusedWorkspaceID != id else { return }
        focusedWorkspaceID = id
        pruneSidebarSelection()
        save()
    }

    /// The focused workspace, resolved from `focusedWorkspaceID` — nil when unfocused OR when the id is
    /// stale (its workspace no longer exists). The single id→workspace lookup the tree filter and the
    /// bottom-bar focus pill both read, so they can't drift.
    public var focusedWorkspace: Workspace? {
        guard let focusedWorkspaceID else { return nil }
        return workspaces.first(where: { $0.id == focusedWorkspaceID })
    }

    /// The workspaces the sidebar tree should render: just the focused workspace when `focusedWorkspaceID`
    /// is set AND that workspace still exists, else all workspaces. The source of truth the tree filters
    /// on; a stale focus id (its workspace gone) falls back to the full tree.
    public var visibleWorkspaces: [Workspace] {
        guard let focused = focusedWorkspace else { return workspaces }
        return [focused]
    }

    /// The session set navigation operates over — the VISIBLE/FILTERED set, not the whole tree: the
    /// flagged sessions in `.flagged` sidebar mode, the focused workspace's sessions when a workspace
    /// is focused, else all sessions. Computed live (`visibleWorkspaces` already collapses to the
    /// focused workspace, or the full tree when unfocused / the focus id is stale), so clearing the
    /// flag/focus naturally restores the full set. `navigateSession` next/prev WRAP within this set (an
    /// end lands on the opposite end, never leaking across the filter). Backs `navigateSession` (and via
    /// it `session.go`, attention-nav), the Ctrl-Tab MRU candidate set, AND the ⌃P session palette
    /// (`AppActions.paletteSessions`), so all follow the same filter as the visible sidebar.
    public var navigableSessions: [Session] {
        sidebarMode == .flagged ? flaggedSessions : visibleWorkspaces.flatMap(\.sessions)
    }
}
