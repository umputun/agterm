import Foundation

// MARK: - Presentation state mirrored from an origin, on the viewer

extension AppStore {
    /// Records what an attach learned about the origin. Set right after the row is created, not at
    /// construction like `remoteHost`: a remote session is never persisted, so no snapshot can catch it
    /// half-written.
    public func bindRemote(_ binding: RemoteBinding, forSession id: UUID) {
        session(withID: id)?.remotePresentation = RemotePresentationState(binding: binding)
    }

    /// Applies the origin's status, nil for idle. Bypasses `applyControlStatus`: that rule arbitrates
    /// between panes writing locally, and would refuse a clear the origin already accepted.
    public func applyRemoteStatus(_ status: PresentationStatus?, forSession id: UUID) {
        guard let session = session(withID: id), session.remotePresentation != nil else { return }
        let owner = status.map { localStatusPane($0.pane, in: session) }
        let indicator = status.map {
            AgentIndicator(status: $0.status, blink: $0.blink, color: $0.color, shape: $0.shape,
                           statusPane: owner?.pane)
        } ?? AgentIndicator()
        setAgentIndicator(indicator, forSession: id)
        // the setter stamps this Mac's clock; the origin's is what orders rows after a reconnect
        if let stamp = status?.changedAt { session.statusChangedAt = Date(timeIntervalSince1970: stamp) }
        session.remotePresentation?.statusBridged = indicator.status != .idle
        session.remotePresentation?.statusOwnerResolved = owner?.resolved ?? true
    }

    /// Applies the status a snapshot carries, unless the row holds a non-idle one set on this Mac. A snapshot
    /// comes with every reconnect, so it must not end what a local write started. An origin write made while
    /// the stream was down is held back with it, until the origin's next live update.
    public func applyRemoteSnapshotStatus(_ status: PresentationStatus?, forSession id: UUID) {
        guard let session = session(withID: id), let state = session.remotePresentation else { return }
        if !state.statusBridged, session.agentIndicator.status != .idle { return }
        applyRemoteStatus(status, forSession: id)
    }

    /// Moves the stream's state. Leaving `connected` withdraws what the bridge put on screen, since a glyph
    /// or a panel outliving the stream that fed it would describe nothing.
    public func setRemoteConnection(_ connection: RemotePresentationConnection, forSession id: UUID) {
        guard let session = session(withID: id), let state = session.remotePresentation else { return }
        session.remotePresentation?.connection = connection
        guard state.connection == .connected, connection != .connected else { return }
        if state.statusBridged { setAgentIndicator(AgentIndicator(), forSession: id) }
        closeBridgedHud(forSession: id)
        // the origin takes a handed-over ask back when the stream goes, so the replica must not answer it
        if session.askReplica { session.releaseAsk() }
        orphanReplicaOverlays(of: session)
    }

    /// Shows an overlay `id`'s origin handed over as a local one running `command`, the job's helper over
    /// ssh, in the mapped pane or the session-wide slot. `closed` tells the origin its surface is gone. False
    /// when the slot is taken or the pane is not shown here, which the caller reports as a refusal.
    public func presentReplicaOverlay(_ overlay: PresentationOverlay, command: String, forSession id: UUID,
                                      closed: @escaping @MainActor (String) -> Void) -> Bool {
        guard let session = session(withID: id), session.remotePresentation != nil else { return false }
        var pane: OverlayPane?
        if overlay.pane != nil {
            guard let role = localPane(overlay.pane, in: session),
                  openPaneOverlay(id, pane: role, command: command, wait: overlay.wait,
                                  backgroundColor: overlay.backgroundColor) == nil else { return false }
            pane = role
        } else {
            guard openOverlay(id, command: command, wait: overlay.wait, sizePercent: overlay.sizePercent,
                              backgroundColor: overlay.backgroundColor) else { return false }
        }
        session.setOverlayReplica(OverlayReplica(job: overlay.job), pane: pane)
        session.onReplicaOverlayClosed = closed
        if overlay.follow { selectSession(id) }
        return true
    }

    /// Takes down the overlay showing `job`, once its origin closed it.
    public func closeReplicaOverlay(_ job: String, forSession id: UUID) {
        guard let slot = session(withID: id)?.overlayReplicas.first(where: { $0.replica.job == job }) else { return }
        if let pane = slot.pane {
            closePaneOverlay(id, pane: pane)
        } else {
            closeOverlay(id)
        }
    }

    public func resizeReplicaOverlay(_ change: PresentationOverlayChange, forSession id: UUID) {
        guard session(withID: id)?.overlayReplica?.job == change.job else { return }
        resizeOverlay(id, sizePercent: change.sizePercent)
    }

    /// A replica's job ssh ended and `--wait` holds its surface. Cut off from its stream, nothing could close
    /// it later, so it closes now; otherwise it stays for the user and closes if the stream goes.
    public func replicaOverlayHeld(forSession id: UUID, pane: OverlayPane?) {
        guard let session = session(withID: id),
              var replica = session.overlayReplicas.first(where: { $0.pane == pane })?.replica else { return }
        guard !replica.orphaned else {
            closeReplicaOverlay(replica.job, forSession: id)
            return
        }
        replica.ended = true
        session.setOverlayReplica(replica, pane: pane)
    }

    /// The stream left `connected`: a held surface closes now, and a running one keeps its program and
    /// closes when its ssh ends, since no later stream adopts it.
    private func orphanReplicaOverlays(of session: Session) {
        for var slot in session.overlayReplicas {
            if slot.replica.ended {
                closeReplicaOverlay(slot.replica.job, forSession: session.id)
                continue
            }
            slot.replica.orphaned = true
            session.setOverlayReplica(slot.replica, pane: slot.pane)
        }
    }

    /// Shows an ask `id`'s origin handed over, in its own style over the mapped session or pane. `answer`
    /// carries the outcome back: the button id alone, nil for Esc or Command-W, and a refusal when the
    /// dialog is cancelled here. False when it cannot be shown, which the caller reports as a refusal.
    public func presentReplicaAsk(_ ask: PresentationAsk, forSession id: UUID,
                                  answer: @escaping @MainActor (PresentationFrame.Body) -> Void) -> Bool {
        guard let session = session(withID: id), let binding = session.remotePresentation?.binding else { return false }
        var paneIdentity: UUID?
        if case .identity(let remote)? = ask.pane {
            guard let local = binding.localPane(forRemote: remote), let role = session.paneRole(forIdentity: local),
                  session.rendersPane(role) else { return false }
            paneIdentity = local
        }
        let pending = PendingAsk(id: ask.id, title: ask.title, message: ask.message, buttons: ask.buttons,
                                 defaultID: ask.defaultID, destructiveID: ask.destructiveID, style: ask.style,
                                 align: ask.align, width: ask.width)
        return session.openReplicaAsk(pending, paneIdentity: paneIdentity) { result in
            switch result.result {
            case .answered: answer(.askResolve(PresentationAskAnswer(id: ask.id, owner: ask.owner, button: result.id)))
            case .escaped: answer(.askResolve(PresentationAskAnswer(id: ask.id, owner: ask.owner, button: nil)))
            case .cancelled, .pending: answer(.askRejected(PresentationAskRef(id: ask.id, owner: ask.owner)))
            }
        }
    }

    /// Takes a replica down without answering it, once its origin ended the ask.
    public func dismissReplicaAsk(_ ref: PresentationAskRef, forSession id: UUID) {
        guard let session = session(withID: id), session.askReplica, session.askPending?.id == ref.id else { return }
        session.releaseAsk()
    }

    /// Records whether this Mac is the session's presenter or a mirror beside the origin.
    public func setRemoteMode(_ mode: PresentationMode, forSession id: UUID) {
        session(withID: id)?.remotePresentation?.mode = mode
    }

    /// Marks the live HUD as the bridge's. Called once the app has the mirrored panel up.
    public func markHudBridged(forSession id: UUID) {
        guard let session = session(withID: id), session.hudActive else { return }
        session.remotePresentation?.hudBridged = true
    }

    /// Closes the HUD only when the bridge opened it. False when there was nothing of the bridge's to close.
    @discardableResult
    public func closeBridgedHud(forSession id: UUID) -> Bool {
        guard let session = session(withID: id), session.remotePresentation?.hudBridged == true else { return false }
        return closeHud(id)
    }

    /// The `tree` read-back of this Mac's stream to `session`'s origin, nil for a local session.
    func presentationNode(of session: Session) -> ControlPresentationNode? {
        guard let state = session.remotePresentation else { return nil }
        switch state.connection {
        case .connecting: return ControlPresentationNode(state: "connecting", mode: state.mode.rawValue)
        case .connected: return ControlPresentationNode(state: "connected", mode: state.mode.rawValue)
        case .unsupported: return ControlPresentationNode(state: "unsupported", mode: state.mode.rawValue)
        case .failed(let reason):
            return ControlPresentationNode(state: "failed", mode: state.mode.rawValue, error: reason)
        }
    }

    /// The `tree` read-back of the viewers mirroring `session`, nil when there is none.
    func presentersNode(of session: Session) -> ControlPresentersNode? {
        guard let hub = presentationHub else { return nil }
        let viewers = hub.subscriberCount(session: session.id)
        guard viewers > 0 else { return nil }
        let presented = hub.hasPresenter(session: session.id)
        return ControlPresentersNode(mirrors: presented ? viewers - 1 : viewers, presenter: presented ? true : nil)
    }

    /// The local role standing for one of the origin's panes, resolved at use so a swap or promotion on this
    /// side since the attach is honoured. Nil for a pane with no counterpart here.
    public func localPane(_ pane: PresentationPane?, in session: Session) -> OverlayPane? {
        guard case .identity(let remote)? = pane,
              let local = session.remotePresentation?.binding.localPane(forRemote: remote) else { return nil }
        return session.paneRole(forIdentity: local)
    }

    /// An unspecified owner is the origin's primary, which it sends as an identity, so nil here is genuinely
    /// session-wide. The origin's scratch has no counterpart at all: an attach imports the primary and the
    /// split only, and this Mac's scratch is a different shell.
    private func localStatusPane(_ pane: PresentationPane?, in session: Session) -> (pane: StatusPane?, resolved: Bool) {
        guard let pane else { return (nil, true) }
        guard let role = localPane(pane, in: session) else { return (nil, false) }
        return (role == .right ? .right : .left, true)
    }
}
