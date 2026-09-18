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

    /// Moves the stream's state. Leaving `connected` withdraws what the bridge put on screen, since a glyph
    /// or a panel outliving the stream that fed it would describe nothing.
    public func setRemoteConnection(_ connection: RemotePresentationConnection, forSession id: UUID) {
        guard let session = session(withID: id), let state = session.remotePresentation else { return }
        session.remotePresentation?.connection = connection
        guard state.connection == .connected, connection != .connected else { return }
        if state.statusBridged { setAgentIndicator(AgentIndicator(), forSession: id) }
        closeBridgedHud(forSession: id)
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
        let mirrors = presentationHub?.subscriberCount(session: session.id) ?? 0
        return mirrors > 0 ? ControlPresentersNode(mirrors: mirrors) : nil
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
