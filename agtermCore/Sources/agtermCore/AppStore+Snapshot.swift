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
        let flaggedIDs = orderedFlaggedSessions.map(\.id).filter(persistable.contains)
        return Snapshot(selectedSessionID: persistedSelection(among: persistable, recency: recency),
                        workspaces: workspaceSnapshots,
                        sidebarWidth: sidebarWidth, sidebarVisible: sidebarVisible, sidebarMode: sidebarMode,
                        focusedWorkspaceIDs: focusIDs.isEmpty ? nil : focusIDs,
                        focusEnabled: focusEnabled ? true : nil,
                        sessionRecency: recency,
                        flaggedOrder: flaggedIDs.isEmpty ? nil : flaggedIDs)
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
                        paneBackgrounds: session.paneBackgrounds.persisted,
                        restoreCommand: session.restoreCommand,
                        splitRestoreCommand: session.splitRestoreCommand,
                        context: session.context,
                        lastSelectedAt: session.lastSelectedAt?.timeIntervalSince1970,
                        tint: session.tint, parentID: session.parentID,
                        collapsed: session.isExpanded ? nil : true)
    }

    /// The single workspace-to-disk producer, used by the launch snapshot and by a closed workspace's
    /// Recent Closed record. Only a collapsed workspace writes the flag, so an all-expanded tree matches a
    /// legacy snapshot.
    func workspaceSnapshot(_ workspace: Workspace) -> WorkspaceSnapshot {
        WorkspaceSnapshot(id: workspace.id, name: workspace.name,
                          sessions: workspace.sessions.filter(\.isPersistable).map(sessionSnapshot),
                          collapsed: workspace.isExpanded ? nil : true, tint: workspace.tint)
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
        session.tint = snapshot.tint
        session.parentID = snapshot.parentID
        session.isExpanded = !(snapshot.collapsed ?? false)
        session.lastSelectedAt = snapshot.lastSelectedAt.map(Date.init(timeIntervalSince1970:))
        session.initialCommand = snapshot.initialCommand
        session.commandWait = snapshot.commandWait ?? false
        session.splitInitialCommand = hasSplit ? snapshot.splitInitialCommand : nil
        session.splitCommandWait = hasSplit ? (snapshot.splitCommandWait ?? false) : false
        session.wasRestored = true
        session.backgroundWatermark = snapshot.backgroundWatermark
        session.paneBackgrounds = PaneBackgrounds(left: snapshot.paneBackgrounds?.left,
                                                  right: hasSplit ? snapshot.paneBackgrounds?.right : nil)
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
        Workspace(id: snapshot.id, name: snapshot.name,
                  sessions: Self.regroupedCompanions(snapshot.sessions.map { session(from: $0) }),
                  isExpanded: !(snapshot.collapsed ?? false), tint: snapshot.tint)
    }

    /// Rebuilds the tree from a snapshot: fresh `Session`s (surfaces and shells spawn lazily on first
    /// display) keyed by the persisted ids so the restored `selectedSessionID` still resolves, replacing the
    /// current state wholesale. A persisted selection pointing at a session that no longer exists is cleared.
    /// Deliberately does NOT call `save()` — it loads what was just read from disk; the closing
    /// `reselectIfSelectionHidden` is the exception, since repairing a stranded selection is worth writing.
    /// `launchRestore` marks an APP-BOOTSTRAP restore, the only thing that arms anything executable — a
    /// persisted `session.restore` override and the captured `foregroundCommand`/`splitForegroundCommand`.
    /// It defaults to false because reopening a closed window mid-process reloads its store through here,
    /// and that RUNTIME caller must not execute anything.
    public func restore(from snapshot: Snapshot, launchRestore: Bool = false) {
        // to the end: the closing repair of a hidden selection is part of the reload too
        restoringSelection = true
        defer { restoringSelection = false }
        freshWorkspaceID = nil // live create-time state, never restored from disk
        // fold duplicate workspace ids into the first occurrence and keep only the first snapshot of a
        // repeated session id, else the rest stay unreachable past the first match and get re-saved.
        var seenSessionIDs: Set<UUID> = []
        workspaces = snapshot.workspaces.reduce(into: [Workspace]()) { restored, workspaceSnapshot in
            let sessions = workspaceSnapshot.sessions
                .filter { seenSessionIDs.insert($0.id).inserted }
                .map { session(from: $0, launchRestore: launchRestore) }
            if let existing = restored.firstIndex(where: { $0.id == workspaceSnapshot.id }) {
                restored[existing].sessions.append(contentsOf: sessions)
                return
            }
            // absent/nil collapsed → expanded (back-compat with snapshots written before the field existed).
            restored.append(Workspace(id: workspaceSnapshot.id, name: workspaceSnapshot.name, sessions: sessions,
                                      isExpanded: !(workspaceSnapshot.collapsed ?? false),
                                      tint: workspaceSnapshot.tint))
        }
        for index in workspaces.indices {
            workspaces[index].sessions = Self.regroupedCompanions(workspaces[index].sessions)
        }
        // clamp on restore (not just nil-default) so a corrupt or hand-edited snapshot can't drive an
        // out-of-range frame width; the drag and `sidebar.width` clamp to the same bounds.
        sidebarWidth = AppStore.clampSidebarWidth(snapshot.sidebarWidth ?? AppStore.sidebarWidthDefault)
        sidebarVisible = snapshot.sidebarVisible ?? true
        sidebarMode = snapshot.sidebarMode ?? .tree
        restoreFlaggedOrder(snapshot.flaggedOrder)
        restoreFocus(from: snapshot)
        if let id = snapshot.selectedSessionID, session(withID: id) == nil {
            selectedSessionID = nil
        } else {
            selectedSessionID = snapshot.selectedSessionID
        }
        replaceSidebarSelection(with: selectedSessionID)
        // re-seed the Ctrl-Tab order from the persisted list (dropping ids not in the restored tree); the
        // restored selection floats to the front, keeping the "previous session" slot truthful.
        let restoredIDs = Set(workspaces.flatMap(\.sessions).map(\.id))
        sessionRecency = RecencyStack(items: (snapshot.sessionRecency ?? []).filter { restoredIDs.contains($0) })
        recordRecency()
        // LAST, after the recency stack is re-seeded: the pick is MRU, so earlier finds an empty stack.
        reselectIfSelectionHidden()
        // a reload is not a pane selection either
        paneFocusBaseline = selectedPaneIdentities()
    }
}
