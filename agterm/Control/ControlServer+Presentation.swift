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
            // a page row has no pane; a remote window's viewer presents it for its asks and picks
            guard session.allPanesBackedByZmx || (session.content == .page && session.remoteHost == nil) else {
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
        // what the lost viewer held is placed by the pass the hub schedules after this
        presentationHub.onOwnerLost = { [weak self] session, owner in
            self?.library.store(forSession: session)?.remoteOverlayOwnerLost(forSession: session, owner: owner)
        }
        presentationHub.onOpenWork = { [weak self] session in self?.reconcileOpenWork(forSession: session) }
        presentationHub.onPresenterFrame = { [weak self] session, sender, body in
            self?.receivePresenterFrame(body, forSession: session, from: sender)
        }
        RemotePageEnds.shared.onEnd = { [weak self] page in self?.pageServeStreams[page]?.shutdown() }
        RemotePageEnds.shared.onWithdrawn = { [weak self] page in
            self?.pendingPageClaims = self?.pendingPageClaims.filter { $0.value.page != page } ?? [:]
            self?.pageServeStreams.removeValue(forKey: page)?.shutdown()
        }
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
        resumeRestoredAttachedRows()
        mailRelay.start()
        trackOpenWorkPlaces()
    }

    /// publishPresentationMail sends each viewed session's mail counts through the store hosting it.
    func publishPresentationMail() {
        for id in presentationHub.subscribedSessions {
            library.store(forSession: id)?.publishPresentationMail(forSession: id)
        }
    }

    /// reconcileOpenWork places `id`'s open ask, pick and pages where its pane's lead now is, this Mac included.
    func reconcileOpenWork(forSession id: UUID) {
        defer { trackOpenWorkPlaces() }
        guard let store = library.store(forSession: id), let windowID = library.windowID(for: store) else { return }
        let local = OpenWorkLocal(modal: { _ in PickRegistry.shared.controller(for: windowID).map { ($0, windowID) } },
                                  showsGuiAsk: { [weak self] session in self?.guiAskFits(session, in: store, windowID: windowID) == true })
        guard store.reconcileOpenWork(forSession: id, now: hudClock(), local: local).offered else { return }
        scheduleOverlayJobExpiry(after: OverlayJobs.launchWindow)
        schedulePageClaimExpiry(after: AppStore.pageClaimWindow)
    }

    /// trackOpenWorkPlaces runs a pass for every viewed session once anything a pass reads here changes: this Mac's
    /// lead of a pane, the window modal, whether a GUI ask could be seen, and the local slots a page would take.
    /// Obsolete trackers still deliver changes; only the newest re-arms.
    func trackOpenWorkPlaces() {
        openWorkTracking &+= 1
        let generation = openWorkTracking
        withObservationTracking {
            for id in presentationHub.subscribedSessions { readOpenWorkPlaces(of: id) }
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for id in self.presentationHub.subscribedSessions { self.presentationHub.scheduleOpenWork(id) }
                    guard generation == self.openWorkTracking else { return }
                    self.trackOpenWorkPlaces()
                }
            }
        }
    }

    private func readOpenWorkPlaces(of id: UUID) {
        guard let store = library.store(forSession: id), let session = store.session(withID: id),
              let windowID = library.windowID(for: store) else { return }
        for pane in [session.paneIdentity, session.splitPaneIdentity].compactMap({ $0 }) { _ = ZmxLeadBook.shared.role(pane: pane) }
        _ = PickRegistry.shared.controller(for: windowID)?.modalPending
        _ = guiAskFits(session, in: store, windowID: windowID)
        _ = session.askPending
        _ = (session.overlayActive, session.hudActive)
        for pane in OverlayPane.allCases { _ = (session.paneOverlay(pane) != nil, session.rendersPane(pane)) }
    }

    func presentationSourceExists(_ session: UUID) -> Bool {
        library.store(forSession: session)?.session(withID: session) != nil
    }
}
