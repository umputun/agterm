import Foundation

extension AppStore {
    /// Moves a session to another workspace (or reorders within one), keeping the **same** `Session` instance
    /// so its attached surface and live shell survive. A parent moves with its companions as one block, and a
    /// companion moves only among its siblings: any other destination is refused and returns false.
    ///
    /// `index` is the destination position **after** the moved session alone is removed (clamped); nil
    /// appends. It is resolved to the session it would land in front of, so a block lands in the same place a
    /// single session would, and a slot inside another group moves past that group. `selectedSessionID` is
    /// unaffected. Moving the **active** session out of the marked set suspends the focus filter while KEEPING
    /// the set; a non-active session leaves the filter intact.
    @discardableResult
    public func moveSession(_ sessionID: UUID, toWorkspace targetID: UUID, at index: Int? = nil) -> Bool {
        guard let source = location(ofSession: sessionID),
              let targetIndex = workspaces.firstIndex(where: { $0.id == targetID }) else { return false }
        let session = workspaces[source.workspaceIndex].sessions[source.sessionIndex]
        if session.parentID != nil {
            guard targetIndex == source.workspaceIndex else { return false }
            moveCompanion(at: source, to: index)
            return true
        }
        let block = groupIDs(at: source)
        let anchor = insertionAnchor(movingIDs: [sessionID], blockIDs: Set(block), workspace: targetIndex, index: index)
        relocate(block, toWorkspace: targetIndex, before: anchor)
        return true
    }

    /// Moves selected sessions in their current tree order. Each selected parent carries its companions; a
    /// companion moves only with its parent, so one selected alone in a batch stays where it is. With
    /// `index == nil`, a multi-session move appends cross-workspace groups and leaves those already in the
    /// target in place; a one-session call matches `moveSession`. With an explicit `index` (a drag drop), the
    /// index is the slot after every selected session is removed. Returns the number of sessions moved.
    @discardableResult
    public func moveSessions(_ sessionIDs: [UUID], toWorkspace targetID: UUID, at index: Int? = nil) -> Int {
        guard let targetIndex = workspaces.firstIndex(where: { $0.id == targetID }) else { return 0 }
        let selected = orderedSessionIDs(matching: Set(sessionIDs))
        if selected.count == 1, let id = selected.first {
            return moveSession(id, toWorkspace: targetID, at: index) ? 1 + companions(of: id).count : 0
        }
        var parents = selected.filter { session(withID: $0)?.parentID == nil }
        if index == nil {
            parents = parents.filter { workspace(forSession: $0)?.id != targetID }
        }
        guard !parents.isEmpty else { return 0 }
        let block = parents.flatMap { id in location(ofSession: id).map(groupIDs(at:)) ?? [] }
        let anchor = insertionAnchor(movingIDs: Set(selected), blockIDs: Set(block), workspace: targetIndex, index: index)
        relocate(block, toWorkspace: targetIndex, before: anchor)
        return block.count
    }

    /// Reorders a session one step (`up`/`down`/`top`/`bottom`) among the sessions it can move between: a
    /// companion among its siblings, any other session among the top-level groups of its workspace, stepping
    /// over a whole group. No-op (no write) on an unknown id or when already at that end.
    public func reorderSession(_ id: UUID, _ direction: ReorderDirection) {
        guard let location = location(ofSession: id) else { return }
        let sessions = workspaces[location.workspaceIndex].sessions
        let workspaceID = workspaces[location.workspaceIndex].id
        if let parentID = sessions[location.sessionIndex].parentID,
           let parent = sessions.firstIndex(where: { $0.id == parentID }) {
            let siblings = Self.groupEnd(from: parent, in: sessions) - parent - 1
            guard let dest = direction.destinationIndex(from: location.sessionIndex - parent - 1, count: siblings) else { return }
            moveSession(id, toWorkspace: workspaceID, at: parent + 1 + dest)
            return
        }
        let units = sessions.indices.filter { sessions[$0].parentID == nil }
        guard let unit = units.firstIndex(of: location.sessionIndex),
              let dest = direction.destinationIndex(from: unit, count: units.count) else { return }
        let remaining = units.filter { $0 != location.sessionIndex }
        let flat = dest < remaining.count ? remaining[dest] - (remaining[dest] > location.sessionIndex ? 1 : 0) : sessions.count - 1
        moveSession(id, toWorkspace: workspaceID, at: flat)
    }

    /// The ids of the group at `location`: the session followed by its companions.
    private func groupIDs(at location: (workspaceIndex: Int, sessionIndex: Int)) -> [UUID] {
        let sessions = workspaces[location.workspaceIndex].sessions
        return sessions[location.sessionIndex..<Self.groupEnd(from: location.sessionIndex, in: sessions)].map(\.id)
    }

    /// The session a move lands in front of, nil for the end. `index` counts the target workspace with the
    /// selected sessions removed; the first session from that slot on that is not part of the moving block is
    /// the anchor, then a companion anchor moves on to the next top-level session.
    private func insertionAnchor(movingIDs: Set<UUID>, blockIDs: Set<UUID>, workspace targetIndex: Int, index: Int?) -> UUID? {
        guard let index else { return nil }
        let remaining = workspaces[targetIndex].sessions.filter { !movingIDs.contains($0.id) }
        let start = max(0, min(index, remaining.count))
        return remaining[start...].first { !blockIDs.contains($0.id) && $0.parentID == nil }?.id
    }

    /// Removes the `block` sessions wherever they are and inserts them, in order, in front of `anchor` in the
    /// target workspace (at its end for nil). Saves and announces a tree change only when the order moved.
    private func relocate(_ block: [UUID], toWorkspace targetIndex: Int, before anchor: UUID?) {
        let before = workspaces.map { $0.sessions.map(\.id) }
        var moving: [Session] = []
        for id in block {
            guard let location = location(ofSession: id) else { continue }
            moving.append(workspaces[location.workspaceIndex].sessions.remove(at: location.sessionIndex))
        }
        let sessions = workspaces[targetIndex].sessions
        let destination = anchor.flatMap { id in sessions.firstIndex { $0.id == id } } ?? sessions.count
        workspaces[targetIndex].sessions.insert(contentsOf: moving, at: destination)
        if let selectedSessionID, block.contains(selectedSessionID) { disableFocusIfSelectionOutsideSet(selectedSessionID) }
        pruneSidebarSelection()
        if before != workspaces.map({ $0.sessions.map(\.id) }) { scheduleTreeChanged() }
        save()
    }

    /// Moves the companion at `source` to `index` among its siblings (post-removal, clamped into the group).
    private func moveCompanion(at source: (workspaceIndex: Int, sessionIndex: Int), to index: Int?) {
        let before = workspaces[source.workspaceIndex].sessions.map(\.id)
        let companion = workspaces[source.workspaceIndex].sessions.remove(at: source.sessionIndex)
        let sessions = workspaces[source.workspaceIndex].sessions
        guard let parent = sessions.firstIndex(where: { $0.id == companion.parentID }) else {
            workspaces[source.workspaceIndex].sessions.insert(companion, at: source.sessionIndex)
            return
        }
        let end = Self.groupEnd(from: parent, in: sessions)
        workspaces[source.workspaceIndex].sessions.insert(companion, at: min(max(index ?? end, parent + 1), end))
        pruneSidebarSelection()
        if before != workspaces[source.workspaceIndex].sessions.map(\.id) { scheduleTreeChanged() }
        save()
    }
}
