import Foundation

/// PanePlacementResolution is where a pane-scoped panel (a HUD, an ask) goes: a pane identity and role, or nil for
/// session-wide, or the refusal.
public enum PanePlacementResolution {
    case resolved(identity: UUID?, pane: OverlayPane?)
    case rejected(ControlResponse)
}

extension Session {
    /// panePlacement resolves `--pane-id`/`--pane` to a pane of this session: a live token wins over the role, an
    /// unknown token without a role is refused, and `requireVisible` refuses a pane the session does not lay out.
    public func panePlacement(_ fallback: OverlayPane?, paneID: String?, requireVisible: Bool,
                              invalidPaneError: String) -> PanePlacementResolution {
        var pane = fallback
        if let token = paneID, !token.isEmpty {
            if let resolved = paneRole(forToken: token) {
                guard resolved != .scratch else {
                    return .rejected(ControlResponse(ok: false, error: invalidPaneError))
                }
                pane = resolved == .left ? .left : .right
            } else if pane == nil {
                return .rejected(ControlResponse(ok: false, error: "unknown pane id: \(token)"))
            }
        }
        guard let pane else { return .resolved(identity: nil, pane: nil) }
        if requireVisible, !rendersPane(pane) {
            return .rejected(ControlResponse(ok: false, error: PaneOverlayError.paneNotVisible))
        }
        switch pane {
        case .left:
            return .resolved(identity: paneIdentity, pane: .left)
        case .right:
            guard let identity = splitPaneIdentity else {
                let error = requireVisible ? PaneOverlayError.paneNotVisible : "session has no split"
                return .rejected(ControlResponse(ok: false, error: error))
            }
            return .resolved(identity: identity, pane: .right)
        }
    }
}
