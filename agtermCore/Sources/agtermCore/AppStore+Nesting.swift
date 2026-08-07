import Foundation

/// Nested-session tree operations bridging observed `Session`/`Workspace` state to the host-free
/// `SessionTree` math: create-child placement (in `addSession`), reparent, subtree lookup, expand/collapse,
/// and the cascade-close helpers `closeSession`/`softCloseSession(s)` hook into. Kept out of
/// `AppStore.swift` to stay under its source line limit.
extension AppStore {
    /// Flat `SessionTree.Node`s for a workspace, in array order (bridges `Session` → pure tree math).
    /// Empty for an unknown workspace id.
    func sessionNodes(inWorkspace workspaceID: UUID) -> [SessionTree.Node] {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return [] }
        return workspace.sessions.map { SessionTree.Node(id: $0.id, parentID: $0.parentID) }
    }

    /// `sessionID` plus every descendant, in tree order — the whole cascade-close block, and the input
    /// `reparentSession`'s cycle guard and `expandedSubtreeIDs` build on. Empty for an unknown id.
    public func sessionSubtreeIDs(_ sessionID: UUID) -> [UUID] {
        guard let workspace = workspace(forSession: sessionID) else { return [] }
        let nodes = sessionNodes(inWorkspace: workspace.id)
        guard let range = SessionTree.subtreeRange(of: sessionID, in: nodes) else { return [] }
        return range.map { nodes[$0].id }
    }

    /// Reparents `sessionID` (and its subtree, riding along untouched) under `newParentID` within its OWN
    /// workspace, appended as that parent's last child. The control `--parent` verb: an already-matching
    /// parent is a no-op (position is not disturbed), otherwise it delegates to the positioned form below.
    /// No-ops (no write) on an unknown id, a `newParentID` outside the same workspace, a cycle, or an
    /// already-matching parent.
    public func reparentSession(_ sessionID: UUID, to newParentID: UUID?) {
        guard let session = session(withID: sessionID), session.parentID != newParentID else { return }
        reparentSession(sessionID, to: newParentID, at: nil)
    }

    /// Reparents `sessionID` (subtree riding along) under `newParentID` (nil = top-level) within its OWN
    /// workspace and inserts it as that parent's child number `destination` (nil / out of range = last
    /// child), then repairs the workspace to `SessionTree.preorder` so contiguity holds. The primitive the
    /// sidebar drag needs — unlike the control verb it CAN reposition among the current siblings (a top-level
    /// or same-parent reorder), so its no-op guard is order-and-parent, not parent alone. No-ops (no write)
    /// on an unknown id, a `newParentID` in another workspace, a cycle (`newParentID` is `sessionID` or one
    /// of its descendants), or when neither the parent nor the resulting order would change.
    public func reparentSession(_ sessionID: UUID, to newParentID: UUID?, at destination: Int?) {
        guard let loc = location(ofSession: sessionID) else { return }
        let wsIndex = loc.workspaceIndex
        let nodes = sessionNodes(inWorkspace: workspaces[wsIndex].id)
        if let newParentID {
            guard let parentLoc = location(ofSession: newParentID), parentLoc.workspaceIndex == wsIndex,
                  !SessionTree.isSelfOrDescendant(newParentID, of: sessionID, in: nodes) else { return }
        }
        guard let range = SessionTree.subtreeRange(of: sessionID, in: nodes) else { return }
        // compute the resulting id order on pure Node values: drop the moved block, retarget the root's
        // parent, reinsert at the sibling slot, then normalize to preorder.
        let block = nodes[range].map { $0.id == sessionID ? SessionTree.Node(id: $0.id, parentID: newParentID) : $0 }
        var remaining = nodes
        remaining.removeSubrange(range)
        let insertAt = SidebarDrop.flatChildInsertIndex(order: remaining, parent: newParentID, childDestination: destination)
        remaining.insert(contentsOf: block, at: insertAt)
        let order = SessionTree.preorder(remaining)
        let parentUnchanged = workspaces[wsIndex].sessions[loc.sessionIndex].parentID == newParentID
        guard order != nodes.map(\.id) || !parentUnchanged else { return }
        var byID: [UUID: Session] = [:]
        for session in workspaces[wsIndex].sessions { byID[session.id] = session }
        byID[sessionID]?.parentID = newParentID
        // reparenting INTO a session reveals that new parent, so the just-nested subtree is visible rather
        // than hidden under a collapsed row — the expected result of "drop this onto that to nest it".
        if let newParentID { byID[newParentID]?.isExpanded = true }
        workspaces[wsIndex].sessions = order.compactMap { byID[$0] }
        scheduleTreeChanged()
        save()
    }

    /// Reorders one workspace's sessions into canonical `SessionTree.preorder` so the contiguity invariant
    /// (a parent immediately followed by its whole subtree) holds again. The anchor-relative placement paths
    /// need this UNCONDITIONALLY: a flat positional splice can split the anchor's own subtree, and
    /// `reparentSession` skips its preorder repair when the parent is unchanged (the placed session already
    /// shares the anchor's parent), so nothing else fixes it. Preorder preserves sibling input order — so a
    /// placed session stays exactly where the positional move put it among its siblings — and is the identity
    /// on a flat/non-nested workspace, keeping childless placements byte-identical. No-op (no write) on an
    /// unknown workspace or when the order already matches.
    public func repairContiguity(inWorkspace workspaceID: UUID) {
        guard let wsIndex = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        let before = workspaces[wsIndex].sessions.map(\.id)
        let order = SessionTree.preorder(sessionNodes(inWorkspace: workspaceID))
        guard order != before else { return }
        var byID: [UUID: Session] = [:]
        for session in workspaces[wsIndex].sessions { byID[session.id] = session }
        workspaces[wsIndex].sessions = order.compactMap { byID[$0] }
        scheduleTreeChanged()
        save()
    }

    /// Sets one session's expand/collapse state and persists it; mirrors `setWorkspaceExpanded`. Clean
    /// no-op (no write) for an unknown id or when unchanged.
    public func setSessionExpanded(_ sessionID: UUID, expanded: Bool) {
        guard let session = session(withID: sessionID), session.isExpanded != expanded else { return }
        session.isExpanded = expanded
        save()
    }

    /// Expands every id in `ids` to its own subtree, dedups, and keeps tree order per input entry — the
    /// shared cascade-expansion `softCloseSession`/`softCloseSessions` feed into the existing batch-close
    /// machinery, so a parent anywhere in the input always closes with its whole subtree under the one
    /// grace timer and one undo the batch already groups.
    func expandedSubtreeIDs(_ ids: [UUID]) -> [UUID] {
        var seen: Set<UUID> = []
        var result: [UUID] = []
        for id in ids {
            for member in sessionSubtreeIDs(id) where seen.insert(member).inserted {
                result.append(member)
            }
        }
        return result
    }

    /// Cascades `closeSession` over `root`'s whole subtree as ONE operation when it has descendants: one
    /// grouped `.sessionGroup` Recent Closed record (so a single Reopen restores the whole subtree, tree
    /// order and nesting intact — `recordRecentClosedSessionGroup`), then the same per-session
    /// teardown `closeSession` performs for a single session, looped over the contiguous subtree block, with
    /// ONE reselection computed from the root's original slot — mirroring `removeWorkspace`'s
    /// cascade-teardown precedent (one teardown loop, then one reselect). Returns false (a no-op) for an
    /// unknown id or a childless session, so `closeSession` falls through unchanged to its original
    /// single-session path, which still records the legacy single `.session` item.
    @discardableResult
    func closeSessionSubtree(_ root: UUID) -> Bool {
        guard let location = location(ofSession: root) else { return false }
        let workspace = workspaces[location.workspaceIndex]
        let nodes = sessionNodes(inWorkspace: workspace.id)
        guard let range = SessionTree.subtreeRange(of: root, in: nodes), range.count > 1 else { return false }

        let removed = Array(workspaces[location.workspaceIndex].sessions[range])
        workspaces[location.workspaceIndex].sessions.removeSubrange(range)
        let wasActive = selectedSessionID.map { id in removed.contains { $0.id == id } } ?? false
        recordRecentClosedSessionGroup(removed, workspaceID: workspace.id, workspaceName: workspace.name,
                                       location: location, selectedSessionID: removed.first?.id)
        for session in removed {
            emitSessionClosed(session, workspace: workspace.id)
            session.surface?.teardown()
            session.splitSurface?.teardown()
            session.overlaySurface?.teardown()
            session.teardownPaneOverlays()
            session.scratchSurface?.teardown()
            session.discardHudBody() // a HUD whose surface never realized has no teardown to delete its body file
            WatermarkStorage.removeRenderedText(sessionID: session.id) // drop any rendered .text PNG; the session is gone
            removeFromRecency(session.id)
        }
        if wasActive {
            selectedSessionID = closeReselectionTarget(after: location)
            replaceSidebarSelection(with: selectedSessionID)
            disableFocusIfSelectionOutsideSet(selectedSessionID) // the reselected session may live outside the marked set
            recordRecency()
        } else {
            pruneSidebarSelection()
        }
        save()
        return true
    }
}
