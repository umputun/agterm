import Foundation
import agtermCore

extension ControlServer {
    func attachRemoteGroup(host: String, session: String, window: String?) async -> ControlResponse {
        let discovery = await remoteTree(host: host)
        guard discovery.ok, let tree = discovery.result?.remote else { return discovery }
        guard let remote = tree.sessions.first(where: { $0.id == session }) else {
            return ControlResponse(ok: false, error: "no attachable session \(session) on \(host)")
        }
        guard remote.parent == nil, remote.content == nil else {
            return ControlResponse(ok: false, error: "\(session) is a companion, not a group's parent")
        }
        let store: AppStore
        switch resolveOpenWindow(window) {
        case .failure(let response): return response
        case .success(let (_, resolved)): store = resolved
        }
        guard let workspace = store.currentWorkspaceID else {
            return ControlResponse(ok: false, error: "no window to attach into")
        }
        let attached = attach(remote, from: tree, host: host, placement: RemotePlacement(store: store, workspace: workspace))
        guard attached.ok, let parentID = attached.result?.id.flatMap(UUID.init(uuidString:)) else { return attached }

        let known = remote.companions != nil
        let members = remote.companions
            ?? tree.sessions.filter { $0.parent == remote.id }.map { ControlRemoteMember(id: $0.id, name: $0.name) }
        var outcomes: [ControlRemoteGroupMember] = []
        for member in members {
            outcomes.append(await attachMember(member, of: parentID, from: tree, host: host))
        }
        let group = ControlRemoteGroup(membershipKnown: known, companions: outcomes)
        let result = ControlResult(id: parentID.uuidString, remoteGroup: group)
        let missing = zip(members, outcomes).filter { $0.1.id == nil }
        // checked after the last member too: a parent closed during a final page wait has no later member to notice it
        if library.store(forSession: parentID) == nil, !members.isEmpty {
            let names = missing.map(\.0.name).joined(separator: ", ")
            let tail = names.isEmpty ? "" : "; not attached: \(names)"
            return ControlResponse(ok: false, result: result, error: "parent row \(parentID.uuidString) was closed\(tail)")
        }
        guard !missing.isEmpty else { return ControlResponse(ok: true, result: result) }
        let reasons = missing.map { "\($0.0.name) (\($0.1.error ?? "not attached"))" }.joined(separator: ", ")
        let kept = outcomes.count - missing.count
        return ControlResponse(ok: false, result: result, error: "kept \(remote.name) (\(parentID.uuidString)) and "
                               + "\(kept) companion(s); not attached: \(reasons)")
    }

    // the parent's store and workspace are read again for every member: a page member's ssh wait lets the row move or close
    private func attachMember(_ member: ControlRemoteMember, of parentID: UUID, from tree: ControlRemoteTree,
                              host: String) async -> ControlRemoteGroupMember {
        guard let store = library.store(forSession: parentID),
              let workspace = store.workspace(forSession: parentID)?.id else {
            return ControlRemoteGroupMember(origin: member.id, error: "parent row was closed")
        }
        guard let row = tree.sessions.first(where: { $0.id == member.id }) else {
            return ControlRemoteGroupMember(origin: member.id, error: "unavailable on \(host)")
        }
        let reply = row.content == "page"
            ? await attachRemotePage(row.id, host: host, parent: parentID, select: false)
            : attach(row, from: tree, host: host,
                     placement: RemotePlacement(store: store, workspace: workspace, parent: parentID, select: false))
        guard reply.ok, let id = reply.result?.id else {
            return ControlRemoteGroupMember(origin: member.id, error: reply.error ?? "attach failed")
        }
        return ControlRemoteGroupMember(origin: member.id, id: id)
    }
}
