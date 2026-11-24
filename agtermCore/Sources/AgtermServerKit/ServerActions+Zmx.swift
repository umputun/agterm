import Foundation
import agtermCore

/// `zmx.list` and `zmx.screen` over the server's own daemon namespace, the same reads a Mac answers for its own.
extension ServerActions {
    public func listZmxDaemons() -> ControlResponse {
        guard let listed = try? panes.runner.list() else {
            return ControlResponse(ok: false, error: "could not read the zmx session list")
        }
        let result = ZmxInventory.join(observed: listed, claims: paneClaims(), inventoryComplete: true)
        let endpoint = ControlZmxEndpoint(executable: panes.configuration.zmxPath,
                                          socketDirectory: panes.configuration.zmxSocketDirectory)
        let restore = ControlRestoreStatus(configured: .live, requestedAtLaunch: .live, active: .live, unavailableReason: nil)
        return ControlResponse(ok: true, result: ControlResult(zmx: ControlZmxInventory(restore: restore, result: result,
                                                                                        endpoint: endpoint)))
    }

    public func readZmxScreen(name: String, fullBuffer: Bool, lines: Int?) -> ControlResponse {
        guard let screen = panes.runner.screen(name, all: fullBuffer) else {
            return ControlResponse(ok: false, error: "could not read the zmx screen of \(name)")
        }
        return ControlResponse(ok: true, result: ControlResult(text: lines.map(screen.lastLines) ?? screen.text))
    }

    /// pruneZmxDaemons kills the daemons no pane claims and no client attaches, as the Mac's prune does: the
    /// candidates are listed again right before the kill, which is never forced, and each one is reported.
    public func pruneZmxDaemons() -> ControlResponse {
        guard let listed = try? panes.runner.list() else {
            return ControlResponse(ok: false, error: "could not read the zmx session list")
        }
        let result = ZmxInventory.join(observed: listed, claims: paneClaims(), inventoryComplete: true)
        // the catalog is the server's whole claim set, so the inventory is always complete
        let candidates = ZmxPrunePolicy.namesToPrune(result) ?? []
        guard !candidates.isEmpty else {
            return ControlResponse(ok: true, result: ControlResult(text: "no orphan daemons", affected: 0))
        }
        guard let recheck = try? panes.runner.list() else {
            return ControlResponse(ok: false, error: "could not re-read the zmx session list before pruning")
        }
        let detached = recheck.filter { $0.clients == 0 }
        let names = candidates.filter { name in detached.contains { $0.name == name } }
        guard !names.isEmpty else {
            return ControlResponse(ok: true, result: ControlResult(text: "no orphan daemons left to prune", affected: 0))
        }
        var outcomes: [String: ZmxKillOutcome] = [:]
        for name in names {
            let job = detached.first { $0.name == name }?.leaderPID.flatMap(processes.foregroundJob(of:))
            outcomes[name] = panes.runner.killConfirmed(name, force: false)
            if outcomes[name] == .killed, let job { processes.send(SIGHUP, to: job) }
        }
        let report = names.sorted().map { name in
            switch outcomes[name] {
            case .killed: "killed \(name)"
            case .staleSocket: "\(name): cleaned up a stale socket, the daemon may still be running"
            case .failed(let reason): "\(name): not killed (\(reason))"
            case nil: "\(name): no result"
            }
        }
        return ControlResponse(ok: true, result: ControlResult(text: report.joined(separator: "; "),
                                                               affected: outcomes.values.filter { $0 == .killed }.count))
    }

    /// killZmxDaemon kills one pane's daemon and, once zmx confirms it, runs the transition the pane's own exit
    /// would: the session closes, a parent respawns, or the live split takes over.
    public func killZmxDaemon(target: String, window: String?, pane: ZmxPaneRole) -> ControlResponse {
        killZmxDaemon(target: target, window: window, pane: pane, pinned: nil)
    }

    public func killZmxPane(target: String, window: String?, pane: ZmxPaneRole, paneID: String) -> ControlResponse {
        killZmxDaemon(target: target, window: window, pane: pane, pinned: paneID)
    }

    private func killZmxDaemon(target: String, window: String?, pane: ZmxPaneRole, pinned: String?) -> ControlResponse {
        if let refusal = windowRefusal(window) { return refusal }
        guard target != "active" else {
            return ControlResponse(ok: false, error: "zmx.kill needs a session id; 'active' is not accepted")
        }
        let owned = paneClaims().filter { $0.pane == pane }
        guard case .resolved(let sessionID) = ControlResolve.resolve(target, candidates: owned.map(\.sessionID), active: nil),
              let claim = owned.first(where: { $0.sessionID == sessionID }),
              let session = store.session(withID: sessionID) else {
            return ControlResponse(ok: false, error: "no \(pane.rawValue) pane daemon for session \(target)")
        }
        if let pinned, let refusal = ZmxPaneRole.pinRefusal(pinned, identity: claim.paneIdentity, pane: pane) {
            return ControlResponse(ok: false, error: refusal)
        }
        let daemon = ZmxSupport.daemonName(for: claim.paneIdentity)
        guard let shells = panes.daemonShells() else {
            return ControlResponse(ok: false, error: "could not read the daemons' shells")
        }
        guard let leader = shells[daemon] else {
            return ControlResponse(ok: false, error: "\(daemon) is not running")
        }
        guard let job = processes.foregroundJob(of: leader) else {
            return ControlResponse(ok: false, error: "the process table cannot be read; nothing was changed")
        }
        switch panes.runner.killConfirmed(daemon, force: true) {
        case .killed:
            processes.send(SIGHUP, to: job)
        case .staleSocket:
            return ControlResponse(ok: false, error: "\(daemon) did not confirm the kill; zmx cleaned "
                + "up a stale socket and the daemon may still be running")
        case .failed(let reason):
            return ControlResponse(ok: false, error: "could not kill \(daemon): \(reason)")
        }
        paneExited?(session, claim.paneIdentity)
        return ControlResponse(ok: true, result: ControlResult(id: sessionID.uuidString, text: "killed \(daemon)",
                                                               pane: pane.rawValue))
    }

    /// paneClaims is every daemon-backed main and split pane of the catalog, a session inside a close's grace
    /// included. A scratch daemon's name is never a pane daemon's, so the inventory lists it as foreign rather than
    /// as an orphan.
    func paneClaims() -> [ZmxPaneClaim] {
        let shown = store.workspaces.flatMap { workspace in workspace.sessions.map { ($0, workspace.id, workspace.name, false) } }
        let pending = store.pendingCloseMembers().map { ($0.session, $0.workspaceID, $0.workspaceName, true) }
        var claims: [ZmxPaneClaim] = []
        for (session, workspaceID, workspaceName, pendingClose) in shown + pending {
            var roles: [(UUID, ZmxPaneRole)] = [(session.paneIdentity, .left)]
            if session.hasSplit, let split = session.splitPaneIdentity { roles.append((split, .right)) }
            for (identity, role) in roles where session.daemonBackedPanes.contains(identity) {
                claims.append(ZmxPaneClaim(paneIdentity: identity, pane: role, pendingClose: pendingClose, windowID: catalog.id,
                                           windowName: catalog.name, windowState: .open, workspaceID: workspaceID,
                                           workspaceName: workspaceName, sessionID: session.id,
                                           sessionName: session.displayName))
            }
        }
        return claims
    }
}
