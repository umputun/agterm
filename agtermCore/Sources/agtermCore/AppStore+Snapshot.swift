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
        let workspaceSnapshots = workspaces.map { workspace in
            let sessions = workspace.sessions.map(sessionSnapshot)
            // only a collapsed workspace writes the flag, so an all-expanded tree matches a legacy snapshot.
            return WorkspaceSnapshot(id: workspace.id, name: workspace.name, sessions: sessions,
                                     collapsed: workspace.isExpanded ? nil : true)
        }
        // TREE order keeps the on-disk list deterministic (not the Set's hash order); an unmarked store omits
        // both focus keys, matching a file written before the set existed. `focusedWorkspaceID` stays unused.
        let focusIDs = workspaces.map(\.id).filter(focusedWorkspaceIDs.contains)
        return Snapshot(selectedSessionID: selectedSessionID, workspaces: workspaceSnapshots,
                        sidebarWidth: sidebarWidth, sidebarVisible: sidebarVisible, sidebarMode: sidebarMode,
                        focusedWorkspaceIDs: focusIDs.isEmpty ? nil : focusIDs,
                        focusEnabled: focusEnabled ? true : nil,
                        sessionRecency: sessionRecency.items)
    }

    func sessionSnapshot(_ session: Session) -> SessionSnapshot {
        SessionSnapshot(id: session.id, customName: session.customName, cwd: session.currentCwd ?? session.initialCwd,
                        isSplit: session.isSplit, splitAxis: session.isSplit ? session.splitAxis : nil,
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
                        splitRestoreCommand: session.splitRestoreCommand)
    }

    func workspaceSnapshot(_ workspace: Workspace) -> WorkspaceSnapshot {
        WorkspaceSnapshot(id: workspace.id, name: workspace.name, sessions: workspace.sessions.map(sessionSnapshot),
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
    /// A split hidden at the last quit is NOT rebuilt (`hasSplit` follows `isSplit`), so its pinned override
    /// describes a pane that no longer exists and is DROPPED here, the rule `closeSplit` applies when a pane
    /// goes away. Keeping it would leave a value `tree` reports but no write can clear (`session.restore
    /// --pane right` is rejected without a split), and a fresh ⌘D split at the next quit would inherit it.
    func session(from snapshot: SessionSnapshot, launchRestore: Bool = false) -> Session {
        let session = Session(id: snapshot.id, initialCwd: snapshot.cwd, customName: snapshot.customName)
        session.isSplit = snapshot.isSplit ?? false
        session.hasSplit = session.isSplit
        session.splitAxis = session.isSplit ? (snapshot.splitAxis ?? .leftRight) : .leftRight
        session.fontSize = snapshot.fontSize
        session.initialSplitCwd = snapshot.splitCwd
        session.splitRatio = snapshot.splitRatio.map { min(AppStore.splitRatioMax, max(AppStore.splitRatioMin, $0)) }
        session.flagged = snapshot.flagged ?? false
        session.initialCommand = snapshot.initialCommand
        session.commandWait = snapshot.commandWait ?? false
        session.splitInitialCommand = session.isSplit ? snapshot.splitInitialCommand : nil
        session.splitCommandWait = session.isSplit ? (snapshot.splitCommandWait ?? false) : false
        session.wasRestored = true
        session.backgroundWatermark = snapshot.backgroundWatermark
        session.restoreCommand = snapshot.restoreCommand
        session.splitRestoreCommand = session.isSplit ? snapshot.splitRestoreCommand : nil
        if launchRestore {
            // into the TRANSIENT slots, leaving the persisted fields nil: `snapshot()` serializes those, so
            // arming them would let any save before the surface spawns rewrite the argv the launch strip
            // just removed from disk.
            session.pendingForegroundCommand = snapshot.foregroundCommand
            session.pendingRestoreCommand = snapshot.restoreCommand
            if session.isSplit {
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
