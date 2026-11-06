import Foundation
import agtermCore

extension ControlServer {
    func closeSession(_ target: String?, window: String?) -> ControlResponse {
        closeSession(target, window: window, undoable: false)
    }

    func closeSessions(_ targets: [String], window: String?) -> ControlResponse {
        closeSessions(targets, window: window, undoable: false)
    }

    func closeSession(_ target: String?, window: String?, undoable: Bool) -> ControlResponse {
        resolver.resolveSession(target, window: window) { store, id in
            closeResolvedSession(id, in: store, undoable: undoable)
        }
    }

    func closeSessions(_ targets: [String], window: String?, undoable: Bool) -> ControlResponse {
        resolveBatchSessions(targets, window: window) { store, ids in
            guard ids.count > 1 else {
                guard let id = ids.first else { return ControlResponse(ok: false, error: "session.close requires at least one --target") }
                return closeResolvedSession(id, in: store, undoable: undoable)
            }
            let soft = closeGraceUndoEnabled
            let closing = closingGroup(ids, in: store)
            let closed: [UUID]
            if soft {
                // one grouped grace record is the batch behavior scripts cannot reproduce by looping.
                closed = store.softCloseSessions(ids) ? closing : []
            } else {
                // match the GUI's immediate batch-close path when grace undo is disabled.
                for id in closeRoots(ids, in: store) where store.session(withID: id) != nil { store.closeSession(id) }
                closed = closing.filter { store.session(withID: $0) == nil }
            }
            // `ok` with the count (0 included) mirrors `placeSessions` — every id resolved, so no error arm.
            return ControlResponse(ok: true, result: ControlResult(affected: closed.count,
                                                                   undoable: undoable ? soft && !closed.isEmpty : nil,
                                                                   closed: closed.map(\.uuidString)))
        }
    }

    // a parent's group count rides `affected`; a lone session keeps the bare receipt
    private func closeResolvedSession(_ id: UUID, in store: AppStore, undoable: Bool) -> ControlResponse {
        let closing = closingGroup([id], in: store)
        let group = closing.count > 1 ? closing.count : nil
        if undoable, closeGraceUndoEnabled {
            guard store.softCloseSession(id) else { return ControlResponse(ok: false, error: "could not close session") }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, affected: group, undoable: true,
                                                                   closed: closing.map(\.uuidString)))
        }
        store.closeSession(id)
        let closed = closing.filter { store.session(withID: $0) == nil }
        return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, affected: group,
                                                               undoable: undoable ? false : nil,
                                                               closed: closed.map(\.uuidString)))
    }

    private var closeGraceUndoEnabled: Bool {
        settingsModel.settings.closeGraceUndoEnabled ?? true
    }
}
