import Foundation
import agtermCore

extension ControlServer {
    enum PanePlacementResolution {
        case resolved(identity: UUID?, pane: OverlayPane?)
        case rejected(ControlResponse)
    }

    func resolvePanePlacement(_ fallback: OverlayPane?, paneID: String?, in session: Session,
                              requireVisible: Bool, invalidPaneError: String) -> PanePlacementResolution {
        var pane = fallback
        if let token = paneID, !token.isEmpty {
            if let resolved = session.paneRole(forToken: token) {
                guard resolved != .scratch else {
                    return .rejected(ControlResponse(ok: false, error: invalidPaneError))
                }
                pane = resolved == .left ? .left : .right
            } else if pane == nil {
                return .rejected(ControlResponse(ok: false, error: "unknown pane id: \(token)"))
            }
        }
        guard let pane else { return .resolved(identity: nil, pane: nil) }
        if requireVisible, !session.rendersPane(pane) {
            return .rejected(ControlResponse(ok: false, error: PaneOverlayError.paneNotVisible))
        }
        switch pane {
        case .left:
            return .resolved(identity: session.paneIdentity, pane: .left)
        case .right:
            guard let identity = session.splitPaneIdentity else {
                let error = requireVisible ? PaneOverlayError.paneNotVisible : "session has no split"
                return .rejected(ControlResponse(ok: false, error: error))
            }
            return .resolved(identity: identity, pane: .right)
        }
    }
}
