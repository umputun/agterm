import Foundation

/// AttachedSessionSnapshot is a row attached from another host, saved apart from `WorkspaceSnapshot.sessions`: a build
/// that predates it ignores the key, where it would read the row as a local terminal and start a shell in it.
public struct AttachedSessionSnapshot: Codable, Equatable, Sendable {
    /// index is the row's place among its workspace's rows.
    public var index: Int
    /// session carries the row's own state: ids, panes, view choices; never a command, a page source or the info line.
    public var session: SessionSnapshot
    public var origin: AttachedOriginSnapshot
    /// followedCompanions and companionsBaselined are `Session`'s, nil for an empty set and an unbaselined row.
    public var followedCompanions: [String]?
    public var companionsBaselined: Bool?

    public init(index: Int, session: SessionSnapshot, origin: AttachedOriginSnapshot, followedCompanions: [String]? = nil,
                companionsBaselined: Bool? = nil) {
        self.index = index
        self.session = session
        self.origin = origin
        self.followedCompanions = followedCompanions
        self.companionsBaselined = companionsBaselined
    }
}

/// AttachedOriginSnapshot is what attaching a saved row again takes: the origin's session and the daemon each local
/// pane runs against.
public struct AttachedOriginSnapshot: Codable, Equatable, Sendable {
    public struct Pane: Codable, Equatable, Sendable {
        public var pane: UUID
        public var daemon: String
        /// lead is the attach nonce the next attach reclaims from (`ZmxLeadBook.savedLead` when saved); nil when the
        /// pane followed.
        public var lead: String?

        public init(pane: UUID, daemon: String, lead: String? = nil) {
            self.pane = pane
            self.daemon = daemon
            self.lead = lead
        }
    }

    public var host: String
    public var sessionID: String
    public var sessionName: String
    public var endpoint: ControlZmxEndpoint
    public var presentationVersion: Int?
    public var headless: Bool?
    public var page: Bool?
    public var panes: [Pane]

    public init(host: String, sessionID: String, sessionName: String, endpoint: ControlZmxEndpoint,
                presentationVersion: Int?, headless: Bool?, page: Bool?, panes: [Pane]) {
        self.host = host
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.endpoint = endpoint
        self.presentationVersion = presentationVersion
        self.headless = headless
        self.page = page
        self.panes = panes
    }

    /// init(binding:page:) is nil for a binding no attach can be rebuilt from: a server window's row, or one without
    /// an origin.
    @MainActor
    init?(binding: RemoteBinding, page: Bool) {
        guard !binding.catalogOwned, let origin = binding.origin else { return nil }
        let panes = binding.daemonsByPane.map {
            Pane(pane: $0.key, daemon: $0.value, lead: ZmxLeadBook.shared.savedLead(pane: $0.key))
        }
        self.init(host: origin.host, sessionID: binding.remoteSessionID, sessionName: origin.sessionName,
                  endpoint: origin.endpoint, presentationVersion: binding.presentationVersion,
                  headless: binding.originHeadless ? true : nil, page: page ? true : nil,
                  panes: panes.sorted { $0.daemon < $1.daemon })
    }

    var binding: RemoteBinding {
        RemoteBinding(remoteSessionID: sessionID,
                      daemonsByLocalPane: Dictionary(panes.map { ($0.pane, $0.daemon) }, uniquingKeysWith: { first, _ in first }),
                      presentationVersion: presentationVersion,
                      origin: RemoteBinding.Origin(host: host, endpoint: endpoint, sessionName: sessionName),
                      originHeadless: headless ?? false)
    }
}

extension Session {
    /// attachedOrigin is what attaching this row again takes; nil for every row not attached from another host.
    var attachedOrigin: AttachedOriginSnapshot? {
        guard remoteHost != nil, let state = remotePresentation else { return nil }
        return AttachedOriginSnapshot(binding: state.binding, page: content == .page)
    }
}
