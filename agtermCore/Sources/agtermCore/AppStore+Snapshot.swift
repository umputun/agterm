import Foundation

// MARK: - Snapshot conversion

/// The `Snapshot` <-> model boundary: building one from the live tree and rebuilding the tree from one.
/// Split out of the main `AppStore` body for the file-size budget, like `AppStore+Restore.swift`.
///
/// `launchRestore` lives here and is the only path that arms anything executable — see `session(from:)`.
extension AppStore {

    /// Builds a `Snapshot` of the current tree; each session captures its live `currentCwd` (or `initialCwd`
    /// if no PWD report arrived). Runs on `@MainActor`; the result is `Sendable`, safe to hand to a writer.
    public func snapshot() -> Snapshot {
        let workspaceSnapshots = workspaces.map(workspaceSnapshot)
        // TREE order keeps the on-disk list deterministic (not the Set's hash order); an unmarked store omits
        // both focus keys, matching a file written before the set existed. `focusedWorkspaceID` stays unused.
        let focusIDs = workspaces.map(\.id).filter(focusedWorkspaceIDs.contains)
        let persistable = Set(workspaceSnapshots.flatMap(\.sessions).map(\.id))
        let recency = sessionRecency.items.filter(persistable.contains)
        return Snapshot(selectedSessionID: persistedSelection(among: persistable, recency: recency),
                        workspaces: workspaceSnapshots,
                        sidebarWidth: sidebarWidth, sidebarVisible: sidebarVisible, sidebarMode: sidebarMode,
                        focusedWorkspaceIDs: focusIDs.isEmpty ? nil : focusIDs,
                        focusEnabled: focusEnabled ? true : nil,
                        sessionRecency: recency)
    }

    /// The selection to write. A remote session is not in the snapshot, so naming it would restore an empty
    /// window while local rows sit there; fall back to the most recent surviving session, then the first,
    /// matching the MRU repair `reselectIfSelectionHidden` already does for a narrowed tree.
    private func persistedSelection(among persistable: Set<UUID>, recency: [UUID]) -> UUID? {
        if let selectedSessionID, persistable.contains(selectedSessionID) { return selectedSessionID }
        guard selectedSessionID != nil else { return nil }
        return recency.first ?? workspaces.flatMap(\.sessions).first { persistable.contains($0.id) }?.id
    }

    func sessionSnapshot(_ session: Session) -> SessionSnapshot {
        SessionSnapshot(id: session.id, paneIdentity: session.paneIdentity,
                        splitPaneIdentity: session.hasSplit ? session.splitPaneIdentity : nil,
                        customName: session.customName, cwd: session.currentCwd ?? session.initialCwd,
                        isSplit: session.isSplit, hasSplit: session.hasSplit ? true : nil,
                        splitAxis: session.hasSplit ? session.splitAxis : nil,
                        fontSize: session.fontSize,
                        splitCwd: session.splitCwd ?? session.initialSplitCwd, splitRatio: session.splitRatio,
                        flagged: session.flagged,
                        foregroundCommand: session.foregroundCommand,
                        splitForegroundCommand: session.splitForegroundCommand,
                        initialCommand: session.initialCommand, commandWait: session.commandWait ? true : nil,
                        splitInitialCommand: session.splitInitialCommand,
                        splitCommandWait: session.splitCommandWait ? true : nil,
                        backgroundWatermark: session.backgroundWatermark,
                        restoreCommand: session.restoreCommand,
                        splitRestoreCommand: session.splitRestoreCommand,
                        context: session.context)
    }

    /// The single workspace-to-disk producer, used by the launch snapshot and by a closed workspace's
    /// Recent Closed record. Only a collapsed workspace writes the flag, so an all-expanded tree matches a
    /// legacy snapshot.
    func workspaceSnapshot(_ workspace: Workspace) -> WorkspaceSnapshot {
        WorkspaceSnapshot(id: workspace.id, name: workspace.name,
                          sessions: workspace.sessions.filter(\.isPersistable).map(sessionSnapshot),
                          collapsed: workspace.isExpanded ? nil : true)
    }

    /// Rebuilds one session from its snapshot. `launchRestore` marks an APP-BOOTSTRAP restore, the only path
    /// allowed to arm anything executable: the captured foreground commands (persisted only by an app-exit
    /// capture, but a stale file could still carry one — a mid-run reopen must never replay a command
    /// without any quit) and the persisted `restoreCommand`. It defaults to false so any other rebuild
    /// (a mid-process window reload, Reopen Closed Item) comes back with nothing armed.
    ///
    /// Everything armed goes to a TRANSIENT slot the surface factory consumes, never to the persisted
    /// field: `snapshot()` serializes those, so arming one would let any save before the surface spawns
    /// rewrite what `loadStore`'s launch strip just removed from disk.
    ///
    /// A hidden split keeps its identity and restore state so showing it reattaches the surviving daemon;
    /// focus is intentionally not persisted and therefore returns to the primary pane.
    func session(from snapshot: SessionSnapshot, launchRestore: Bool = false) -> Session {
        let hasSplit = (snapshot.isSplit ?? false) || (snapshot.hasSplit ?? false)
        let session = Session(id: snapshot.id, initialCwd: snapshot.cwd, customName: snapshot.customName,
                              paneIdentity: snapshot.paneIdentity ?? UUID(),
                              splitPaneIdentity: hasSplit ? (snapshot.splitPaneIdentity ?? UUID()) : nil)
        session.isSplit = snapshot.isSplit ?? false
        session.hasSplit = hasSplit
        session.splitAxis = hasSplit ? (snapshot.splitAxis ?? .leftRight) : .leftRight
        session.fontSize = snapshot.fontSize
        session.initialSplitCwd = snapshot.splitCwd
        session.splitRatio = snapshot.splitRatio.map { min(AppStore.splitRatioMax, max(AppStore.splitRatioMin, $0)) }
        session.flagged = snapshot.flagged ?? false
        session.context = snapshot.context
        session.initialCommand = snapshot.initialCommand
        session.commandWait = snapshot.commandWait ?? false
        session.splitInitialCommand = hasSplit ? snapshot.splitInitialCommand : nil
        session.splitCommandWait = hasSplit ? (snapshot.splitCommandWait ?? false) : false
        session.wasRestored = true
        session.backgroundWatermark = snapshot.backgroundWatermark
        session.restoreCommand = snapshot.restoreCommand
        session.splitRestoreCommand = hasSplit ? snapshot.splitRestoreCommand : nil
        if launchRestore {
            // into the TRANSIENT slots, leaving the persisted fields nil: `snapshot()` serializes those, so
            // arming them would let any save before the surface spawns rewrite the argv the launch strip
            // just removed from disk.
            session.pendingForegroundCommand = snapshot.foregroundCommand
            session.pendingRestoreCommand = snapshot.restoreCommand
            if hasSplit {
                session.pendingSplitForegroundCommand = snapshot.splitForegroundCommand
                session.pendingSplitRestoreCommand = session.splitRestoreCommand
            }
        }
        return session
    }

    func workspace(from snapshot: WorkspaceSnapshot) -> Workspace {
        Workspace(id: snapshot.id, name: snapshot.name, sessions: snapshot.sessions.map { session(from: $0) },
                  isExpanded: !(snapshot.collapsed ?? false))
    }
}
