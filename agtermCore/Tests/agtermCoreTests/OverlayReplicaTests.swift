import Foundation
import Testing
@testable import agtermCore

@MainActor
struct OverlayReplicaTests {
    let store = AppStore(persistence: PersistenceStore(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent("agterm-tests-\(UUID().uuidString)")))

    @Test func onlyAnOverlaySurfaceShowingAReplicaJobRunsOnTheOrigin() throws {
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp", remoteHost: "buildbox"))
        store.toggleSplit(session.id)
        #expect(store.openOverlay(session.id, command: "ssh buildbox run-job j"))
        #expect(store.openPaneOverlay(session.id, pane: .right, command: "less log") == nil)
        let full = SpySurface(), pane = SpySurface()
        session.overlaySurface = full
        session.setPaneOverlaySurface(pane, pane: .right)
        #expect(!session.overlayRunsOnOrigin(full))

        session.setOverlayReplica(OverlayReplica(job: "j"), pane: nil)

        #expect(session.overlayRunsOnOrigin(full))
        #expect(!session.overlayRunsOnOrigin(pane))
        session.setOverlayReplica(OverlayReplica(job: "k"), pane: .right)
        #expect(session.overlayRunsOnOrigin(pane))
        #expect(!session.overlayRunsOnOrigin(SpySurface()))
    }
}
