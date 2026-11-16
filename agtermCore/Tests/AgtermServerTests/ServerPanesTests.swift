import Foundation
import Testing
@testable import AgtermServerKit
import agtermCore

@MainActor
struct ServerPanesTests {
    private let harness: ServerHarness

    init() throws { harness = try ServerHarness() }

    @Test func unownedScratchDaemonsAreEndedAndTheRestKept() throws {
        let session = try harness.session(harness.actions.createSession(
            ControlSessionCreateOptions(window: nil, cwd: "/tmp", workspace: nil, workspaceName: nil, createWorkspace: nil,
                                        command: nil, wait: nil, name: nil, after: nil, before: nil, noSelect: false)))
        _ = harness.actions.scratchSession(session.id.uuidString, window: nil, mode: "on", command: nil)
        let owned = ZmxSupport.scratchDaemonName(for: try #require(session.scratchDaemon?.identity))
        let pane = ZmxSessionRecord(name: ZmxSupport.daemonName(for: UUID()), clients: 0, leaderPID: 1)
        let leftover = ZmxSessionRecord(name: ZmxSupport.scratchDaemonName(for: UUID()), clients: 1, leaderPID: 2)
        let mine = ZmxSessionRecord(name: owned, clients: 0, leaderPID: 3)
        let foreign = ZmxSessionRecord(name: "work", clients: 0, leaderPID: 4)

        let kept = harness.panes.endUnownedScratches([pane, leftover, mine, foreign])

        #expect(kept.map(\.name) == [pane.name, mine.name, foreign.name])
        #expect(harness.runner.kills == [leftover.name])
    }

    @Test func aScratchWhoseKillFailedIsNoLongerOwned() async throws {
        let session = try harness.session(await harness.actions.serve(ControlRequest(cmd: .sessionNew)))
        _ = harness.actions.scratchSession(session.id.uuidString, window: nil, mode: "on", command: nil)
        let name = ZmxSupport.scratchDaemonName(for: try #require(session.scratchDaemon?.identity))
        harness.runner.killFails = true
        _ = harness.actions.closeSession(session.id.uuidString, window: nil)
        harness.runner.killFails = false

        let kept = harness.panes.endUnownedScratches([ZmxSessionRecord(name: name, clients: 0, leaderPID: 1)])

        #expect(kept.isEmpty)
        #expect(harness.runner.kills.filter { $0 == name }.count == 2)
    }

    @Test func closingASessionHangsUpItsForegroundJob() async throws {
        let session = try harness.session(await harness.actions.serve(ControlRequest(cmd: .sessionNew)))
        let name = ZmxSupport.daemonName(for: session.paneIdentity)
        harness.runner.records = [ZmxSessionRecord(name: name, clients: 1, leaderPID: 100)]
        harness.processes.shell(100, job: 1100)

        _ = harness.actions.closeSession(session.id.uuidString, window: nil)

        #expect(harness.runner.kills == [name])
        #expect(harness.processes.signals.map(\.signal) == [SIGHUP])
        #expect(harness.processes.signals.first?.pids == [1100])
    }

    @Test func aFailedKillHangsUpNothing() async throws {
        let session = try harness.session(await harness.actions.serve(ControlRequest(cmd: .sessionNew)))
        harness.runner.records = [ZmxSessionRecord(name: ZmxSupport.daemonName(for: session.paneIdentity), clients: 1, leaderPID: 100)]
        harness.processes.shell(100, job: 1100)
        harness.runner.killFails = true

        _ = harness.actions.closeSession(session.id.uuidString, window: nil)

        #expect(harness.processes.signals.isEmpty)
    }

    @Test func anUnreadableListingStillEndsTheDaemon() async throws {
        let session = try harness.session(await harness.actions.serve(ControlRequest(cmd: .sessionNew)))
        harness.runner.records = nil
        harness.processes.shell(100, job: 1100)

        _ = harness.actions.closeSession(session.id.uuidString, window: nil)

        #expect(harness.runner.kills == [ZmxSupport.daemonName(for: session.paneIdentity)])
        #expect(harness.processes.signals.isEmpty)
    }

    @Test(arguments: [
        ("agterm-scratch-" + String(repeating: "a", count: 32), true),
        ("agterm-scratch-" + String(repeating: "A", count: 32), false),
        ("agterm-scratch-" + String(repeating: "a", count: 31), false),
        ("agterm-scratch-", false),
    ])
    func onlyTheEmittedShapeIsAScratchName(name: String, scratch: Bool) {
        #expect(ZmxSupport.isScratchDaemonName(name) == scratch)
        #expect(!ZmxSupport.isDaemonName(name))
    }

    @Test func anEmittedScratchNameIsAScratchNameAndNoPaneName() {
        let name = ZmxSupport.scratchDaemonName(for: UUID())

        #expect(ZmxSupport.isScratchDaemonName(name))
        #expect(!ZmxSupport.isDaemonName(name))
    }
}
