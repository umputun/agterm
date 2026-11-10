import Foundation
import Testing
@testable import AgtermServerKit
import agtermCore

@MainActor
struct ServerActionsEffectsTests {
    private let harness: ServerHarness

    init() throws { harness = try ServerHarness() }

    private func newSession() throws -> Session {
        try harness.session(harness.actions.createSession(ControlSessionCreateOptions(
            window: nil, cwd: nil, workspace: nil, workspaceName: nil, createWorkspace: nil, command: nil, wait: nil,
            name: nil, after: nil, before: nil, noSelect: false)))
    }

    private func status(_ session: Session, _ status: AgentStatus, pane: StatusPane? = nil, sound: String? = nil) async -> ControlResponse {
        await harness.actions.setSessionStatus(session.id.uuidString, window: nil, update: ControlSessionStatusUpdate(
            status: status, blink: nil, autoReset: nil, sound: sound, color: nil, shape: nil, pane: pane, paneID: nil))
    }

    @Test func aStatusIsSetOnTheSession() async throws {
        let session = try newSession()

        #expect(await status(session, .blocked, sound: "Glass").ok)

        #expect(session.agentIndicator.status == .blocked)
    }

    @Test func aBlockedStatusRefusesAnotherPanesWrite() async throws {
        let session = try newSession()
        _ = harness.actions.splitSession(session.id.uuidString, window: nil, mode: "on")
        _ = await status(session, .blocked, pane: .left)

        let reply = await status(session, .active, pane: .right)

        #expect(reply == ControlResponse(ok: false, error: "blocked status owned by pane left (write from that pane to change it)"))
        #expect(session.agentIndicator.status == .blocked)
    }

    @Test func aContextIsSetAndCleared() throws {
        let session = try newSession()

        #expect(harness.actions.setSessionContext(session.id.uuidString, window: nil, context: "release prep").ok)
        #expect(session.context == "release prep")
        #expect(harness.actions.setSessionContext(session.id.uuidString, window: nil, context: nil).ok)
        #expect(session.context == nil)
    }

    @Test func aNotificationCountsAsUnseen() throws {
        let session = try newSession()

        #expect(harness.actions.sendNotification(session.id.uuidString, window: nil, title: "done", body: "build passed").ok)

        #expect(session.unseenCount == 1)
    }
}
