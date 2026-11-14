import Foundation
import Testing
@testable import AgtermServerKit
import agtermCore

@MainActor
struct ServerActionsRestartTests {
    private let harness: ServerHarness

    init() throws { harness = try ServerHarness() }

    private func newSession(split: Bool = false) throws -> Session {
        let session = try harness.session(harness.actions.createSession(ControlSessionCreateOptions(
            window: nil, cwd: "/tmp", workspace: nil, workspaceName: nil, createWorkspace: nil, command: nil, wait: nil,
            name: nil, after: nil, before: nil, noSelect: false)))
        if split { _ = harness.actions.splitSession(session.id.uuidString, window: nil, mode: "on") }
        return session
    }

    private func running(_ identity: UUID, pid: Int32 = 100, job: Int32? = 300) {
        let daemon = ZmxSupport.daemonName(for: identity)
        harness.runner.records = (harness.runner.records ?? []) + [ZmxSessionRecord(name: daemon, clients: 1, leaderPID: pid)]
        harness.processes.shell(pid, job: job)
        let runner = harness.runner
        runner.onCreate = { launch in
            guard launch.name == daemon else { return }
            runner.records = (runner.records ?? []) + [ZmxSessionRecord(name: daemon, clients: 0, leaderPID: pid + 1)]
        }
    }

    private func restart(_ session: Session, command: String? = nil, pane: StatusPane? = .left) async -> ControlResponse {
        await harness.actions.restartSessionPane(session.id.uuidString, window: nil,
                                                 options: ControlSessionRestartOptions(command: command, pane: pane))
    }

    private func returning(_ line: String) -> String {
        ZmxReplayScript.render(commandLine: line, integrationDirectory: harness.panes.configuration.resourcesDirectory
                                   + "/shell-integration/zsh", inheritedZdotdir: nil, shell: "/bin/zsh")
    }

    @Test func aCommandReplacesTheShellAfterTheOldJobIsHungUp() async throws {
        let session = try newSession()
        running(session.paneIdentity)

        let reply = await restart(session, command: "make test")

        #expect(reply.ok, "\(reply.error ?? "")")
        #expect(reply.result?.restart == ControlRestartReceipt(paneID: session.paneIdentity.uuidString, oldPid: 100, newPid: 101))
        #expect(harness.runner.confirmedKills.map(\.name) == [ZmxSupport.daemonName(for: session.paneIdentity)])
        #expect(harness.runner.confirmedKills.map(\.force) == [true])
        #expect(harness.processes.signals.first?.signal == SIGHUP)
        #expect(harness.processes.signals.first?.pids == [300])
        let launch = try #require(harness.runner.launches.last)
        #expect(launch.name == ZmxSupport.daemonName(for: session.paneIdentity))
        #expect(launch.argv.last == returning("make test"))
        #expect(session.daemonBackedPanes.contains(session.paneIdentity))
    }

    @Test func noCommandReplaysTheForegroundProgramInItsDirectoryThenTheLoginShell() async throws {
        let session = try newSession()
        running(session.paneIdentity)
        let root = harness.scratch.root
        harness.actions.replayObservation = { leader, _ in
            RestartReplay.Observation(foreground: CommandRestore.paneForeground(argv: ["vim", "notes.md"], extra: "zsh"),
                                      isDaemonLeader: leader != 100, workingDirectory: root)
        }

        let reply = await restart(session)

        #expect(reply.result?.restart?.replayedArgv == ["vim", "notes.md"])
        let launch = try #require(harness.runner.launches.last)
        #expect(launch.directory == root)
        #expect(launch.argv.last == ZmxReplayScript.render(argv: ["vim", "notes.md"],
                                                           integrationDirectory: harness.panes.configuration.resourcesDirectory
                                                               + "/shell-integration/zsh",
                                                           inheritedZdotdir: nil, shell: "/bin/zsh"))
    }

    @Test(arguments: [(["tmux"], "tmux is on the restore denylist"), (["-zsh"], "no replayable foreground program: zsh holds the pane")])
    func aReplayItCannotRunIsRefusedBeforeAnythingIsEnded(argv: [String], reason: String) async throws {
        let session = try newSession()
        running(session.paneIdentity)
        harness.actions.replayObservation = { _, _ in
            RestartReplay.Observation(foreground: CommandRestore.paneForeground(argv: argv, extra: "zsh"), isDaemonLeader: false,
                                      workingDirectory: "/srv")
        }
        let launches = harness.runner.launches.count

        let reply = await restart(session)

        #expect(reply.error == reason + "; pass --command to name the line. nothing was changed")
        #expect(harness.runner.confirmedKills.isEmpty)
        #expect(harness.runner.launches.count == launches)
    }

    @Test func anUnreadableProcessTableRefusesBeforeTheKill() async throws {
        let session = try newSession()
        running(session.paneIdentity)
        harness.processes.table = nil

        let reply = await restart(session, command: "true")

        #expect(reply.error == "the process table cannot be read, so the old program could not be tracked; nothing was changed")
        #expect(harness.runner.confirmedKills.isEmpty)
    }

    @Test(arguments: [(ZmxKillOutcome.staleSocket, "did not confirm the kill; nothing was started"),
                      (.failed("SessionUnresponsive"), "could not end the pane's shell: SessionUnresponsive; nothing was started")])
    func aKillZmxDidNotConfirmStartsNothing(outcome: ZmxKillOutcome, message: String) async throws {
        let session = try newSession()
        running(session.paneIdentity)
        harness.runner.killOutcome = outcome
        let launches = harness.runner.launches.count

        let reply = await restart(session, command: "true")

        #expect(reply.error?.hasSuffix(message) == true)
        #expect(harness.runner.launches.count == launches)
        #expect(harness.processes.signals.isEmpty)
        #expect(harness.store.session(withID: session.id) === session)
    }

    @Test func aProgramThatOutlivesTheKillStartsNothingAndClosesThePane() async throws {
        let session = try newSession()
        running(session.paneIdentity)
        harness.processes.ends = []
        let launches = harness.runner.launches.count

        let reply = await restart(session, command: "true")

        #expect(reply.error == "the old shell ended (pid 100) but its program is still running; nothing was started and the pane was closed")
        #expect(harness.processes.signals.map(\.signal) == [SIGHUP, SIGKILL])
        #expect(harness.runner.launches.count == launches)
        #expect(harness.store.session(withID: session.id) == nil)
    }

    @Test func aRightPaneRestartKeepsTheSplitAndItsIdentity() async throws {
        let session = try newSession(split: true)
        let split = try #require(session.splitPaneIdentity)
        running(split, pid: 200, job: nil)

        let reply = await restart(session, command: "htop", pane: .right)

        #expect(reply.result?.pane == "right")
        #expect(reply.result?.restart?.paneID == split.uuidString)
        #expect(harness.runner.launches.last?.name == ZmxSupport.daemonName(for: split))
        #expect(session.splitPaneIdentity == split)
    }

    @Test func anUnknownPaneIDIsRefusedEvenBesideARole() async throws {
        let session = try newSession()

        let reply = await harness.actions.restartSessionPane(session.id.uuidString, window: nil,
                                                             options: ControlSessionRestartOptions(command: "true", pane: .left,
                                                                                                    paneID: UUID().uuidString))

        #expect(reply.error?.hasPrefix("unknown pane id:") == true)
    }

    @Test func anEndedRowStartsItsPrimaryWithACommandAndHasNoOldShell() async throws {
        let session = try newSession()
        harness.store.markSessionEnded(session.id)
        harness.store.setAgentIndicator(AgentIndicator(status: .blocked, statusPane: .left), forSession: session.id)
        let runner = harness.runner
        let daemon = ZmxSupport.daemonName(for: session.paneIdentity)
        runner.onCreate = { _ in runner.records = [ZmxSessionRecord(name: daemon, clients: 0, leaderPID: 500)] }

        let reply = await restart(session, command: "make")

        #expect(reply.result?.restart == ControlRestartReceipt(paneID: session.paneIdentity.uuidString, oldPid: nil, newPid: 500))
        #expect(reply.result?.text == "restarted left pane: shell 500")
        #expect(!session.ended)
        #expect(session.agentIndicator.status == .idle)
        #expect(harness.runner.confirmedKills.isEmpty)
        #expect(harness.runner.launches.last?.argv.last == returning("make"))
    }

    @Test(arguments: [(nil as String?, StatusPane.left, "an ended session has no program to replay; pass --command"),
                      ("make", .right, "an ended session restarts its primary pane")])
    func anEndedRowRefusesWhatItCannotRun(command: String?, pane: StatusPane, message: String) async throws {
        let session = try newSession(split: true)
        harness.store.markSessionEnded(session.id)

        let reply = await restart(session, command: command, pane: pane)

        #expect(reply.error == message)
        #expect(session.ended)
    }

    @Test func anEndedRowWhoseStartFailsStaysEnded() async throws {
        let session = try newSession()
        harness.store.markSessionEnded(session.id)
        harness.store.setAgentIndicator(AgentIndicator(status: .blocked, statusPane: .left), forSession: session.id)
        harness.runner.failure = "zmx is gone"

        let reply = await restart(session, command: "make")

        #expect(reply.error == "could not start the pane: zmx is gone")
        #expect(session.ended)
        #expect(session.agentIndicator.status == .blocked)
    }

    @Test func aBashPaneReplaysThroughTheRearmScript() async throws {
        let harness = try ServerHarness(shell: "/bin/bash")
        let session = try harness.session(harness.actions.createSession(ControlSessionCreateOptions(
            window: nil, cwd: "/tmp", workspace: nil, workspaceName: nil, createWorkspace: nil, command: nil, wait: nil,
            name: nil, after: nil, before: nil, noSelect: false)))
        let daemon = ZmxSupport.daemonName(for: session.paneIdentity)
        harness.runner.records = [ZmxSessionRecord(name: daemon, clients: 1, leaderPID: 100)]
        harness.processes.shell(100, job: 300)
        let runner = harness.runner
        runner.onCreate = { _ in runner.records = [ZmxSessionRecord(name: daemon, clients: 0, leaderPID: 101)] }
        harness.actions.replayObservation = { _, _ in
            RestartReplay.Observation(foreground: CommandRestore.paneForeground(argv: ["top"], extra: "bash"), isDaemonLeader: false,
                                      workingDirectory: "/tmp")
        }

        let reply = await harness.actions.restartSessionPane(session.id.uuidString, window: nil,
                                                             options: ControlSessionRestartOptions(command: nil, pane: .left))

        #expect(reply.result?.restart?.replayedArgv == ["top"])
        let argv = try #require(harness.runner.launches.last?.argv)
        #expect(argv.prefix(3) == ["/bin/bash", "--posix", "-lic"])
        #expect(argv.last?.hasSuffix("builtin trap __agterm_rearm EXIT; " + CommandRestore.shellQuotedLine(["top"])) == true)
    }

    private func viewer(of session: Session) async throws -> ServerStreamsTests.Viewer {
        var fds: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, UnixSocket.streamType, 0, &fds) == 0)
        harness.actions.streams.adoptPresentationStream(descriptor: fds[0], session: session.id)
        let viewer = ServerStreamsTests.Viewer(fd: fds[1])
        try viewer.send(.hello(PresentationHello(version: PresentationCodec.version, kinds: PresentationHub.supportedKinds, mode: .mirror)))
        let snapshot = await offPool { viewer.first { if case .snapshot = $0 { true } else { false } } }
        #expect(snapshot != nil)
        return viewer
    }

    @Test func aConfirmedRestartPublishesTheRespawnToTheSessionsViewers() async throws {
        let session = try newSession()
        running(session.paneIdentity)
        let viewer = try await viewer(of: session)
        defer { viewer.disconnect() }

        let reply = await restart(session, command: "make test")

        #expect(reply.ok, "\(reply.error ?? "")")
        let frame = await offPool { viewer.first { if case .respawn = $0 { true } else { false } } }
        guard case .respawn(let respawns)? = frame else { Issue.record("no respawn frame"); return }
        #expect(respawns.epoch == harness.actions.streams.originEpoch)
        #expect(respawns.generations == [ZmxSupport.daemonName(for: session.paneIdentity): 1])
    }
}
