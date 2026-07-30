import Foundation

/// The sidebar focus filter: which workspaces the tree renders, the session set navigation and the
/// palettes derive from it, and the mutators/lifecycle guards keeping the filter in step with the
/// selection. The stored filter state stays on the class — an extension cannot hold stored properties.
extension AppStore {
    /// Switches the focus filter OFF — KEEPING the marked set — when the newly selected session lives
    /// outside it, so an explicit cross-set select (`session.select <id>` of a hidden session, a
    /// notification reveal, a move/close that reselects elsewhere) reveals its target and the active
    /// session is always inside the visible set. Navigation is scoped to the filtered set
    /// (`navigableSessions`), so its targets never trip this. No-op when the filter is off, nothing is
    /// selected, or the selection sits in a member workspace; persistence rides the caller's
    /// `selectSession` save. Also a no-op in `.flagged` mode — that flat list is cross-workspace and
    /// ignores the marked set, so a selection outside it has not navigated past the filter; without the
    /// term, entering the flagged view with the only flagged session in an unmarked workspace silently
    /// switches the filter off. Returning to `.tree` re-applies it.
    func disableFocusIfSelectionOutsideSet(_ sessionID: UUID?) {
        guard focusEnabled, sidebarMode != .flagged, let sessionID else { return }
        if let owner = workspace(forSession: sessionID)?.id, focusedWorkspaceIDs.contains(owner) { return }
        focusEnabled = false
    }

    /// Replaces the marked set with just `id` and ENABLES the filter — the single-workspace zoom every
    /// row-menu/menu-bar/`workspace.focus on` caller drives. No-op for an id naming no workspace: a
    /// phantom member no tree can render breaks the row-visibility read-back contract
    /// (`ControlWorkspaceNode.focused`) until the next restore prunes it.
    func setFocusedWorkspace(_ id: UUID) {
        guard workspaces.contains(where: { $0.id == id }) else { return }
        commitFocus(ids: [id], enabled: true)
    }

    /// Empties the marked set and switches the filter off, restoring the full tree — the menu/palette
    /// "Clear Focus" and the clearing half of the replace-toggle. Clean no-op when nothing is marked.
    /// Distinct from `setFocusEnabled(false)`, which keeps the set and only stops applying it.
    public func clearFocus() {
        commitFocus(ids: [], enabled: false)
    }

    /// Replace-TOGGLE: clears the filter when `id` is the SOLE marked workspace and the filter applies,
    /// else replaces the marked set with it (enabling). The row menu's Focus/Unfocus, the
    /// `focus_workspace` keybind/menu item and `workspace.focus toggle` share this ONE definition, so a
    /// "toggle" can never mean two things. No-op on an unknown id, like `setFocusedWorkspace`.
    public func toggleFocusedWorkspace(_ id: UUID) {
        if isSoleFocus(id) { clearFocus() } else { setFocusedWorkspace(id) }
    }

    /// The ONE workspace the tree is zoomed to — the sole marked workspace while the filter APPLIES, else
    /// nil. The single definition, read by `isSoleFocus(_:)`, the sidebar's force-expand of a zoomed-to
    /// workspace, and the empty-space drop fallback (a Finder folder dropped below the rows lands where
    /// the user is looking, so adding a session cannot silently leave the filtered view). The
    /// `focusEnabled` term is load-bearing: marked but filter OFF means the WHOLE tree is on screen, so
    /// nothing is zoomed to; two or more members have no unambiguous answer either.
    public var soleFocusedWorkspaceID: UUID? {
        guard focusEnabled, focusedWorkspaceIDs.count == 1 else { return nil }
        return focusedWorkspaceIDs.first
    }

    /// Whether `id` is the workspace the tree is zoomed to — the "already focused on this one" state,
    /// which is what makes Focus read Unfocus and what a `toggle` clears.
    public func isSoleFocus(_ id: UUID) -> Bool { soleFocusedWorkspaceID == id }

    /// `isSoleFocus` for the CURRENT workspace (the one new sessions land in) — the fact the keyless View ▸
    /// Focus/Unfocus Workspace item needs, since it has no clicked row and targets `currentWorkspaceID`
    /// exactly as `AppActions.focusActiveWorkspace()` does.
    public var isCurrentWorkspaceSoleFocus: Bool {
        guard let id = currentWorkspaceID else { return false }
        return isSoleFocus(id)
    }

    /// Whether the CURRENT workspace is already in the marked set — what View ▸ Add Workspace to Focus and
    /// its palette twin read to avoid offering a silent no-op (the row menu instead flips to "Remove from
    /// Focus", which it can do because it has a clicked row).
    public var isCurrentWorkspaceFocusMember: Bool {
        guard let id = currentWorkspaceID else { return false }
        return focusedWorkspaceIDs.contains(id)
    }

    /// Applies one `workspace.focus` mode to `id`. Host-free, so the mode-to-mutator mapping is unit
    /// tested, the app-side control arm keeps only target resolution, and the GUI's replace-toggle can't
    /// drift from the wire's `toggle`. Every arm is delta-guarded, so each mode is idempotent.
    public func applyFocusMode(_ mode: ControlWorkspaceFocusMode, to id: UUID) {
        switch mode {
        case .on: setFocusedWorkspace(id)
        case .off: setFocusMembership(id, member: false)
        case .add: setFocusMembership(id, member: true)
        case .toggle: toggleFocusedWorkspace(id)
        }
    }

    /// Applies one `workspace.filter` mode to this window's filter flag, leaving the marked set alone.
    /// Host-free half of the control arm (which keeps only the window resolution), so the mode-to-flag
    /// mapping — including the refusal to enable an empty set — is unit tested rather than re-spelled.
    public func applyWorkspaceFilter(_ mode: ControlToggleMode) {
        setFocusEnabled(mode.desiredValue(current: focusEnabled))
    }

    /// Adds or removes one workspace from the marked set, leaving the other members alone. Marking ONLY
    /// marks — an add that enabled the filter would hide the very rows the next add needs — so a working
    /// set is built row by row with the whole tree on screen; `setFocusedWorkspace(_:)` (the replacing
    /// "Focus") is the one that enables immediately. Removing still disables the filter once the set
    /// empties. Marking is refused for an id naming no workspace, so no phantom member is ever persisted;
    /// un-marking is never gated on existence, so a stale id already in the set stays removable.
    public func setFocusMembership(_ id: UUID, member: Bool) {
        if member, !workspaces.contains(where: { $0.id == id }) { return }
        var wantIDs = focusedWorkspaceIDs
        if member { wantIDs.insert(id) } else { wantIDs.remove(id) }
        commitFocus(ids: wantIDs, enabled: focusEnabled)
    }

    /// Turns the focus filter on or off WITHOUT touching the marked set, so peeking at the whole tree
    /// costs one flip. Enabling an empty set is refused (a no-op), matching the bottom-bar toggle, which
    /// is disabled in exactly that state.
    public func setFocusEnabled(_ on: Bool) {
        commitFocus(ids: focusedWorkspaceIDs, enabled: on)
    }

    /// The single write point for the two filter fields: clamps `enabled` to false on an empty set (the
    /// guard making `enabled + empty` unrepresentable), skips the write when nothing changes (so the
    /// delta-computed control/menu callers stay idempotent and no-op writes never persist), then prunes
    /// the sidebar selection and saves.
    private func commitFocus(ids: Set<UUID>, enabled: Bool) {
        let wantEnabled = enabled && !ids.isEmpty
        guard focusedWorkspaceIDs != ids || focusEnabled != wantEnabled else { return }
        focusedWorkspaceIDs = ids
        focusEnabled = wantEnabled
        pruneSidebarSelection()
        reselectIfSelectionHidden()
        save()
    }

    /// Drops `id` from the marked set, disabling the filter once it empties — the LIFECYCLE half of the
    /// `enabled + empty` invariant, for the paths that remove a workspace outright (`removeWorkspace`,
    /// `softRemoveWorkspace`) rather than un-marking it, so a further removal path gets it for free.
    /// Deliberately does NOT `save()` or prune the sidebar selection: its callers do both.
    func dropFocusMember(_ id: UUID) {
        focusedWorkspaceIDs.remove(id)
        if focusedWorkspaceIDs.isEmpty { focusEnabled = false }
    }

    /// Marks a freshly created workspace so it is visible while the filter applies (the auto-reveal
    /// contract of `addWorkspace`/`ensureWorkspace`); a no-op when the filter is off, where the whole tree
    /// is on screen and the set must not widen behind the user's back. Save-free: `addWorkspace` saves.
    func revealNewFocusMember(_ id: UUID) {
        guard focusEnabled else { return }
        focusedWorkspaceIDs.insert(id)
    }

    /// Puts a workspace back into the marked set when its removal is REVERSED — both restore paths, the
    /// pending-close undo and Reopen Closed Item. MARK-ONLY: membership belongs to the closed workspace
    /// and is restored with it, but `focusEnabled` is CURRENT WINDOW STATE, so a restore must never
    /// override a toggle made meanwhile; an insert-only path also honors the marking rule (an add never
    /// applies the filter) and can never reach `enabled + empty`. Callers run it BEFORE their reselect (so
    /// a restored member is in-set for `disableFocusIfSelectionOutsideSet`) and, in the undo, ahead of the
    /// empty-workspace early return whose row would otherwise stay filtered out. Save-free; the restore
    /// paths save.
    func markFocusMember(_ id: UUID) {
        focusedWorkspaceIDs.insert(id)
    }

    /// Restores the focus filter from a snapshot, PRUNING member ids absent from the restored tree and
    /// disabling the filter when the pruned set comes back empty — that prune keeps `enabled + empty`
    /// unrepresentable across a restore, or an all-stale set (workspaces deleted by another window, or a
    /// hand-edited file) restores as an enabled-but-invisible filter and the row-visibility read-back
    /// lies. A partially stale set keeps its survivors and stays enabled. Called from `restore(from:)`
    /// AFTER the tree is rebuilt; writes the fields directly, since the mutators would `save()` what was
    /// just read.
    func restoreFocus(from snapshot: Snapshot) {
        let present = Set(workspaces.map(\.id))
        focusedWorkspaceIDs = Set(snapshot.focusedWorkspaceIDs ?? []).intersection(present)
        focusEnabled = (snapshot.focusEnabled ?? false) && !focusedWorkspaceIDs.isEmpty
    }

    /// The workspaces the sidebar TREE renders: the marked set when the filter is enabled, else all — the
    /// `!workspaceFilter || focused` TERM of the published row-visibility contract
    /// (`ControlWorkspaceNode.focused`). Only that term: sidebar mode and visibility gate the tree ABOVE
    /// this (`.flagged` renders a flat session list and never calls here), so it is not the whole
    /// predicate a script evaluates. The empty-result fallback guards an INVARIANT VIOLATION only — the
    /// mutators keep `enabled + empty` out of reach, marking is gated on the id existing and
    /// `restoreFocus` prunes stale ids, so reaching it takes writing the two stored fields directly,
    /// which `internal(set)` limits to this module. Rendering the full tree there beats stranding the
    /// user with no rows at all.
    public var visibleWorkspaces: [Workspace] {
        guard focusEnabled else { return workspaces }
        let visible = workspaces.filter { focusedWorkspaceIDs.contains($0.id) }
        return visible.isEmpty ? workspaces : visible
    }

    /// The session set navigation operates over — the VISIBLE/FILTERED set, not the whole tree: the
    /// flagged sessions in `.flagged` sidebar mode, the marked workspaces' sessions when the focus filter
    /// is on, else all. Computed live, so clearing the flag/filter restores the full set.
    /// `navigateSession` next/prev WRAP within it (an end lands on the opposite end, never leaking across
    /// the filter). Backs `navigateSession` (and via it `session.go`, attention-nav), the Ctrl-Tab MRU
    /// candidates, AND the ⌃P session palette (`AppActions.paletteSessions`) — all one filter.
    public var navigableSessions: [Session] {
        sidebarMode == .flagged ? flaggedSessions : visibleWorkspaces.flatMap(\.sessions)
    }

    /// Moves the selection back inside the visible set whenever the active session is outside it — a
    /// narrowing that hid it, or a widening that filled a set which was empty; the counterpart of
    /// `disableFocusIfSelectionOutsideSet`. Targets the most recent visible session, else the first (MRU
    /// rather than positional keeps a filter-off-then-on round trip in place). No-op on a nil selection (a
    /// restore clears a dangling one deliberately) or an empty visible set; keyboard focus needs nothing
    /// here, `TerminalView.updateNSView` moves first responder on a selection change.
    func reselectIfSelectionHidden() {
        guard let selected = selectedSessionID else { return }
        let visible = navigableSessions
        guard !visible.isEmpty else { return }
        guard !visible.contains(where: { $0.id == selected }) else { return }
        selectSession(navigableRecentSessions(limit: 1).first ?? visible[0].id)
    }

    /// The selection after the workspace holding the active session is removed: the most recent session
    /// still VISIBLE, else the first visible one. Unlike `closeReselectionTarget` there is no "stay in the
    /// current workspace" term (that workspace is what was removed), but the visible-set term holds or the
    /// pick strands the selection on a row the sidebar cannot render. Falls back to the positional walk at
    /// `index` only when nothing is visible at all.
    func workspaceRemovalTarget(at index: Int) -> UUID? {
        let visible = navigableSessions
        if !visible.isEmpty { return navigableRecentSessions(limit: 1).first ?? visible[0].id }
        guard !workspaces.isEmpty else { return nil }
        let fallbackIndex = min(index, workspaces.count - 1)
        return workspaces[fallbackIndex].sessions.first?.id
            ?? workspaces.first(where: { !$0.sessions.isEmpty })?.sessions.first?.id
    }
}
