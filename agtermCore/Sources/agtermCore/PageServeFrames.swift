import Foundation

/// PageServeFrame is one line of a page channel, the connection a presenter's helper opens back to the origin
/// for one handed-over page. It multiplexes resource transfers and bridge calls by request id.
public enum PageServeFrame: Equatable, Sendable {
    /// resource asks for one of the page's files by its path on the origin.
    case resource(id: Int, path: String)
    /// head starts a resource's answer; chunks follow, then `end`.
    case head(id: Int, mimeType: String)
    case chunk(id: Int, data: Data)
    case end(id: Int)
    /// failure ends a resource or bridge request the other side could not serve.
    case failure(id: Int, error: String)
    /// cancel withdraws a resource request whose answer is no longer wanted.
    case cancel(id: Int)
    /// bridge carries a page's control request as the raw JSON the page sent. Only the origin decodes it, so a
    /// presenter on an older protocol neither refuses nor strips a command or argument it does not know.
    case bridge(id: Int, request: String)
    /// reply carries the origin's raw JSON response, passed to the page as received.
    case reply(id: Int, response: String)

    /// busy is the failure a request gets when the origin already runs as many of its kind as it takes.
    public static let busy = "too many requests in flight"
    /// cancelled is the failure that ends a transfer the viewer cancelled.
    public static let cancelled = "cancelled"

    public var id: Int {
        switch self {
        case .resource(let id, _), .head(let id, _), .chunk(let id, _), .end(let id), .failure(let id, _),
             .cancel(let id), .bridge(let id, _), .reply(let id, _):
            return id
        }
    }
}

extension PageServeFrame: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, id, path, mimeType, data, error, request, response
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(Int.self, forKey: .id)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "resource":
            self = .resource(id: id, path: try container.decode(String.self, forKey: .path))
        case "head": self = .head(id: id, mimeType: try container.decode(String.self, forKey: .mimeType))
        case "chunk": self = .chunk(id: id, data: try container.decode(Data.self, forKey: .data))
        case "end": self = .end(id: id)
        case "failure": self = .failure(id: id, error: try container.decode(String.self, forKey: .error))
        case "cancel": self = .cancel(id: id)
        case "bridge": self = .bridge(id: id, request: try container.decode(String.self, forKey: .request))
        case "reply": self = .reply(id: id, response: try container.decode(String.self, forKey: .response))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "unknown kind \(kind)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        switch self {
        case .resource(_, let path):
            try container.encode("resource", forKey: .kind)
            try container.encode(path, forKey: .path)
        case .head(_, let mimeType):
            try container.encode("head", forKey: .kind)
            try container.encode(mimeType, forKey: .mimeType)
        case .chunk(_, let data):
            try container.encode("chunk", forKey: .kind)
            try container.encode(data, forKey: .data)
        case .end:
            try container.encode("end", forKey: .kind)
        case .failure(_, let error):
            try container.encode("failure", forKey: .kind)
            try container.encode(error, forKey: .error)
        case .cancel:
            try container.encode("cancel", forKey: .kind)
        case .bridge(_, let request):
            try container.encode("bridge", forKey: .kind)
            try container.encode(request, forKey: .request)
        case .reply(_, let response):
            try container.encode("reply", forKey: .kind)
            try container.encode(response, forKey: .response)
        }
    }
}

/// PageServeCodec frames a page channel as newline-delimited JSON. It refuses a line over `maxFrameBytes` and a
/// chunk body over `maxChunkBytes`, in both directions.
public enum PageServeCodec {
    public static let maxChunkBytes = 64 * 1024
    public static let maxFrameBytes = PresentationCodec.maxFrameBytes

    /// encode renders `frame` as one line, newline included.
    public static func encode(_ frame: PageServeFrame) throws -> Data {
        try checkChunk(frame)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(frame)
        guard line.count < maxFrameBytes else { throw PresentationCodec.FrameError.oversize(line.count) }
        line.append(UInt8(ascii: "\n"))
        return line
    }

    /// decode parses one line, without its newline.
    public static func decode(_ line: Data) throws -> PageServeFrame {
        guard line.count <= maxFrameBytes else { throw PresentationCodec.FrameError.oversize(line.count) }
        let frame: PageServeFrame
        do {
            frame = try JSONDecoder().decode(PageServeFrame.self, from: line)
        } catch {
            throw PresentationCodec.FrameError.malformed(String(describing: error))
        }
        try checkChunk(frame)
        return frame
    }

    private static func checkChunk(_ frame: PageServeFrame) throws {
        guard case .chunk(_, let data) = frame, data.count > maxChunkBytes else { return }
        throw PresentationCodec.FrameError.oversize(data.count)
    }
}
