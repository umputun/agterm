import Foundation
import agtermCore

/// The streams themselves are agtermCore's `PresentationStreamHost`, shared with agterm-server; this Mac adds the
/// store wiring and its respawn generations.
extension ControlServer: PresentationStreamHost {
    /// Answers `zmx.present`. The stream itself starts only after this reply is on the wire.
    func openPresentation(session target: String) -> ControlResponse {
        resolver.resolveSession(target, window: nil) { store, id in
            guard let session = store.session(withID: id) else {
                return ControlResponse(ok: false, error: "no such session")
            }
            guard session.allPanesBackedByZmx else {
                return ControlResponse(ok: false, error: "session is not live-backed, so nothing can be attached to it")
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    func presentationSnapshot(forSession id: UUID) -> PresentationSnapshot {
        var snapshot = library.store(forSession: id)?.presentationSnapshot(forSession: id, now: hudClock())
            ?? PresentationSnapshot(status: nil, hud: nil)
        snapshot.respawns = PresentationRespawns(epoch: originEpoch, generations: respawnGenerations[id] ?? [:])
        return snapshot
    }

    func prepareForPresentationStream() { attachPresentationHub() }

    /// Points every open store at the hub. Stores are created by the window library, which this file cannot
    /// reach into, so the server assigns wherever it already walks the open windows.
    func attachPresentationHub() {
        presentationHub.onPresenterLost = { [weak self] session in
            self?.takeBackRemoteAsk(forSession: session)
            self?.takeBackRemotePick(forSession: session)
            self?.library.store(forSession: session)?.remoteOverlayPresenterLost(forSession: session)
        }
        presentationHub.onPresenterFrame = { [weak self] session, body in
            self?.receivePresenterFrame(body, forSession: session)
        }
        RemotePageEnds.shared.onEnd = { [weak self] page in self?.pageServeStreams[page]?.shutdown() }
        HtmlOverlayReleases.shared.onReplicaRelease = { [weak self] local, origin in self?.replicaPageReleased(local, origin: origin) }
        overlayJobs.onFinished = { [weak self] job in
            self?.pendingJobCancels.remove(job.id)
            self?.library.store(forSession: job.session)?.finishRemoteOverlay(job)
        }
        for entry in library.windows {
            guard let store = library.store(for: entry.id) else { continue }
            store.presentationHub = presentationHub
            store.overlayJobs = overlayJobs
            store.onRemoteRowVisibility = { [weak self] session, shown in
                MainActor.assumeIsolated { self?.remoteRowVisibilityChanged(session, shown: shown) }
            }
            store.onReplicaPageChanged = { [weak self] page in MainActor.assumeIsolated { self?.replicaPageChanged(page) } }
        }
        dropOrphanedPresentationStreams()
    }

    func presentationSourceExists(_ session: UUID) -> Bool {
        library.store(forSession: session)?.session(withID: session) != nil
    }
}
