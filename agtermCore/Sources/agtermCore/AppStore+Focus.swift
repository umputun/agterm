import Foundation

/// The sidebar focus filter: which workspaces the tree renders, the session set navigation and the palettes
/// derive from it, and the mutators/lifecycle guards keeping it in step with the selection. The stored filter
/// state lives on the class — an extension cannot hold stored properties.
extension AppStore {
    /// Switches the filter OFF — KEEPING the marked set — when the newly selected session is outside it, so an
    /// explicit cross-set select (a hidden `session.select`, a notification reveal, a reselect after move/close)
    /// reveals its target and the active session is always inside the visible set. Navigation is scoped to
    /// `navigableSessions`, so it never trips this. No-op when the filter is off, nothing is selected, or the
    /// selection sits in a member workspace; persistence rides the caller's `selectSession` save. Also a no-op
    /// in `.flagged` mode — that flat list is cross-workspace and ignores the marked set, so without the term,
    /// entering flagged view with the only flagged session in an unmarked workspace would silently disable it.
    /// Returning to `.tree` re-applies it.
    func disableFocusIfSelectionOutsideSet(_ sessionID: UUID?) {
        guard focusEnabled, sidebarMode != .flagged, let sessionID else { return }
        if let owner = workspace(forSession: sessionID)?.id, focusedWorkspaceIDs.contains(owner) { return }
        focusEnabled = false
    }

    /// Replaces the marked set with just `id` and ENABLES the filter — the single-workspace zoom every
    /// row-menu/menu-bar/`workspace.focus on` caller drives. No-op for an id naming no workspace: a phantom
    /// member breaks the row-visibility read-back (`ControlWorkspaceNode.focused`) until a restore prunes it.
    func setFocusedWorkspace(_ id: UUID) {
        guard workspaces.contains(where: { $0.id == id }) else { return }
        commitFocus(ids: [id], enabled: true)
    }

    /// Empties the marked set and switches the filter off — the menu/palette "Clear Focus" and the clearing half
    /// of the replace-toggle; no-op when nothing is marked. Unlike `setFocusEnabled(false)`, which keeps the set.
    public func clearFocus() {
        commitFocus(ids: [], enabled: false)
    }

    /// Replace-TOGGLE: clears the filter when `id` is the SOLE marked workspace and the filter applies, else
    /// replaces the set with it (enabling), so the row menu's Focus/Unfocus, the `focus_workspace` keybind/menu
    /// item and `workspace.focus toggle` cannot mean two things. No-op on an unknown id.
    public func toggleFocusedWorkspace(_ id: UUID) {
        if isSoleFocus(id) { clearFocus() } else { setFocusedWorkspace(id) }
    }

    /// The ONE workspace the tree is zoomed to — the sole marked workspace while the filter APPLIES, else nil.
    /// The single definition, read by `isSoleFocus(_:)`, the sidebar's force-expand, and the empty-space drop
    /// fallback (a Finder folder dropped below the rows lands where the user is looking, so adding a session
    /// cannot silently leave the filtered view). The `focusEnabled` term is load-bearing: marked with the
    /// filter OFF means the WHOLE tree is on screen, so nothing is zoomed to; two or more members are ambiguous.
    public var soleFocusedWorkspaceID: UUID? {
        guard focusEnabled, focusedWorkspaceIDs.count == 1 else { return nil }
        return focusedWorkspaceIDs.first
    }

    /// Whether `id` is the workspace the tree is zoomed to — the state that makes Focus read Unfocus and that
    /// a `toggle` clears.
    public func isSoleFocus(_ id: UUID) -> Bool { soleFocusedWorkspaceID == id }

    /// `isSoleFocus` for the CURRENT workspace — what the keyless View ▸ Focus/Unfocus Workspace item needs,
    /// having no clicked row and targeting `currentWorkspaceID` like `AppActions.focusActiveWorkspace()`.
    public var isCurrentWorkspaceSoleFocus: Bool {
        guard let id = currentWorkspaceID else { return false }
        return isSoleFocus(id)
    }

    /// Whether the CURRENT workspace is already marked — read by View ▸ Add Workspace to Focus and its
    /// palette twin to avoid a silent no-op (the row menu, having a clicked row, flips to "Remove from Focus").
    public var isCurrentWorkspaceFocusMember: Bool {
        guard let id = currentWorkspaceID else { return false }
        return focusedWorkspaceIDs.contains(id)
    }

    /// Applies one `workspace.focus` mode to `id`, host-free so the mode-to-mutator mapping is unit tested, the
    /// control arm keeps only target resolution, and the GUI toggle can't drift from the wire's. Arms are
    /// delta-guarded, so each mode is idempotent.
    public func applyFocusMode(_ mode: ControlWorkspaceFocusMode, to id: UUID) {
        switch mode {
        case .on: setFocusedWorkspace(id)
        case .off: setFocusMembership(id, member: false)
        case .add: setFocusMembership(id, member: true)
        case .toggle: toggleFocusedWorkspace(id)
        }
    }

    /// Applies one `workspace.filter` mode to this window's flag, leaving the marked set alone. Host-free half of
    /// the control arm, so the mapping — including the refusal to enable an empty set — is unit tested.
    public func applyWorkspaceFilter(_ mode: ControlToggleMode) {
        setFocusEnabled(mode.desiredValue(current: focusEnabled))
    }

    /// Adds or removes one workspace from the marked set, leaving the others alone. Marking ONLY marks — an add
    /// that enabled the filter would hide the very rows the next add needs — so a working set is built row by
    /// row with the whole tree on screen; `setFocusedWorkspace(_:)` is the one that enables immediately.
    /// Removing still disables the filter once the set empties. Marking is refused for an id naming no
    /// workspace (no phantom member is persisted); un-marking is ungated, so a stale id stays removable.
    public func setFocusMembership(_ id: UUID, member: Bool) {
        if member, !workspaces.contains(where: { $0.id == id }) { return }
        var wantIDs = focusedWorkspaceIDs
        if member { wantIDs.insert(id) } else { wantIDs.remove(id) }
        commitFocus(ids: wantIDs, enabled: focusEnabled)
    }

    /// Turns the filter on or off WITHOUT touching the marked set, so peeking at the whole tree costs one flip.
    /// Enabling an empty set is refused, matching the bottom-bar toggle, disabled in exactly that state.
    public func setFocusEnabled(_ on: Bool) {
        commitFocus(ids: focusedWorkspaceIDs, enabled: on)
    }

    /// The single write point for the two filter fields: clamps `enabled` to false on an empty set (making
    /// `enabled + empty` unrepresentable), skips an unchanged write (so delta-computed control/menu callers
    /// stay idempotent and no-op writes never persist), then prunes the sidebar selection and saves.
    private func commitFocus(ids: Set<UUID>, enabled: Bool) {
        let wantEnabled = enabled && !ids.isEmpty
        guard focusedWorkspaceIDs != ids || focusEnabled != wantEnabled else { return }
        focusedWorkspaceIDs = ids
        focusEnabled = wantEnabled
        // a filtered-out target would leave Rename Workspace enabled with no row to edit, and the sidebar
        // builds its row cache from `visibleWorkspaces`.
        forgetHiddenFreshWorkspace()
        pruneSidebarSelection()
        reselectIfSelectionHidden()
        save()
    }

    /// Drops `id` from the marked set, disabling the filter once it empties — the LIFECYCLE half of the
    /// `enabled + empty` invariant, for paths that remove a workspace outright (`removeWorkspace`,
    /// `softRemoveWorkspace`) rather than un-marking it. No `save()` or selection prune: its callers do both.
    func dropFocusMember(_ id: UUID) {
        focusedWorkspaceIDs.remove(id)
        if focusedWorkspaceIDs.isEmpty { focusEnabled = false }
    }

    /// Marks a freshly created workspace so it is visible while the filter applies (the auto-reveal contract of
    /// `addWorkspace`/`ensureWorkspace`); no-op with the filter off, where the whole tree is on screen and the
    /// set must not widen behind the user's back. Save-free: `addWorkspace` saves.
    func revealNewFocusMember(_ id: UUID) {
        guard focusEnabled else { return }
        focusedWorkspaceIDs.insert(id)
    }

    /// Puts a workspace back into the marked set when its removal is REVERSED — the pending-close undo and Reopen
    /// Closed Item. MARK-ONLY: membership belongs to the closed workspace, but `focusEnabled` is CURRENT WINDOW
    /// STATE, so a restore must never override a toggle made meanwhile; insert-only also honors the marking rule
    /// and can never reach `enabled + empty`. Callers run it BEFORE their reselect (so a restored member is
    /// in-set for `disableFocusIfSelectionOutsideSet`) and, in the undo, ahead of the empty-workspace early
    /// return whose row would otherwise stay filtered out. Save-free; the restore paths save.
    func markFocusMember(_ id: UUID) {
        focusedWorkspaceIDs.insert(id)
    }

    /// Restores the filter from a snapshot, PRUNING member ids absent from the restored tree and disabling when
    /// the pruned set comes back empty — without it an all-stale set (workspaces deleted by another window, or
    /// a hand-edited file) restores as an enabled-but-invisible filter and the row-visibility read-back lies. A
    /// partially stale set keeps its survivors and stays enabled. Called from `restore(from:)` AFTER the tree
    /// is rebuilt; writes the fields directly, since the mutators would `save()` what was just read.
    func restoreFocus(from snapshot: Snapshot) {
        let present = Set(workspaces.map(\.id))
        focusedWorkspaceIDs = Set(snapshot.focusedWorkspaceIDs ?? []).intersection(present)
        focusEnabled = (snapshot.focusEnabled ?? false) && !focusedWorkspaceIDs.isEmpty
    }

    /// The workspaces the sidebar TREE renders: the marked set while the filter is enabled, else all — the
    /// `!workspaceFilter || focused` TERM of the row-visibility contract (`ControlWorkspaceNode.focused`), not
    /// the whole predicate a script evaluates: sidebar mode and visibility gate the tree ABOVE this (`.flagged`
    /// renders a flat session list and never calls here). The empty-result fallback guards an INVARIANT
    /// VIOLATION only — reaching it takes writing the two stored fields directly (`internal(set)`, so
    /// in-module), since the mutators keep `enabled + empty` out of reach, marking is gated on the id existing
    /// and `restoreFocus` prunes stale ids. Rendering the full tree beats stranding the user with no rows.
    public var visibleWorkspaces: [Workspace] {
        guard focusEnabled else { return workspaces }
        let visible = workspaces.filter { focusedWorkspaceIDs.contains($0.id) }
        return visible.isEmpty ? workspaces : visible
    }

    /// Whether a workspace step has anywhere to go. The predicate `navigateWorkspace` itself turns on, and
    /// what `PaletteCommand.isEnabled` reads, so the menu item and the mapped key cannot claim to do
    /// something the action then declines. A lone visible workspace is a dead end only while it is ALREADY
    /// current: when the current one is filtered out, entering the sole survivor is the whole point of the
    /// step. Flagged mode renders no workspace rows at all.
    public var canStepWorkspaces: Bool {
        guard sidebarMode == .tree else { return false }
        let ids = visibleWorkspaces.map(\.id)
        guard !ids.isEmpty else { return false }
        guard let current = currentWorkspaceID, ids.contains(current) else { return true }
        return ids.count > 1
    }

    /// The session set navigation operates over — the VISIBLE/FILTERED set, not the whole tree: flagged
    /// sessions in `.flagged` mode, the marked workspaces' sessions while the filter is on, else all. Computed
    /// live, so clearing the flag/filter restores the full set. `navigateSession` next/prev WRAP within it,
    /// never leaking across the filter. Backs `navigateSession` (and via it `session.go`, attention-nav), the
    /// Ctrl-Tab MRU candidates and the ⌃P session palette (`AppActions.paletteSessions`) — all one filter.
    public var navigableSessions: [Session] {
        sidebarMode == .flagged ? flaggedSessions : visibleWorkspaces.flatMap(\.sessions)
    }

    /// Moves the selection back inside the visible set whenever the active session is outside it — a narrowing
    /// that hid it, or a widening that filled an empty set; counterpart of `disableFocusIfSelectionOutsideSet`.
    /// Targets the most recent visible session, else the first (MRU rather than positional keeps a
    /// filter-off-then-on round trip in place). No-op on a nil selection (a restore clears a dangling one
    /// deliberately) or an empty visible set; `TerminalView.updateNSView` moves first responder on its own.
    func reselectIfSelectionHidden() {
        guard let selected = selectedSessionID else { return }
        let visible = navigableSessions
        guard !visible.isEmpty else { return }
        guard !visible.contains(where: { $0.id == selected }) else { return }
        selectSession(navigableRecentSessions(limit: 1).first ?? visible[0].id)
    }

    /// The selection after the workspace holding the active session is removed: the most recent VISIBLE
    /// session, else the first visible one. Unlike `closeReselectionTarget` there is no "stay in the current
    /// workspace" term (that workspace is what was removed), but the visible-set term holds or the pick strands
    /// the selection on a row the sidebar cannot render. Positional walk at `index` only when nothing is visible.
    func workspaceRemovalTarget(at index: Int) -> UUID? {
        let visible = navigableSessions
        if !visible.isEmpty { return navigableRecentSessions(limit: 1).first ?? visible[0].id }
        guard !workspaces.isEmpty else { return nil }
        let fallbackIndex = min(index, workspaces.count - 1)
        return workspaces[fallbackIndex].sessions.first?.id
            ?? workspaces.first(where: { !$0.sessions.isEmpty })?.sessions.first?.id
    }
}
