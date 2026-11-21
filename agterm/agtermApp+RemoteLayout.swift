import agtermCore
import Foundation

extension agtermApp {
    @MainActor
    static func applyRemoteLayout(_ layout: PresentationLayout, store: AppStore, sessionID: UUID, library: WindowLibrary,
                                  attach: RemoteAttachLines) {
        for local in store.applyRemoteLayout(layout, forSession: sessionID, attach: attach) {
            closeRemovedRemotePane(local, store: store, sessionID: sessionID, library: library, attach: attach)
        }
    }

    @MainActor
    static func handleRemotePaneHeld(_ view: GhosttySurfaceView, store: AppStore, sessionID: UUID, library: WindowLibrary,
                                     attach: RemoteAttachLines?) {
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
        closeRemovedRemotePane(local, store: store, sessionID: sessionID, library: library, attach: attach)
    }

    /// closeEndedRemoteRow closes the replicas of a row whose origin removed the session for good; the row goes with its
    /// last one, which keeps its terminal until ssh exits.
    @MainActor
    static func closeEndedRemoteRow(store: AppStore, sessionID: UUID, library: WindowLibrary) {
        for local in store.remoteSessionEnded(forSession: sessionID) {
            closeRemovedRemotePane(local, store: store, sessionID: sessionID, library: library, attach: nil)
        }
    }

    /// closeRemovedRemotePane closes a replica its origin removed, then attaches what the origin added in its place.
    @MainActor
    private static func closeRemovedRemotePane(_ local: UUID, store: AppStore, sessionID: UUID, library: WindowLibrary,
                                               attach: RemoteAttachLines?) {
        guard store.canCloseRemovedRemotePane(local, forSession: sessionID),
              let session = store.session(withID: sessionID) else { return }
        defer { attach.map { store.attachOriginAdditions(forSession: sessionID, attach: $0) } }
        let split = session.splitPaneIdentity == local
        let surface = split ? session.splitSurface : session.surface
        if split, surface == nil {
            store.closeSplit(sessionID)
            return
        }
        let ended = session.remotePresentation?.originEnded == true
        guard let view = surface as? GhosttySurfaceView else {
            if ended, surface == nil { _ = store.closePrimaryPane(sessionID) }
            return
        }
        let survivor = split ? session.surface : session.splitSurface
        // the last replica keeps its terminal until ssh exits; no empty row needs a replacement factory. One of an
        // ended row that never spawned has no exit coming and nothing on screen to keep.
        let unspawned = ended && !view.isRealized
        guard survivor?.isRealized == true || store.remotePaneIsHeld(local, forSession: sessionID) || unspawned,
              view.claimProcessExit() else { return }
        handlePaneExit(view, store: store, sessionID: sessionID, library: library)
    }
}
