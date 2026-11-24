import Foundation
import Testing
@testable import AgtermServerKit
import agtermCore

@MainActor
struct ServerActionsZmxTests {
    private let harness: ServerHarness

    init() throws { harness = try ServerHarness() }

    private func newSession() throws -> Session {
        try harness.session(harness.actions.createSession(ControlSessionCreateOptions(
            window: nil, cwd: nil, workspace: nil, workspaceName: nil, createWorkspace: nil, command: nil, wait: nil,
            name: nil, after: nil, before: nil, noSelect: false)))
    }

    @Test func listJoinsTheServersDaemonsAgainstItsPanes() throws {
        let session = try newSession()
        let daemon = ZmxSupport.daemonName(for: session.paneIdentity)
        let stray = ZmxSupport.daemonName(for: UUID())
        harness.runner.records = [ZmxSessionRecord(name: daemon, clients: 1, leaderPID: 100),
                                  ZmxSessionRecord(name: stray, clients: 0, leaderPID: 200)]

        let inventory = try #require(harness.actions.listZmxDaemons().result?.zmx)

        #expect(inventory.inventoryComplete)
        #expect(inventory.restore.active == "live")
        #expect(inventory.endpoint == ControlZmxEndpoint(executable: harness.panes.configuration.zmxPath,
                                                         socketDirectory: harness.panes.configuration.zmxSocketDirectory))
        let states = Dictionary(uniqueKeysWithValues: inventory.entries.map { ($0.daemon, $0.state) })
        #expect(states == [daemon: ZmxClaimState.claimed.rawValue, stray: ZmxClaimState.orphan.rawValue])
        #expect(inventory.entries.first { $0.daemon == daemon }?.sessionID == session.id.uuidString)
    }

    @Test func aListingThatFailsIsAnError() {
        harness.runner.records = nil

        #expect(harness.actions.listZmxDaemons() == ControlResponse(ok: false, error: "could not read the zmx session list"))
    }

    @Test func screenReadsADaemonByName() {
        harness.runner.screens["agterm-other"] = "one\ntwo"
        harness.runner.histories["agterm-other"] = "zero\n"

        #expect(harness.actions.readZmxScreen(name: "agterm-other", fullBuffer: false, lines: nil).result?.text == "one\ntwo")
        #expect(harness.actions.readZmxScreen(name: "agterm-other", fullBuffer: true, lines: 2).result?.text == "one\ntwo")
        #expect(harness.actions.readZmxScreen(name: "agterm-other", fullBuffer: true, lines: nil).result?.text == "zero\none\ntwo")
    }

    @Test func screenOfAnUnknownDaemonIsAnError() {
        #expect(harness.actions.readZmxScreen(name: "missing", fullBuffer: false, lines: nil)
            == ControlResponse(ok: false, error: "could not read the zmx screen of missing"))
    }

    private func running(_ identity: UUID, pid: Int32, clients: Int = 1) {
        harness.runner.records = (harness.runner.records ?? [])
            + [ZmxSessionRecord(name: ZmxSupport.daemonName(for: identity), clients: clients, leaderPID: pid)]
        harness.processes.shell(pid, job: pid + 1000)
    }

    @Test func aConfirmedKillHangsUpTheJobAndClosesAStandaloneSession() throws {
        let session = try newSession()
        running(session.paneIdentity, pid: 100)

        let reply = harness.actions.killZmxDaemon(target: session.id.uuidString, window: nil, pane: .left)

        #expect(reply.result?.text == "killed \(ZmxSupport.daemonName(for: session.paneIdentity))")
        #expect(harness.runner.confirmedKills.map(\.force) == [true])
        #expect(harness.processes.signals.map(\.signal) == [SIGHUP])
        #expect(harness.processes.signals.first?.pids == [1100])
        #expect(harness.store.session(withID: session.id) == nil)
    }

    @Test func leaderReadsAnswerFromTheScanWhileTheListingFails() throws {
        let killed = try newSession(), closed = try newSession()
        running(killed.paneIdentity, pid: 100)
        running(closed.paneIdentity, pid: 200)
        harness.runner.listFails = true
        harness.actions.foregroundArgv = { $0 == 100 ? ["htop"] : nil }

        let node = try #require(harness.actions.controlTree(window: nil).result?.tree?.workspaces.flatMap(\.sessions)
            .first { $0.id == killed.id.uuidString })
        #expect(node.foreground == ["htop"])
        #expect(harness.actions.killZmxDaemon(target: killed.id.uuidString, window: nil, pane: .left).ok)
        #expect(harness.actions.closeSession(closed.id.uuidString, window: nil).ok)

        #expect(harness.processes.signals.map(\.signal) == [SIGHUP, SIGHUP])
        #expect(harness.processes.signals.map(\.pids) == [[1100], [1200]])
    }

    @Test func killingTheLeftPanePromotesTheLiveSplit() throws {
        let session = try newSession()
        _ = harness.actions.splitSession(session.id.uuidString, window: nil, mode: "on")
        let split = try #require(session.splitPaneIdentity)
        running(session.paneIdentity, pid: 100)
        running(split, pid: 200)

        _ = harness.actions.killZmxDaemon(target: session.id.uuidString, window: nil, pane: .left)

        #expect(harness.store.session(withID: session.id) === session)
        #expect(session.paneIdentity == split)
        #expect(!session.hasSplit)
        #expect(!session.ended)
    }

    @Test(arguments: [ZmxKillOutcome.staleSocket, .failed("SessionUnresponsive")])
    func aKillZmxDidNotConfirmLeavesThePane(outcome: ZmxKillOutcome) throws {
        let session = try newSession()
        running(session.paneIdentity, pid: 100)
        harness.runner.killOutcome = outcome

        let reply = harness.actions.killZmxDaemon(target: session.id.uuidString, window: nil, pane: .left)

        #expect(!reply.ok)
        #expect(harness.processes.signals.isEmpty)
        #expect(harness.store.session(withID: session.id) === session)
        #expect(session.daemonBackedPanes.contains(session.paneIdentity))
    }

    @Test func anUnreadableProcessTableRefusesTheKill() throws {
        let session = try newSession()
        running(session.paneIdentity, pid: 100)
        harness.processes.table = nil

        let reply = harness.actions.killZmxDaemon(target: session.id.uuidString, window: nil, pane: .left)

        #expect(reply.error == "the process table cannot be read; nothing was changed")
        #expect(harness.runner.confirmedKills.isEmpty)
    }

    @Test func activeIsNotAKillTarget() {
        #expect(harness.actions.killZmxDaemon(target: "active", window: nil, pane: .left).error
            == "zmx.kill needs a session id; 'active' is not accepted")
    }

    @Test func aPinnedKillOfAStalePaneRefusesBeforeAnyKill() throws {
        let session = try newSession()
        running(session.paneIdentity, pid: 100)
        let stale = UUID().uuidString

        let reply = harness.actions.killZmxPane(target: session.id.uuidString, window: nil, pane: .left, paneID: stale)

        #expect(reply == ControlResponse(ok: false, error: "pane \(stale) is no longer the left pane; nothing was killed"))
        #expect(harness.runner.confirmedKills.isEmpty)
        #expect(harness.runner.kills.isEmpty)
        #expect(harness.processes.signals.isEmpty)
        #expect(harness.store.session(withID: session.id) === session)
    }

    @Test func aPinnedKillOfTheCurrentPaneKillsIt() throws {
        let session = try newSession()
        running(session.paneIdentity, pid: 100)
        let daemon = ZmxSupport.daemonName(for: session.paneIdentity)

        let reply = harness.actions.killZmxPane(target: session.id.uuidString, window: nil, pane: .left,
                                                paneID: session.paneIdentity.uuidString)

        #expect(reply.result?.text == "killed \(daemon)")
        #expect(harness.runner.confirmedKills.map(\.name) == [daemon])
        #expect(harness.store.session(withID: session.id) == nil)
    }

    @Test func pruneKillsOnlyDetachedUnclaimedDaemonsWithoutForce() throws {
        let session = try newSession()
        running(session.paneIdentity, pid: 100, clients: 0)
        let orphan = UUID(), attached = UUID()
        running(orphan, pid: 200, clients: 0)
        running(attached, pid: 300, clients: 1)
        let name = ZmxSupport.daemonName(for: orphan)

        let reply = harness.actions.pruneZmxDaemons()

        #expect(reply.result?.affected == 1)
        #expect(reply.result?.text == "killed \(name)")
        #expect(harness.runner.confirmedKills.map(\.name) == [name])
        #expect(harness.runner.confirmedKills.map(\.force) == [false])
        #expect(harness.processes.signals.first?.pids == [1200])
        #expect(harness.store.session(withID: session.id) === session)
    }

    @Test func pruneReportsAStaleSocketAsNotAKill() throws {
        let orphan = UUID()
        running(orphan, pid: 200, clients: 0)
        harness.runner.killOutcome = .staleSocket

        let reply = harness.actions.pruneZmxDaemons()

        #expect(reply.result?.affected == 0)
        #expect(reply.result?.text == "\(ZmxSupport.daemonName(for: orphan)): cleaned up a stale socket, the daemon may still be running")
        #expect(harness.processes.signals.isEmpty)
    }

    @Test func pruneLeavesTheDaemonOfACloseStillInsideItsGrace() throws {
        let session = try newSession()
        running(session.paneIdentity, pid: 100, clients: 0)
        _ = harness.actions.closeSession(session.id.uuidString, window: nil, undoable: true)

        #expect(harness.actions.pruneZmxDaemons().result?.text == "no orphan daemons")
        #expect(harness.runner.confirmedKills.isEmpty)
    }

    @Test func pruneWithNoOrphanSaysSo() throws {
        let session = try newSession()
        running(session.paneIdentity, pid: 100, clients: 0)

        #expect(harness.actions.pruneZmxDaemons().result?.text == "no orphan daemons")
    }
}
