import Foundation
import Testing
@testable import AgtermServerKit
import agtermCore

@MainActor
struct ServerActionsPickTests {
    private let harness: ServerHarness

    init() throws { harness = try ServerHarness() }

    private func pick() -> PendingPick {
        PendingPick(id: UUID().uuidString, items: [ControlPickItem(id: "a", label: "A")])
    }

    @Test func anUntargetedPickNeedsASession() {
        let reply = harness.actions.openPick(pick(), window: nil, follow: false)

        #expect(reply == ControlResponse(ok: false, error: "pick.open needs --session on agterm-server, which has no window to show it in"))
    }

    @Test func aSessionPickWithNoMacPresentingWaitsUnpresented() throws {
        let session = try #require(harness.store.addSession(toWorkspace: harness.store.workspaces[0].id, cwd: "/tmp", select: false))
        let pending = pick()

        let reply = harness.actions.openPick(pending, session: session.id.uuidString, window: nil, follow: false)

        #expect(reply.ok)
        #expect(harness.actions.pickResult(pending.id, window: nil).result?.pick?.result == .pending)
        #expect(harness.actions.openPick(pick(), session: session.id.uuidString, window: nil, follow: false)
            == ControlResponse(ok: false, error: "pick already pending"))
        let node = harness.store.controlTree().workspaces.flatMap(\.sessions).first { $0.id == session.id.uuidString }
        #expect(node?.interactions == [ControlInteraction(kind: "pick", id: pending.id, state: ControlInteraction.unpresented)])
        #expect(harness.actions.cancelPick(pending.id, window: nil).ok)
    }

    @Test func aPickNoFrameCanCarryIsRefusedBeforeBooking() throws {
        let session = try #require(harness.store.addSession(toWorkspace: harness.store.workspaces[0].id, cwd: "/tmp", select: false))
        let items = (0..<1000).map { ControlPickItem(id: "item-\($0)", label: String(repeating: "x", count: 300)) }
        let huge = PendingPick(id: UUID().uuidString, items: items)

        let reply = harness.actions.openPick(huge, session: session.id.uuidString, window: nil, follow: false)

        #expect(reply == ControlResponse(ok: false, error: "pick is too large to send to a Mac"))
        #expect(harness.actions.pickResult(huge.id, window: nil) == ControlResponse(ok: false, error: "unknown pick: \(huge.id)"))
    }

    @Test func aWaitingPickEndsAtItsDeadline() async throws {
        let session = try #require(harness.store.addSession(toWorkspace: harness.store.workspaces[0].id, cwd: "/tmp", select: false))
        var timed = pick()
        timed.deadline = Date().addingTimeInterval(0.1)
        _ = harness.actions.openPick(timed, session: session.id.uuidString, window: nil, follow: false)

        var ended = false
        for _ in 0..<100 where !ended {
            ended = harness.actions.pickResult(timed.id, window: nil).result?.pick?.result == .cancelled
            if !ended { try await Task.sleep(for: .milliseconds(50)) }
        }

        #expect(ended)
    }

    @Test func anUnknownPickIsNamed() {
        let id = UUID().uuidString

        #expect(harness.actions.pickResult(id, window: nil) == ControlResponse(ok: false, error: "unknown pick: \(id)"))
        #expect(harness.actions.cancelPick(id, window: nil) == ControlResponse(ok: false, error: "unknown pick: \(id)"))
    }
}
