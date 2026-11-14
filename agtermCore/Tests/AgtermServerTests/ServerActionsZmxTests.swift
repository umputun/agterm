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
}
