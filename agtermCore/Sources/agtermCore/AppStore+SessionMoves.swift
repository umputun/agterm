import Foundation

extension AppStore {
    /// moveSession moves a session, keeping the same `Session` so its surfaces survive. A parent carries its
    /// companions; a companion moves only among its siblings and any other destination returns false unchanged.
    /// `index` counts the target with the moved session alone removed, the slot callers compute for one row;
    /// a parent's block lands where that single row would. nil appends.
    @discardableResult
    public func moveSession(_ sessionID: UUID, toWorkspace targetID: UUID, at index: Int? = nil) -> Bool {
        guard let source = location(ofSession: sessionID),
              let targetIndex = workspaces.firstIndex(where: { $0.id == targetID }) else { return false }
        let session = workspaces[source.workspaceIndex].sessions[source.sessionIndex]
        if session.parentID != nil {
            guard targetIndex == source.workspaceIndex else { return false }
            return moveCompanions([sessionID], to: index)
        }
        let block = groupIDs(at: source)
        let anchor = insertionAnchor(movingIDs: [sessionID], blockIDs: Set(block), workspace: targetIndex, index: index)
        relocate(block, toWorkspace: targetIndex, before: anchor)
        return true
    }

    /// moveSessions moves the selection in tree order and returns how many sessions moved. A selected parent
    /// carries its companions. Siblings selected without their parent reorder among themselves; any other
    /// companion in a batch stays put. With nil `index`, groups already in the target stay; an explicit
    /// `index` counts the target with every selected session removed.
    @discardableResult
    public func moveSessions(_ sessionIDs: [UUID], toWorkspace targetID: UUID, at index: Int? = nil) -> Int {
        guard let targetIndex = workspaces.firstIndex(where: { $0.id == targetID }) else { return 0 }
        let selected = orderedSessionIDs(matching: Set(sessionIDs))
        if selected.count == 1, let id = selected.first {
            return moveSession(id, toWorkspace: targetID, at: index) ? 1 + companions(of: id).count : 0
        }
        var parents = selected.filter { session(withID: $0)?.parentID == nil }
        if parents.isEmpty, workspace(forSession: selected.first ?? UUID())?.id == targetID {
            return moveCompanions(selected, to: index) ? selected.count : 0
        }
        if index == nil {
            parents = parents.filter { workspace(forSession: $0)?.id != targetID }
        }
        guard !parents.isEmpty else { return 0 }
        let block = parents.flatMap { id in location(ofSession: id).map(groupIDs(at:)) ?? [] }
        let anchor = insertionAnchor(movingIDs: Set(selected), blockIDs: Set(block), workspace: targetIndex, index: index)
        relocate(block, toWorkspace: targetIndex, before: anchor)
        return block.count
    }

    /// reorderSession steps a session `up`/`down`/`top`/`bottom`: a companion among its siblings, any other
    /// session among its workspace's top-level groups, stepping over a whole group. No write at an end.
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

    private func groupIDs(at location: (workspaceIndex: Int, sessionIndex: Int)) -> [UUID] {
        let sessions = workspaces[location.workspaceIndex].sessions
        return sessions[location.sessionIndex..<Self.groupEnd(from: location.sessionIndex, in: sessions)].map(\.id)
    }

    // the first remaining top-level session from `index` on that is not in the moving block, nil for the end
    private func insertionAnchor(movingIDs: Set<UUID>, blockIDs: Set<UUID>, workspace targetIndex: Int, index: Int?) -> UUID? {
        guard let index else { return nil }
        let remaining = workspaces[targetIndex].sessions.filter { !movingIDs.contains($0.id) }
        let start = max(0, min(index, remaining.count))
        return remaining[start...].first { !blockIDs.contains($0.id) && $0.parentID == nil }?.id
    }

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

    /// canMoveSessions answers whether `moveSessions` accepts this destination, without moving; the sidebar
    /// asks it so a drop indicator or a Move to entry never offers a destination the move refuses.
    public func canMoveSessions(_ sessionIDs: [UUID], toWorkspace targetID: UUID, at index: Int? = nil) -> Bool {
        guard workspaces.contains(where: { $0.id == targetID }) else { return false }
        let selected = orderedSessionIDs(matching: Set(sessionIDs))
        if selected.count == 1, let id = selected.first, session(withID: id)?.parentID == nil { return true }
        var parents = selected.filter { session(withID: $0)?.parentID == nil }
        if parents.isEmpty {
            guard workspace(forSession: selected.first ?? UUID())?.id == targetID else { return false }
            return companionDestination(selected, index: index) != nil
        }
        if index == nil {
            parents = parents.filter { workspace(forSession: $0)?.id != targetID }
        }
        return !parents.isEmpty
    }

    // `index` counts the workspace with the moving siblings removed and must fall inside their group: from
    // right after the parent to its end. nil appends to the group. false, with nothing changed, otherwise.
    private func moveCompanions(_ ids: [UUID], to index: Int?) -> Bool {
        guard let (workspaceIndex, remaining, destination) = companionDestination(ids, index: index) else { return false }
        let moving = Set(ids)
        let sessions = workspaces[workspaceIndex].sessions
        let block = sessions.filter { moving.contains($0.id) }
        workspaces[workspaceIndex].sessions = Array(remaining[..<destination]) + block + Array(remaining[destination...])
        pruneSidebarSelection()
        if sessions.map(\.id) != workspaces[workspaceIndex].sessions.map(\.id) { scheduleTreeChanged() }
        save()
        return true
    }

    private func companionDestination(_ ids: [UUID], index: Int?) -> (workspace: Int, remaining: [Session], destination: Int)? {
        guard let first = ids.first.flatMap(location(ofSession:)),
              let parentID = workspaces[first.workspaceIndex].sessions[first.sessionIndex].parentID else { return nil }
        let sessions = workspaces[first.workspaceIndex].sessions
        guard ids.allSatisfy({ id in sessions.contains { $0.id == id && $0.parentID == parentID } }) else { return nil }
        let moving = Set(ids)
        let remaining = sessions.filter { !moving.contains($0.id) }
        guard let parent = remaining.firstIndex(where: { $0.id == parentID }) else { return nil }
        let end = Self.groupEnd(from: parent, in: remaining)
        let destination = index ?? end
        guard destination > parent, destination <= end else { return nil }
        return (first.workspaceIndex, remaining, destination)
    }
}
