import Foundation
import agtermCore

/// `session.restart` on agterm-server: the Mac's order of checks and waits over the server's daemons, so a pane keeps
/// its identity, daemon name and environment. `.claude/rules/control-api.md` owns the contract.
extension ServerActions {
    public func restartSessionPane(_ target: String?, window: String?,
                                   options: ControlSessionRestartOptions) async -> ControlResponse {
        if let refusal = windowRefusal(window) { return refusal }
        let session: Session
        let pane: (identity: UUID, role: StatusPane)
        switch resolveSession(target) {
        case .failure(let refusal): return refusal.response
        case .success(let resolved): session = resolved
        }
        switch restartPane(of: session, options: options) {
        case .failure(let refusal): return refusal.response
        case .success(let resolved): pane = resolved
        }
        if session.ended { return await restartEnded(session, pane: pane, command: options.command) }
        guard session.daemonBackedPanes.contains(pane.identity) else { return Self.restartFailure("the pane's shell is not running") }
        let daemon = ZmxSupport.daemonName(for: pane.identity)
        guard let oldPid = await leader(of: daemon, otherThan: nil, within: .zero) else {
            return Self.restartFailure("the pane's shell is not running")
        }
        var replay: RestartReplay.Launch?
        if options.command == nil {
            let shell = (panes.shellPath as NSString).lastPathComponent
            switch RestartReplay.resolve(replayObservation(oldPid, shell), shell: shell, denylist: CommandRestore.defaultDenylist) {
            case .failure(let refusal): return Self.restartFailure(refusal.message)
            case .success(let launch): replay = launch
            }
        }
        // read before the kill: without it the restart could not tell when the old program is gone
        guard let program = processes.foregroundJob(of: oldPid) else {
            return Self.restartFailure("the process table cannot be read, so the old program could not be tracked; nothing was changed")
        }
        let runner = panes.runner
        panes.restarting.insert(pane.identity)
        defer { panes.restarting.remove(pane.identity) }
        switch await Task.detached(operation: { runner.killConfirmed(daemon, force: true) }).value {
        case .killed: processes.send(SIGHUP, to: program)
        case .staleSocket: return Self.restartFailure("\(daemon) did not confirm the kill; nothing was started")
        case .failed(let reason): return Self.restartFailure("could not end the pane's shell: \(reason); nothing was started")
        }
        // the new shell starts only once the old program is gone, so it cannot meet a held port or lock
        guard await programEnded(program) else {
            endKilledPane(session, identity: pane.identity)
            return Self.restartFailure("the old shell ended (pid \(oldPid)) but its program is still running; "
                + "nothing was started and the pane was closed")
        }
        guard store.session(withID: session.id) === session, let role = session.paneRole(forIdentity: pane.identity),
              (role == .right ? StatusPane.right : .left) == pane.role else {
            endKilledPane(session, identity: pane.identity)
            return Self.restartFailure("the old shell ended (pid \(oldPid)) and the pane changed during the restart; nothing was started")
        }
        store.clearPaneOwnedState(session.id, pane: pane.role)
        // after the wait, which lets other requests run: mail sent to the old program meanwhile must not reach the new one
        MessageBus.shared.dispose(pane: pane.identity)
        let workspace = store.sessionLocation(ofSession: session.id)?.workspace
        let start = ServerPanes.Start(identity: pane.identity, session: session, workspace: workspace, pane: pane.role,
                                      program: replay.map { .replay($0.argv) } ?? .command(options.command ?? "", wait: false),
                                      directory: replay?.workingDirectory ?? session.cwd(for: pane.role == .right ? .right : .left))
        if let refusal = panes.start(start) {
            endKilledPane(session, identity: pane.identity)
            return Self.restartFailure("the old shell ended (pid \(oldPid)) and the new shell could not be started: \(refusal); "
                + "the pane was closed")
        }
        panes.restarting.remove(pane.identity)
        guard let newPid = await leader(of: daemon, otherThan: oldPid, within: restartWaits.shell) else {
            return Self.restartFailure("the old shell ended (pid \(oldPid)) and no new one was observed")
        }
        streams.noteRespawn(session: session.id, daemon: daemon)
        return Self.restarted(session, pane: pane, oldPid: oldPid, newPid: newPid, replayed: replay?.argv)
    }

    /// restartEnded starts an ended row's primary pane again with the caller's line; the row stays ended when it cannot.
    private func restartEnded(_ session: Session, pane: (identity: UUID, role: StatusPane), command: String?) async -> ControlResponse {
        guard pane.role == .left else { return Self.restartFailure("an ended session restarts its primary pane") }
        guard let command else { return Self.restartFailure("an ended session has no program to replay; pass --command") }
        let workspace = store.sessionLocation(ofSession: session.id)?.workspace
        if let refusal = panes.start(.init(identity: pane.identity, session: session, workspace: workspace, pane: .left,
                                           program: .command(command, wait: false), directory: session.effectiveCwd)) {
            return Self.restartFailure(refusal)
        }
        // what the ended program left (status, ask, HUD, pane overlay) would otherwise sit over the new one
        store.clearPaneOwnedState(session.id, pane: .left)
        store.resumeEndedSession(session.id)
        guard let newPid = await leader(of: ZmxSupport.daemonName(for: pane.identity), otherThan: nil,
                                        within: restartWaits.shell) else {
            return Self.restartFailure("no shell was observed for the restarted pane")
        }
        streams.noteRespawn(session: session.id, daemon: ZmxSupport.daemonName(for: pane.identity))
        return Self.restarted(session, pane: pane, oldPid: nil, newPid: newPid, replayed: nil)
    }

    /// restartPane is the pane a restart addresses: a live `paneID` token first, which is refused when unknown even
    /// beside a role, else the role.
    private func restartPane(of session: Session, options: ControlSessionRestartOptions)
        -> Result<(identity: UUID, role: StatusPane), ActionRefusal> {
        let split = session.hasSplit ? session.splitPaneIdentity : nil
        if let token = options.paneID, !token.isEmpty {
            if UUID(uuidString: token) == session.paneIdentity { return .success((session.paneIdentity, .left)) }
            if let split, UUID(uuidString: token) == split { return .success((split, .right)) }
            return .refused(Self.restartFailure("unknown pane id: \(token)"))
        }
        switch options.pane {
        case .left: return .success((session.paneIdentity, .left))
        case .right:
            guard let split else { return .refused(Self.restartFailure("session has no split pane")) }
            return .success((split, .right))
        default: return .refused(Self.restartFailure("session.restart requires --pane-id or --pane"))
        }
    }

    /// leader is the pid `zmx list` reports for `daemon` once it differs from `otherThan`, polled until `wait` ends.
    func leader(of daemon: String, otherThan: Int32?, within wait: Duration) async -> Int32? {
        let runner = panes.runner
        let deadline = ContinuousClock.now + wait
        while true {
            let records = await Task.detached(operation: { try? runner.list() }).value
            if let pid = records?.first(where: { $0.name == daemon })?.leaderPID, pid != otherThan { return pid }
            guard ContinuousClock.now < deadline else { return nil }
            try? await Task.sleep(for: restartWaits.poll)
        }
    }

    /// programEnded waits for the hung-up job, kills what is left of it, and waits once more; an unreadable process
    /// table counts as still running.
    private func programEnded(_ job: [ProcessRecord]) async -> Bool {
        for (grace, kills) in [(restartWaits.program, true), (restartWaits.program / 2, false)] {
            let deadline = ContinuousClock.now + grace
            while ContinuousClock.now < deadline {
                guard processes.isRunning(job) else { return true }
                try? await Task.sleep(for: restartWaits.poll)
            }
            if kills { processes.send(SIGKILL, to: job) }
        }
        return !processes.isRunning(job)
    }

    /// endKilledPane runs the exit transition for a pane whose shell a restart ended and did not replace, so the pane
    /// is not left without a shell.
    private func endKilledPane(_ session: Session, identity: UUID) {
        panes.restarting.remove(identity)
        guard store.session(withID: session.id) === session, session.paneRole(forIdentity: identity) != nil else { return }
        paneExited?(session, identity)
    }

    private static func restarted(_ session: Session, pane: (identity: UUID, role: StatusPane), oldPid: Int32?, newPid: Int32,
                                  replayed: [String]?) -> ControlResponse {
        let receipt = ControlRestartReceipt(paneID: pane.identity.uuidString, oldPid: oldPid, newPid: newPid, replayedArgv: replayed)
        let shells = oldPid.map { "shell \($0) -> \(newPid)" } ?? "shell \(newPid)"
        let replay = replayed.map { "; replay requested: \(CommandRestore.shellQuotedLine($0))" } ?? ""
        return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString,
                                                               text: "restarted \(pane.role.rawValue) pane: \(shells)\(replay)",
                                                               pane: pane.role.rawValue, restart: receipt))
    }

    static func restartFailure(_ message: String) -> ControlResponse {
        ControlResponse(ok: false, error: message)
    }
}
