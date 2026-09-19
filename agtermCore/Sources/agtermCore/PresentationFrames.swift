import Foundation

/// PresentationPane names a pane of the origin session on the wire. A main or split pane travels as its stable
/// identity, never as a left/right role, so a swap or promotion on either Mac cannot misroute it.
public enum PresentationPane: Equatable, Sendable, Codable {
    case identity(UUID)
    case scratch

    private static let scratchName = "scratch"

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        if text == Self.scratchName {
            self = .scratch
            return
        }
        guard let id = UUID(uuidString: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "pane is neither scratch nor a uuid"))
        }
        self = .identity(id)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .identity(let id): try container.encode(id.uuidString)
        case .scratch: try container.encode(Self.scratchName)
        }
    }
}

/// PresentationMode is what a viewer asks to be: a mirror beside the origin, or the sole presenter.
public enum PresentationMode: String, Codable, Sendable {
    case mirror, presenter
}

/// PresentationHello opens a stream in both directions and carries what each side can speak.
public struct PresentationHello: Codable, Equatable, Sendable {
    public var version: Int
    public var kinds: [String]
    public var mode: PresentationMode

    public init(version: Int, kinds: [String], mode: PresentationMode) {
        self.version = version
        self.kinds = kinds
        self.mode = mode
    }
}

/// PresentationStatus is a session's full non-idle agent status. Idle travels as an absent status.
public struct PresentationStatus: Codable, Equatable, Sendable {
    public var status: AgentStatus
    public var blink: Bool
    public var color: String?
    public var shape: StatusShape?
    public var pane: PresentationPane?
    /// Epoch seconds on the origin's clock.
    public var changedAt: Double?

    public init(status: AgentStatus, blink: Bool, color: String?, shape: StatusShape?, pane: PresentationPane?,
                changedAt: Double?) {
        self.status = status
        self.blink = blink
        self.color = color
        self.shape = shape
        self.pane = pane
        self.changedAt = changedAt
    }
}

/// PresentationHud is the origin's live HUD. `generation` counts its publications; a withdrawal carries
/// none, and the frame's `rev` is what orders it against a replacement.
public struct PresentationHud: Codable, Equatable, Sendable {
    public var spec: HudSpec
    /// The pane a pane-scoped panel sits over; nil for a session-wide one. `HudSpec` holds only the position
    /// inside that area.
    public var pane: PresentationPane?
    public var generation: Int
    /// Seconds until the origin hides the panel, sampled when the frame was built; nil for a persistent one.
    public var remaining: Double?

    public init(spec: HudSpec, pane: PresentationPane?, generation: Int, remaining: Double?) {
        self.spec = spec
        self.pane = pane
        self.generation = generation
        self.remaining = remaining
    }
}

/// PresentationNotify is one control-origin notification. It is a live event, never part of a snapshot.
public struct PresentationNotify: Codable, Equatable, Sendable {
    public var title: String
    public var body: String
    public var pane: PresentationPane?
    public var source: String

    public init(title: String, body: String, pane: PresentationPane?, source: String) {
        self.title = title
        self.body = body
        self.pane = pane
        self.source = source
    }
}

/// PresentationSnapshot is the replaceable state a subscriber starts from.
public struct PresentationSnapshot: Codable, Equatable, Sendable {
    public var status: PresentationStatus?
    public var hud: PresentationHud?

    public init(status: PresentationStatus?, hud: PresentationHud?) {
        self.status = status
        self.hud = hud
    }
}

/// PresentationFrame is one line of the presentation stream. `gen` is the connection generation and `rev` a
/// revision monotonic within it, so a receiver can drop anything left over from an earlier connection.
public struct PresentationFrame: Equatable, Sendable {
    public enum Body: Equatable, Sendable {
        case hello(PresentationHello)
        case ping
        case ack
        case snapshot(PresentationSnapshot)
        case status(PresentationStatus?)
        case hud(PresentationHud?)
        case notify(PresentationNotify)
        /// A viewer asking to be the session's sole presenter. Sent only after the origin's hello offered it.
        case presenterAcquire
        case presenterGranted
        /// The role is held by another viewer; this one stays a mirror until it reconnects.
        case presenterRefused
        /// A kind this build does not speak. Kept, with its ordering, so a newer peer does not break the stream.
        case unknown(String)

        var kind: String {
            switch self {
            case .hello: return "hello"
            case .ping: return "ping"
            case .ack: return "ack"
            case .snapshot: return "snapshot"
            case .status: return "status"
            case .hud: return "hud"
            case .notify: return "notify"
            case .presenterAcquire: return "presenter.acquire"
            case .presenterGranted: return "presenter.granted"
            case .presenterRefused: return "presenter.refused"
            case .unknown(let kind): return kind
            }
        }
    }

    public var gen: Int
    public var rev: Int
    public var body: Body

    public init(gen: Int, rev: Int, body: Body) {
        self.gen = gen
        self.rev = rev
        self.body = body
    }
}

extension PresentationFrame: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, gen, rev, hello, snapshot, status, hud, notify
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gen = try container.decode(Int.self, forKey: .gen)
        rev = try container.decode(Int.self, forKey: .rev)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "hello": body = .hello(try container.decode(PresentationHello.self, forKey: .hello))
        case "ping": body = .ping
        case "ack": body = .ack
        case "snapshot": body = .snapshot(try container.decode(PresentationSnapshot.self, forKey: .snapshot))
        case "status": body = .status(try container.decodeIfPresent(PresentationStatus.self, forKey: .status))
        case "hud": body = .hud(try container.decodeIfPresent(PresentationHud.self, forKey: .hud))
        case "notify": body = .notify(try container.decode(PresentationNotify.self, forKey: .notify))
        case "presenter.acquire": body = .presenterAcquire
        case "presenter.granted": body = .presenterGranted
        case "presenter.refused": body = .presenterRefused
        default: body = .unknown(kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(body.kind, forKey: .kind)
        try container.encode(gen, forKey: .gen)
        try container.encode(rev, forKey: .rev)
        switch body {
        case .hello(let hello): try container.encode(hello, forKey: .hello)
        case .snapshot(let snapshot): try container.encode(snapshot, forKey: .snapshot)
        case .status(let status): try container.encodeIfPresent(status, forKey: .status)
        case .hud(let hud): try container.encodeIfPresent(hud, forKey: .hud)
        case .notify(let notify): try container.encode(notify, forKey: .notify)
        case .ping, .ack, .presenterAcquire, .presenterGranted, .presenterRefused, .unknown: break
        }
    }
}

/// PresentationCodec frames the stream as newline-delimited JSON, one frame per line.
public enum PresentationCodec {
    public enum FrameError: Error, Equatable {
        case oversize(Int)
        case malformed(String)
    }

    public static let version = 1
    /// A HUD body is the largest legitimate frame; this leaves it room and still bounds a hostile line.
    public static let maxFrameBytes = 256 * 1024
    /// Frames a subscriber may have queued before it counts as stalled.
    public static let maxPendingFrames = 256

    /// Encodes `frame` as one line, newline included.
    public static func encode(_ frame: PresentationFrame) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(frame)
        guard line.count < maxFrameBytes else { throw FrameError.oversize(line.count) }
        line.append(UInt8(ascii: "\n"))
        return line
    }

    /// Decodes one line, without its newline.
    public static func decode(_ line: Data) throws -> PresentationFrame {
        guard line.count <= maxFrameBytes else { throw FrameError.oversize(line.count) }
        do {
            return try JSONDecoder().decode(PresentationFrame.self, from: line)
        } catch let error as DecodingError {
            throw FrameError.malformed(detail(error))
        } catch {
            throw FrameError.malformed(error.localizedDescription)
        }
    }

    /// The version both sides speak, or nil when the peer's is not a version at all.
    public static func negotiatedVersion(ours: Int, theirs: Int) -> Int? {
        guard ours >= 1, theirs >= 1 else { return nil }
        return min(ours, theirs)
    }

    private static func detail(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _): return "missing \(key.stringValue)"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        @unknown default: return "undecodable frame"
        }
    }
}
