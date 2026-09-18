import Foundation

/// NotificationOrigin is where an accepted notification came from, which decides whether it travels to viewers.
public enum NotificationOrigin: String, Sendable {
    /// OSC 9/777 from a pane. zmx already carries those bytes to a viewer's own pane, which raises it there.
    case terminal
    /// An explicit control `notify`.
    case control
    /// One a viewer received from its origin. Never relayed onward.
    case mirrored
}

// MARK: - Presentation state for attached viewers

extension AppStore {
    /// The replaceable presentation state a viewer of `id` starts from. Empty for an unknown session.
    public func presentationSnapshot(forSession id: UUID, now: Date = Date()) -> PresentationSnapshot {
        guard let session = session(withID: id) else { return PresentationSnapshot(status: nil, hud: nil) }
        return PresentationSnapshot(status: presentationStatus(of: session),
                                    hud: presentationHud(of: session, now: now))
    }

    /// Publishes the session's live HUD to attached viewers. Called once its body is on disk, never before:
    /// a rejected open or update must not reach a viewer as a panel the origin is not showing.
    public func publishHud(forSession id: UUID, expiresAt: Date?, now: Date = Date()) {
        guard let session = session(withID: id), session.hudActive else { return }
        session.hudExpiresAt = expiresAt
        session.hudResizedWidthPercent = nil
        session.hudPublishGeneration += 1
        session.onHudWithdrawn = { [weak self] in
            MainActor.assumeIsolated { self?.presentationHub?.publish(.hud(nil), session: id) }
        }
        presentationHub?.publish(.hud(presentationHud(of: session, now: now)), session: id)
    }

    /// Republishes a published HUD after `overlay.resize` changed its width. The deadline it already has is
    /// kept: a resize does not restart the interval.
    public func publishHudResize(forSession id: UUID, now: Date = Date()) {
        guard let session = session(withID: id), session.onHudWithdrawn != nil else { return }
        session.hudResizedWidthPercent = session.overlaySizePercent
        session.hudPublishGeneration += 1
        presentationHub?.publish(.hud(presentationHud(of: session, now: now)), session: id)
    }

    /// The published HUD as it travels to a viewer, its remaining lifetime sampled at `now`.
    func presentationHud(of session: Session, now: Date) -> PresentationHud? {
        guard session.onHudWithdrawn != nil, let live = session.hudSpec else { return nil }
        let spec = live.withSizePercent(session.hudResizedWidthPercent ?? live.sizePercent)
        return PresentationHud(spec: spec, pane: session.hudPaneIdentity.map(PresentationPane.identity),
                               generation: session.hudPublishGeneration,
                               remaining: session.hudExpiresAt.map { max(0, $0.timeIntervalSince(now)) })
    }

    /// The session's status as it travels to a viewer, nil when idle.
    func presentationStatus(of session: Session) -> PresentationStatus? {
        let indicator = session.agentIndicator
        guard indicator.status != .idle else { return nil }
        return PresentationStatus(status: indicator.status, blink: indicator.blink, color: indicator.color,
                                  shape: indicator.shape,
                                  pane: presentationStatusPane(indicator.statusPane, of: session),
                                  changedAt: session.statusChangedAt?.timeIntervalSince1970)
    }

    /// A status owner as the stable identity a viewer can follow across a swap or promotion on either Mac.
    /// An unspecified owner is the primary pane, as `AgentIndicator` treats it, and a swap rewrites it to an
    /// explicit role without publishing, so it has to travel as that identity from the start.
    func presentationStatusPane(_ pane: StatusPane?, of session: Session) -> PresentationPane {
        switch pane {
        case nil, .left: return .identity(session.paneIdentity)
        case .right: return .identity(session.splitPaneIdentity ?? session.paneIdentity)
        case .scratch: return .scratch
        }
    }
}
