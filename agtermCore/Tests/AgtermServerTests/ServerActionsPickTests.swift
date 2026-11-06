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

    @Test func aSessionPickWithNoMacPresentingIsRefused() throws {
        let session = try #require(harness.store.addSession(toWorkspace: harness.store.workspaces[0].id, cwd: "/tmp", select: false))

        let reply = harness.actions.openPick(pick(), session: session.id.uuidString, window: nil, follow: false)

        #expect(reply == ControlResponse(ok: false, error: "no connected Mac to show the pick"))
    }

    @Test func anUnknownPickIsNamed() {
        let id = UUID().uuidString

        #expect(harness.actions.pickResult(id, window: nil) == ControlResponse(ok: false, error: "unknown pick: \(id)"))
        #expect(harness.actions.cancelPick(id, window: nil) == ControlResponse(ok: false, error: "unknown pick: \(id)"))
    }
}
