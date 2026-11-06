import Foundation
import Testing
@testable import AgtermServerKit
import agtermCore

@MainActor
struct ServerActionsRemoteTests {
    private let harness: ServerHarness

    init() throws { harness = try ServerHarness() }

    private func newSession() throws -> Session {
        try harness.session(harness.actions.createSession(ControlSessionCreateOptions(
            window: nil, cwd: nil, workspace: nil, workspaceName: nil, createWorkspace: nil, command: nil, wait: nil,
            name: nil, after: nil, before: nil, noSelect: false)))
    }

    private func running(_ identities: [UUID]) {
        harness.runner.records = identities.map { ZmxSessionRecord(name: ZmxSupport.daemonName(for: $0), clients: 0, leaderPID: 100) }
    }

    @Test func theTreeListsRunningPanesWithTheServersOwnZmx() async throws {
        let session = try newSession()
        _ = harness.actions.splitSession(session.id.uuidString, window: nil, mode: "on")
        let split = try #require(session.splitPaneIdentity)
        running([session.paneIdentity, split])

        let tree = try #require(await harness.actions.remoteTree(host: nil).result?.remote)

        #expect(tree.endpoint == ControlZmxEndpoint(executable: harness.panes.configuration.zmxPath,
                                                    socketDirectory: harness.panes.configuration.zmxSocketDirectory))
        let listed = try #require(tree.sessions.first { $0.id == session.id.uuidString })
        #expect(listed.windowID == harness.catalog.id.uuidString)
        #expect(Dictionary(uniqueKeysWithValues: listed.panes.map { ($0.pane, $0.daemon) })
            == ["left": ZmxSupport.daemonName(for: session.paneIdentity), "right": ZmxSupport.daemonName(for: split)])
    }

    @Test func aSessionWhoseDaemonIsNotRunningIsNotListed() async throws {
        let session = try newSession()
        running([])

        let tree = try #require(await harness.actions.remoteTree(host: nil).result?.remote)

        #expect(!tree.sessions.contains { $0.id == session.id.uuidString })
    }

    @Test func aDaemonZmxCouldNotProbeIsNotOfferedForAttach() async throws {
        let session = try newSession()
        harness.runner.records = try ZmxListParser.parse("name=\(ZmxSupport.daemonName(for: session.paneIdentity))\terr=Timeout\tstatus=unreachable\n")

        let tree = try #require(await harness.actions.remoteTree(host: nil).result?.remote)

        #expect(!tree.sessions.contains { $0.id == session.id.uuidString })
    }

    @Test func aSplitWithOneUnreadablePaneIsNotOfferedAndStaysBooked() async throws {
        let session = try newSession()
        _ = harness.actions.splitSession(session.id.uuidString, window: nil, mode: "on")
        let split = try #require(session.splitPaneIdentity)
        harness.runner.records = try ZmxListParser.parse(
            "name=\(ZmxSupport.daemonName(for: session.paneIdentity))\tpid=100\tclients=0\n"
                + "name=\(ZmxSupport.daemonName(for: split))\terr=ConnectionRefused\tstatus=unreachable\n")

        let tree = try #require(await harness.actions.remoteTree(host: nil).result?.remote)

        #expect(!tree.sessions.contains { $0.id == session.id.uuidString })
        #expect(session.daemonBackedPanes == [session.paneIdentity, split])
    }

    @Test func anotherHostsTreeIsRefused() async {
        let reply = await harness.actions.remoteTree(host: "elsewhere")

        #expect(reply == ControlResponse(ok: false, error: "agterm-server lists only its own sessions"))
    }

    @Test func anUnreadableListingIsAnError() async {
        harness.runner.records = nil

        #expect(await harness.actions.remoteTree(host: nil) == ControlResponse(ok: false, error: "could not read the zmx session list"))
    }

    @Test func onlyALiveBackedSessionCanBePresented() throws {
        let session = try newSession()

        #expect(harness.actions.openPresentation(session: session.id.uuidString)
            == ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString)))
        session.daemonBackedPanes.removeAll()
        #expect(harness.actions.openPresentation(session: session.id.uuidString)
            == ControlResponse(ok: false, error: "session is not live-backed, so nothing can be attached to it"))
    }
}
