import Foundation
import Observation

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
    /// Whether the bottom status bar is hidden. UI chrome preference, persisted
    /// alongside the workspace tree so it survives relaunch and stays isolated
    /// under a test's `AGT_STATE_DIR`.
    public var statusBarHidden: Bool

    /// Most-recently-selected session ids, front = current. Drives the Ctrl-Tab switcher
    /// (`items[1]` is the previous session). `@ObservationIgnored`: read imperatively by the
    /// switcher, not by any SwiftUI view, and not persisted.
    @ObservationIgnored public private(set) var sessionRecency = RecencyStack<UUID>()

    @ObservationIgnored private let persistence: PersistenceStore

    public init(workspaces: [Workspace] = [], selectedSessionID: UUID? = nil,
                statusBarHidden: Bool = false, persistence: PersistenceStore = PersistenceStore()) {
        self.workspaces = workspaces
        self.selectedSessionID = selectedSessionID
        self.statusBarHidden = statusBarHidden
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
    public func addSession(toWorkspace workspaceID: UUID, cwd: String) -> Session? {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return nil }
        let session = Session(initialCwd: cwd)
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
    /// the next structural mutation.
    public func selectSession(_ sessionID: UUID?) {
        if let sessionID, session(withID: sessionID) == nil { return }
        selectedSessionID = sessionID
        recordRecency()
        save()
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
        save()
    }

    /// Closes the split pane: hides it AND tears down its surface, so a subsequent split
    /// starts a fresh shell. Used when the split shell exits on its own.
    public func closeSplit(_ sessionID: UUID) {
        guard let session = session(withID: sessionID) else { return }
        session.isSplit = false
        session.splitSurface?.teardown()
        session.splitSurface = nil
        save()
    }

    /// Opens an ephemeral overlay terminal on a session running `command` (e.g. a TUI). The overlay
    /// surface is created lazily by the detail pane and runs the command as its process; when the
    /// program exits, `closeOverlay` tears it down. No-op (returns false) when the session is unknown
    /// or already has an overlay open. NOT persisted — the overlay never survives a relaunch.
    @discardableResult public func openOverlay(_ sessionID: UUID, command: String, cwd: String? = nil,
                                               wait: Bool = false) -> Bool {
        guard let session = session(withID: sessionID), !session.overlayActive else { return false }
        session.overlayCommand = command
        session.overlayCwd = cwd
        session.overlayWait = wait
        session.overlayActive = true
        return true
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

    /// Sets whether the bottom status bar is hidden and persists. No-ops when the
    /// value is unchanged so a redundant menu toggle doesn't write.
    public func setStatusBarHidden(_ hidden: Bool) {
        guard statusBarHidden != hidden else { return }
        statusBarHidden = hidden
        save()
    }

    // MARK: - Persistence

    /// Builds a `Snapshot` value of the current tree. Each session captures its
    /// live `currentCwd` (or `initialCwd` if no PWD report has arrived). Runs on
    /// `@MainActor`; the resulting value is `Sendable` and safe to hand to a writer.
    public func snapshot() -> Snapshot {
        let workspaceSnapshots = workspaces.map { workspace in
            WorkspaceSnapshot(id: workspace.id, name: workspace.name, sessions: workspace.sessions.map { session in
                SessionSnapshot(id: session.id, customName: session.customName, cwd: session.currentCwd ?? session.initialCwd,
                                isSplit: session.isSplit, fontSize: session.fontSize)
            })
        }
        return Snapshot(selectedSessionID: selectedSessionID, workspaces: workspaceSnapshots, statusBarHidden: statusBarHidden)
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
        statusBarHidden = snapshot.statusBarHidden ?? false
        workspaces = snapshot.workspaces.map { workspaceSnapshot in
            let sessions = workspaceSnapshot.sessions.map { sessionSnapshot -> Session in
                let session = Session(id: sessionSnapshot.id, initialCwd: sessionSnapshot.cwd, customName: sessionSnapshot.customName)
                session.isSplit = sessionSnapshot.isSplit ?? false
                session.fontSize = sessionSnapshot.fontSize
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
        NSLog("agt: %@", message())
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
