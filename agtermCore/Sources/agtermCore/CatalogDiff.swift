import Foundation

extension CatalogSnapshot {
    /// apply makes one change, the same way on the server that diffed it and on a viewer reading it. A change naming
    /// something absent is a no-op.
    public mutating func apply(_ change: CatalogChange) {
        switch change {
        case .workspaceAdded(let workspace, let index):
            workspaces.removeAll { $0.id == workspace.id }
            workspaces.insert(workspace, at: min(max(index, 0), workspaces.count))
        case .workspaceChanged(let id, let name):
            if let index = workspaces.firstIndex(where: { $0.id == id }) { workspaces[index].name = name }
        case .workspaceRemoved(let id):
            workspaces.removeAll { $0.id == id }
        case .workspaceOrder(let ids):
            workspaces = Self.ordered(workspaces, by: ids, id: \.id)
        case .sessionAdded(let session, let workspace, let index):
            removeSession(session.id)
            guard let at = workspaces.firstIndex(where: { $0.id == workspace }) else { return }
            workspaces[at].sessions.insert(session, at: min(max(index, 0), workspaces[at].sessions.count))
        case .sessionChanged(let fields):
            updateSession(fields.id) { session in
                session.fields = fields
                session.normalize()
            }
        case .sessionRemoved(let id):
            removeSession(id)
        case .sessionOrder(let ids, let workspace):
            guard let at = workspaces.firstIndex(where: { $0.id == workspace }) else { return }
            workspaces[at].sessions = Self.ordered(workspaces[at].sessions, by: ids, id: \.id)
        case .paneAdded(let pane, let session), .paneChanged(let pane, let session):
            updateSession(session) { session in
                if let index = session.panes.firstIndex(where: { $0.identity == pane.identity }) {
                    session.panes[index] = pane
                } else {
                    session.panes.append(pane)
                }
                session.normalize()
            }
        case .paneRemoved(let identity, let session):
            updateSession(session) { $0.panes.removeAll { $0.identity == identity } }
        }
    }

    /// changes lists what turns `self` into `next`, each applied to a working copy as it is listed, so applying the
    /// list in order lands exactly on `next`'s workspaces.
    public func changes(to next: CatalogSnapshot) -> [CatalogChange] {
        var state = self
        var list: [CatalogChange] = []
        func emit(_ change: CatalogChange) {
            list.append(change)
            state.apply(change)
        }
        let nextPlace = Dictionary(next.workspaces.flatMap { workspace in workspace.sessions.map { ($0.id, workspace.id) } },
                                   uniquingKeysWith: { first, _ in first })
        for workspace in state.workspaces {
            for session in workspace.sessions where nextPlace[session.id] != workspace.id {
                emit(.sessionRemoved(session.id))
            }
        }
        let nextIDs = Set(next.workspaces.map(\.id))
        for workspace in state.workspaces where !nextIDs.contains(workspace.id) {
            emit(.workspaceRemoved(workspace.id))
        }
        for (index, workspace) in next.workspaces.enumerated() {
            guard let current = state.workspaces.first(where: { $0.id == workspace.id }) else {
                emit(.workspaceAdded(workspace, index: index))
                continue
            }
            if current.name != workspace.name { emit(.workspaceChanged(id: workspace.id, name: workspace.name)) }
        }
        if state.workspaces.map(\.id) != next.workspaces.map(\.id) { emit(.workspaceOrder(next.workspaces.map(\.id))) }
        for workspace in next.workspaces {
            for (index, session) in workspace.sessions.enumerated() {
                guard let current = state.session(session.id) else {
                    emit(.sessionAdded(session, workspace: workspace.id, index: index))
                    continue
                }
                for change in Self.paneChanges(from: current, to: session) { emit(change) }
                if current.fields != session.fields { emit(.sessionChanged(session.fields)) }
            }
            let order = workspace.sessions.map(\.id)
            if state.workspaces.first(where: { $0.id == workspace.id })?.sessions.map(\.id) != order {
                emit(.sessionOrder(order, workspace: workspace.id))
            }
        }
        return list
    }

    func session(_ id: UUID) -> CatalogSession? {
        for workspace in workspaces {
            if let session = workspace.sessions.first(where: { $0.id == id }) { return session }
        }
        return nil
    }

    private static func paneChanges(from current: CatalogSession, to next: CatalogSession) -> [CatalogChange] {
        let id = next.id
        var list: [CatalogChange] = current.panes.filter { pane in !next.panes.contains { $0.identity == pane.identity } }
            .map { .paneRemoved($0.identity, session: id) }
        for pane in next.panes {
            guard let old = current.panes.first(where: { $0.identity == pane.identity }) else {
                list.append(.paneAdded(pane, session: id))
                continue
            }
            if old != pane { list.append(.paneChanged(pane, session: id)) }
        }
        return list
    }

    private mutating func removeSession(_ id: UUID) {
        for index in workspaces.indices { workspaces[index].sessions.removeAll { $0.id == id } }
    }

    private mutating func updateSession(_ id: UUID, _ change: (inout CatalogSession) -> Void) {
        for index in workspaces.indices {
            guard let at = workspaces[index].sessions.firstIndex(where: { $0.id == id }) else { continue }
            change(&workspaces[index].sessions[at])
            return
        }
    }

    /// ordered puts the listed ids first in their listed order and keeps anything unlisted after them as it was.
    private static func ordered<T>(_ items: [T], by ids: [UUID], id: KeyPath<T, UUID>) -> [T] {
        let rank = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return items.enumerated().sorted { lhs, rhs in
            let left = rank[lhs.element[keyPath: id]] ?? ids.count + lhs.offset
            let right = rank[rhs.element[keyPath: id]] ?? ids.count + rhs.offset
            return left < right
        }.map(\.element)
    }
}
