import Foundation
import Testing
@testable import agtermCore

@MainActor
struct SessionRestartTests {
    @Test func requestAndReceiptRoundTrip() throws {
        let request = ControlRequest(cmd: .sessionRestart, target: "9f3c",
                                     args: ControlArgs(command: "cld brief.md", pane: "right", paneID: "token"))
        let encoded = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(ControlRequest.self, from: encoded) == request)
        #expect(String(decoding: encoded, as: UTF8.self).contains(#""cmd":"session.restart""#))

        let receipt = ControlRestartReceipt(paneID: "token", oldPid: 11, newPid: 22)
        let response = ControlResponse(ok: true, result: ControlResult(id: "9f3c", pane: "right", restart: receipt))
        let decoded = try JSONDecoder().decode(ControlResponse.self, from: JSONEncoder().encode(response))
        #expect(decoded.result?.restart == receipt)

        let bare = String(decoding: try JSONEncoder().encode(ControlResult(id: "9f3c")), as: UTF8.self)
        #expect(!bare.contains("restart"))
    }

    @Test func aReplayReceiptCarriesTheArgvAndAnExplicitOneOmitsIt() throws {
        let replayed = ControlRestartReceipt(paneID: "token", oldPid: 11, newPid: 22, replayedArgv: ["sh", "-c", "a b", ""])
        let encoded = try JSONEncoder().encode(replayed)
        #expect(try JSONDecoder().decode(ControlRestartReceipt.self, from: encoded) == replayed)

        let explicit = try JSONEncoder().encode(ControlRestartReceipt(paneID: "token", oldPid: 11, newPid: 22))
        #expect(!String(decoding: explicit, as: UTF8.self).contains("replayedArgv"))

        let old = Data(#"{"paneID":"token","oldPid":11,"newPid":22}"#.utf8)
        #expect(try JSONDecoder().decode(ControlRestartReceipt.self, from: old).replayedArgv == nil)
    }

    @Test(arguments: [StatusPane.left, .right])
    func clearPaneOwnedStateDropsOnlyThatPanesStatusAskAndOverlay(pane: StatusPane) throws {
        let (store, session) = try splitSession()
        store.openPaneOverlay(session.id, pane: .left, command: "revdiff")
        store.openPaneOverlay(session.id, pane: .right, command: "htop")
        let owned: OverlayPane = pane == .left ? .left : .right
        let identity = pane == .left ? session.paneIdentity : session.splitPaneIdentity
        #expect(session.openAsk(makeAsk(), paneIdentity: identity))
        store.setAgentIndicator(AgentIndicator(status: .blocked, statusPane: pane), forSession: session.id)
        let (left, right) = (session.paneIdentity, session.splitPaneIdentity)

        store.clearPaneOwnedState(session.id, pane: pane)

        #expect(session.agentIndicator.status == .idle)
        #expect(session.askPending == nil)
        #expect(session.paneOverlay(owned) == nil)
        #expect(session.paneOverlay(owned == .left ? .right : .left) != nil)
        #expect(session.paneIdentity == left)
        #expect(session.splitPaneIdentity == right)
        #expect(session.hasSplit)
    }

    @Test func clearPaneOwnedStateLeavesTheOtherPanesStatusAndAsk() throws {
        let (store, session) = try splitSession()
        let ask = makeAsk()
        #expect(session.openAsk(ask, paneIdentity: session.splitPaneIdentity))
        defer { session.cancelAsk(id: ask.id) }
        store.setAgentIndicator(AgentIndicator(status: .blocked, statusPane: .right), forSession: session.id)

        store.clearPaneOwnedState(session.id, pane: .left)

        #expect(session.agentIndicator.status == .blocked)
        #expect(session.askPending == ask)
    }

    private func splitSession() throws -> (AppStore, Session) {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/a"))
        session.surface = SpySurface()
        store.toggleSplit(session.id)
        session.splitSurface = SpySurface()
        return (store, session)
    }

    private func makeAsk() -> PendingAsk {
        PendingAsk(id: UUID().uuidString, title: "Continue?", buttons: [ControlAskButton(id: "yes", label: "Yes")])
    }
}
