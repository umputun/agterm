import Foundation

/// The sidebar focus filter: which workspaces the tree renders, the session set navigation and the
/// palettes derive from it, and the mutators/lifecycle guards that keep the filter in step with the
/// selection. Split out of the main `AppStore` declaration to keep each file focused; the stored
/// filter state itself stays on the class, since an extension cannot hold stored properties.
extension AppStore {
    /// Clears the focus filter when the newly selected session lives outside the marked set, so an
    /// explicit cross-set select (`session.select <id>` of a hidden session, a notification reveal, a
    /// move/close that reselects elsewhere) reveals its target — the active session is then always
    /// inside the visible set. Session navigation (`navigateSession`/`session.go`, Ctrl-Tab,
    /// attention-nav) is scoped to the filtered set (`navigableSessions`), so its targets are always
    /// in-set and never trip this — it stays the safety net only for the explicit cross-set cases.
    /// No-op when the filter is off, when nothing is selected, or when the selection sits in a member
    /// workspace. Persistence rides the caller's `selectSession` save.
    func autoUnfocusIfOutsideFocus(_ sessionID: UUID?) {
        guard focusEnabled, let sessionID else { return }
        if let owner = workspace(forSession: sessionID)?.id, focusedWorkspaceIDs.contains(owner) { return }
        focusedWorkspaceIDs.removeAll()
        focusEnabled = false
    }

    /// Replaces the marked set with just `id` and enables the filter; nil clears the set and disables it.
    /// The single-workspace convenience every row-menu/menu-bar/`workspace.focus on` caller drives. Clean
    /// no-op (no write) when nothing changes, so the delta-computed control/menu callers stay idempotent.
    public func setFocusedWorkspace(_ id: UUID?) {
        let wantIDs: Set<UUID> = id.map { [$0] } ?? []
        let wantEnabled = id != nil
        guard focusedWorkspaceIDs != wantIDs || focusEnabled != wantEnabled else { return }
        focusedWorkspaceIDs = wantIDs
        focusEnabled = wantEnabled
        pruneSidebarSelection()
        save()
    }

    /// Adds or removes one workspace from the marked set, leaving the other members alone. Adding also
    /// enables the filter (marking is only meaningful when it applies); removing disables it once the set
    /// empties, keeping `enabled + empty` unrepresentable. Clean no-op (no write) when nothing changes.
    public func setFocusMembership(_ id: UUID, member: Bool) {
        var wantIDs = focusedWorkspaceIDs
        if member { wantIDs.insert(id) } else { wantIDs.remove(id) }
        let wantEnabled = wantIDs.isEmpty ? false : (member || focusEnabled)
        guard focusedWorkspaceIDs != wantIDs || focusEnabled != wantEnabled else { return }
        focusedWorkspaceIDs = wantIDs
        focusEnabled = wantEnabled
        pruneSidebarSelection()
        save()
    }

    /// Turns the focus filter on or off WITHOUT touching the marked set, so peeking at the whole tree
    /// costs one flip. Enabling an empty set is refused (a no-op), matching the bottom-bar toggle, which
    /// is disabled in exactly that state — that is what makes `enabled + empty` unrepresentable. Clean
    /// no-op (no write) when nothing changes.
    public func setFocusEnabled(_ on: Bool) {
        let want = on && !focusedWorkspaceIDs.isEmpty
        guard focusEnabled != want else { return }
        focusEnabled = want
        pruneSidebarSelection()
        save()
    }

    /// The workspaces the sidebar tree should render: the marked set when the filter is enabled, else
    /// all workspaces. The source of truth the tree filters on. The empty-result fallback is defensive
    /// belt-and-braces — the mutators above keep `enabled + empty` and an all-stale enabled set out of
    /// reach, so it cannot be hit in practice.
    public var visibleWorkspaces: [Workspace] {
        guard focusEnabled else { return workspaces }
        let visible = workspaces.filter { focusedWorkspaceIDs.contains($0.id) }
        return visible.isEmpty ? workspaces : visible
    }

    /// The session set navigation operates over — the VISIBLE/FILTERED set, not the whole tree: the
    /// flagged sessions in `.flagged` sidebar mode, the marked workspaces' sessions when the focus
    /// filter is on, else all sessions. Computed live (`visibleWorkspaces` already collapses to the
    /// marked set, or the full tree when the filter is off), so clearing the flag/filter naturally
    /// restores the full set. `navigateSession` next/prev WRAP within this set (an end lands on the
    /// opposite end, never leaking across the filter). Backs `navigateSession` (and via it `session.go`,
    /// attention-nav), the Ctrl-Tab MRU candidate set, AND the ⌃P session palette
    /// (`AppActions.paletteSessions`), so all follow the same filter as the visible sidebar.
    public var navigableSessions: [Session] {
        sidebarMode == .flagged ? flaggedSessions : visibleWorkspaces.flatMap(\.sessions)
    }
}
