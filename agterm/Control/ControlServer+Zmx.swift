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
        let inventory = ControlZmxInventory(restore: restoreStatus(), result: result,
                                            endpoint: client.endpoint)
        return ControlResponse(ok: true, result: ControlResult(zmx: inventory))
    }
}

extension ControlServer {
    /// Attachable sessions: this app's own when `host` is nil, another machine's when it is not.
    ///
    /// The remote form runs the BARE form over ssh, so the far side does the whole join in one walk of its
    /// own windows and answers with a single document. Nothing is composed across two remote calls, so
    /// there is no framing and no window where the far side's topology can move between reads.
    func remoteTree(host: String?) async -> ControlResponse {
        guard let host else { return localAttachableSessions() }
        let argv: [String]
        do {
            argv = try RemoteSession.treeCommand(host: host)
        } catch {
            // the host is NOT echoed: reaching here means validation rejected it, and it is rejected for
            // carrying control characters, which agtermctl would print to a terminal after JSON decoding
            return ControlResponse(ok: false, error: "invalid host")
        }
        let result = await remoteRunner.run(argv, deadline: Self.remoteTreeDeadline)
        guard result.status == 0 else {
            // stdout first: the remote's agtermctl prints a not-ok response there and exits nonzero, so
            // its own sentence never reaches stderr. ssh's own failures do. An ok-looking payload from a
            // nonzero process is never accepted, which is why the status is read before the output.
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = RemoteTreeMerger.remoteError(stdout: result.stdout) ?? (stderr.isEmpty ? nil : stderr)
            return ControlResponse(ok: false, error: detail ?? "the remote command failed on \(host)")
        }
        do {
            let remote = try RemoteTreeMerger.decode(stdout: result.stdout)
            // the far side cannot know which name reached it, so the destination we were given is stamped
            // here rather than self-reported there
            let stamped = ControlRemoteTree(host: host, endpoint: remote.endpoint, sessions: remote.sessions)
            return ControlResponse(ok: true, result: ControlResult(remote: stamped))
        } catch let error as RemoteTreeMerger.MergeError {
            return ControlResponse(ok: false, error: error.message)
        } catch {
            return ControlResponse(ok: false, error: "the remote answer could not be read")
        }
    }

    /// This app's own attachable sessions, across every OPEN window. An empty list is a successful answer
    /// and does not distinguish "not running live" from "live with nothing eligible"; `zmx list` is the
    /// restore-mode diagnostic.
    private func localAttachableSessions() -> ControlResponse {
        guard let client = zmxClient else {
            return ControlResponse(ok: false, error: ControlZmxError.unavailable)
        }
        guard let observed = client.listSessions() else {
            return ControlResponse(ok: false, error: "could not read the zmx session list")
        }
        let walk = library.paneClaims()
        let inventory = ControlZmxInventory(restore: restoreStatus(),
                                            result: ZmxInventory.join(observed: observed,
                                                                      claims: walk.claims,
                                                                      inventoryComplete: walk.complete),
                                            endpoint: client.endpoint)
        // a live store IS the open-window test, the same one `openCounts` uses: a closed window has no
        // store, and its panes are not attachable from here anyway
        let windows = library.windows.compactMap { entry in
            library.store(for: entry.id).map {
                RemoteWindowProjection(id: entry.id.uuidString, name: entry.name, tree: buildTree(in: $0))
            }
        }
        do {
            let tree = try RemoteTreeMerger.candidates(windows: windows, inventory: inventory)
            return ControlResponse(ok: true, result: ControlResult(remote: tree))
        } catch let error as RemoteTreeMerger.MergeError {
            return ControlResponse(ok: false, error: error.message)
        } catch {
            return ControlResponse(ok: false, error: "the session list could not be built")
        }
    }

    /// Create a local session attached to one of `host`'s.
    ///
    /// The remote is resolved again here rather than trusted from whatever the caller last saw: a picker's
    /// answer can be minutes old, and a daemon that has gone since would otherwise be CREATED by the
    /// attach, handing back a fresh shell wearing the session's name. Everything that can fail is checked
    /// before the model is touched, so a refusal leaves no half-built row behind.
    func attachRemoteSession(host: String, session: String) async -> ControlResponse {
        let discovery = await remoteTree(host: host)
        guard discovery.ok, let tree = discovery.result?.remote else { return discovery }
        // by id only: remote session names are mutable and deliberately non-unique across workspaces, and
        // `zmx tree` prints the id for exactly this hand-off
        guard let remote = tree.sessions.first(where: { $0.id == session }) else {
            return ControlResponse(ok: false, error: "no attachable session \(session) on \(host)")
        }
        guard let store = library.activeStore, let workspace = store.currentWorkspaceID else {
            return ControlResponse(ok: false, error: "no window to attach into")
        }
        // by role, never by position: a payload with two lefts or no left must fail rather than quietly
        // become one pane, or the wrong one
        let byRole = Dictionary(remote.panes.map { (ZmxPaneRole(controlName: $0.pane), $0.daemon) },
                                uniquingKeysWith: { first, _ in first })
        guard byRole.count == remote.panes.count, let left = byRole[.left] else {
            return ControlResponse(ok: false, error: "\(host) reported panes agterm cannot address")
        }
        let right = byRole[.right]
        let primary: String
        let split: String?
        do {
            primary = try paneCommand(host: host, tree: tree, daemon: left, name: remote.name, pane: .left)
            split = try right.map {
                try paneCommand(host: host, tree: tree, daemon: $0, name: remote.name, pane: .right)
            }
        } catch {
            return ControlResponse(ok: false, error: "\(host) reported a session agterm cannot address")
        }
        // the LOCAL working directory, not the remote one: libghostty chdirs the ssh process here, and a
        // path that exists on the far side may not exist on this Mac. The attached shell reports its real
        // cwd through the terminal stream anyway.
        guard let created = store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory(),
                                             command: primary, name: remote.name, wait: true,
                                             remoteHost: host) else {
            return ControlResponse(ok: false, error: "could not create the session")
        }
        if let split {
            created.splitInitialCommand = split
            created.splitCommandWait = true
            store.setSplitVisibility(created.id, shown: true,
                                     axis: remote.splitAxis.flatMap(SplitAxis.init(rawValue:)) ?? .leftRight)
        }
        return ControlResponse(ok: true, result: ControlResult(id: created.id.uuidString))
    }

    private func paneCommand(host: String, tree: ControlRemoteTree, daemon: String, name: String,
                             pane: ZmxPaneRole) throws -> String {
        try RemoteSession.attachPaneCommand(host: host, endpoint: tree.endpoint, daemon: daemon,
                                            session: name, pane: pane)
    }

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
