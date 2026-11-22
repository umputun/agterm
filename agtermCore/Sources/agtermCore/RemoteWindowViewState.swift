import Foundation

/// RemoteWindowViewState is what a remote window keeps on this Mac about how its server's sessions are shown:
/// selection, focus, font, divider ratio, background, companion fold, context override, collapsed and focused
/// workspaces, flagged order, and which sessions and workspaces it has detached. The sessions themselves are the
/// server's and are never saved here, nor is the info line, which is runtime-only everywhere.
public struct RemoteWindowViewState: Codable, Equatable, Sendable {
    public struct SessionView: Codable, Equatable, Sendable {
        /// focusedPane is the pane identity that had the focus, the split's or the primary's.
        public var focusedPane: UUID?
        public var fontSize: Double?
        public var splitRatio: Double?
        public var background: BackgroundWatermark?
        /// paneBackgrounds are the left and right overrides keyed by pane identity, so each follows its terminal
        /// through a swap or promotion on the server; the scratch's is never kept, as on a local row.
        public var paneBackgrounds: [UUID: BackgroundWatermark]?
        /// collapsed is set when the row folds its companions.
        public var collapsed: Bool?
        /// context is this Mac's own context, never the one mirrored from the server.
        public var context: String?
        /// leads are the attach nonces the window's first attach of each pane reclaims from, by pane identity.
        public var leads: [UUID: String]?

        public init(focusedPane: UUID? = nil, fontSize: Double? = nil, splitRatio: Double? = nil,
                    background: BackgroundWatermark? = nil, paneBackgrounds: [UUID: BackgroundWatermark]? = nil, collapsed: Bool? = nil,
                    context: String? = nil, leads: [UUID: String]? = nil) {
            self.focusedPane = focusedPane
            self.fontSize = fontSize
            self.splitRatio = splitRatio
            self.background = background
            self.paneBackgrounds = paneBackgrounds
            self.collapsed = collapsed
            self.context = context
            self.leads = leads
        }

        @MainActor
        init(of session: Session) {
            let focused = session.hasSplit && session.splitFocused ? session.splitPaneIdentity : nil
            var overrides: [UUID: BackgroundWatermark] = [:]
            overrides[session.paneIdentity] = session.paneBackgrounds.left
            if session.hasSplit, let split = session.splitPaneIdentity { overrides[split] = session.paneBackgrounds.right }
            let panes = [session.paneIdentity] + (session.hasSplit ? [session.splitPaneIdentity].compactMap { $0 } : [])
            let leads = panes.reduce(into: [UUID: String]()) { $0[$1] = ZmxLeadBook.shared.savedLead(pane: $1) }
            self.init(focusedPane: focused, fontSize: session.fontSize, splitRatio: session.splitRatio,
                      background: session.backgroundWatermark, paneBackgrounds: overrides.isEmpty ? nil : overrides,
                      collapsed: session.isExpanded ? nil : true, context: session.context, leads: leads.isEmpty ? nil : leads)
        }

        var isEmpty: Bool {
            focusedPane == nil && fontSize == nil && splitRatio == nil && background == nil && paneBackgrounds == nil
                && collapsed == nil && context == nil && leads == nil
        }

        /// apply restores this view on `session`; a focused pane or a pane override the row no longer has is ignored.
        @MainActor
        func apply(to session: Session) {
            session.fontSize = fontSize
            session.splitRatio = splitRatio
            if let focusedPane, session.hasSplit { session.splitFocused = focusedPane == session.splitPaneIdentity }
            session.backgroundWatermark = background
            let right = session.hasSplit ? session.splitPaneIdentity.flatMap { paneBackgrounds?[$0] } : nil
            session.paneBackgrounds = PaneBackgrounds(left: paneBackgrounds?[session.paneIdentity], right: right,
                                                      scratch: session.paneBackgrounds.scratch)
            session.isExpanded = collapsed != true
            session.context = context
        }
    }

    public var selectedSessionID: UUID?
    public var collapsedWorkspaces: [UUID] = []
    public var sessions: [UUID: SessionView] = [:]
    /// detachedSessions and detachedWorkspaces are hidden here and left running on the server.
    public var detachedSessions: [UUID] = []
    public var detachedWorkspaces: [UUID] = []
    /// focusedWorkspaces, workspaceFilter and flaggedOrder are the window's own, restored when it reopens.
    public var focusedWorkspaces: [UUID] = []
    public var workspaceFilter = false
    public var flaggedOrder: [UUID] = []

    public init(selectedSessionID: UUID? = nil, collapsedWorkspaces: [UUID] = [], sessions: [UUID: SessionView] = [:],
                detachedSessions: [UUID] = [], detachedWorkspaces: [UUID] = [], focusedWorkspaces: [UUID] = [],
                workspaceFilter: Bool = false, flaggedOrder: [UUID] = []) {
        self.selectedSessionID = selectedSessionID
        self.collapsedWorkspaces = collapsedWorkspaces
        self.sessions = sessions
        self.detachedSessions = detachedSessions
        self.detachedWorkspaces = detachedWorkspaces
        self.focusedWorkspaces = focusedWorkspaces
        self.workspaceFilter = workspaceFilter
        self.flaggedOrder = flaggedOrder
    }

    private enum CodingKeys: String, CodingKey {
        case selectedSessionID, collapsedWorkspaces, sessions, detachedSessions, detachedWorkspaces, focusedWorkspaces,
             workspaceFilter, flaggedOrder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedSessionID = try container.decodeIfPresent(UUID.self, forKey: .selectedSessionID)
        collapsedWorkspaces = try container.decodeIfPresent([UUID].self, forKey: .collapsedWorkspaces) ?? []
        sessions = try container.decodeIfPresent([UUID: SessionView].self, forKey: .sessions) ?? [:]
        detachedSessions = try container.decodeIfPresent([UUID].self, forKey: .detachedSessions) ?? []
        detachedWorkspaces = try container.decodeIfPresent([UUID].self, forKey: .detachedWorkspaces) ?? []
        focusedWorkspaces = try container.decodeIfPresent([UUID].self, forKey: .focusedWorkspaces) ?? []
        workspaceFilter = try container.decodeIfPresent(Bool.self, forKey: .workspaceFilter) ?? false
        flaggedOrder = try container.decodeIfPresent([UUID].self, forKey: .flaggedOrder) ?? []
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
                                          detachedWorkspaces: store.catalogDetachedWorkspaces.sorted { $0.uuidString < $1.uuidString },
                                          focusedWorkspaces: store.workspaces.map(\.id).filter(store.focusedWorkspaceIDs.contains)
                                              + store.catalogHiddenFocus.sorted { $0.uuidString < $1.uuidString },
                                          workspaceFilter: store.focusEnabled, flaggedOrder: store.flaggedOrder)
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

    /// applyWindow restores the window's focus set, filter and flagged order once its rows are in `store`, keeping
    /// the membership of detached workspaces and the slots of `parked` rows, then reselects as a local restore does.
    @MainActor
    func applyWindow(to store: AppStore, parked: Set<UUID>) {
        store.restoreFocus(ids: focusedWorkspaces, enabled: workspaceFilter)
        store.catalogHiddenFocus = Set(focusedWorkspaces).intersection(store.catalogDetachedWorkspaces)
        store.restoreFlaggedOrder(flaggedOrder, parked: parked)
        store.reselectIfSelectionHidden()
    }
}
