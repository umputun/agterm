import Foundation

/// The sidebar focus filter: which workspaces the tree renders, the session set navigation and the
/// palettes derive from it, and the mutators/lifecycle guards that keep the filter in step with the
/// selection. Split out of the main `AppStore` declaration to keep each file focused; the stored
/// filter state itself stays on the class, since an extension cannot hold stored properties.
extension AppStore {
    /// Switches the focus filter OFF — KEEPING the marked set — when the newly selected session lives
    /// outside that set, so an explicit cross-set select (`session.select <id>` of a hidden session, a
    /// notification reveal, a move/close that reselects elsewhere) reveals its target: the active session
    /// is then always inside the visible set. The set survives so a hand-curated working set is not
    /// destroyed by a passive reveal — re-enabling it costs one flip of the bottom-bar toggle.
    /// Session navigation (`navigateSession`/`session.go`, Ctrl-Tab, attention-nav) is scoped to the
    /// filtered set (`navigableSessions`), so its targets are always in-set and never trip this — it
    /// stays the safety net only for the explicit cross-set cases. No-op when the filter is off, when
    /// nothing is selected, or when the selection sits in a member workspace. Persistence rides the
    /// caller's `selectSession` save.
    func disableFocusIfSelectionOutsideSet(_ sessionID: UUID?) {
        guard focusEnabled, let sessionID else { return }
        if let owner = workspace(forSession: sessionID)?.id, focusedWorkspaceIDs.contains(owner) { return }
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

    /// Restores the focus filter from a snapshot, PRUNING member ids absent from the restored tree and
    /// disabling the filter when the pruned set comes back empty. The prune is what keeps
    /// `enabled + empty` unrepresentable across a restore: an all-stale set (its workspaces deleted by
    /// another window, or a hand-edited file) would otherwise restore as an enabled-but-invisible filter,
    /// making the documented `focused && workspaceFilter` read-back contract lie — the tree would render
    /// in full while no workspace reported `focused`. A partially stale set keeps its survivors and stays
    /// enabled. Called from `restore(from:)` AFTER the tree is rebuilt, and deliberately writes the fields
    /// directly rather than going through the mutators, which would `save()` what was just read.
    func restoreFocus(from snapshot: Snapshot) {
        let present = Set(workspaces.map(\.id))
        focusedWorkspaceIDs = Set(snapshot.focusedWorkspaceIDs ?? []).intersection(present)
        focusEnabled = (snapshot.focusEnabled ?? false) && !focusedWorkspaceIDs.isEmpty
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

    /// The workspace a drop into EMPTY sidebar space (a Finder folder dropped below the rows) should land
    /// in, or nil to let the drop fall through to the current workspace. It is the marked workspace only
    /// when the filter is ENABLED and the set holds exactly ONE member — the state where the tree renders
    /// that single workspace, so the drop lands where the user is looking and adding a session cannot
    /// silently leave the filtered view. The `focusEnabled` term is load-bearing: with a workspace marked
    /// but the filter OFF the WHOLE tree is on screen, so the mark has no claim on an empty-space drop.
    /// Two or more members give no unambiguous target, so those fall through as well. Host-free, unlike
    /// the AppKit drop handler that consumes it, so the rule is unit-testable.
    public var dropFallbackWorkspaceID: UUID? {
        guard focusEnabled, focusedWorkspaceIDs.count == 1 else { return nil }
        return focusedWorkspaceIDs.first
    }
}
