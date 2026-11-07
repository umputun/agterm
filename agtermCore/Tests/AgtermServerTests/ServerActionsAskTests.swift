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

    @Test func anAskWithNoConnectedMacWaitsUnpresented() throws {
        let session = try newSession()
        let pending = ask()

        let reply = harness.actions.openAsk(pending, target: session.id.uuidString, window: nil, placement: ControlAskPlacement(),
                                            follow: false)

        #expect(reply.ok)
        #expect(session.askPending?.id == pending.id)
        #expect(!session.askPresentedRemotely)
        #expect(harness.actions.askResult(pending.id, window: nil).result?.ask?.result == .pending)
        let node = harness.store.controlTree().workspaces.flatMap(\.sessions).first { $0.id == session.id.uuidString }
        #expect(node?.interactions == [ControlInteraction(kind: "ask", id: pending.id, state: ControlInteraction.unpresented)])
    }

    @Test func anAskNoFrameCanCarryIsRefusedBeforeBooking() throws {
        let session = try newSession()
        let huge = PendingAsk(id: UUID().uuidString, title: "deploy?", message: String(repeating: "x", count: 300 * 1024),
                              buttons: [ControlAskButton(id: "yes", label: "Yes")])

        let reply = harness.actions.openAsk(huge, target: session.id.uuidString, window: nil, placement: ControlAskPlacement(),
                                            follow: false)

        #expect(reply == ControlResponse(ok: false, error: "ask is too large to send to a Mac"))
        #expect(session.askPending == nil)
    }

    @Test func aSecondAskWhileOneWaitsIsRefused() throws {
        let session = try newSession()
        _ = harness.actions.openAsk(ask(), target: session.id.uuidString, window: nil, placement: ControlAskPlacement(), follow: false)

        let reply = harness.actions.openAsk(ask(), target: session.id.uuidString, window: nil, placement: ControlAskPlacement(),
                                            follow: false)

        #expect(reply == ControlResponse(ok: false, error: "ask already pending"))
    }

    @Test func aWaitingAskEndsAtItsDeadline() async throws {
        let session = try newSession()
        var timed = ask()
        timed.deadline = Date().addingTimeInterval(0.1)
        _ = harness.actions.openAsk(timed, target: session.id.uuidString, window: nil, placement: ControlAskPlacement(), follow: false)
        let node = harness.store.controlTree().workspaces.flatMap(\.sessions).first { $0.id == session.id.uuidString }
        #expect(node?.interactions?.first?.deadline == timed.deadline?.timeIntervalSince1970)

        let ended = await eventually { harness.actions.askResult(timed.id, window: nil).result?.ask?.result == .cancelled }
        #expect(ended, "\(String(describing: harness.actions.askResult(timed.id, window: nil))), pending \(String(describing: session.askPending?.id))")
        #expect(session.askPending == nil)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test func aCancelledWaitingAskEnds() throws {
        let session = try newSession()
        let pending = ask()
        _ = harness.actions.openAsk(pending, target: session.id.uuidString, window: nil, placement: ControlAskPlacement(), follow: false)

        #expect(harness.actions.cancelAsk(pending.id, window: nil).ok)

        #expect(harness.actions.askResult(pending.id, window: nil).result?.ask?.result == .cancelled)
    }

    @Test func anAskOfAnEarlierRunIsUnknownToANewOne() throws {
        let session = try newSession()
        let pending = ask()
        _ = harness.actions.openAsk(pending, target: session.id.uuidString, window: nil, placement: ControlAskPlacement(), follow: false)
        let restarted = try ServerHarness()

        #expect(restarted.actions.askResult(pending.id, window: nil) == ControlResponse(ok: false, error: "unknown ask: \(pending.id)"))
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
