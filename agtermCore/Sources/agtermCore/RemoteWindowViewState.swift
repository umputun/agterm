import Foundation

/// RemoteWindowViewState is what a remote window keeps on this Mac about how its server's sessions are shown:
/// selection, focus, font, divider ratio, collapsed workspaces, and which sessions and workspaces it has detached.
/// The sessions themselves are the server's and are never saved here.
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

        @MainActor
        init(of session: Session) {
            let focused = session.hasSplit && session.splitFocused ? session.splitPaneIdentity : nil
            self.init(focusedPane: focused, fontSize: session.fontSize, splitRatio: session.splitRatio)
        }

        var isEmpty: Bool { focusedPane == nil && fontSize == nil && splitRatio == nil }

        /// apply restores this view on `session`; a focused pane the row no longer has is ignored.
        @MainActor
        func apply(to session: Session) {
            session.fontSize = fontSize
            session.splitRatio = splitRatio
            if let focusedPane, session.hasSplit { session.splitFocused = focusedPane == session.splitPaneIdentity }
        }
    }

    public var selectedSessionID: UUID?
    public var collapsedWorkspaces: [UUID] = []
    public var sessions: [UUID: SessionView] = [:]
    /// detachedSessions and detachedWorkspaces are hidden here and left running on the server.
    public var detachedSessions: [UUID] = []
    public var detachedWorkspaces: [UUID] = []

    public init(selectedSessionID: UUID? = nil, collapsedWorkspaces: [UUID] = [], sessions: [UUID: SessionView] = [:],
                detachedSessions: [UUID] = [], detachedWorkspaces: [UUID] = []) {
        self.selectedSessionID = selectedSessionID
        self.collapsedWorkspaces = collapsedWorkspaces
        self.sessions = sessions
        self.detachedSessions = detachedSessions
        self.detachedWorkspaces = detachedWorkspaces
    }

    private enum CodingKeys: String, CodingKey {
        case selectedSessionID, collapsedWorkspaces, sessions, detachedSessions, detachedWorkspaces
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedSessionID = try container.decodeIfPresent(UUID.self, forKey: .selectedSessionID)
        collapsedWorkspaces = try container.decodeIfPresent([UUID].self, forKey: .collapsedWorkspaces) ?? []
        sessions = try container.decodeIfPresent([UUID: SessionView].self, forKey: .sessions) ?? [:]
        detachedSessions = try container.decodeIfPresent([UUID].self, forKey: .detachedSessions) ?? []
        detachedWorkspaces = try container.decodeIfPresent([UUID].self, forKey: .detachedWorkspaces) ?? []
    }

    /// capture reads the view state of `store`'s rows, and keeps the views of rows its detach hides. A session whose
    /// view matches the defaults is left out.
    @MainActor
    public static func capture(from store: AppStore) -> RemoteWindowViewState {
        let hiddenCollapsed = store.catalogHiddenCollapsed.filter(\.value).map(\.key).sorted { $0.uuidString < $1.uuidString }
        var state = RemoteWindowViewState(selectedSessionID: store.selectedSessionID,
                                          collapsedWorkspaces: store.workspaces.filter { !$0.isExpanded }.map(\.id) + hiddenCollapsed,
                                          sessions: store.catalogHiddenViews,
                                          detachedSessions: store.catalogDetachedSessions.sorted { $0.uuidString < $1.uuidString },
                                          detachedWorkspaces: store.catalogDetachedWorkspaces.sorted { $0.uuidString < $1.uuidString })
        for session in store.workspaces.flatMap(\.sessions) {
            let view = SessionView(of: session)
            if !view.isEmpty { state.sessions[session.id] = view }
        }
        return state
    }

    /// apply restores the view of one row the mirror just created.
    @MainActor
    public func apply(to session: Session) {
        sessions[session.id]?.apply(to: session)
    }
}
