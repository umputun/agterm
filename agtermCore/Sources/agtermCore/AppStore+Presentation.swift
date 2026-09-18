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
    public func presentationSnapshot(forSession id: UUID) -> PresentationSnapshot {
        guard let session = session(withID: id) else { return PresentationSnapshot(status: nil, hud: nil) }
        return PresentationSnapshot(status: presentationStatus(of: session), hud: nil)
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
