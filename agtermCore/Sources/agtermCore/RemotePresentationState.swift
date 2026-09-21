import Foundation

/// RemoteBinding ties a session attached from another Mac to the origin's own model: which session it is
/// there, and which local pane stands for each of the origin's panes. Both sides create their own pane
/// identities, so presentation state names the origin's and is routed through this mapping.
public struct RemoteBinding: Equatable, Sendable {
    /// What attaching one of the origin's panes again takes. Taking the lead back is a fresh attach, and
    /// the pane's first command line cannot be reused: it carries that attachment's token.
    public struct Origin: Equatable, Sendable {
        public let host: String
        public let endpoint: ControlZmxEndpoint
        public let sessionName: String

        public init(host: String, endpoint: ControlZmxEndpoint, sessionName: String) {
            self.host = host
            self.endpoint = endpoint
            self.sessionName = sessionName
        }
    }

    public let remoteSessionID: String
    /// The origin's presentation protocol version, nil for an origin that predates the stream.
    public let presentationVersion: Int?
    /// Nil for a binding built without one, which can then not be attached again.
    public let origin: Origin?
    private let localByRemotePane: [UUID: UUID]
    private let daemonsByLocalPane: [UUID: String]

    /// `daemonsByLocalPane` is what an attach knows: the daemon each local pane runs `zmx attach` against.
    /// A daemon name encodes the origin's pane identity, so the mapping is decoded once, here.
    public init(remoteSessionID: String, daemonsByLocalPane: [UUID: String], presentationVersion: Int?,
                origin: Origin? = nil) {
        self.remoteSessionID = remoteSessionID
        self.presentationVersion = presentationVersion
        self.origin = origin
        self.daemonsByLocalPane = daemonsByLocalPane
        var mapping: [UUID: UUID] = [:]
        for (local, daemon) in daemonsByLocalPane {
            if let remote = ZmxSupport.paneIdentity(fromDaemonName: daemon) { mapping[remote] = local }
        }
        localByRemotePane = mapping
    }

    public func localPane(forRemote identity: UUID) -> UUID? { localByRemotePane[identity] }

    public func daemon(forLocalPane identity: UUID) -> String? { daemonsByLocalPane[identity] }
}

/// RemotePresentationConnection is the state of a viewer's presentation stream, as read-back reports it.
public enum RemotePresentationConnection: Equatable, Sendable {
    case connecting
    case connected
    /// The origin predates the stream. Terminal for the row: nothing is ever launched.
    case unsupported
    case failed(String)

    /// What a remote row tells the user while its stream is not up, nil when there is nothing to say. Read
    /// from the state itself, so the notice clears the moment the stream is back. An origin too old for the
    /// stream gets none: nothing the user does here changes it.
    public func rowNotice(host: String) -> String? {
        switch self {
        case .connected, .unsupported: return nil
        case .connecting: return "Connecting to \(host) for status, context, notifications, dialogs and overlays"
        case .failed(let reason):
            return "Lost the connection to \(host) (\(reason)), retrying. Close and reattach the session to retry now."
        }
    }
}

/// RemotePresentationState is everything a viewer keeps about one attached session's presentation.
public struct RemotePresentationState: Equatable, Sendable {
    public let binding: RemoteBinding
    public var connection: RemotePresentationConnection
    public var mode: PresentationMode = .mirror
    /// Whether the glyph on the row is the bridge's. A flag and not a comparison of values: a pane swap
    /// rewrites the indicator without changing who set it, and a local write of the very same value does
    /// change who set it. Every local write clears this.
    public internal(set) var statusBridged = false
    /// False when the origin named a pane this Mac has no counterpart for: one the attach never mapped,
    /// one closed here since, or the origin's scratch. The glyph then carries no local owner.
    public internal(set) var statusOwnerResolved = true
    /// Whether the live HUD was opened by the bridge. Cleared whenever the HUD is discarded, so a panel the
    /// viewer's own program opens afterwards is never the bridge's to close.
    public internal(set) var hudBridged = false

    /// Whether the glyph on the row stands for a pane this Mac has no counterpart for. Every layer that
    /// turns `statusPane` into a local pane reads this first, since nil otherwise means the primary.
    public var statusOwnerUnknown: Bool { statusBridged && !statusOwnerResolved }

    /// Typing in a pane here must not clear a status that pane does not stand for.
    public var allowsKeystrokeStatusClear: Bool { !statusOwnerUnknown }

    init(binding: RemoteBinding) {
        self.binding = binding
        connection = binding.presentationVersion == nil ? .unsupported : .connecting
    }
}
