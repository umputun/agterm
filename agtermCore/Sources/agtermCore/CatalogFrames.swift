import Foundation

/// CatalogVersions is what a headless origin advertises: its build, the presentation protocol it speaks and the
/// catalog protocol. A Mac origin advertises none, which is how a remote window knows not to bind to it.
public struct CatalogVersions: Codable, Equatable, Sendable {
    public var server: String
    public var protocolVersion: Int
    public var catalog: Int

    public init(server: String, protocolVersion: Int, catalog: Int) {
        self.server = server
        self.protocolVersion = protocolVersion
        self.catalog = catalog
    }

    enum CodingKeys: String, CodingKey {
        case server, protocolVersion = "protocol", catalog
    }
}

/// CatalogLifecycle is `ended` for a session whose panes are all gone without their shell exiting; it stays in
/// the catalog until closed.
public enum CatalogLifecycle: String, Codable, Sendable {
    case live, ended
}

/// CatalogPane is one daemon-backed pane: its stable identity, the zmx daemon carrying it and how to reach it.
public struct CatalogPane: Codable, Equatable, Sendable {
    public var identity: UUID
    public var daemon: String
    public var endpoint: ControlZmxEndpoint

    public init(identity: UUID, daemon: String, endpoint: ControlZmxEndpoint) {
        self.identity = identity
        self.daemon = daemon
        self.endpoint = endpoint
    }
}

/// CatalogSessionFields is a session without its panes, which travel as their own changes.
public struct CatalogSessionFields: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var parent: UUID?
    public var cwd: String
    /// primary is the left pane's identity.
    public var primary: UUID
    /// axis is present only for a session that has a split.
    public var axis: String?
    /// shown is whether the split is shown.
    public var shown: Bool
    public var lifecycle: CatalogLifecycle
    /// scratch is the session's server scratch while its daemon runs, an ended session's included.
    public var scratch: CatalogScratch?

    public init(id: UUID, name: String, parent: UUID?, cwd: String, primary: UUID, axis: String?, shown: Bool,
                lifecycle: CatalogLifecycle, scratch: CatalogScratch? = nil) {
        self.id = id
        self.name = name
        self.parent = parent
        self.cwd = cwd
        self.primary = primary
        self.axis = axis
        self.shown = shown
        self.lifecycle = lifecycle
        self.scratch = scratch
    }
}

/// CatalogScratch is a session's scratch on agterm-server: its daemon, attached like a pane, and whether it is shown.
public struct CatalogScratch: Codable, Equatable, Sendable {
    public var pane: CatalogPane
    public var shown: Bool

    public init(pane: CatalogPane, shown: Bool) {
        self.pane = pane
        self.shown = shown
    }
}

/// CatalogSession is a session with its panes, the primary pane first.
public struct CatalogSession: Codable, Equatable, Sendable {
    public var fields: CatalogSessionFields
    public var panes: [CatalogPane]

    public init(fields: CatalogSessionFields, panes: [CatalogPane]) {
        self.fields = fields
        self.panes = panes
        normalize()
    }

    public var id: UUID { fields.id }

    /// normalize puts the primary pane first, the one pane order the wire knows.
    mutating func normalize() {
        guard let index = panes.firstIndex(where: { $0.identity == fields.primary }), index > 0 else { return }
        panes.insert(panes.remove(at: index), at: 0)
    }

    public init(from decoder: Decoder) throws {
        fields = try CatalogSessionFields(from: decoder)
        panes = try decoder.container(keyedBy: CodingKeys.self).decode([CatalogPane].self, forKey: .panes)
        normalize()
    }

    public func encode(to encoder: Encoder) throws {
        try fields.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(panes, forKey: .panes)
    }

    enum CodingKeys: String, CodingKey {
        case panes
    }
}

public struct CatalogWorkspace: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var sessions: [CatalogSession]

    public init(id: UUID, name: String, sessions: [CatalogSession]) {
        self.id = id
        self.name = name
        self.sessions = sessions
    }
}

/// CatalogSnapshot is the whole catalog at `(epoch, rev)`. A new epoch is a restarted server, whose revisions
/// start over and never compare with an earlier epoch's.
public struct CatalogSnapshot: Codable, Equatable, Sendable {
    public var epoch: String
    public var rev: Int
    public var catalogID: UUID
    public var versions: CatalogVersions
    public var workspaces: [CatalogWorkspace]

    public init(epoch: String, rev: Int, catalogID: UUID, versions: CatalogVersions, workspaces: [CatalogWorkspace]) {
        self.epoch = epoch
        self.rev = rev
        self.catalogID = catalogID
        self.versions = versions
        self.workspaces = workspaces
    }
}

/// CatalogChange is one structural change, applied in order by `CatalogSnapshot.apply`.
public enum CatalogChange: Equatable, Sendable {
    case workspaceAdded(CatalogWorkspace, index: Int)
    case workspaceChanged(id: UUID, name: String)
    case workspaceRemoved(UUID)
    case workspaceOrder([UUID])
    case sessionAdded(CatalogSession, workspace: UUID, index: Int)
    case sessionChanged(CatalogSessionFields)
    case sessionRemoved(UUID)
    /// sessionMoved puts a session into another workspace; the viewer keeps its row.
    case sessionMoved(UUID, workspace: UUID, index: Int)
    case sessionOrder([UUID], workspace: UUID)
    case paneAdded(CatalogPane, session: UUID)
    case paneChanged(CatalogPane, session: UUID)
    case paneRemoved(UUID, session: UUID)

    public var kind: String {
        switch self {
        case .workspaceAdded: "workspace.added"
        case .workspaceChanged: "workspace.changed"
        case .workspaceRemoved: "workspace.removed"
        case .workspaceOrder: "workspace.order"
        case .sessionAdded: "session.added"
        case .sessionChanged: "session.changed"
        case .sessionRemoved: "session.removed"
        case .sessionMoved: "session.moved"
        case .sessionOrder: "session.order"
        case .paneAdded: "pane.added"
        case .paneChanged: "pane.changed"
        case .paneRemoved: "pane.removed"
        }
    }
}

public struct CatalogHello: Codable, Equatable, Sendable {
    public var version: Int
    /// epoch is set on the server's answer, never on the viewer's opening hello.
    public var epoch: String?
    public var versions: CatalogVersions?

    public init(version: Int, epoch: String? = nil, versions: CatalogVersions? = nil) {
        self.version = version
        self.epoch = epoch
        self.versions = versions
    }
}

/// CatalogFrame is one line of the catalog stream. A delta's kind is its change's kind; an unknown kind decodes
/// as `.unknown`, keeping the envelope's epoch and revision so a viewer can step past it, and is never an error.
public enum CatalogFrame: Equatable, Sendable {
    case hello(CatalogHello)
    case snapshot(CatalogSnapshot)
    /// chunk is one base64 slice of an oversized snapshot's JSON; nothing applies until its commit.
    case chunk(index: Int, data: String)
    case commit(epoch: String, rev: Int, chunks: Int)
    case delta(epoch: String, rev: Int, change: CatalogChange)
    case ping
    case ack
    case unknown(kind: String, epoch: String?, rev: Int?)
}

extension CatalogFrame: Codable {
    private enum Keys: String, CodingKey {
        case kind, hello, snapshot, index, data, epoch, rev, chunks
        case workspace, session, id, ids, name, pane, identity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "hello": self = .hello(try container.decode(CatalogHello.self, forKey: .hello))
        case "snapshot": self = .snapshot(try container.decode(CatalogSnapshot.self, forKey: .snapshot))
        case "snapshot.chunk":
            self = .chunk(index: try container.decode(Int.self, forKey: .index), data: try container.decode(String.self, forKey: .data))
        case "snapshot.commit":
            self = .commit(epoch: try container.decode(String.self, forKey: .epoch), rev: try container.decode(Int.self, forKey: .rev),
                           chunks: try container.decode(Int.self, forKey: .chunks))
        case "ping": self = .ping
        case "ack": self = .ack
        default:
            guard let change = try Self.change(kind, container) else {
                self = .unknown(kind: kind, epoch: try container.decodeIfPresent(String.self, forKey: .epoch),
                                rev: try container.decodeIfPresent(Int.self, forKey: .rev))
                return
            }
            self = .delta(epoch: try container.decode(String.self, forKey: .epoch), rev: try container.decode(Int.self, forKey: .rev),
                          change: change)
        }
    }

    private static func change(_ kind: String, _ container: KeyedDecodingContainer<Keys>) throws -> CatalogChange? {
        switch kind {
        case "workspace.added":
            return .workspaceAdded(try container.decode(CatalogWorkspace.self, forKey: .workspace),
                                   index: try container.decode(Int.self, forKey: .index))
        case "workspace.changed":
            return .workspaceChanged(id: try container.decode(UUID.self, forKey: .id), name: try container.decode(String.self, forKey: .name))
        case "workspace.removed": return .workspaceRemoved(try container.decode(UUID.self, forKey: .id))
        case "workspace.order": return .workspaceOrder(try container.decode([UUID].self, forKey: .ids))
        case "session.added":
            return .sessionAdded(try container.decode(CatalogSession.self, forKey: .session),
                                 workspace: try container.decode(UUID.self, forKey: .workspace),
                                 index: try container.decode(Int.self, forKey: .index))
        case "session.changed": return .sessionChanged(try container.decode(CatalogSessionFields.self, forKey: .session))
        case "session.removed": return .sessionRemoved(try container.decode(UUID.self, forKey: .id))
        case "session.moved":
            return .sessionMoved(try container.decode(UUID.self, forKey: .id), workspace: try container.decode(UUID.self, forKey: .workspace),
                                 index: try container.decode(Int.self, forKey: .index))
        case "session.order":
            return .sessionOrder(try container.decode([UUID].self, forKey: .ids), workspace: try container.decode(UUID.self, forKey: .workspace))
        case "pane.added":
            return .paneAdded(try container.decode(CatalogPane.self, forKey: .pane), session: try container.decode(UUID.self, forKey: .session))
        case "pane.changed":
            return .paneChanged(try container.decode(CatalogPane.self, forKey: .pane), session: try container.decode(UUID.self, forKey: .session))
        case "pane.removed":
            return .paneRemoved(try container.decode(UUID.self, forKey: .identity), session: try container.decode(UUID.self, forKey: .session))
        default: return nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .hello(let hello):
            try container.encode("hello", forKey: .kind)
            try container.encode(hello, forKey: .hello)
        case .snapshot(let snapshot):
            try container.encode("snapshot", forKey: .kind)
            try container.encode(snapshot, forKey: .snapshot)
        case .chunk(let index, let data):
            try container.encode("snapshot.chunk", forKey: .kind)
            try container.encode(index, forKey: .index)
            try container.encode(data, forKey: .data)
        case .commit(let epoch, let rev, let chunks):
            try container.encode("snapshot.commit", forKey: .kind)
            try container.encode(epoch, forKey: .epoch)
            try container.encode(rev, forKey: .rev)
            try container.encode(chunks, forKey: .chunks)
        case .delta(let epoch, let rev, let change):
            try container.encode(change.kind, forKey: .kind)
            try container.encode(epoch, forKey: .epoch)
            try container.encode(rev, forKey: .rev)
            try Self.encode(change, into: &container)
        case .ping: try container.encode("ping", forKey: .kind)
        case .ack: try container.encode("ack", forKey: .kind)
        case .unknown(let kind, let epoch, let rev):
            try container.encode(kind, forKey: .kind)
            try container.encodeIfPresent(epoch, forKey: .epoch)
            try container.encodeIfPresent(rev, forKey: .rev)
        }
    }

    private static func encode(_ change: CatalogChange, into container: inout KeyedEncodingContainer<Keys>) throws {
        switch change {
        case .workspaceAdded(let workspace, let index):
            try container.encode(workspace, forKey: .workspace)
            try container.encode(index, forKey: .index)
        case .workspaceChanged(let id, let name):
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
        case .workspaceRemoved(let id), .sessionRemoved(let id): try container.encode(id, forKey: .id)
        case .workspaceOrder(let ids): try container.encode(ids, forKey: .ids)
        case .sessionAdded(let session, let workspace, let index):
            try container.encode(session, forKey: .session)
            try container.encode(workspace, forKey: .workspace)
            try container.encode(index, forKey: .index)
        case .sessionChanged(let fields): try container.encode(fields, forKey: .session)
        case .sessionMoved(let id, let workspace, let index):
            try container.encode(id, forKey: .id)
            try container.encode(workspace, forKey: .workspace)
            try container.encode(index, forKey: .index)
        case .sessionOrder(let ids, let workspace):
            try container.encode(ids, forKey: .ids)
            try container.encode(workspace, forKey: .workspace)
        case .paneAdded(let pane, let session), .paneChanged(let pane, let session):
            try container.encode(pane, forKey: .pane)
            try container.encode(session, forKey: .session)
        case .paneRemoved(let identity, let session):
            try container.encode(identity, forKey: .identity)
            try container.encode(session, forKey: .session)
        }
    }
}

/// CatalogCodec frames the catalog stream as newline-delimited JSON under the presentation stream's frame cap.
public enum CatalogCodec {
    public static let version = 1
    public static let maxFrameBytes = PresentationCodec.maxFrameBytes
    /// chunkBytes is raw snapshot bytes per chunk; base64 grows them by a third and still leaves room under the cap.
    static let chunkBytes = 128 * 1024

    public static func encode(_ frame: CatalogFrame) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(frame)
        guard line.count < maxFrameBytes else { throw PresentationCodec.FrameError.oversize(line.count) }
        line.append(UInt8(ascii: "\n"))
        return line
    }

    public static func decode(_ line: Data) throws -> CatalogFrame {
        guard line.count <= maxFrameBytes else { throw PresentationCodec.FrameError.oversize(line.count) }
        return try JSONDecoder().decode(CatalogFrame.self, from: line)
    }

    /// snapshotFrames is the snapshot as one frame, or as chunks and a commit when one frame would pass the cap.
    public static func snapshotFrames(_ snapshot: CatalogSnapshot) throws -> [CatalogFrame] {
        let whole = CatalogFrame.snapshot(snapshot)
        if (try? encode(whole)) != nil { return [whole] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(snapshot)
        var frames: [CatalogFrame] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkBytes, data.count)
            frames.append(.chunk(index: frames.count, data: data[offset..<end].base64EncodedString()))
            offset = end
        }
        frames.append(.commit(epoch: snapshot.epoch, rev: snapshot.rev, chunks: frames.count))
        return frames
    }
}

/// CatalogChunks gathers an oversized snapshot's chunks and yields it only at a commit that matches them.
public struct CatalogChunks: Sendable {
    public enum Failure: Error, Equatable {
        case outOfOrder(Int)
        case incomplete(expected: Int, got: Int)
        case mismatched
    }

    private var data = Data()
    private var count = 0

    public init() {}

    public mutating func add(index: Int, data slice: String) throws {
        guard index == count, let bytes = Data(base64Encoded: slice) else {
            reset()
            throw Failure.outOfOrder(index)
        }
        data.append(bytes)
        count += 1
    }

    public mutating func commit(epoch: String, rev: Int, chunks: Int) throws -> CatalogSnapshot {
        defer { reset() }
        guard chunks == count else { throw Failure.incomplete(expected: chunks, got: count) }
        let snapshot = try JSONDecoder().decode(CatalogSnapshot.self, from: data)
        guard snapshot.epoch == epoch, snapshot.rev == rev else { throw Failure.mismatched }
        return snapshot
    }

    private mutating func reset() {
        data = Data()
        count = 0
    }
}
