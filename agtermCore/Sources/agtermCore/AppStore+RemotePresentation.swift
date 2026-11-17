import Foundation

// MARK: - Presentation state mirrored from an origin, on the viewer

extension AppStore {
    /// Records what an attach learned about the origin. Set right after the row is created, not at
    /// construction like `remoteHost`: the row is saved only once it has a binding, so this saves it.
    public func bindRemote(_ binding: RemoteBinding, forSession id: UUID) {
        guard let row = session(withID: id) else { return }
        row.remotePresentation = RemotePresentationState(binding: binding)
        save()
    }

    /// Keeps origin updates even while a local override hides them.
    public func applyRemoteContext(_ context: String?, forSession id: UUID) {
        guard let session = session(withID: id), session.remotePresentation != nil else { return }
        let previous = session.effectiveContext
        if let context, case let .valid(value) = Session.validateContext(context) {
            session.mirroredContext = value
        } else {
            session.mirroredContext = nil
        }
        if previous != session.effectiveContext { scheduleTreeChanged() }
    }

    /// applyRemoteInfo records the origin's info line, kept even while a local line hides it; one that does not
    /// parse here reads as none.
    public func applyRemoteInfo(_ info: PresentationInfo?, forSession id: UUID) {
        guard let session = session(withID: id), session.remotePresentation != nil else { return }
        let previous = session.effectiveInfo
        session.mirroredInfo = info.flatMap {
            try? SessionInfo.make(source: $0.source, markdown: $0.markdown, hideAfter: $0.hideAfter).get()
        }
        if previous != session.effectiveInfo { scheduleTreeChanged() }
    }

    /// applyRemoteMail records the origin's mail counts for the row's tree read-back; nil means it sends none.
    public func applyRemoteMail(_ mail: PresentationMail?, forSession id: UUID) {
        guard let session = session(withID: id), session.remotePresentation != nil else { return }
        session.remotePresentation?.mail = mail
    }

    /// Applies the origin's status, nil for idle. Bypasses `applyControlStatus`: that rule arbitrates
    /// between panes writing locally, and would refuse a clear the origin already accepted.
    public func applyRemoteStatus(_ status: PresentationStatus?, forSession id: UUID) {
        guard let session = session(withID: id), session.remotePresentation != nil else { return }
        let owner = status.map { localStatusPane($0.pane, in: session) }
        let indicator = status.map {
            AgentIndicator(status: $0.status, blink: $0.blink, autoReset: $0.autoReset ?? false, color: $0.color,
                           shape: $0.shape, statusPane: owner?.pane)
        } ?? AgentIndicator()
        setAgentIndicator(indicator, forSession: id)
        // the origin's word replaces any local pane activity, which a later local clear would otherwise bring back
        session.paneActivity.removeAll()
        session.remotePresentation?.activePanes = status.map(\.activePanes) ?? []
        // the setter stamps this Mac's clock; the origin's is what orders rows after a reconnect
        if let stamp = status?.changedAt { session.statusChangedAt = Date(timeIntervalSince1970: stamp) }
        session.remotePresentation?.statusBridged = indicator.status != .idle
        session.remotePresentation?.statusOwnerResolved = owner?.resolved ?? true
        session.remotePresentation?.statusKeySent = false
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
        if state.connection != connection { session.remoteConnectionRevision += 1 }
        if connection == .connected { armRemoteSeen(forSession: id) }
        guard state.connection == .connected, connection != .connected else { return }
        withdrawRemoteReplicas(of: session)
    }

    /// sendToOrigin hands `body` to the origin of a session this Mac presents or leads a pane of; false when it does
    /// neither or the origin does not take the frame, and the caller then keeps to what this Mac decides alone.
    func sendToOrigin(_ body: PresentationFrame.Body, forSession id: UUID) -> Bool {
        guard let session = session(withID: id), session.remotePresentation?.mode == .presenter || !originLeads(of: session).isEmpty
        else { return false }
        return onOriginFrame?(id, body) ?? false
    }

    /// originLeads is the set of the origin's panes `session` leads on this Mac, the claim its presentation stream
    /// reports; a pane with no origin twin claims nothing.
    public func originLeads(of session: Session) -> Set<UUID> {
        guard let binding = session.remotePresentation?.binding else { return [] }
        let panes = [session.paneIdentity] + [session.splitPaneIdentity].compactMap { $0 }
        return Set(panes.filter { ZmxLeadBook.shared.role(pane: $0) == .leader }.compactMap { binding.remotePane(forLocal: $0) })
    }

    /// markSeen lowers the badge of a session the user is looking at, and asks an attached row's origin to lower its own.
    public func markSeen(_ id: UUID) {
        clearUnseen(id)
        _ = sendToOrigin(.statusSeen(PresentationSeen(reason: .viewed)), forSession: id)
    }

    /// forwardStatusKeystroke hands typing in `pane` on a bridged status to the origin, whose reset rule decides; its
    /// answer comes back as a status frame. False when the row decides here: nothing bridged, typing other than an
    /// interrupt in a pane that does not own the status, which no origin rule clears, a pane the origin has no twin
    /// of, or an origin that does not take the frame. An interrupt in any pane goes, since it also ends that pane's
    /// activity on the origin. Plain typing goes once per status.
    public func forwardStatusKeystroke(_ keystroke: StatusKeystroke, pane: StatusPane, forSession id: UUID) -> Bool {
        guard let session = session(withID: id), let state = session.remotePresentation, state.statusBridged,
              keystroke == .interrupt || (state.statusOwnerResolved && (session.agentIndicator.statusPane ?? .left) == pane),
              let origin = originPane(of: pane, in: session) else { return false }
        if keystroke == .other, state.statusKeySent { return true }
        guard sendToOrigin(.statusClear(PresentationStatusClear(reason: PresentationClearReason(keystroke), pane: origin)),
                           forSession: id) else { return false }
        if keystroke == .other { session.remotePresentation?.statusKeySent = true }
        return true
    }

    /// forwardSeenKeystroke reports typing to an attached row's origin, whose badge rule decides whatever this Mac's
    /// own count and rule say. Only the first key and the first submit after the stream connects or a notification
    /// arrives go.
    public func forwardSeenKeystroke(_ keystroke: StatusKeystroke, forSession id: UUID) {
        guard let session = session(withID: id), let state = session.remotePresentation else { return }
        let first = !state.seenKeySent
        let submit = keystroke == .submit && !state.seenSubmitSent
        guard first || submit, sendToOrigin(.statusSeen(PresentationSeen(reason: PresentationClearReason(keystroke))), forSession: id) else {
            return
        }
        session.remotePresentation?.seenKeySent = true
        if keystroke == .submit { session.remotePresentation?.seenSubmitSent = true }
    }

    /// armRemoteSeen lets the next typing on an attached row reach its origin's badge again, after a notification.
    public func armRemoteSeen(forSession id: UUID) {
        session(withID: id)?.remotePresentation?.seenKeySent = false
        session(withID: id)?.remotePresentation?.seenSubmitSent = false
    }

    /// mirroredActivePanes maps the origin's working panes to this Mac's, dropping one with no counterpart here, and
    /// adds this Mac's own reports, which a pane with no origin counterpart can only make here.
    func mirroredActivePanes(of session: Session) -> [StatusPane]? {
        guard let working = session.remotePresentation?.activePanes else { return nil }
        let local = Set(working.compactMap { localStatusPane($0, in: session).pane }).union(session.paneActivity.keys)
        return StatusPane.allCases.filter(local.contains)
    }

    /// noteMirroredActivity puts a local report the origin's block keeps off the row into the origin's list, so the
    /// read-back agrees with the work this Mac accepted until the origin's next status replaces it.
    func noteMirroredActivity(_ working: Bool, pane: StatusPane, of session: Session) {
        guard let state = session.remotePresentation, state.statusBridged, var list = state.activePanes,
              let origin = originPane(of: pane, in: session) else { return }
        list.removeAll { $0 == origin }
        if working { list.append(origin) }
        session.remotePresentation?.activePanes = list
    }

    private func originPane(of pane: StatusPane, in session: Session) -> PresentationPane? {
        switch pane {
        case .scratch: return session.scratchDaemon != nil ? .scratch : nil
        case .left: return session.remotePresentation?.binding.remotePane(forLocal: session.paneIdentity).map { .identity($0) }
        case .right: return session.splitPaneIdentity.flatMap { session.remotePresentation?.binding.remotePane(forLocal: $0) }.map { .identity($0) }
        }
    }

    /// withdrawRemoteReplicas takes down everything the presentation stream put on `session`, its terminals
    /// excepted: the stream left, or the session ended and no stream will come back.
    func withdrawRemoteReplicas(of session: Session) {
        let id = session.id
        applyRemoteContext(nil, forSession: id)
        applyRemoteInfo(nil, forSession: id)
        session.remotePresentation?.mail = nil
        if session.remotePresentation?.statusBridged == true { showRemainingActivity(of: session) }
        session.remotePresentation?.activePanes = nil
        closeBridgedHud(forSession: id)
        // the origin takes a handed-over ask back when the stream goes, so the replica must not answer it
        if session.askReplica { session.releaseAsk() }
        SessionPickBook.shared.dropReplicas(forSession: id)
        orphanReplicaOverlays(of: session)
        closeReplicaPages(of: session)
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
                              points: overlay.points,
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
        resizeOverlay(id, sizePercent: change.sizePercent, points: change.points)
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
    /// dialog is cancelled here. False when it cannot be shown, which the caller reports as a refusal. With `holds`,
    /// an ask for a pane not shown here waits in the slot and appears with its pane.
    public func presentReplicaAsk(_ ask: PresentationAsk, forSession id: UUID, holds: Bool = false,
                                  answer: @escaping @MainActor (PresentationFrame.Body) -> Void) -> Bool {
        guard let session = session(withID: id), let binding = session.remotePresentation?.binding else { return false }
        var paneIdentity: UUID?
        if case .identity(let remote)? = ask.pane {
            guard let local = binding.localPane(forRemote: remote), let role = session.paneRole(forIdentity: local),
                  holds || session.rendersPane(role) else { return false }
            paneIdentity = local
        }
        let pending = PendingAsk(id: ask.id, title: ask.title, message: ask.message, buttons: ask.buttons,
                                 defaultID: ask.defaultID, destructiveID: ask.destructiveID, style: ask.style,
                                 align: ask.align, width: ask.width, form: ask.form, cancelID: ask.cancelID)
        return session.openReplicaAsk(pending, paneIdentity: paneIdentity) { result in
            switch result.result {
            case .answered:
                answer(.askResolve(PresentationAskAnswer(id: ask.id, owner: ask.owner, button: result.id,
                                                         text: result.text, selected: result.selected, offer: ask.offer)))
            case .escaped: answer(.askResolve(PresentationAskAnswer(id: ask.id, owner: ask.owner, button: nil, offer: ask.offer)))
            case .cancelled, .pending: answer(.askRejected(PresentationAskRef(id: ask.id, owner: ask.owner, offer: ask.offer)))
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
        return ControlPresentersNode(mirrors: presented ? viewers - 1 : viewers, presenter: presented ? true : nil, viewers: viewers)
    }

    /// remotelyPresented is the `tree` read-back of whether `pane`, a primary or split pane of `session`, hands its
    /// next work to an attached Mac; nil for any other pane and when it does not.
    func remotelyPresented(_ session: Session, pane: UUID?) -> Bool? {
        guard let pane, pane == session.paneIdentity || pane == session.splitPaneIdentity,
              remoteRecipient(session, paneIdentity: pane) != nil else { return nil }
        return true
    }

    /// attachEnded is the `tree` read-back of a pane showing the ended notice, nil otherwise.
    func attachEnded(_ pane: UUID?) -> Bool? { RemoteEndBook.shared.notice(pane: pane) != nil ? true : nil }

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
        // a remote window's scratch is the origin's own, attached here, so its statuses land on it
        if let scratch = session.scratchDaemon, pane == .scratch || pane == .identity(scratch.identity) { return (.scratch, true) }
        guard let role = localPane(pane, in: session) else { return (nil, false) }
        return (role == .right ? .right : .left, true)
    }
}

extension Session {
    /// remoteConnection is the presentation stream's state, read through here by anything that must
    /// redraw when it changes: `remotePresentation` announces nothing.
    public var remoteConnection: RemotePresentationConnection? {
        _ = remoteConnectionRevision
        return remotePresentation?.connection
    }

    /// remoteRowNotice is the line under a remote row: an ended session names its host, others say what their
    /// presentation stream is doing, nil when there is nothing to say.
    public var remoteRowNotice: String? {
        guard let host = remoteHost, remotePresentation?.originEnded != true else { return nil }
        if ended { return "Ended on \(host)" }
        return remoteConnection?.rowNotice(host: host)
    }
}
