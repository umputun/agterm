import Foundation
import Testing
@testable import agtermCore

@MainActor
struct FailureHudOwnerTests {
    private func makeSession() -> (store: AppStore, session: Session) {
        let store = AppStore()
        let workspace = store.addWorkspace(name: "work")
        return (store, store.addSession(toWorkspace: workspace.id, cwd: "/a")!)
    }

    private func openHud(_ store: AppStore, _ session: Session, message: String) {
        store.openHud(session.id, command: "hud.sh", spec: HudSpec(message: message), file: "/tmp/body",
                      size: HudPanelSize(widthPercent: 20, heightPercent: 9))
    }

    @Test func ownsThePanelItRecorded() {
        let (store, session) = makeSession()
        openHud(store, session, message: "failed")
        #expect(FailureHudOwner(session: session).owns(session))
    }

    @Test func doesNotOwnAHudOpenedAfterIt() {
        let (store, session) = makeSession()
        openHud(store, session, message: "failed")
        let owner = FailureHudOwner(session: session)
        openHud(store, session, message: "a script's own progress")
        #expect(!owner.owns(session), "the replacement belongs to whoever posted it")
    }

    @Test func doesNotOwnAnEmptySlot() {
        let (store, session) = makeSession()
        openHud(store, session, message: "failed")
        let owner = FailureHudOwner(session: session)
        store.closeHud(session.id)
        #expect(!owner.owns(session))
    }

    @Test func doesNotOwnASessionShowingNoHudAtAll() {
        let (_, session) = makeSession()
        #expect(!FailureHudOwner(session: session).owns(session))
    }

    @Test func doesNotOwnARestoredSessionWearingTheSameIdAndGeneration() {
        let (store, session) = makeSession()
        openHud(store, session, message: "failed")
        let owner = FailureHudOwner(session: session)

        // what a window reload produces: same UUID, fresh object, slot generation counted from zero again.
        let restored = Session(id: session.id, initialCwd: "/a")
        restored.overlayActive = true
        restored.hudSpec = HudSpec(message: "a panel of its own")
        restored.overlaySlotGeneration = session.overlaySlotGeneration

        #expect(restored.id == session.id)
        #expect(restored.hudActive)
        #expect(!owner.owns(restored), "identity is the object, not the id it carries")
    }
}
