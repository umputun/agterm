import agtermCore
import Foundation

extension agtermApp {
    @MainActor
    static func applyRemoteLayout(_ layout: PresentationLayout, store: AppStore, sessionID: UUID, library: WindowLibrary) {
        for local in store.applyRemoteLayout(layout, forSession: sessionID) {
            closeRemovedRemotePane(local, store: store, sessionID: sessionID, library: library)
        }
    }

    @MainActor
    static func handleRemotePaneHeld(_ view: GhosttySurfaceView, store: AppStore, sessionID: UUID, library: WindowLibrary) {
        guard let session = store.session(withID: sessionID) else { return }
        let local: UUID
        if session.surface === view {
            local = session.paneIdentity
        } else if session.splitSurface === view, let split = session.splitPaneIdentity {
            local = split
        } else {
            return
        }
        store.remotePaneHeld(local, forSession: sessionID)
        closeRemovedRemotePane(local, store: store, sessionID: sessionID, library: library)
    }

    @MainActor
    private static func closeRemovedRemotePane(_ local: UUID, store: AppStore, sessionID: UUID, library: WindowLibrary) {
        guard store.canCloseRemovedRemotePane(local, forSession: sessionID),
              let session = store.session(withID: sessionID) else { return }
        let split = session.splitPaneIdentity == local
        let surface = split ? session.splitSurface : session.surface
        if split, surface == nil {
            store.closeSplit(sessionID)
            return
        }
        guard let view = surface as? GhosttySurfaceView else { return }
        let survivor = split ? session.surface : session.splitSurface
        // the last replica keeps its terminal until ssh exits; no empty row needs a replacement factory
        guard survivor?.isRealized == true || store.remotePaneIsHeld(local, forSession: sessionID),
              view.claimProcessExit() else { return }
        handlePaneExit(view, store: store, sessionID: sessionID, library: library)
    }
}
