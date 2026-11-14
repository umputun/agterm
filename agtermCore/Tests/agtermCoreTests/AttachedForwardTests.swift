import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AttachedForwardTests {
    private let forward = AttachedForward.killPane(session: "s1", pane: .left, paneID: "p1")
    private let tooOld = AttachedOutcome.refused("the agterm on box is too old for this")
    private let endpoint = ControlZmxEndpoint(executable: "/bin/zmx", socketDirectory: "/tmp/zmx")

    private func printed(_ response: ControlResponse, status: Int32 = 0) throws -> RemoteCommandResult {
        RemoteCommandResult(status: status, stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "")
    }

    @Test func anOkReplyIsDone() throws {
        let reply = ControlResponse(ok: true, result: ControlResult(id: "s1"))

        #expect(forward.outcome(of: try printed(reply), host: "box") == .done(reply))
    }

    @Test func anOriginRejectingItsArgumentsIsTooOld() {
        #expect(forward.outcome(of: RemoteCommandResult(status: 64, stdout: "", stderr: "Error: Unknown option '--pane-id'"),
                                host: "box") == tooOld)
    }

    @Test func anOriginRefusingTheCommandAsUnknownIsTooOld() throws {
        let reply = ControlResponse(ok: false, error: "invalid request: Cannot initialize Command from invalid String value zmx.kill.pane")

        #expect(forward.outcome(of: try printed(reply, status: 1), host: "box") == tooOld)
    }

    @Test func anOriginRefusalKeepsItsReason() throws {
        #expect(forward.outcome(of: try printed(ControlResponse(ok: false, error: "no such session"), status: 1), host: "box")
            == .refused("no such session"))
        #expect(forward.outcome(of: try printed(ControlResponse(ok: false), status: 1), host: "box")
            == .refused("the command failed on box"))
    }

    @Test(arguments: [("", "box gave no answer; whether the pane was killed there is unknown"),
                      ("ssh: timeout\n", "box gave no answer (ssh: timeout); whether the pane was killed there is unknown")])
    func anUnreadableReplyIsUnknownNamingTheHost(stderr: String, reason: String) {
        #expect(forward.outcome(of: RemoteCommandResult(status: 255, stdout: "{\"ok\":", stderr: stderr), host: "box") == .unknown(reason))
    }

    private func attachedRow(_ store: AppStore, host: String = "box", remotePane: UUID = UUID(),
                             origin: Bool = true, catalogOwned: Bool = false) throws -> Session {
        let workspace = store.workspaces.first ?? store.addWorkspace(name: "w")
        let row = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/a", remoteHost: host, remoteSessionID: "o1"))
        let binding = RemoteBinding(remoteSessionID: "o1", daemonsByLocalPane: [row.paneIdentity: ZmxSupport.daemonName(for: remotePane)],
                                    presentationVersion: 1,
                                    origin: origin ? RemoteBinding.Origin(host: host, endpoint: endpoint, sessionName: "o1") : nil,
                                    catalogOwned: catalogOwned, originHeadless: true)
        store.bindRemote(binding, forSession: row.id)
        return row
    }

    @Test func anAttachedRowNamesItsOriginAndTheOriginsPaneToken() throws {
        let store = makeStore()
        let remotePane = UUID()
        let row = try attachedRow(store, remotePane: remotePane)

        let origin = try #require(AttachedOrigin(row))
        let sibling = try #require(AttachedOrigin(attachedRow(store)))
        let elsewhere = try #require(AttachedOrigin(attachedRow(store, host: "other")))

        #expect(origin.host == "box")
        #expect(origin.endpoint == endpoint)
        #expect(origin.session == "o1")
        #expect(origin.headless)
        #expect(AttachedOrigin.originPaneID(of: row, local: row.paneIdentity) == remotePane.uuidString)
        #expect(AttachedOrigin.originPaneID(of: row, local: UUID()) == nil)
        #expect(origin.shares(sibling))
        #expect(!origin.shares(elsewhere))
    }

    @Test func aRowThatCannotReachAnOriginHasNone() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "w")
        let local = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/a"))
        let unbound = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/a", remoteHost: "box"))

        #expect(AttachedOrigin(local) == nil)
        #expect(AttachedOrigin(unbound) == nil)
        #expect(try AttachedOrigin(attachedRow(store, catalogOwned: true)) == nil)
        #expect(try AttachedOrigin(attachedRow(store, origin: false)) == nil)
    }
}
