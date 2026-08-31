import AppKit
import agtermCore
import Foundation

/// The `zmx` command group: the daemon inventory and, later, the actions over it. Every command needs a
/// running instance by design — only one can join the live stores, the pending-close records, the checked
/// closed-window snapshots and the observed daemons into a single answer.
extension ControlServer {
    /// Observed daemons joined against the panes that claim them, with the restore status as a header.
    ///
    /// A failed listing is an error rather than an empty inventory: an empty namespace is a real answer and
    /// must not be indistinguishable from not having looked.
    func listZmxDaemons() -> ControlResponse {
        guard let client = zmxClient else {
            return ControlResponse(ok: false, error: ControlZmxError.unavailable)
        }
        guard let observed = client.listSessions() else {
            return ControlResponse(ok: false, error: "could not read the zmx session list")
        }
        let walk = library.paneClaims()
        let result = ZmxInventory.join(observed: observed, claims: walk.claims,
                                       inventoryComplete: walk.complete)
        let inventory = ControlZmxInventory(restore: restoreStatus(), result: result)
        return ControlResponse(ok: true, result: ControlResult(zmx: inventory))
    }
}

extension ControlServer {
    /// Kill the daemons the inventory shows as unclaimed and detached.
    ///
    /// The gate is checked and revalidated, never atomic: pinned zmx has no kill-if-detached, so this
    /// re-lists immediately before mutating and drops any candidate that gained a client in between. What
    /// remains is a client attaching from outside agterm inside that gap, which the docs state plainly.
    /// Model resolution stays on this actor, so agterm's own claims cannot move underneath the operation.
    func pruneZmxDaemons() -> ControlResponse {
        guard let client = zmxClient else {
            return ControlResponse(ok: false, error: ControlZmxError.unavailable)
        }
        guard let observed = client.listSessions() else {
            return ControlResponse(ok: false, error: "could not read the zmx session list")
        }
        let walk = library.paneClaims()
        let inventory = ZmxInventory.join(observed: observed, claims: walk.claims,
                                          inventoryComplete: walk.complete)
        guard let candidates = ZmxPrunePolicy.namesToPrune(inventory) else {
            return ControlResponse(ok: false, error: ControlZmxError.incompleteInventory)
        }
        guard !candidates.isEmpty else {
            return ControlResponse(ok: true, result: ControlResult(text: "no orphan daemons", affected: 0))
        }

        guard let recheck = client.listSessions() else {
            return ControlResponse(ok: false, error: "could not re-read the zmx session list before pruning")
        }
        let stillDetached = Set(recheck.filter { $0.clients == 0 }.map(\.name))
        let names = candidates.filter { stillDetached.contains($0) }
        guard !names.isEmpty else {
            return ControlResponse(ok: true, result: ControlResult(text: "no orphan daemons left to prune",
                                                                   affected: 0))
        }

        let outcomes = client.killObservedOrphan(names: names)
        let killed = outcomes.filter { $0.value == .killed }.keys.sorted()
        return ControlResponse(ok: true, result: ControlResult(text: pruneReport(outcomes),
                                                               affected: killed.count))
    }

    /// Reports per daemon rather than a bare count: a stale-socket cleanup is not a kill, and a caller that
    /// cannot tell the two apart would believe a live unresponsive daemon had gone.
    private func pruneReport(_ outcomes: [String: ZmxClient.KillOutcome]) -> String {
        outcomes.keys.sorted().map { name in
            switch outcomes[name] {
            case .killed: return "killed \(name)"
            case .staleSocket: return "\(name): cleaned up a stale socket, the daemon may still be running"
            case .failed(let reason): return "\(name): not killed (\(reason))"
            case nil: return "\(name): no result"
            }
        }
        .joined(separator: "; ")
    }
}

extension ControlServer {
    /// Destroy one pane's daemon, then drive the same model transition the pane's own exit would have.
    ///
    /// Resolution runs against the INVENTORY rather than `ControlTargetResolver`, which searches open
    /// stores only: this command deliberately reaches closed and unindexed claims no window shows.
    func killZmxDaemon(target: String, window: String?, pane: ZmxPaneRole) -> ControlResponse {
        guard let client = zmxClient else {
            return ControlResponse(ok: false, error: ControlZmxError.unavailable)
        }
        guard let observed = client.listSessions() else {
            return ControlResponse(ok: false, error: "could not read the zmx session list")
        }
        let walk = library.paneClaims()
        let inventory = ZmxInventory.join(observed: observed, claims: walk.claims,
                                          inventoryComplete: walk.complete)

        // `active` is refused on BOTH selectors rather than resolved: the contract is that nothing about
        // this destruction falls back to whatever is in front of the user, and a window selector that
        // silently means "frontmost" would reintroduce exactly that
        guard target != "active" else {
            return ControlResponse(ok: false, error: "zmx.kill needs a session id; 'active' is not accepted")
        }
        guard window != "active" else {
            return ControlResponse(ok: false, error: "zmx.kill needs a window id; 'active' is not accepted")
        }

        // an explicit --window scopes the claims BEFORE the session resolves, so a prefix ambiguous across
        // windows can be disambiguated and an exact id in another window is not killed regardless
        let windowIDs = Array(Set(inventory.rows.compactMap { $0.claim?.windowID }))
        var owned = inventory.rows.filter { $0.claim?.pane == pane }
        if let window, !window.isEmpty {
            guard case .resolved(let windowID) = ControlResolve.resolve(window, candidates: windowIDs,
                                                                        active: nil) else {
                return ControlResponse(ok: false, error: "no such window: \(window)")
            }
            owned = owned.filter { $0.claim?.windowID == windowID }
        }
        let candidates = owned.compactMap { $0.claim?.sessionID }
        guard case .resolved(let sessionID) = ControlResolve.resolve(target, candidates: candidates,
                                                                     active: nil),
              let row = owned.first(where: { $0.claim?.sessionID == sessionID }), let claim = row.claim else {
            return ControlResponse(ok: false, error: "no \(pane.rawValue) pane daemon for session \(target)")
        }
        if let refusal = ControlZmxError.killRefusal(row) {
            return ControlResponse(ok: false, error: refusal)
        }

        // only an exact confirmation may close a live pane. zmx exits zero after unlinking a socket it
        // could not reach, so trusting the status would let this report a kill, tear the pane down, and
        // leave the daemon running and unreachable by name.
        switch client.killConfirmed(name: row.daemon) {
        case .killed:
            break
        case .staleSocket:
            return ControlResponse(ok: false, error: "\(row.daemon) did not confirm the kill; zmx cleaned "
                + "up a stale socket and the daemon may still be running")
        case .failed(let reason):
            return ControlResponse(ok: false, error: "could not kill \(row.daemon): \(reason)")
        }
        applyKilledPaneExit(claim)
        return ControlResponse(ok: true, result: ControlResult(id: claim.sessionID.uuidString,
                                                               text: "killed \(row.daemon)",
                                                               pane: claim.pane.rawValue))
    }

    /// Runs the pane's exit transition for a daemon this command has already destroyed.
    ///
    /// Marks the surface's exit handled FIRST — after the kill, never before, so a failed kill leaves the
    /// natural path working — then drives `handlePaneExit`, which owns the model transition plus the
    /// promoted survivor's font callback, its dashboard membership and the refocus. A store-only
    /// transition would skip those three. The already-killed identity is excluded from the finalizer, or
    /// the teardown would ask zmx to kill a name that is gone and, on a session close, reach the sibling.
    private func applyKilledPaneExit(_ claim: ZmxPaneClaim) {
        guard let store = library.store(for: claim.windowID),
              let session = store.session(withID: claim.sessionID) else { return }
        let surface = claim.pane == .left ? session.surface : session.splitSurface
        // `backedByZmx` is what makes this surface a CLIENT of the daemon just killed. On a requested-live
        // fallback the launch reap preserves claimed daemons while the pane gets a fresh plain shell, so
        // without this the kill would close a live pane that never attached to the thing it destroyed.
        guard let view = surface as? GhosttySurfaceView, view.backedByZmx,
              view.claimProcessExit() else { return }
        agtermApp.handlePaneExit(view, store: store, sessionID: claim.sessionID, library: library,
                                 alreadyFinalized: claim.paneIdentity)
    }
}

/// Error strings shared by the zmx commands, so the CLI and the server cannot word the same refusal
/// differently.
public enum ControlZmxError {
    /// Why a row may not be killed, nil when it may. `absent` has nothing to kill, and `unreadable` is
    /// refused in v1 because a forced kill there can unlink a live daemon's socket and still exit zero,
    /// leaving the process running and unreachable by name.
    static func killRefusal(_ row: ZmxInventoryRow) -> String? {
        switch row.observation {
        case .absent: return "\(row.daemon) is not running"
        case .unreadable: return "\(row.daemon) is unreadable; killing it could orphan a live daemon"
        case .running: break
        }
        switch row.state {
        case .claimed: return nil
        case .pendingClose: return "\(row.daemon) belongs to a session waiting out its undo window"
        case .unknown, .conflicted: return incompleteInventory
        case .orphan, .foreign: return "\(row.daemon) is not claimed by that pane"
        }
    }

    public static let unavailable = "zmx is unavailable in this instance"
    public static let incompleteInventory =
        "the pane inventory is incomplete or has conflicting owners, so no daemon can be safely pruned"
}
