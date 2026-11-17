import Foundation
import agtermCore

/// Rows attached from another host that a relaunch restored: a terminal row's stream starts once it is back in the
/// tree, and one check per host settles the rows whose origin session may be gone and hands each page row its page.
extension ControlServer {
    /// resumeRestoredAttachedRows starts the stream of each restored terminal row and checks every host they come from;
    /// a host already being checked is left to that check.
    func resumeRestoredAttachedRows() {
        let rows = restoredAttachedRows()
        for row in rows where row.content == .terminal { startRemotePresentation(for: row) }
        for host in Set(rows.compactMap(\.remoteHost)) where restoredOriginChecks[host] == nil {
            restoredOriginChecks[host] = 0
            Task { await checkRestoredOrigin(host) }
        }
    }

    /// checkRestoredOrigin asks `host` about its restored rows. A terminal session its tree lists is alive; one it leaves
    /// out is gone only when the host's complete daemon inventory has no claim for it, since a closed window's session is
    /// still claimed there. A page owns no daemon, so each page row asks for its page and shows the host's refusal.
    /// A host that does not answer is tried again.
    func checkRestoredOrigin(_ host: String) async {
        guard !restoredAttachedRows(host: host).isEmpty else {
            restoredOriginChecks[host] = nil
            return
        }
        let discovery = await remoteTree(host: host)
        guard discovery.ok, let tree = discovery.result?.remote else {
            let reason = discovery.error ?? "\(host) gave no answer"
            for row in restoredAttachedRows(host: host) where row.content == .page {
                library.store(forSession: row.id)?.setRemoteConnection(.failed(reason), forSession: row.id)
            }
            return retryRestoredOrigin(host)
        }
        let listed = Dictionary(tree.sessions.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var claimed: Set<String>? = []
        if restoredAttachedRows(host: host).contains(where: { $0.content == .terminal && listed[$0.originKey] == nil }) {
            guard let inventory = await originInventory(host) else { return retryRestoredOrigin(host) }
            claimed = inventory.inventoryComplete ? Set(inventory.entries.compactMap { $0.sessionID?.lowercased() }) : nil
        }
        var waiting = false
        for row in restoredAttachedRows(host: host) {
            guard row.content == .terminal else {
                waiting = await fillRestoredPage(row, host: host, tree: tree, listed: listed[row.originKey]) || waiting
                continue
            }
            if listed[row.originKey] == nil, let claimed, !claimed.contains(row.originKey) {
                stopRemotePresentation(row.id)
                library.store(forSession: row.id)?.closeEndedAttachedRow(row.id)
            } else {
                // a terminal row attaches by itself, so an inconclusive answer leaves it attaching
                row.awaitsOriginCheck = false
            }
        }
        guard waiting else {
            restoredOriginChecks[host] = nil
            return
        }
        retryRestoredOrigin(host)
    }

    /// fillRestoredPage asks for page row `row`'s page and shows it there, or shows the host's refusal; true when the
    /// host did not answer and the row waits for another try.
    private func fillRestoredPage(_ row: Session, host: String, tree: ControlRemoteTree, listed: ControlRemoteSession?) async -> Bool {
        guard let saved = row.remotePresentation?.binding, let sessionName = listed?.name ?? saved.origin?.sessionName else {
            return false
        }
        let failure: String
        switch await requestRemotePage(saved.remoteSessionID, host: host) {
        case .unanswered(let reason):
            library.store(forSession: row.id)?.setRemoteConnection(.failed(reason), forSession: row.id)
            return true
        case .refused(let reason):
            failure = reason
        case .page(let page):
            let origin = RemoteBinding.Origin(host: host, endpoint: tree.endpoint, sessionName: sessionName)
            let source = RemotePageOrigin(session: saved.remoteSessionID, binding: origin, presentation: PagePresentation(tree))
            let filled = placeRemotePage(page, from: source, at: .existing(row.id), select: false)
            guard !filled.ok else {
                row.awaitsOriginCheck = false
                return false
            }
            failure = filled.error ?? "the page cannot be shown here"
        }
        row.awaitsOriginCheck = false
        library.store(forSession: row.id)?.setRemoteConnection(.failed(failure), forSession: row.id)
        return false
    }

    private func retryRestoredOrigin(_ host: String) {
        let failures = (restoredOriginChecks[host] ?? 0) + 1
        restoredOriginChecks[host] = failures
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(RemoteRetryBackoff.delay(afterFailures: failures)))
            await self?.checkRestoredOrigin(host)
        }
    }

    private func restoredAttachedRows(host: String? = nil) -> [Session] {
        library.allOpenSessions().filter { $0.awaitsOriginCheck && !$0.ended && (host == nil || $0.remoteHost == host) }
    }

    /// originInventory is `host`'s own daemon list, nil when it gave none.
    private func originInventory(_ host: String) async -> ControlZmxInventory? {
        guard let argv = try? RemoteSession.controlCommand(host: host, arguments: ["zmx", "list"]) else { return nil }
        let result = await remoteRunner.run(argv, deadline: Self.remoteTreeDeadline)
        guard result.status == 0 else { return nil }
        return (try? JSONDecoder().decode(ControlResponse.self, from: Data(result.stdout.utf8)))?.result?.zmx
    }
}

private extension Session {
    var originKey: String { (remoteSessionID ?? "").lowercased() }
}
