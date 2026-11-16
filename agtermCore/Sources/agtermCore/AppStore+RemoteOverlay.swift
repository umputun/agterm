import Foundation

/// What `openRemoteOverlay` did with a request.
public enum RemoteOverlayOpen: Equatable, Sendable {
    /// The caller opens the overlay here.
    case notPresented
    /// The slot holds an overlay, local or remote.
    case slotTaken
    /// The origin has no pane in the requested role.
    case paneMissing
    /// The launch context is larger than the helper reads in one frame.
    case tooLarge
    /// pointsUnsupported is never returned; it stays for agterm-linux, whose switches still name it.
    case pointsUnsupported
    case opened(job: String)
}

/// RemoteOverlayResize is the result of a remote resize request.
public enum RemoteOverlayResize: Equatable, Sendable {
    case sent
    /// viewerGone: the stream the slot was handed to is gone, even if another is up.
    case viewerGone
    /// notFloating: points alone need a floating overlay whose percent the other axis keeps.
    case notFloating

    /// error is what a refused resize answers with, nil once it was sent.
    public var error: String? {
        switch self {
        case .sent: nil
        case .viewerGone: OverlayResultError.viewerGone
        case .notFloating: OverlayPointError.notFloating
        }
    }
}

// MARK: - Overlays handed to the viewer presenting a session, on the origin

extension AppStore {
    /// Hands an overlay to the viewer leading its pane: registers the job, reserves the slot so no second overlay
    /// opens on it, and asks that viewer to show it. Nothing is mounted here, so the session stays uncovered on this
    /// Mac. The slot's previous result is cleared, as a local open clears it.
    public func openRemoteOverlay(_ sessionID: UUID, options: ControlSessionOverlayOpenOptions,
                                  context: OverlayLaunchContext) -> RemoteOverlayOpen {
        let pane = options.pane
        // a headless origin holds the overlay for a viewer to come; a Mac shows it here
        guard let hub = presentationHub, let jobs = overlayJobs, hub.subscriberCount(session: sessionID) > 0 || headless,
              let session = session(withID: sessionID) else { return .notPresented }
        guard session.remoteOverlays.slot(pane) == nil, !localOverlayHolds(pane, in: session) else { return .slotTaken }
        let identity = pane.map { $0 == .right ? session.splitPaneIdentity : session.paneIdentity }
        if case .some(nil) = identity { return .paneMissing }
        let owner = remoteRecipient(session, paneIdentity: identity.flatMap { $0 })
        guard owner != nil || headless else { return .notPresented }
        guard let frame = try? OverlayJobFrame.context(context).line(),
              frame.count <= PresentationCodec.maxFrameBytes else { return .tooLarge }
        // a HUD yields the session-wide slot to a program, as it does to a local one
        if pane == nil, session.hudActive { closeHud(sessionID) }
        let size = pane == nil ? options.sizePercent.map { min(100, max(1, $0)) } : nil
        guard let owner else {
            let job = jobs.registerUnpresented(session: sessionID, pane: pane, context: context)
            var slot = RemoteOverlaySlot(job: job, pane: pane, owner: nil, sizePercent: size, wait: options.wait)
            if size != nil { slot.points = options.points }
            slot.request = PresentationOverlay(job: job, pane: identity.flatMap { $0 }.map { .identity($0) }, sizePercent: size,
                                               points: slot.points, backgroundColor: options.backgroundColor,
                                               follow: options.follow, wait: options.wait)
            session.remoteOverlays.reserve(slot)
            clearOverlayExitCode(pane, in: session)
            scheduleTreeChanged()
            return .opened(job: job)
        }
        let token = hub.supports(PresentationHub.jobTokenKind, owner: owner) ? UUID().uuidString : nil
        let job = jobs.register(session: sessionID, pane: pane, owner: owner, context: context, token: token)
        var slot = RemoteOverlaySlot(job: job, pane: pane, owner: owner, sizePercent: size, wait: options.wait)
        if size != nil { slot.points = options.points }
        let request = PresentationOverlay(job: job, pane: identity.flatMap { $0 }.map { .identity($0) }, sizePercent: size,
                                          points: slot.points, backgroundColor: options.backgroundColor,
                                          follow: options.follow, wait: options.wait)
        slot.request = request
        session.remoteOverlays.reserve(slot)
        clearOverlayExitCode(pane, in: session)
        scheduleTreeChanged()
        var sent = request
        sent.points = presentablePoints(request.points, owner: owner)
        sent.token = token
        hub.send(.overlayRequest(sent), toOwner: owner)
        return .opened(job: job)
    }

    /// offerPendingOverlay hands the program a headless origin holds in `slot` to the viewer its pane routes to, with
    /// a fresh offer token; false when nothing there waits.
    @discardableResult
    func offerPendingOverlay(_ slot: RemoteOverlaySlot, in session: Session) -> Bool {
        guard slot.owner == nil, slot.page == nil, var request = slot.request, let hub = presentationHub, let jobs = overlayJobs,
              let owner = pendingRecipient(session, paneIdentity: request.pane?.identity) else { return false }
        let token = UUID().uuidString
        guard jobs.offer(slot.job, owner: owner, token: token) else { return false }
        trackingSlots(of: session) {
            session.remoteOverlays.update(job: slot.job) { $0.owner = owner; $0.wait = request.wait }
        }
        request.sizePercent = slot.sizePercent
        request.points = presentablePoints(slot.points, owner: owner)
        request.token = token
        hub.send(.overlayRequest(request), toOwner: owner)
        return true
    }

    /// Records a remote job's first outcome into its slot's result, an exit code where a local overlay keeps
    /// one and a failure name for an outcome that has none, and frees the slot unless a held `--wait`
    /// surface still occupies it on the viewer.
    public func finishRemoteOverlay(_ job: OverlayJob) {
        guard let session = session(withID: job.session) else { return }
        var ended: RemoteOverlaySlot?
        trackingSlots(of: session) { ended = session.remoteOverlays.end(job: job.id) }
        guard let slot = ended else { return }
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
    /// helper, a held surface whose program ended is freed, and the viewer showing it is asked to take its surface
    /// down. It reports the request, not the program's end, which `session.overlay.result` answers. False
    /// when no viewer holds the slot.
    @discardableResult
    public func closeRemoteOverlay(_ sessionID: UUID, pane: OverlayPane?) -> Bool {
        guard let session = session(withID: sessionID), let slot = session.remoteOverlays.slot(pane) else { return false }
        if slot.page != nil {
            if let owner = slot.owner { presentationHub?.send(.pageClose(PresentationPageChange(page: slot.job)), toOwner: owner) }
            endRemotePage(slot.job, in: session)
            return true
        }
        if let owner = slot.owner { presentationHub?.send(.overlayClose(PresentationOverlayChange(job: slot.job)), toOwner: owner) }
        trackingSlots(of: session) { session.remoteOverlays.surfaceGone(job: slot.job) }
        overlayJobs?.cancel(slot.job)
        return true
    }

    /// The viewer `sender` closed its surface for `job`, so a slot held only for that surface is freed. A close from a
    /// viewer the job was not handed to changes nothing.
    public func remoteOverlaySurfaceClosed(_ job: String, forSession sessionID: UUID, from sender: Int) {
        guard let session = session(withID: sessionID), session.remoteOverlays.slot(job: job)?.owner == sender else { return }
        trackingSlots(of: session) { session.remoteOverlays.surfaceGone(job: job) }
    }

    /// Asks the viewer showing a session-wide remote overlay to resize it and records the requested size. Nil when no
    /// viewer holds the slot, false when the stream the job was handed to is gone, even if another is up.
    public func resizeRemoteOverlay(_ sessionID: UUID, sizePercent: Int?) -> Bool? {
        switch resizeRemoteOverlay(sessionID, sizePercent: sizePercent, points: OverlayPointSize()) {
        case nil: nil
        case .sent: true
        case .viewerGone, .notFloating: false
        }
    }

    /// resizeRemoteOverlay sends the resolved size because the presenter replaces its state, except a point resize of
    /// a picture the presenter sized, which sends only its axes to merge; nil means no remote slot.
    public func resizeRemoteOverlay(_ sessionID: UUID, sizePercent: Int?, points: OverlayPointSize) -> RemoteOverlayResize? {
        guard let session = session(withID: sessionID), let slot = session.remoteOverlays.slot(nil) else { return nil }
        guard let hub = presentationHub, let owner = slot.owner, hub.isConnected(owner: owner) else { return .viewerGone }
        let size: Int?
        let merged: OverlayPointSize
        if let sizePercent {
            size = min(100, max(1, sizePercent))
            merged = points
        } else if points.isEmpty {
            size = nil
            merged = OverlayPointSize()
        } else {
            guard let current = slot.sizePercent else { return .notFloating }
            size = current
            merged = slot.points.merging(points)
        }
        // a picture the presenter fitted keeps its fitted axes there: a point resize sends only its own axes to merge,
        // and any other resize replaces the size whole and ends that
        let merge = slot.presenterSized && sizePercent == nil && !points.isEmpty
        session.remoteOverlays.resize(job: slot.job, sizePercent: size, points: merged, presenterSized: merge)
        let sent = presentablePoints(merge ? points : merged, owner: owner)
        let delivered = slot.page != nil
            ? sendRemotePageCommand(sessionID, pane: nil, action: .resize, sizePercent: size, points: sent, merge: merge ? true : nil)
            : hub.send(.overlayResize(PresentationOverlayChange(job: slot.job, sizePercent: size, points: sent)), toOwner: owner)
        return delivered ? .sent : .viewerGone
    }

    func presentablePoints(_ points: OverlayPointSize, owner: Int) -> OverlayPointSize {
        presentationHub?.supports(PresentationHub.overlayPointsKind, owner: owner) == true ? points : OverlayPointSize()
    }

    /// The viewer `owner` of `sessionID` is gone. On a Mac every overlay it held goes with it for good: an unclaimed
    /// job is cancelled and can no longer launch, a slot whose program already ended is freed, and a claimed or running
    /// job keeps its slot until its helper reports. A headless origin keeps pages and unclaimed jobs for another viewer.
    /// What other viewers hold stays with them.
    public func remoteOverlayOwnerLost(forSession sessionID: UUID, owner: Int) {
        guard let session = session(withID: sessionID) else { return }
        if headless { return withdrawRemoteOverlays(of: session, owner: owner) }
        for slot in session.remoteOverlays.slots where slot.owner == owner {
            if slot.page != nil {
                endRemotePage(slot.job, in: session)
                continue
            }
            trackingSlots(of: session) { session.remoteOverlays.surfaceGone(job: slot.job) }
            if case .unclaimed? = overlayJobs?.job(slot.job)?.state { overlayJobs?.cancel(slot.job) }
        }
    }

    /// withdrawRemoteOverlays takes back, on a headless origin, what the lost viewer `owner` held without a running
    /// program: every page, shown or claimed, and every job no helper claimed wait for another viewer. A claimed or
    /// running job keeps its slot until its helper reports, as on a Mac, and is never launched again.
    private func withdrawRemoteOverlays(of session: Session, owner: Int) {
        for slot in session.remoteOverlays.slots where slot.owner == owner {
            if let page = slot.page {
                session.remoteOverlays.update(job: slot.job) { $0.owner = nil }
                session.remoteOverlays.updatePage(slot.job) { $0.claimed = false }
                settleRemoteTextWaits(job: slot.job)
                RemotePageEnds.shared.onWithdrawn?(page.overlay.id)
                continue
            }
            if overlayJobs?.withdraw(slot.job) == true {
                session.remoteOverlays.update(job: slot.job) { $0.owner = nil }
                continue
            }
            trackingSlots(of: session) { session.remoteOverlays.surfaceGone(job: slot.job) }
        }
        scheduleTreeChanged()
    }

    /// Fails a job the viewer `sender` it was handed to refused to show, before any helper claimed it.
    public func rejectRemoteOverlay(_ job: String, forSession sessionID: UUID, from sender: Int) {
        guard let session = session(withID: sessionID), session.remoteOverlays.slot(job: job)?.owner == sender else { return }
        // no surface was ever shown, so a --wait slot has nothing left to hold it
        trackingSlots(of: session) { session.remoteOverlays.surfaceGone(job: job) }
        overlayJobs?.finish(job, .launchFailed)
    }

    /// `pane` is gone on this Mac: its job is ended and its slot and result dropped, since nothing is left
    /// for a late outcome to describe.
    func dropRemoteOverlay(_ pane: OverlayPane, of session: Session) {
        if let slot = session.remoteOverlays.slot(pane) {
            closeRemoteOverlay(session.id, pane: pane)
            trackingSlots(of: session) { session.remoteOverlays.remove(job: slot.job) }
        }
        session.remoteOverlays.clearFailure(pane)
    }

    /// Ends what `session` handed out or took over before it leaves this store, soft close included: its
    /// ask, its overlays shown on viewers, and the replicas it shows for an origin. Neither side's cleanup
    /// can find a session once it is gone, and an undo must bring back neither a reservation nor a replica
    /// whose held exit went unseen, so each ends now.
    func releaseLeavingSession(_ session: Session) {
        session.cancelPendingAsk()
        SessionPickBook.shared.sessionEnded(session.id)
        disposeMailboxes(of: session)
        for slot in session.remoteOverlays.slots { closeRemoteOverlay(session.id, pane: slot.pane) }
        session.remoteOverlays = RemoteOverlays()
        for slot in session.overlayReplicas { closeReplicaOverlay(slot.replica.job, forSession: session.id) }
        closeReplicaPages(of: session)
    }

    /// `remoteOverlays` read-back: one entry per slot a viewer holds.
    func remoteOverlayNodes(of session: Session) -> [ControlRemoteOverlayNode]? {
        let slots = session.remoteOverlays.slots
        guard !slots.isEmpty else { return nil }
        return slots.map {
            ControlRemoteOverlayNode(pane: $0.pane?.rawValue, sizePercent: $0.sizePercent, pageID: $0.page?.overlay.id.uuidString)
        }
    }

    /// Runs `change` and invalidates the tree when it took or freed a slot. Not every call does: a held
    /// `--wait` slot outlives its job, and a slot can already be gone.
    private func trackingSlots(of session: Session, _ change: () -> Void) {
        let before = session.remoteOverlays.slots.map(\.job)
        change()
        if session.remoteOverlays.slots.map(\.job) != before { scheduleTreeChanged() }
    }

    func localOverlayHolds(_ pane: OverlayPane?, in session: Session) -> Bool {
        guard let pane else { return session.coverOverlayActive }
        return session.paneOverlay(pane) != nil
    }

    func clearOverlayExitCode(_ pane: OverlayPane?, in session: Session) {
        if let pane {
            session.setPaneOverlayExitCode(nil, pane: pane)
        } else {
            session.overlayExitCode = nil
        }
    }
}
