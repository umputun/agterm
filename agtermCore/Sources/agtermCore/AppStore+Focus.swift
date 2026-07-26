import Foundation

/// The sidebar focus filter: which workspaces the tree renders, the session set navigation and the
/// palettes derive from it, and the mutators/lifecycle guards that keep the filter in step with the
/// selection. Split out of the main `AppStore` declaration to keep each file focused; the stored
/// filter state itself stays on the class, since an extension cannot hold stored properties.
extension AppStore {
    /// Switches the focus filter OFF — KEEPING the marked set — when the newly selected session lives
    /// outside that set, so an explicit cross-set select (`session.select <id>` of a hidden session, a
    /// notification reveal, a move/close that reselects elsewhere) reveals its target: the active session
    /// is then always inside the visible set. Session navigation is scoped to the filtered set
    /// (`navigableSessions`), so its targets are always in-set and never trip this. No-op when the filter
    /// is off, when nothing is selected, or when the selection sits in a member workspace. Persistence
    /// rides the caller's `selectSession` save.
    func disableFocusIfSelectionOutsideSet(_ sessionID: UUID?) {
        guard focusEnabled, let sessionID else { return }
        if let owner = workspace(forSession: sessionID)?.id, focusedWorkspaceIDs.contains(owner) { return }
        focusEnabled = false
    }

    /// Replaces the marked set with just `id` and ENABLES the filter — the single-workspace zoom every
    /// row-menu/menu-bar/`workspace.focus on` caller drives. Clean no-op for an id that names no workspace:
    /// marking a phantom id would persist a member no tree can render and would break the row-visibility
    /// read-back contract (`ControlWorkspaceNode.focused`) until the next restore pruned it.
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
    /// else replaces the marked set with it (enabling). The semantic of the row menu's Focus/Unfocus, the
    /// `focus_workspace` keybind/menu item, and `workspace.focus toggle` — one definition all three drive,
    /// so a "toggle" can never mean two things. Clean no-op on an unknown id, like `setFocusedWorkspace`.
    public func toggleFocusedWorkspace(_ id: UUID) {
        if isSoleFocus(id) { clearFocus() } else { setFocusedWorkspace(id) }
    }

    /// The ONE workspace the tree is zoomed to — the sole marked workspace while the filter APPLIES, else
    /// nil. The single definition of that state, read by everything that needs it: `isSoleFocus(_:)`, the
    /// sidebar's force-expand of a zoomed-to workspace, and the empty-space drop fallback (a Finder folder
    /// dropped below the rows lands where the user is looking, so adding a session cannot silently leave
    /// the filtered view). The `focusEnabled` term is load-bearing: with a workspace marked but the filter
    /// OFF the WHOLE tree is on screen, so the mark names nothing to zoom to. Two or more members give no
    /// unambiguous answer either.
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

    /// Applies one `workspace.focus` mode to `id`. Host-free, so the whole mode-to-mutator mapping is unit
    /// tested and the app-side control arm is left with only target resolution — and so the GUI's
    /// replace-toggle and the wire's `toggle` cannot drift apart. Every arm is delta-guarded, so each mode
    /// is idempotent.
    public func applyFocusMode(_ mode: ControlWorkspaceFocusMode, to id: UUID) {
        switch mode {
        case .on: setFocusedWorkspace(id)
        case .off: setFocusMembership(id, member: false)
        case .add: setFocusMembership(id, member: true)
        case .toggle: toggleFocusedWorkspace(id)
        }
    }

    /// Applies one `workspace.filter` mode to this window's filter flag, leaving the marked set alone.
    /// Host-free half of the control arm (which is left with only the window resolution), so the
    /// mode-to-flag mapping — including the refusal to enable an empty set — is exercised by a unit test
    /// rather than re-spelled in a test double.
    public func applyWorkspaceFilter(_ mode: ControlToggleMode) {
        setFocusEnabled(mode.desiredValue(current: focusEnabled))
    }

    /// Adds or removes one workspace from the marked set, leaving the other members alone. Marking ONLY
    /// marks: adding never switches the filter on, so a working set is built row by row with the whole
    /// tree on screen — an add that enabled the filter would hide the very rows the next add needs.
    /// Removing still disables the filter once the set empties. `setFocusedWorkspace(_:)` (the replacing
    /// "Focus") is the one that enables immediately. Marking is refused for an id that names no workspace,
    /// so a phantom member can never be persisted; un-marking is never gated on existence, because a stale
    /// id already in the set must stay removable.
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

    /// The single write point for the two filter fields. It clamps `enabled` to false on an empty set —
    /// the guard that makes `enabled + empty` unrepresentable — skips the write entirely when nothing
    /// changes (so the delta-computed control/menu callers stay idempotent and no-op writes never persist),
    /// then prunes the sidebar selection and saves.
    private func commitFocus(ids: Set<UUID>, enabled: Bool) {
        let wantEnabled = enabled && !ids.isEmpty
        guard focusedWorkspaceIDs != ids || focusEnabled != wantEnabled else { return }
        focusedWorkspaceIDs = ids
        focusEnabled = wantEnabled
        pruneSidebarSelection()
        save()
    }

    /// Drops `id` from the marked set, disabling the filter once the set empties — the LIFECYCLE half of
    /// the `enabled + empty` invariant, for the paths that remove a workspace outright
    /// (`removeWorkspace`, `softRemoveWorkspace`) rather than un-marking it. It exists so the two-line
    /// remove-then-disable pair lives in ONE place: a fourth removal path added elsewhere gets the
    /// invariant for free. Deliberately does NOT `save()` or prune the sidebar selection — the callers do
    /// both as part of the larger removal they are in the middle of.
    func dropFocusMember(_ id: UUID) {
        focusedWorkspaceIDs.remove(id)
        if focusedWorkspaceIDs.isEmpty { focusEnabled = false }
    }

    /// Marks a freshly created workspace so it is visible while the filter applies (the auto-reveal
    /// contract of `addWorkspace`/`ensureWorkspace`), and a no-op when the filter is off — the whole tree
    /// is on screen then, so there is nothing to reveal and the set must not be widened behind the user's
    /// back. Save-free: `addWorkspace` saves.
    func revealNewFocusMember(_ id: UUID) {
        guard focusEnabled else { return }
        focusedWorkspaceIDs.insert(id)
    }

    /// Puts a workspace back into the marked set when its removal is REVERSED — both restore paths, the
    /// pending-close undo and Reopen Closed Item. MARK-ONLY, leaving `focusEnabled` exactly as the window
    /// has it: membership belongs to the closed workspace and is restored with it, but the filter flag is
    /// CURRENT WINDOW STATE, so a restore must never override a toggle the user made in the meantime.
    /// That also honors the marking rule (an add never applies the filter) and keeps `enabled + empty`
    /// unreachable, since an insert-only path can never enable. Callers run it BEFORE their reselect, so a
    /// restored member is inside the set when `disableFocusIfSelectionOutsideSet` runs, and — in the undo —
    /// ahead of the empty-workspace early return, whose row would otherwise stay filtered out. Save-free;
    /// the restore paths save.
    func markFocusMember(_ id: UUID) {
        focusedWorkspaceIDs.insert(id)
    }

    /// Restores the focus filter from a snapshot, PRUNING member ids absent from the restored tree and
    /// disabling the filter when the pruned set comes back empty. The prune is what keeps
    /// `enabled + empty` unrepresentable across a restore: an all-stale set (its workspaces deleted by
    /// another window, or a hand-edited file) would otherwise restore as an enabled-but-invisible filter,
    /// making the row-visibility read-back contract lie. A partially stale set keeps its
    /// survivors and stays enabled. Called from `restore(from:)` AFTER the tree is rebuilt, and
    /// deliberately writes the fields directly rather than going through the mutators, which would
    /// `save()` what was just read.
    func restoreFocus(from snapshot: Snapshot) {
        let present = Set(workspaces.map(\.id))
        focusedWorkspaceIDs = Set(snapshot.focusedWorkspaceIDs ?? []).intersection(present)
        focusEnabled = (snapshot.focusEnabled ?? false) && !focusedWorkspaceIDs.isEmpty
    }

    /// The workspaces the sidebar TREE should render: the marked set when the filter is enabled, else
    /// all workspaces — the `!workspaceFilter || focused` TERM of the published row-visibility contract
    /// (`ControlWorkspaceNode.focused`), spelled in code. Only that term: the sidebar's mode and
    /// visibility gate the tree ABOVE this (`.flagged` mode renders a flat session list and never calls
    /// here), so this is not the whole predicate a script evaluates.
    /// The empty-result fallback guards an INVARIANT VIOLATION and nothing else, since
    /// the mutators keep `enabled + empty` out of reach, marking is gated on the id existing, and
    /// `restoreFocus` prunes stale ids — the only way to reach it is to write the two stored fields
    /// directly, which `internal(set)` limits to inside this module. Rendering the full tree there is the
    /// lesser evil: an empty sidebar strands the user with no rows at all.
    public var visibleWorkspaces: [Workspace] {
        guard focusEnabled else { return workspaces }
        let visible = workspaces.filter { focusedWorkspaceIDs.contains($0.id) }
        return visible.isEmpty ? workspaces : visible
    }

    /// The session set navigation operates over — the VISIBLE/FILTERED set, not the whole tree: the
    /// flagged sessions in `.flagged` sidebar mode, the marked workspaces' sessions when the focus
    /// filter is on, else all sessions. Computed live, so clearing the flag/filter naturally restores the
    /// full set. `navigateSession` next/prev WRAP within this set (an end lands on the opposite end, never
    /// leaking across the filter). Backs `navigateSession` (and via it `session.go`, attention-nav), the
    /// Ctrl-Tab MRU candidate set, AND the ⌃P session palette (`AppActions.paletteSessions`), so all
    /// follow the same filter as the visible sidebar.
    public var navigableSessions: [Session] {
        sidebarMode == .flagged ? flaggedSessions : visibleWorkspaces.flatMap(\.sessions)
    }
}
