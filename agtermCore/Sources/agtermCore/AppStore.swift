import Foundation
import Observation

/// A relative step through the flattened session list for keyboard navigation.
/// `next`/`previous` step one and stop at the ends (no wrap), `first`/`last` jump to a tree end.
/// `nextAttention`/`previousAttention` step through only the sessions needing attention
/// (status `blocked` or `completed`), wrapping around.
public enum SessionNavigation: Sendable { case next, previous, first, last, nextAttention, previousAttention }

extension SessionNavigation {
    /// Maps a control-channel direction string to a case. The CLI uses `prev`; the enum case is
    /// `.previous`, so both spellings are accepted. Returns nil for an unknown string.
    public init?(wire: String) {
        switch wire {
        case "next": self = .next
        case "prev", "previous": self = .previous
        case "first": self = .first
        case "last": self = .last
        case "next-attention": self = .nextAttention
        case "prev-attention", "previous-attention": self = .previousAttention
        default: return nil
        }
    }
}

/// The whole app state: the workspace tree and the current selection.
///
/// `@Observable @MainActor` so SwiftUI views observe mutations and all model
/// access is main-actor isolated (implicitly `Sendable` via isolation). Selection
/// is a single `Session.ID?` — workspace rows are non-selectable disclosure
/// headers, so one id is enough; the owning workspace is derived.
@Observable
@MainActor
public final class AppStore {
    public var workspaces: [Workspace]
    public var selectedSessionID: UUID?

    /// Whether this window's sidebar is shown. Ephemeral per-window UI state (NOT in `Snapshot`, so it
    /// resets to visible on relaunch); the custom split owns visibility, so the toolbar button, the View
    /// menu item, the action palette, and the `sidebar` control command all flip this one flag.
    public var sidebarVisible = true

    /// Most-recently-selected session ids, front = current. Drives the Ctrl-Tab switcher
    /// (`items[1]` is the previous session). `@ObservationIgnored`: read imperatively by the
    /// switcher, not by any SwiftUI view, and not persisted.
    @ObservationIgnored public private(set) var sessionRecency = RecencyStack<UUID>()

    @ObservationIgnored private let persistence: PersistenceStore

    public init(workspaces: [Workspace] = [], selectedSessionID: UUID? = nil,
                persistence: PersistenceStore = PersistenceStore()) {
        self.workspaces = workspaces
        self.selectedSessionID = selectedSessionID
        self.persistence = persistence
    }

    /// The currently selected session, derived from `selectedSessionID`.
    public var activeSession: Session? {
        guard let selectedSessionID else { return nil }
        return session(withID: selectedSessionID)
    }

    /// The workspace a new session should land in: the selected session's workspace, else the
    /// last workspace (nil when there are no workspaces). Drives both the bottom bar's add
    /// actions and the File menu's New Session / Open Directory.
    public var currentWorkspaceID: UUID? {
        if let selectedSessionID, let workspace = workspace(forSession: selectedSessionID) {
            return workspace.id
        }
        return workspaces.last?.id
    }

    /// The auto-generated name for the next new workspace (`workspace 1`, `workspace 2`, …).
    public var defaultWorkspaceName: String {
        "workspace \(workspaces.count + 1)"
    }

    @discardableResult
    public func addWorkspace(name: String) -> Workspace {
        let workspace = Workspace(name: name)
        workspaces.append(workspace)
        save()
        return workspace
    }

    /// Creates a session in the given workspace, appends it, and selects it.
    /// Returns nil if no workspace matches.
    @discardableResult
    public func addSession(toWorkspace workspaceID: UUID, cwd: String, command: String? = nil) -> Session? {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return nil }
        let session = Session(initialCwd: cwd)
        session.initialCommand = command
        workspaces[index].sessions.append(session)
        selectedSessionID = session.id
        recordRecency()
        save()
        return session
    }

    /// Selects a session (or clears the selection when passed nil) and persists.
    /// A non-nil id that matches no session is ignored, leaving the current
    /// selection untouched; nil always deselects. Backs the sidebar's
    /// `List(selection:)` so a click persists immediately rather than waiting for
    /// the next structural mutation. Visiting a session clears its unseen badge. An
    /// `autoReset` agent indicator (the one-time `completed` flash) is reset to idle on
    /// BOTH the session moved to (you've seen it) and the one moved from (it must not
    /// persist once you leave it); a non-`autoReset` indicator (active/blocked) is left
    /// untouched (keep-state).
    public func selectSession(_ sessionID: UUID?) {
        if let sessionID, session(withID: sessionID) == nil { return }
        let previous = selectedSessionID
        selectedSessionID = sessionID
        if let sessionID { clearUnseen(sessionID) }
        clearAutoResetIndicator(sessionID) // visit: you've seen it
        clearAutoResetIndicator(previous)  // leave: a one-time status must not linger on the row you left
        recordRecency()
        save()
    }

    /// Reset a session's agent indicator to idle when it is marked `autoReset` (the one-time `completed`
    /// flash). No-op for nil / an unknown id / a non-autoReset indicator.
    private func clearAutoResetIndicator(_ id: UUID?) {
        guard let id, let session = session(withID: id), session.agentIndicator.autoReset else { return }
        session.agentIndicator = AgentIndicator()
    }

    /// Clears a session's unseen-notification badge — it's been looked at. No-op for an unknown id.
    /// Not persisted (the count is ephemeral), so it never triggers a `save()`.
    public func clearUnseen(_ sessionID: UUID) {
        session(withID: sessionID)?.unseenCount = 0
    }

    /// Sets a session's agent status indicator (the sidebar status glyph). The single mutation point
    /// for the control channel's `session.status`. No-op for an unknown id. Not persisted (the
    /// indicator is ephemeral), so it never triggers a `save()`.
    public func setAgentIndicator(_ indicator: AgentIndicator, forSession id: UUID) {
        session(withID: id)?.agentIndicator = indicator
    }

    /// Pushes the current selection to the front of the recency stack (the Ctrl-Tab order).
    /// No-op when nothing is selected.
    private func recordRecency() {
        if let selectedSessionID { sessionRecency.push(selectedSessionID) }
    }

    /// Sets a session's custom name. An empty (or whitespace-only) name clears
    /// `customName` to nil, reverting the row to the auto basename.
    public func renameSession(_ sessionID: UUID, to name: String) {
        guard let session = session(withID: sessionID) else { return }
        session.customName = name.trimmedOrNil
        save()
    }

    /// Renames a workspace. An empty (or whitespace-only) name is ignored —
    /// workspaces have no auto fallback, so a blank name is rejected.
    public func renameWorkspace(_ workspaceID: UUID, to name: String) {
        guard let trimmed = name.trimmedOrNil, let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        workspaces[index].name = trimmed
        save()
    }

    /// Removes a session, tears down its surface, and — if it was the active
    /// session — reselects a neighbor (next in the same workspace, else the
    /// previous, else any remaining session, else nil).
    public func closeSession(_ sessionID: UUID) {
        guard let location = location(ofSession: sessionID) else { return }
        let wasActive = selectedSessionID == sessionID
        let removed = workspaces[location.workspaceIndex].sessions.remove(at: location.sessionIndex)
        removed.surface?.teardown()
        removed.splitSurface?.teardown()
        removed.overlaySurface?.teardown()
        removed.scratchSurface?.teardown()
        sessionRecency.remove(sessionID)
        if wasActive {
            selectedSessionID = reselectionTarget(after: location)
            recordRecency()
        }
        save()
    }

    /// Whether a workspace may be removed: one workspace is always kept, so removal is
    /// allowed only when more than one exists.
    public var canRemoveWorkspace: Bool { workspaces.count > 1 }

    /// Removes a workspace and every session in it, tearing down each session's surfaces
    /// and pruning them from the recency stack. No-ops unless more than one workspace
    /// exists (the last one is kept). If the active session lived in the removed
    /// workspace, reselects the first session of a remaining workspace (the one that
    /// shifted into the removed slot, else the first non-empty workspace), or nil when
    /// no sessions remain.
    public func removeWorkspace(_ workspaceID: UUID) {
        guard canRemoveWorkspace, let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        let removingActive = selectedSessionID.map { id in workspaces[index].sessions.contains { $0.id == id } } ?? false
        for session in workspaces[index].sessions {
            session.surface?.teardown()
            session.splitSurface?.teardown()
            session.overlaySurface?.teardown()
            session.scratchSurface?.teardown()
            sessionRecency.remove(session.id)
        }
        workspaces.remove(at: index)
        if removingActive {
            let fallbackIndex = min(index, workspaces.count - 1)
            selectedSessionID = workspaces[fallbackIndex].sessions.first?.id
                ?? workspaces.first(where: { !$0.sessions.isEmpty })?.sessions.first?.id
            recordRecency()
        }
        save()
    }

    /// Toggles the one-level split for a session. The second pane's surface is created
    /// lazily by the detail pane on first show and kept alive when hidden, so this only
    /// flips the flag. The flag is persisted, so the split is restored on relaunch.
    public func toggleSplit(_ sessionID: UUID) {
        guard let session = session(withID: sessionID) else { return }
        session.isSplit.toggle()
        // opening marks the session as having a split and moves focus to the new (right) pane; hiding
        // (toggling off) leaves `hasSplit` and `splitFocused` set so the split indicators persist and
        // the focused pane is the one shown maximized. Only `closeSplit` clears them.
        if session.isSplit {
            session.hasSplit = true
            session.splitFocused = true
        }
        save()
    }

    /// Closes the split pane: hides it AND tears down its surface, so a subsequent split
    /// starts a fresh shell. Used when the split shell exits on its own; resets the focus flag so a
    /// stale `splitFocused` doesn't point the collapsed view at the gone pane.
    public func closeSplit(_ sessionID: UUID) {
        guard let session = session(withID: sessionID) else { return }
        session.isSplit = false
        session.hasSplit = false
        session.splitFocused = false
        session.splitSurface?.teardown()
        session.splitSurface = nil
        session.splitCwd = nil
        session.splitTitle = nil
        session.initialSplitCwd = nil
        // a search bar pinned to the torn-down split surface would otherwise stay stuck (the weak
        // `searchSurface` zeroes but `searchActive` stays true), so reset search on the surviving session.
        session.clearSearch()
        save()
    }

    /// The primary pane's shell exited. If a split pane is alive it becomes the session's single
    /// (non-split) pane and the session survives; otherwise the session is closed. The survivor stays
    /// in the `splitSurface` slot, shown maximized via `splitFocused`, and its cwd is promoted to the
    /// session's so a restart restores the single session in the right directory. Called by the primary
    /// surface's `onExit`.
    public func closePrimaryPane(_ sessionID: UUID) {
        guard let session = session(withID: sessionID) else { return }
        guard session.splitSurface != nil else {
            closeSession(sessionID)
            return
        }
        session.surface?.teardown()
        session.surface = nil
        session.isSplit = false
        session.hasSplit = false
        session.splitFocused = true
        if let cwd = session.splitCwd { session.currentCwd = cwd }
        // the primary surface (possibly the search owner) is torn down while the session survives as the
        // promoted split, so reset search rather than leave a stuck bar pinned to the gone primary.
        session.clearSearch()
        save()
    }

    /// The split pane's shell exited. If the primary is alive the split collapses to it (`closeSplit`);
    /// otherwise the primary already exited, so this was the last pane and the session is closed. Called
    /// by the split surface's `onExit`.
    public func closeSplitPane(_ sessionID: UUID) {
        guard let session = session(withID: sessionID) else { return }
        guard session.surface != nil else {
            closeSession(sessionID)
            return
        }
        closeSplit(sessionID)
    }

    /// Opens an ephemeral overlay terminal on a session running `command` (e.g. a TUI). The overlay
    /// surface is created lazily by the detail pane and runs the command as its process; when the
    /// program exits, `closeOverlay` tears it down. No-op (returns false) when the session is unknown
    /// or already has an overlay open. NOT persisted — the overlay never survives a relaunch.
    ///
    /// `sizePercent` (clamped to 1...100) requests a *floating* overlay: an opaque, framed panel sized
    /// to that percent of the pane, with the session still visible behind it. nil gives the default
    /// full-pane overlay that hides the session.
    @discardableResult public func openOverlay(_ sessionID: UUID, command: String, cwd: String? = nil,
                                               wait: Bool = false, sizePercent: Int? = nil) -> Bool {
        guard let session = session(withID: sessionID), !session.overlayActive else { return false }
        session.overlayCommand = command
        session.overlayCwd = cwd
        session.overlayWait = wait
        session.overlayExitCode = nil
        session.overlaySizePercent = sizePercent.map { min(100, max(1, $0)) }
        session.overlayActive = true
        return true
    }

    /// Records the overlay program's exit status (parsed app-side from the wrapper's temp file on the
    /// surface's teardown) so `session.overlay.result` can report it after the overlay closes. No-op
    /// for an unknown session.
    public func recordOverlayExit(_ sessionID: UUID, code: Int) {
        session(withID: sessionID)?.overlayExitCode = code
    }

    /// Closes the overlay terminal: hides it AND tears down its surface (unlike the split, the overlay
    /// is never kept alive — it is ephemeral). Used both on explicit close and when the overlay's
    /// program exits on its own. No-op (returns false) when there is no overlay.
    @discardableResult public func closeOverlay(_ sessionID: UUID) -> Bool {
        guard let session = session(withID: sessionID), session.overlayActive else { return false }
        session.overlayActive = false
        session.overlaySurface?.teardown()
        session.overlaySurface = nil
        session.overlayCommand = nil
        session.overlayCwd = nil
        session.overlayWait = false
        session.overlaySizePercent = nil
        return true
    }

    /// Toggles the scratch terminal for a session — a third, full-overlay login shell. The scratch
    /// surface is created lazily by the detail pane on first show and, like the split, kept alive when
    /// hidden (this only flips `scratchActive`), so a re-show reuses the same shell. Not persisted, so
    /// no `save()`. No-op for an unknown session.
    public func toggleScratch(_ sessionID: UUID) {
        guard let session = session(withID: sessionID) else { return }
        session.scratchActive.toggle()
    }

    /// Closes the scratch terminal: hides it AND tears down its surface (so a subsequent show starts a
    /// fresh shell). Used on the scratch shell's own `exit` and on session/workspace/window teardown.
    /// No-op (returns false) when there is no scratch surface.
    @discardableResult public func closeScratch(_ sessionID: UUID) -> Bool {
        guard let session = session(withID: sessionID), let scratch = session.scratchSurface else { return false }
        session.scratchActive = false
        // if the open search bar is pinned to the scratch being torn down, reset search rather than leave a
        // stuck, no-op bar (the weak `searchSurface` zeroes but `searchActive` stays true) — mirrors the
        // closeSplit/closePrimaryPane handling. Guarded on identity so a search owned by the main/split pane
        // (the scratch can cover a session whose pane opened search) survives the scratch teardown.
        if session.searchSurface === scratch { session.clearSearch() }
        scratch.teardown()
        session.scratchSurface = nil
        return true
    }

    /// Moves a session to another workspace (or reorders within the same one),
    /// keeping the **same** `Session` instance so its attached surface and live
    /// shell survive. `index` is the destination position in the target's session
    /// array **after** the move's removal (clamped to bounds); nil appends.
    /// `selectedSessionID` is unaffected — the id is stable, so a moved active
    /// session stays selected. No-ops if the session or target workspace is
    /// unknown; a same-workspace move to the current slot leaves order unchanged.
    public func moveSession(_ sessionID: UUID, toWorkspace targetID: UUID, at index: Int? = nil) {
        guard let source = location(ofSession: sessionID) else { return }
        guard let targetIndex = workspaces.firstIndex(where: { $0.id == targetID }) else { return }

        let session = workspaces[source.workspaceIndex].sessions.remove(at: source.sessionIndex)
        let destination = max(0, min(index ?? workspaces[targetIndex].sessions.count, workspaces[targetIndex].sessions.count))
        workspaces[targetIndex].sessions.insert(session, at: destination)
        save()
    }

    /// Reorders a session one relative step within its own workspace (`up`/`down`/`top`/`bottom`),
    /// reusing `moveSession` with the same workspace id. No-op (no write) on an unknown id or when
    /// the move would leave order unchanged (already at the end in that direction).
    public func reorderSession(_ id: UUID, _ direction: ReorderDirection) {
        guard let loc = location(ofSession: id) else { return }
        let count = workspaces[loc.workspaceIndex].sessions.count
        guard let dest = direction.destinationIndex(from: loc.sessionIndex, count: count) else { return }
        moveSession(id, toWorkspace: workspaces[loc.workspaceIndex].id, at: dest)
    }

    /// Moves a workspace to `index` among its siblings, mirroring `moveSession`'s
    /// remove/clamp/insert/save shape. `index` is the destination position **after**
    /// the move's removal (clamped to bounds). No-op on an unknown id.
    public func moveWorkspace(_ id: UUID, at index: Int) {
        guard let current = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let workspace = workspaces.remove(at: current)
        let dest = max(0, min(index, workspaces.count))
        workspaces.insert(workspace, at: dest)
        save()
    }

    /// Reorders a workspace one relative step among its siblings (`up`/`down`/`top`/`bottom`),
    /// reusing `moveWorkspace`. No-op (no write) on an unknown id or when the move would leave
    /// order unchanged (already at the end in that direction).
    public func reorderWorkspace(_ id: UUID, _ direction: ReorderDirection) {
        guard let current = workspaces.firstIndex(where: { $0.id == id }) else { return }
        guard let dest = direction.destinationIndex(from: current, count: workspaces.count) else { return }
        moveWorkspace(id, at: dest)
    }

    /// The owning workspace id, the session's index within it, and that workspace's session count, or
    /// nil for an unknown id. Lets the sidebar drag handler resolve owner + index in a single tree walk
    /// instead of re-deriving each piece, while feeding the host-free `SidebarDrop` resolver.
    public func sessionLocation(ofSession id: UUID) -> (workspace: UUID, index: Int, count: Int)? {
        guard let loc = location(ofSession: id) else { return nil }
        let workspace = workspaces[loc.workspaceIndex]
        return (workspace.id, loc.sessionIndex, workspace.sessions.count)
    }

    /// Steps the selection through the flattened session list (`workspaces.flatMap(\.sessions)`,
    /// the sidebar's visual order). `next`/`previous` move one and stop at the ends (no wrap — `next`
    /// on the last session and `previous` on the first are no-ops); `first`/`last` jump to the tree
    /// ends. With no/invalid current selection, `next`/`previous` land on the first session. No-op
    /// when there are no sessions. Routes through `selectSession`, inheriting recency, badge clearing,
    /// persistence, and workspace derivation.
    public func navigateSession(_ direction: SessionNavigation) {
        let sessions = workspaces.flatMap(\.sessions)
        let ids = sessions.map(\.id)
        guard let first = ids.first, let last = ids.last else { return }
        let target: UUID
        switch direction {
        case .first: target = first
        case .last: target = last
        case .next, .previous:
            if let current = selectedSessionID, let i = ids.firstIndex(of: current) {
                let step = direction == .next ? 1 : -1
                let next = i + step
                guard next >= 0, next < ids.count else { return } // at an end -> stay put (no wrap)
                target = ids[next]
            } else {
                target = first // no/invalid selection -> first
            }
        case .nextAttention, .previousAttention:
            guard let found = attentionTarget(in: sessions, forward: direction == .nextAttention) else { return }
            target = found
        }
        selectSession(target)
    }

    /// The next/previous session needing attention (status `blocked` or `completed`) in the flattened
    /// order, scanning from the current selection and WRAPPING around. The current session is excluded,
    /// so repeated steps cycle through the others. With no/invalid selection the scan starts from the
    /// tree end opposite the direction. Returns nil when no other attention session exists (a no-op).
    private func attentionTarget(in sessions: [Session], forward: Bool) -> UUID? {
        let ids = sessions.map(\.id)
        let count = ids.count
        guard count > 0 else { return nil }
        let step = forward ? 1 : -1
        let curIndex = selectedSessionID.flatMap { ids.firstIndex(of: $0) }
        let start = curIndex ?? (forward ? -1 : count)
        for k in 1...count {
            let idx = ((start + step * k) % count + count) % count
            if let curIndex, idx == curIndex { break } // wrapped back to the current session, none other
            if sessions[idx].agentIndicator.status.needsAttention { return ids[idx] }
        }
        return nil
    }

    /// Records a session's terminal font size (points) and persists it. No-ops when
    /// unchanged so the cell-size event firing on a DPI change (not a font change)
    /// doesn't write. Persisted like a structural mutation, not on every keystroke.
    public func setFontSize(_ sessionID: UUID, _ size: Double) {
        guard let session = session(withID: sessionID), session.fontSize != size else { return }
        session.fontSize = size
        save()
    }

    /// Clears every session's per-session font-size override (back to the app default). Called
    /// when an appearance change is applied: the shared ghostty `update_config` resets all live
    /// surfaces to the default size, so the persisted overrides are cleared to match. No-ops (no
    /// write) when nothing was overridden.
    public func resetSessionFontSizes() {
        var changed = false
        for workspace in workspaces {
            for session in workspace.sessions where session.fontSize != nil {
                session.fontSize = nil
                changed = true
            }
        }
        if changed { save() }
    }

    // MARK: - Persistence

    /// Builds a `Snapshot` value of the current tree. Each session captures its
    /// live `currentCwd` (or `initialCwd` if no PWD report has arrived). Runs on
    /// `@MainActor`; the resulting value is `Sendable` and safe to hand to a writer.
    public func snapshot() -> Snapshot {
        let workspaceSnapshots = workspaces.map { workspace in
            WorkspaceSnapshot(id: workspace.id, name: workspace.name, sessions: workspace.sessions.map { session in
                SessionSnapshot(id: session.id, customName: session.customName, cwd: session.currentCwd ?? session.initialCwd,
                                isSplit: session.isSplit, fontSize: session.fontSize,
                                splitCwd: session.splitCwd ?? session.initialSplitCwd)
            })
        }
        return Snapshot(selectedSessionID: selectedSessionID, workspaces: workspaceSnapshots)
    }

    /// Rebuilds the tree from a snapshot: fresh `Session`s (surfaces and shells
    /// spawn lazily on first display) keyed by the persisted ids so the restored
    /// `selectedSessionID` still resolves. Replaces the current state wholesale.
    ///
    /// Deliberately does NOT call `save()`: it loads what was just read from disk,
    /// so re-persisting it would be a pointless write (and the only mutator that
    /// skips `save()` for that reason). If the persisted `selectedSessionID` points
    /// at a session that no longer exists, it is cleared to keep selection valid.
    public func restore(from snapshot: Snapshot) {
        workspaces = snapshot.workspaces.map { workspaceSnapshot in
            let sessions = workspaceSnapshot.sessions.map { sessionSnapshot -> Session in
                let session = Session(id: sessionSnapshot.id, initialCwd: sessionSnapshot.cwd, customName: sessionSnapshot.customName)
                session.isSplit = sessionSnapshot.isSplit ?? false
                session.hasSplit = session.isSplit
                session.fontSize = sessionSnapshot.fontSize
                session.initialSplitCwd = sessionSnapshot.splitCwd
                return session
            }
            return Workspace(id: workspaceSnapshot.id, name: workspaceSnapshot.name, sessions: sessions)
        }
        if let id = snapshot.selectedSessionID, session(withID: id) == nil {
            selectedSessionID = nil
        } else {
            selectedSessionID = snapshot.selectedSessionID
        }
        sessionRecency = RecencyStack<UUID>()
        recordRecency()
    }

    /// Persists the current state eagerly. Called after every mutation and on
    /// terminate. A write failure is logged and swallowed — a transient disk error
    /// must not bring down the model.
    public func save() {
        do {
            try persistence.save(snapshot())
        } catch {
            log("save failed: \(error)")
        }
    }

    private func log(_ message: @autoclosure () -> String) {
        NSLog("agterm: %@", message())
    }

    // MARK: - Derivation

    /// The workspace that owns the given session, if any.
    public func workspace(forSession sessionID: UUID) -> Workspace? {
        guard let location = location(ofSession: sessionID) else { return nil }
        return workspaces[location.workspaceIndex]
    }

    /// The session with the given id across all workspaces, if any.
    public func session(withID sessionID: UUID) -> Session? {
        for workspace in workspaces {
            if let session = workspace.sessions.first(where: { $0.id == sessionID }) { return session }
        }
        return nil
    }

    private func location(ofSession sessionID: UUID) -> (workspaceIndex: Int, sessionIndex: Int)? {
        for (wi, workspace) in workspaces.enumerated() {
            if let si = workspace.sessions.firstIndex(where: { $0.id == sessionID }) { return (wi, si) }
        }
        return nil
    }

    /// Picks the next selection after removing the session at `location`. Prefers
    /// the session that shifted into the removed slot, then the previous one in
    /// that workspace, then the first session of any remaining workspace.
    private func reselectionTarget(after location: (workspaceIndex: Int, sessionIndex: Int)) -> UUID? {
        let sessions = workspaces[location.workspaceIndex].sessions
        if location.sessionIndex < sessions.count { return sessions[location.sessionIndex].id }
        if location.sessionIndex > 0 { return sessions[location.sessionIndex - 1].id }
        for workspace in workspaces {
            if let first = workspace.sessions.first { return first.id }
        }
        return nil
    }
}
