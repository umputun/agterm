import agtermCore
import Foundation

/// `session.restart`: ends a live pane's daemon and builds the pane a new surface whose daemon runs the
/// caller's line, the way a `session.new --command` pane is created, or the pane's foreground program again. `.claude/rules/control-api.md` owns
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
        // a session waiting out its undo window is not in an open store: killing its shell would leave undo
        // a dead pane to restore
        guard (resolved.view.isSplitPane ? session.splitSurface : session.surface) === old,
              library.store(forSession: session.id) != nil else {
            return Self.restartFailure("the pane changed before the restart; nothing was started")
        }
        var replay: RestartReplay.Launch?
        if options.command == nil {
            switch replayLaunch(of: old, leader: oldPid, client: client) {
            case .failure(let refusal): return Self.restartFailure(refusal.message)
            case .success(let launch): replay = launch
            }
        }
        // read before the kill: without it the restart could not tell when the old program is gone
        guard let program = client.foregroundJob(ofShell: oldPid) else {
            return Self.restartFailure("the process table cannot be read, so the old program could not be tracked; "
                + "nothing was changed")
        }
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
        guard await programEnded(program, client: client) else {
            closeEndedPane(old, session: session, identity: resolved.identity)
            return Self.restartFailure("the old shell ended (pid \(oldPid)) but its program is still running; "
                + "nothing was started and the pane was closed")
        }
        guard let pane = session.paneRole(forIdentity: resolved.identity).map({ $0 == .right ? StatusPane.right : .left }),
              (pane == .right ? session.splitSurface : session.surface) === old,
              let store = library.store(forSession: session.id) else {
            closeEndedPane(old, session: session, identity: resolved.identity)
            return Self.restartFailure("the old shell ended (pid \(oldPid)) and the pane changed during the restart; "
                + "nothing was started")
        }
        store.clearPaneOwnedState(session.id, pane: pane)
        let cwd = session.cwd(for: pane == .right ? .right : .left)
        let launch = PaneReattach(
            // the denylist was applied before the kill: a rejection here would start a plain shell instead
            command: ZmxSupport.attachCommand(zmx, replaying: replay?.argv, creationCommand: options.command, denylist: []),
            wait: false, environment: zmx.environment,
            workingDirectory: replay?.workingDirectory
                ?? (FileManager.default.fileExists(atPath: cwd) ? cwd : old.workingDirectory))
        guard let fresh = PaneLead.replace?(old, launch, lead) else {
            closeEndedPane(old, session: session, identity: resolved.identity)
            return Self.restartFailure("the old shell ended (pid \(oldPid)) and the pane could not be rebuilt; "
                + "it was closed")
        }
        guard fresh.isRealized else {
            // destroyed first: a surface that failed to create re-arms itself for the next layout or wake,
            // which would run the line after this error
            fresh.destroySurface()
            closeEndedPane(fresh, session: session, identity: resolved.identity)
            return Self.restartFailure("the old shell ended (pid \(oldPid)) and the new terminal could not be "
                + "created; the pane was closed")
        }

        guard let newPid = await shell(daemon: resolved.daemon, otherThan: oldPid, client: client,
                                       within: Self.restartWait) else {
            return Self.restartFailure("the old shell ended (pid \(oldPid)) and no new one was observed")
        }
        let receipt = ControlRestartReceipt(paneID: resolved.identity.uuidString, oldPid: oldPid, newPid: newPid,
                                            replayedArgv: replay?.argv)
        let replayed = replay.map { "; replay requested: \(CommandRestore.shellQuotedLine($0.argv))" } ?? ""
        return ControlResponse(ok: true, result: ControlResult(
            id: session.id.uuidString, text: "restarted \(pane.rawValue) pane: shell \(oldPid) -> \(newPid)\(replayed)",
            pane: pane.rawValue, restart: receipt))
    }

    private func replayLaunch(of view: GhosttySurfaceView, leader: pid_t,
                              client: ZmxClient) -> Result<RestartReplay.Launch, RestartReplay.Refusal> {
        // a failed listing drops the cached leaders, so a daemon that is gone cannot answer for the pane
        zmxForegroundResolver?.acceptLeaderSnapshot(client.sessionLeaderPIDs())
        let shell = ProcessInfo.processInfo.environment["SHELL"].map(CommandRestore.basename)
        let observed = ForegroundProcess.observed(for: view, shellBasename: shell, zmxResolver: zmxForegroundResolver)
        var isDirectory: ObjCBool = false
        let directory = observed.flatMap { ForegroundProcess.workingDirectory(of: $0.pid) }
            .flatMap { FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) && isDirectory.boolValue ? $0 : nil }
        return RestartReplay.resolve(
            .init(foreground: observed?.foreground, isDaemonLeader: observed?.pid == leader, workingDirectory: directory),
            shell: shell, denylist: GhosttyApp.shared.restoreDenylist)
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

    /// closeEndedPane runs the exit transition the restart claimed, for a restart that stops after its
    /// kill: the pane has no shell, and with its exit claimed nothing else would ever close it.
    ///
    /// A session soft-closed meanwhile sits in a pending close, where undo would restore that dead pane, so
    /// the close is made final instead.
    private func closeEndedPane(_ view: GhosttySurfaceView, session: Session, identity: UUID) {
        if let store = library.store(forSession: session.id) {
            agtermApp.handlePaneExit(view, store: store, sessionID: session.id, library: library,
                                     alreadyFinalized: identity)
        } else {
            library.store(holdingSession: session.id)?.finalizePendingClose(ofSession: session.id)
        }
    }

    /// programEnded gives the old foreground program a second to act on the hangup the kill sent it, then
    /// kills it: a restart replaces the program, so one that ignores a hangup cannot stay. False when it
    /// outlives the kill too, as a program this user cannot signal does.
    private func programEnded(_ job: [ProcessRecord], client: ZmxClient) async -> Bool {
        for (grace, kills) in [(Duration.seconds(1), true), (.milliseconds(500), false)] {
            let deadline = ContinuousClock.now + grace
            while ContinuousClock.now < deadline {
                guard client.isRunning(job) else { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if kills { client.forceEnd(job) }
        }
        return !client.isRunning(job)
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
