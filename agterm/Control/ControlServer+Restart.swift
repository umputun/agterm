import agtermCore
import Foundation

/// `session.restart`: ends a live pane's daemon and builds the pane a new surface whose daemon runs the
/// caller's line, the way a `session.new --command` pane is created. `.claude/rules/control-api.md` owns
/// the contract.
extension ControlServer {
    private static let restartWait: Duration = .seconds(10)

    private struct RestartTarget {
        let session: Session
        let view: GhosttySurfaceView
        let identity: UUID
        let daemon: String
        let client: ZmxClient
    }

    func restartSessionPane(_ target: String?, window: String?,
                            options: ControlSessionRestartOptions) async -> ControlResponse {
        let resolved: RestartTarget
        switch resolveRestartTarget(target, window: window, options: options) {
        case .failure(let response): return response
        case .success(let value): resolved = value
        }
        let (session, old, client) = (resolved.session, resolved.view, resolved.client)
        let lead = ZmxLeadAttachment(claim: false)
        guard let zmx = ZmxLaunch.configuration(paneIdentity: resolved.identity, pane: old.isSplitPane ? "split" : "primary",
                                                environment: old.env, lead: lead) else {
            return Self.restartFailure("live sessions are unavailable for this pane")
        }
        // a pane just created reads as backed before the session host has finished creating its daemon
        guard let oldPid = await shell(daemon: resolved.daemon, otherThan: nil, client: client, within: .seconds(5)) else {
            return Self.restartFailure("the pane's shell is not running")
        }
        guard (resolved.view.isSplitPane ? session.splitSurface : session.surface) === old else {
            return Self.restartFailure("the pane changed before the restart; nothing was started")
        }
        let program = client.foregroundJobs(of: [resolved.daemon], shells: [resolved.daemon: oldPid])[resolved.daemon] ?? []
        switch client.killConfirmed(name: resolved.daemon) {
        case .killed: break
        case .staleSocket: return Self.restartFailure("\(resolved.daemon) did not confirm the kill; nothing was started")
        case .failed(let reason): return Self.restartFailure("could not end the pane's shell: \(reason); nothing was started")
        }
        // claimed before the first suspension: the dead client's exit reaches the main queue during the
        // wait below and would close the pane
        old.claimProcessExit()
        // the dying client reports `unowned`, which would reattach to a daemon that is gone and close the pane
        ZmxLeadBook.shared.forget(pane: resolved.identity)
        // the new shell starts only once the old program is gone, so it cannot meet a held port or lock
        await programEnded(program, client: client)
        guard let pane = session.paneRole(forIdentity: resolved.identity).map({ $0 == .right ? StatusPane.right : .left }),
              (pane == .right ? session.splitSurface : session.surface) === old,
              let store = library.store(forSession: session.id) else {
            return Self.restartFailure("the old shell ended (pid \(oldPid)) and the pane changed during the restart; "
                + "nothing was started")
        }
        store.clearPaneOwnedState(session.id, pane: pane)
        let cwd = session.cwd(for: pane == .right ? .right : .left)
        let launch = PaneReattach(
            command: ZmxSupport.attachCommand(zmx, replaying: nil, creationCommand: options.command, denylist: []),
            wait: false, environment: zmx.environment,
            workingDirectory: FileManager.default.fileExists(atPath: cwd) ? cwd : old.workingDirectory)
        guard PaneLead.replace?(old, launch, lead) != nil else {
            return Self.restartFailure("the old shell ended (pid \(oldPid)) and the pane could not be rebuilt")
        }

        guard let newPid = await shell(daemon: resolved.daemon, otherThan: oldPid, client: client,
                                       within: Self.restartWait) else {
            return Self.restartFailure("the old shell ended (pid \(oldPid)) and no new one was observed")
        }
        let receipt = ControlRestartReceipt(paneID: resolved.identity.uuidString, oldPid: oldPid, newPid: newPid)
        return ControlResponse(ok: true, result: ControlResult(
            id: session.id.uuidString, text: "restarted \(pane.rawValue) pane: shell \(oldPid) -> \(newPid)",
            pane: pane.rawValue, restart: receipt))
    }

    private func resolveRestartTarget(_ target: String?, window: String?, options: ControlSessionRestartOptions)
        -> ControlTargetResolver.Resolution<RestartTarget> {
        let store: AppStore, sessionID: UUID
        switch resolver.resolveSessionTarget(target, window: window) {
        case .failure(let response): return .failure(response)
        case .success(let resolved): (store, sessionID) = resolved
        }
        guard let session = store.session(withID: sessionID) else {
            return .failure(Self.restartFailure("no such session: \(target ?? "active")"))
        }
        if let host = session.remoteHost {
            return .failure(Self.restartFailure("session.restart needs a local pane; this session runs on \(host)"))
        }
        // a token that resolves to nothing is refused even beside `--pane`: the role may by now name a
        // different terminal than the one the caller meant to end
        if let token = options.paneID, session.paneRole(forToken: token) == nil {
            return .failure(Self.restartFailure("unknown pane id: \(token)"))
        }
        let pane: StatusPane
        switch session.paneAddress(token: options.paneID, pane: options.pane) {
        case .unknownToken(let token): return .failure(Self.restartFailure("unknown pane id: \(token)"))
        case .pane(.scratch), .pane(nil):
            return .failure(Self.restartFailure("session.restart does not address the scratch pane"))
        case .pane(let resolved?): pane = resolved
        }
        if pane == .right, session.splitSurface == nil {
            return .failure(Self.restartFailure("session has no split pane"))
        }
        guard let view = (pane == .right ? session.splitSurface : session.surface) as? GhosttySurfaceView,
              let identity = UUID(uuidString: view.paneToken) else {
            return .failure(Self.restartFailure("session not realized"))
        }
        guard let daemon = view.zmxSessionName, let client = zmxClient else {
            return .failure(Self.restartFailure("session.restart needs Live sessions mode; this pane has no live shell to replace"))
        }
        return .success(RestartTarget(session: session, view: view, identity: identity, daemon: daemon, client: client))
    }

    /// programEnded gives the old foreground program a second to act on the hangup the kill sent it, then
    /// kills it: a restart replaces the program, so one that ignores a hangup cannot stay.
    private func programEnded(_ job: [ProcessRecord], client: ZmxClient) async {
        for grace in [Duration.seconds(1), .milliseconds(500)] {
            let deadline = ContinuousClock.now + grace
            while ContinuousClock.now < deadline {
                guard client.isRunning(job) else { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            client.forceEnd(job)
        }
    }

    /// shell returns the leader pid `zmx list` reports for `daemon` once it differs from `otherThan`, nil
    /// when none shows up in time.
    private func shell(daemon: String, otherThan: pid_t?, client: ZmxClient, within wait: Duration) async -> pid_t? {
        let deadline = ContinuousClock.now + wait
        while ContinuousClock.now < deadline {
            if let pid = client.sessionRecords(timeout: 1)?.first(where: { $0.name == daemon })?.leaderPID,
               pid != otherThan { return pid }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private static func restartFailure(_ message: String) -> ControlResponse {
        ControlResponse(ok: false, error: message)
    }
}
