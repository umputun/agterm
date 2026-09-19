import Foundation

/// What `openRemoteOverlay` did with a request.
public enum RemoteOverlayOpen: Equatable, Sendable {
    /// No viewer presents the session; the caller opens the overlay here.
    case notPresented
    /// The slot holds an overlay, local or remote.
    case slotTaken
    /// The origin has no pane in the requested role.
    case paneMissing
    /// The launch context is larger than the helper reads in one frame.
    case tooLarge
    case opened(job: String)
}

// MARK: - Overlays handed to the viewer presenting a session, on the origin

extension AppStore {
    /// Hands an overlay to the viewer presenting `sessionID`: registers the job, reserves the slot so no
    /// second overlay opens on it, and asks the presenter to show it. Nothing is mounted here, so the session
    /// stays uncovered on this Mac. The slot's previous result is cleared, as a local open clears it.
    public func openRemoteOverlay(_ sessionID: UUID, options: ControlSessionOverlayOpenOptions,
                                  context: OverlayLaunchContext) -> RemoteOverlayOpen {
        let pane = options.pane
        guard let hub = presentationHub, let jobs = overlayJobs, hub.hasPresenter(session: sessionID),
              let session = session(withID: sessionID) else { return .notPresented }
        guard session.remoteOverlays.slot(pane) == nil, !localOverlayHolds(pane, in: session) else { return .slotTaken }
        let identity = pane.map { $0 == .right ? session.splitPaneIdentity : session.paneIdentity }
        if case .some(nil) = identity { return .paneMissing }
        guard let frame = try? OverlayJobFrame.context(context).line(),
              frame.count <= PresentationCodec.maxFrameBytes else { return .tooLarge }
        // a HUD yields the session-wide slot to a program, as it does to a local one
        if pane == nil, session.hudActive { closeHud(sessionID) }
        let owner = hub.presenterGeneration(session: sessionID)
        let job = jobs.register(session: sessionID, pane: pane, owner: owner, context: context)
        let size = pane == nil ? options.sizePercent.map { min(100, max(1, $0)) } : nil
        session.remoteOverlays.reserve(RemoteOverlaySlot(job: job, pane: pane, owner: owner, sizePercent: size,
                                                              wait: options.wait))
        clearOverlayExitCode(pane, in: session)
        hub.sendToPresenter(.overlayRequest(PresentationOverlay(
            job: job, pane: identity.flatMap { $0 }.map { .identity($0) }, sizePercent: size, backgroundColor: options.backgroundColor,
            follow: options.follow, wait: options.wait)), session: sessionID)
        return .opened(job: job)
    }

    /// Records a remote job's first outcome into its slot's result, an exit code where a local overlay keeps
    /// one and a failure name for an outcome that has none, and frees the slot unless a held `--wait`
    /// surface still occupies it on the viewer.
    public func finishRemoteOverlay(_ job: OverlayJob) {
        guard let session = session(withID: job.session),
              let slot = session.remoteOverlays.end(job: job.id) else { return }
        guard case .finished(let outcome) = job.state else { return }
        switch outcome {
        case .exited(let code):
            if let pane = slot.pane {
                session.setPaneOverlayExitCode(code, pane: pane)
            } else {
                session.overlayExitCode = code
            }
        case .canceled, .launchFailed, .unknown:
            session.remoteOverlays.recordFailure(outcome.failureName ?? "unknown", pane: slot.pane)
        }
    }

    /// Closes the remote overlay on a slot: an unclaimed job ends at once, a running one through its
    /// helper, a held surface whose program ended is freed, and the presenter is asked to take its surface
    /// down. It reports the request, not the program's end, which `session.overlay.result` answers. False
    /// when no viewer holds the slot.
    @discardableResult
    public func closeRemoteOverlay(_ sessionID: UUID, pane: OverlayPane?) -> Bool {
        guard let session = session(withID: sessionID), let slot = session.remoteOverlays.slot(pane) else { return false }
        presentationHub?.sendToPresenter(.overlayClose(PresentationOverlayChange(job: slot.job)), session: sessionID)
        session.remoteOverlays.surfaceGone(job: slot.job)
        overlayJobs?.cancel(slot.job)
        return true
    }

    /// The viewer closed its surface for `job`, so a slot held only for that surface is freed.
    public func remoteOverlaySurfaceClosed(_ job: String, forSession sessionID: UUID) {
        session(withID: sessionID)?.remoteOverlays.surfaceGone(job: job)
    }

    /// Asks the presenter to resize a session-wide remote overlay and records the requested size. Nil when no
    /// viewer holds the slot, false when the stream the job was handed to is gone, even if another is up.
    public func resizeRemoteOverlay(_ sessionID: UUID, sizePercent: Int?) -> Bool? {
        guard let session = session(withID: sessionID), let slot = session.remoteOverlays.slot(nil) else { return nil }
        guard let hub = presentationHub, hub.hasPresenter(session: sessionID),
              hub.presenterGeneration(session: sessionID) == slot.owner else { return false }
        let size = sizePercent.map { min(100, max(1, $0)) }
        session.remoteOverlays.resize(job: slot.job, sizePercent: size)
        return hub.sendToPresenter(.overlayResize(PresentationOverlayChange(job: slot.job, sizePercent: size)),
                                   session: sessionID)
    }

    /// The viewer presenting `sessionID` is gone, and every overlay it held goes with it for good: a later
    /// stream never adopts one. An unclaimed job is cancelled and can no longer launch, a slot whose program
    /// already ended is freed, and a claimed or running job keeps its slot until its helper reports.
    public func remoteOverlayPresenterLost(forSession sessionID: UUID) {
        guard let session = session(withID: sessionID) else { return }
        for slot in session.remoteOverlays.slots {
            session.remoteOverlays.surfaceGone(job: slot.job)
            if case .unclaimed? = overlayJobs?.job(slot.job)?.state { overlayJobs?.cancel(slot.job) }
        }
    }

    /// Fails a job its presenter refused to show, before any helper claimed it.
    public func rejectRemoteOverlay(_ job: String, forSession sessionID: UUID) {
        guard let session = session(withID: sessionID), session.remoteOverlays.slot(job: job) != nil else { return }
        // no surface was ever shown, so a --wait slot has nothing left to hold it
        session.remoteOverlays.surfaceGone(job: job)
        overlayJobs?.finish(job, .launchFailed)
    }

    /// `pane` is gone on this Mac: its job is ended and its slot and result dropped, since nothing is left
    /// for a late outcome to describe.
    func dropRemoteOverlay(_ pane: OverlayPane, of session: Session) {
        if let slot = session.remoteOverlays.slot(pane) {
            closeRemoteOverlay(session.id, pane: pane)
            session.remoteOverlays.remove(job: slot.job)
        }
        session.remoteOverlays.clearFailure(pane)
    }

    /// Ends what `session` handed out or took over before it leaves this store, soft close included: its
    /// ask, its overlays shown on viewers, and the replicas it shows for an origin. Neither side's cleanup
    /// can find a session once it is gone, and an undo must bring back neither a reservation nor a replica
    /// whose held exit went unseen, so each ends now.
    func releaseLeavingSession(_ session: Session) {
        session.cancelPendingAsk()
        for slot in session.remoteOverlays.slots { closeRemoteOverlay(session.id, pane: slot.pane) }
        session.remoteOverlays = RemoteOverlays()
        for slot in session.overlayReplicas { closeReplicaOverlay(slot.replica.job, forSession: session.id) }
    }

    /// `remoteOverlays` read-back: one entry per slot a viewer holds.
    func remoteOverlayNodes(of session: Session) -> [ControlRemoteOverlayNode]? {
        let slots = session.remoteOverlays.slots
        guard !slots.isEmpty else { return nil }
        return slots.map { ControlRemoteOverlayNode(pane: $0.pane?.rawValue, sizePercent: $0.sizePercent) }
    }

    private func localOverlayHolds(_ pane: OverlayPane?, in session: Session) -> Bool {
        guard let pane else { return session.programOverlayActive }
        return session.paneOverlay(pane) != nil
    }

    private func clearOverlayExitCode(_ pane: OverlayPane?, in session: Session) {
        if let pane {
            session.setPaneOverlayExitCode(nil, pane: pane)
        } else {
            session.overlayExitCode = nil
        }
    }
}
