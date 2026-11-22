import Foundation
import agtermCore

extension ControlServer {
    /// originReopenBudget bounds the wait for sessions an origin reopened to become attachable.
    static let originReopenBudget: TimeInterval = 20

    /// attachedRecentRoute reopens an attached row's Recent Closed entry, which needs its origin; nil leaves a local
    /// entry, and a server window's list, to the usual paths.
    func attachedRecentRoute(_ request: ControlRequest) -> RemoteRoute? {
        guard request.cmd == .recentOpen, !library.remoteRecentClosedItems.isEmpty else { return nil }
        if let window = request.args?.window, resolver.placementStore(window)?.remoteActions != nil { return nil }
        switch RecentClosedTarget.resolve(request.target, in: library.recentClosedItems, remote: library.remoteRecentClosedItems) {
        case .failure(let error): return .refused(ControlResponse(ok: false, error: error.message))
        case .success(.local): return nil
        case .success(.remote(let id)): return .reopenAttached(id, window: request.args?.window)
        }
    }

    /// reopenAttached shows an attached row's session here again: attached anew while its origin still lists it,
    /// otherwise after the origin reopens its own entry for it. The entry leaves only once every session is attached,
    /// so an unreachable origin, a refusal or a partial attach keeps it for another try.
    func reopenAttached(_ id: UUID, window: String?) async -> ControlResponse {
        guard let item = library.remoteRecentClosedItems.first(where: { $0.id == id }) else {
            return ControlResponse(ok: false, error: "no recent item \(id.uuidString)")
        }
        // pinned before the first ssh wait, so a frontmost change during it cannot move the reopen
        let pinned: String
        switch resolveOpenWindow(window) {
        case .failure(let refusal): return refusal
        case .success(let (id, _)): pinned = id.uuidString
        }
        // a server window's catalog does not own the row and would drop it at the next reconcile
        if library.windows.first(where: { $0.id.uuidString == pinned })?.isRemote == true {
            return ControlResponse(ok: false, error: "recent.open is not available in a remote window")
        }
        let current = await remoteTree(host: item.host)
        guard let tree = current.result?.remote else { return current }
        var sessions = [item.originSessionID]
        if !tree.sessions.contains(where: { $0.id == item.originSessionID }) {
            switch await reopenOnOrigin(item) {
            case .refused(let refusal): return refusal
            case .reopened(let reopened): sessions = reopened
            }
        }
        return await reattach(sessions, item: item, window: pinned)
    }

    /// undoOriginClose undoes a terminate of attached rows on their origin, then attaches the sessions it brought back
    /// into `window`. An origin past its grace refuses, and the rows stay in Recent Closed.
    func undoOriginClose(_ undo: AttachedUndo, window: String) async -> ControlResponse {
        let reply = await originCommand(undo.host, ["session", "undo", "--target", undo.undoID])
        guard reply.ok else { return reply }
        var last = reply
        for session in undo.sessions {
            guard let item = library.remoteRecentClosedItems.first(where: { $0.host == undo.host && $0.originSessionID == session }) else { continue }
            last = await reattach([session], item: item, window: window)
            guard last.ok else { return last }
        }
        return last
    }

    private enum OriginReopen {
        case reopened([String])
        case refused(ControlResponse)
    }

    private func reopenOnOrigin(_ item: RemoteRecentClosedItem) async -> OriginReopen {
        let host = item.host
        var entry = item.originRecentID
        if entry == nil {
            let list = await originCommand(host, ["recent", "list"])
            guard list.ok else { return .refused(list) }
            entry = list.result?.recent?.first { $0.host == nil && $0.sessionIDs.contains(item.originSessionID) }?.id
        }
        guard let entry else {
            return .refused(ControlResponse(ok: false, error: "the session on \(host) is gone and \(host) keeps no record of it"))
        }
        let reply = await originCommand(host, ["recent", "open"], operands: [entry])
        guard reply.ok, let open = reply.result?.recentOpen else {
            return .refused(ControlResponse(ok: false, error: reply.error ?? "\(host) did not reopen \(item.name)"))
        }
        return .reopened(open.item.sessionIDs)
    }

    /// reattach attaches `sessions` from the entry's origin, parent first, once the origin lists them all, then puts
    /// the entry's own row back in its workspace when this window still has it.
    private func reattach(_ sessions: [String], item: RemoteRecentClosedItem, window: String?) async -> ControlResponse {
        let host = item.host
        let deadline = Date().addingTimeInterval(Self.originReopenBudget)
        var tree: ControlRemoteTree
        while true {
            let reply = await remoteTree(host: host)
            guard let listed = reply.result?.remote else { return reply }
            tree = listed
            if sessions.allSatisfy({ id in listed.sessions.contains { $0.id == id } }) { break }
            guard Date() < deadline else {
                return ControlResponse(ok: false, error: "\(host) reopened \(item.name) but does not list it as attachable yet; Reopen tries again")
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        var order = sessions
        // a page companion is placed only under a row showing its parent
        if let own = tree.sessions.first(where: { $0.id == item.originSessionID }), own.content == "page", let parent = own.parent,
           !order.contains(parent), shownRow(parent, host: host) == nil, tree.sessions.contains(where: { $0.id == parent }) {
            order.insert(parent, at: 0)
        }
        var shown: UUID?
        var reopened = false
        for session in order {
            if let row = shownRow(session, host: host) {
                if session == item.originSessionID { shown = row }
                continue
            }
            let target = destination(for: session, tree: tree, host: host) ?? window
            let root = session == item.originSessionID ? rootPlacement(item, window: target) : nil
            let reply = await attachRemoteSession(host: host, session: session, window: root?.window ?? target, workspace: root?.workspace)
            guard reply.ok else { return reply }
            if session == item.originSessionID {
                shown = reply.result?.id.flatMap(UUID.init(uuidString:)) ?? shownRow(session, host: host)
                reopened = true
            }
        }
        guard let shown, let store = library.store(forSession: shown), let windowID = library.windowID(for: store) else {
            return ControlResponse(ok: false, error: "\(item.name) did not attach")
        }
        // a row already shown stays where it is unless this window still has its saved workspace
        let home = store.workspaces.first { $0.id == item.placement.workspaceID }?.id
            ?? (reopened && item.placement.root == true ? store.rootWorkspace?.id : nil)
        if store.session(withID: shown)?.parentID == nil, let home {
            store.moveSession(shown, toWorkspace: home, at: item.placement.sessionIndex)
        }
        library.removeRemoteRecentClosed(item.id)
        let open = ControlRecentOpen(item: ControlRecentItem(item), window: windowID.uuidString, complete: true)
        return ControlResponse(ok: true, result: ControlResult(id: shown.uuidString, recentOpen: open))
    }

    /// rootPlacement pins a top-level row's reopen to one window and that window's top-level sessions, resolved together:
    /// the attach resolves its window again after an ssh wait, and a frontmost change there would pair two windows.
    private func rootPlacement(_ item: RemoteRecentClosedItem, window: String?) -> (window: String, workspace: ControlAttachWorkspace)? {
        guard item.placement.root == true, case .success(let (id, store)) = resolveOpenWindow(window),
              let root = store.rootWorkspace else { return nil }
        return (id.uuidString, .id(root.id.uuidString))
    }

    /// destination is the window showing `session`'s parent, where a companion must attach; nil for a top-level session or
    /// a parent shown nowhere.
    private func destination(for session: String, tree: ControlRemoteTree, host: String) -> String? {
        guard let parent = tree.sessions.first(where: { $0.id == session })?.parent, let row = shownRow(parent, host: host),
              let store = library.store(forSession: row), let window = library.windowID(for: store) else { return nil }
        return window.uuidString
    }

    /// shownRow is the row here showing `host`'s session `session`, in any window.
    private func shownRow(_ session: String, host: String) -> UUID? {
        library.allOpenSessions().first { row in
            guard let origin = AttachedOrigin(row) else { return false }
            return origin.host == host && origin.session == session
        }?.id
    }

    private func originCommand(_ host: String, _ words: [String], operands: [String] = []) async -> ControlResponse {
        let sent: RemoteCommandResult? = if let argv = try? RemoteSession.controlCommand(host: host, arguments: words, operands: operands) {
            await remoteRunner.run(argv, deadline: Self.remoteCompanionDeadline)
        } else {
            nil
        }
        guard let result = sent else { return ControlResponse(ok: false, error: "\(host) cannot be addressed") }
        if result.refusedArguments {
            return ControlResponse(ok: false, error: "the agterm on \(host) refused the command; nothing was done there")
        }
        guard let reply = try? JSONDecoder().decode(ControlResponse.self, from: Data(result.stdout.utf8)) else {
            return ControlResponse(ok: false, error: "\(host) did not answer; whether it did anything is unknown")
        }
        return reply
    }
}
