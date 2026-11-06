import Foundation
import Testing
@testable import AgtermServerKit
import agtermCore

@MainActor
struct ServerActionsAskTests {
    private let harness: ServerHarness

    init() throws { harness = try ServerHarness() }

    private func newSession() throws -> Session {
        try harness.session(harness.actions.createSession(ControlSessionCreateOptions(
            window: nil, cwd: nil, workspace: nil, workspaceName: nil, createWorkspace: nil, command: nil, wait: nil,
            name: nil, after: nil, before: nil, noSelect: false)))
    }

    private func ask(style: ControlAskStyle = .terminal) -> PendingAsk {
        PendingAsk(id: UUID().uuidString, title: "deploy?", buttons: [ControlAskButton(id: "yes", label: "Yes")], style: style)
    }

    @Test func anAskWithNoConnectedMacIsRefusedAndLeavesTheSlotFree() throws {
        let session = try newSession()

        let reply = harness.actions.openAsk(ask(), target: session.id.uuidString, window: nil, placement: ControlAskPlacement(),
                                            follow: false)

        #expect(reply == ControlResponse(ok: false, error: "no connected Mac to show the ask"))
        #expect(session.askPending == nil)
    }

    @Test func aWindowAskWithNoSessionIsRefused() {
        let reply = harness.actions.openAsk(ask(style: .gui), target: nil, window: nil, placement: ControlAskPlacement(), follow: false)

        #expect(reply == ControlResponse(ok: false, error: "ask.open needs --target on agterm-server, which has no window to show it in"))
    }

    @Test func anAskOnAPaneTheSessionDoesNotHaveIsRefused() throws {
        let session = try newSession()

        let reply = harness.actions.openAsk(ask(), target: session.id.uuidString, window: nil,
                                            placement: ControlAskPlacement(pane: .right), follow: false)

        #expect(reply == ControlResponse(ok: false, error: "session has no split"))
        #expect(session.askPending == nil)
    }

    @Test func anUnknownAskHasNoResultAndCannotBeCancelled() {
        let id = UUID().uuidString

        #expect(harness.actions.askResult(id, window: nil) == ControlResponse(ok: false, error: "unknown ask: \(id)"))
        #expect(harness.actions.cancelAsk(id, window: nil) == ControlResponse(ok: false, error: "unknown ask: \(id)"))
    }
}
