import Foundation
import Testing
@testable import AgtermServerKit
import agtermCore

@MainActor
struct ServerActionsHudTests {
    private let harness: ServerHarness

    init() throws { harness = try ServerHarness() }

    private func newSession() throws -> Session {
        try harness.session(harness.actions.createSession(ControlSessionCreateOptions(
            window: nil, cwd: nil, workspace: nil, workspaceName: nil, createWorkspace: nil, command: nil, wait: nil,
            name: nil, after: nil, before: nil, noSelect: false)))
    }

    private func node(_ session: Session) -> ControlSessionNode? {
        harness.store.controlTree().workspaces.flatMap(\.sessions).first { $0.id == session.id.uuidString }
    }

    @Test func aHudHoldsTheSlotWithItsSpecAndNoGeometry() throws {
        let session = try newSession()

        #expect(harness.actions.openHud(session.id.uuidString, window: nil, spec: HudSpec(message: "building")).ok)

        #expect(session.hudActive)
        #expect(session.overlayCommand == nil)
        #expect(session.hudFile == nil)
        let hud = try #require(node(session)?.hud)
        #expect(hud.message == "building")
        #expect(hud.sizePercent == nil)
        #expect(hud.heightPercent == nil)
    }

    @Test func anUpdateReplacesTheMessageAndCloseEndsIt() throws {
        let session = try newSession()
        _ = harness.actions.openHud(session.id.uuidString, window: nil, spec: HudSpec(message: "building"))

        #expect(harness.actions.updateHud(session.id.uuidString, window: nil, spec: HudSpec(message: "testing")).ok)
        #expect(node(session)?.hud?.message == "testing")
        #expect(harness.actions.closeHud(session.id.uuidString, window: nil).ok)

        #expect(!session.hudActive)
        #expect(harness.actions.closeHud(session.id.uuidString, window: nil) == ControlResponse(ok: false, error: OverlayHudError.noHud))
    }

    @Test func anUpdateWithNoHudIsRefused() throws {
        let session = try newSession()

        #expect(harness.actions.updateHud(session.id.uuidString, window: nil, spec: HudSpec(message: "x"))
            == ControlResponse(ok: false, error: OverlayHudError.noHud))
    }

    @Test func aHudOnAPaneTheSessionDoesNotShowIsRefused() throws {
        let session = try newSession()

        let reply = harness.actions.openHud(session.id.uuidString, window: nil, spec: HudSpec(message: "x"),
                                            placement: ControlHudPlacement(pane: .right))

        #expect(reply == ControlResponse(ok: false, error: PaneOverlayError.paneNotVisible))
    }

    @Test func aHudWithHideAfterClosesItself() async throws {
        let session = try newSession()

        _ = harness.actions.openHud(session.id.uuidString, window: nil, spec: HudSpec(message: "done", hideAfter: 0.2))
        let timer = try #require(harness.actions.hudAutoHide[session.id]?.task)

        await timer.value

        #expect(!session.hudActive)
    }
}
