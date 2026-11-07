import Foundation

/// RemoteWindowViewState is what a remote window keeps on this Mac about how its server's sessions are shown:
/// selection, focus, font, divider ratio and collapsed workspaces. The sessions themselves are the server's
/// and are never saved here.
public struct RemoteWindowViewState: Codable, Equatable, Sendable {
    public struct SessionView: Codable, Equatable, Sendable {
        /// focusedPane is the pane identity that had the focus, the split's or the primary's.
        public var focusedPane: UUID?
        public var fontSize: Double?
        public var splitRatio: Double?

        public init(focusedPane: UUID? = nil, fontSize: Double? = nil, splitRatio: Double? = nil) {
            self.focusedPane = focusedPane
            self.fontSize = fontSize
            self.splitRatio = splitRatio
        }

        var isEmpty: Bool { focusedPane == nil && fontSize == nil && splitRatio == nil }
    }

    public var selectedSessionID: UUID?
    public var collapsedWorkspaces: [UUID] = []
    public var sessions: [UUID: SessionView] = [:]

    public init(selectedSessionID: UUID? = nil, collapsedWorkspaces: [UUID] = [], sessions: [UUID: SessionView] = [:]) {
        self.selectedSessionID = selectedSessionID
        self.collapsedWorkspaces = collapsedWorkspaces
        self.sessions = sessions
    }

    /// capture reads the view state of `store`'s rows. A session whose view matches the defaults is left out.
    @MainActor
    public static func capture(from store: AppStore) -> RemoteWindowViewState {
        var state = RemoteWindowViewState(selectedSessionID: store.selectedSessionID,
                                          collapsedWorkspaces: store.workspaces.filter { !$0.isExpanded }.map(\.id))
        for session in store.workspaces.flatMap(\.sessions) {
            let focused = session.hasSplit && session.splitFocused ? session.splitPaneIdentity : nil
            let view = SessionView(focusedPane: focused, fontSize: session.fontSize, splitRatio: session.splitRatio)
            if !view.isEmpty { state.sessions[session.id] = view }
        }
        return state
    }

    /// apply restores the view of one row the mirror just created; a focused pane the row no longer has is
    /// ignored.
    @MainActor
    public func apply(to session: Session) {
        guard let view = sessions[session.id] else { return }
        session.fontSize = view.fontSize
        session.splitRatio = view.splitRatio
        if let focused = view.focusedPane, session.hasSplit { session.splitFocused = focused == session.splitPaneIdentity }
    }
}
