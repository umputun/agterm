import Foundation

/// ForwardedClickPane is the pane a click forwarded from the presenting Mac names, by the directory a relative link
/// clicked there is joined to.
public struct ForwardedClickPane: Equatable, Sendable {
    public let cwd: String
}

extension AppStore {
    /// forwardedClickPane resolves the pane identity a forwarded click carries to one of `sessionID`'s own panes; nil
    /// for an identity that is neither its primary nor its split.
    public func forwardedClickPane(_ sessionID: UUID, pane identity: UUID) -> ForwardedClickPane? {
        guard let session = session(withID: sessionID) else { return nil }
        if identity == session.paneIdentity { return ForwardedClickPane(cwd: session.cwd(for: .left)) }
        if identity == session.splitPaneIdentity { return ForwardedClickPane(cwd: session.cwd(for: .right)) }
        return nil
    }
}
