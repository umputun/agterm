import Foundation

/// Portable messages and launch decisions for the Live session host.
public enum SessionHost {
    public enum Attribution: String, Codable, Sendable, CaseIterable {
        case supervisor, app, orphaned, unknown
    }

    public enum ResponsibleProcess: Equatable, Sendable {
        case live(Int32)
        case dead
        case unknown
    }

    public static func classify(leader: Int32?, responsible: ResponsibleProcess?, hostPid: Int32?, appPid: Int32?) -> Attribution {
        guard let leader, leader > 0 else { return .unknown }
        switch responsible {
        case .dead: return .orphaned
        case .live(let pid) where pid > 0:
            if pid == leader { return .orphaned }
            if pid == hostPid { return .supervisor }
            if pid == appPid { return .app }
            return .unknown
        default: return .unknown
        }
    }

    public static let protocolVersion = 1
    /// Includes the newline terminator.
    public static let maximumFrameBytes = 64 * 1024

    public enum Rejection: Error, Equatable {
        case frameTooLarge
        case invalidFrame
        case invalidMessage
        case invalidSocketDirectory
        case socketPathTooLong
    }

    public struct Hello: Codable, Equatable, Sendable {
        public let protocolVersion: Int
        public let bundleID: String
        public let bundlePath: String
        public let pid: Int32?

        public init(bundleID: String, bundlePath: String, pid: Int32? = nil,
                    protocolVersion: Int = SessionHost.protocolVersion) {
            self.protocolVersion = protocolVersion
            self.bundleID = bundleID
            self.bundlePath = bundlePath
            self.pid = pid
        }

        private enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol"
            case bundleID, bundlePath, pid
        }
    }

    public struct Ensure: Codable, Equatable, Sendable {
        public let name: String
        public let argv: [String]
        public let cwd: String
        public let env: [String: String]
        public let rows: UInt16
        public let cols: UInt16

        public init(name: String, argv: [String], cwd: String, env: [String: String], rows: UInt16, cols: UInt16) {
            self.name = name
            self.argv = argv
            self.cwd = cwd
            self.env = env
            self.rows = rows
            self.cols = cols
        }
    }

    public struct Ready: Codable, Equatable, Sendable {
        public enum State: String, Codable, Sendable {
            case existing, created
        }

        public let state: State
        public let leaderPid: Int32

        public init(state: State, leaderPid: Int32) {
            self.state = state
            self.leaderPid = leaderPid
        }
    }

    public struct Failure: Codable, Equatable, Sendable {
        public enum Stage: String, Codable, Sendable {
            case before, started
        }

        public let stage: Stage
        public let message: String

        public init(stage: Stage, message: String) {
            self.stage = stage
            self.message = message
        }
    }

    public enum Request: Codable, Equatable, Sendable {
        case hello(Hello)
        case ensure(Ensure)
        case stop

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: MessageKey.self)
            guard container.allKeys.count == 1 else { throw Rejection.invalidMessage }
            switch container.allKeys.first {
            case .hello: self = .hello(try container.decode(Hello.self, forKey: .hello))
            case .ensure: self = .ensure(try container.decode(Ensure.self, forKey: .ensure))
            case .stop:
                _ = try container.decode(Empty.self, forKey: .stop)
                self = .stop
            default: throw Rejection.invalidMessage
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: MessageKey.self)
            switch self {
            case .hello(let hello): try container.encode(hello, forKey: .hello)
            case .ensure(let ensure): try container.encode(ensure, forKey: .ensure)
            case .stop: try container.encode(Empty(), forKey: .stop)
            }
        }
    }

    public enum Response: Codable, Equatable, Sendable {
        case hello(Hello)
        case ok(Ready)
        case error(Failure)
        case stopped

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: MessageKey.self)
            guard container.allKeys.count == 1 else { throw Rejection.invalidMessage }
            switch container.allKeys.first {
            case .hello: self = .hello(try container.decode(Hello.self, forKey: .hello))
            case .ok: self = .ok(try container.decode(Ready.self, forKey: .ok))
            case .error: self = .error(try container.decode(Failure.self, forKey: .error))
            case .stopped:
                _ = try container.decode(Empty.self, forKey: .stopped)
                self = .stopped
            default: throw Rejection.invalidMessage
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: MessageKey.self)
            switch self {
            case .hello(let hello): try container.encode(hello, forKey: .hello)
            case .ok(let ready): try container.encode(ready, forKey: .ok)
            case .error(let failure): try container.encode(failure, forKey: .error)
            case .stopped: try container.encode(Empty(), forKey: .stopped)
            }
        }
    }

    public struct Paths: Equatable, Sendable {
        public let socket: String
        public let ownerLock: String
        public let spawnLock: String
        public let pidfile: String
        public let log: String
    }

    public enum DispatchPhase: Sendable {
        case beforeDispatch, afterDispatch
    }

    public enum ClientOutcome: Equatable, Sendable {
        case plainAttach
        case fullAttach
        case uncertain

        public var diagnostic: String? {
            guard self == .uncertain else { return nil }
            return "Session creation could not be confirmed; the command may have started and was not retried."
        }

        public static func decide(phase: DispatchPhase, reply: Response?) -> ClientOutcome {
            switch reply {
            case .ok: return .plainAttach
            case .error(let failure): return failure.stage == .before ? .fullAttach : .uncertain
            case .hello, .stopped, nil: return phase == .beforeDispatch ? .fullAttach : .uncertain
            }
        }
    }

    public static func encodeFrame<Message: Encodable>(_ message: Message) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var frame = try encoder.encode(message)
        guard frame.count < maximumFrameBytes else { throw Rejection.frameTooLarge }
        frame.append(0x0A)
        return frame
    }

    public static func decodeFrame<Message: Decodable>(_ type: Message.Type, from frame: Data) throws -> Message {
        guard frame.count <= maximumFrameBytes else { throw Rejection.frameTooLarge }
        guard frame.count > 1, frame.last == 0x0A, !frame.dropLast().contains(0x0A) else { throw Rejection.invalidFrame }
        return try JSONDecoder().decode(type, from: frame.dropLast())
    }

    public static func paths(socketDirectory: String) throws -> Paths {
        guard (socketDirectory as NSString).isAbsolutePath else { throw Rejection.invalidSocketDirectory }
        let directory = URL(fileURLWithPath: socketDirectory, isDirectory: true).appendingPathComponent("session-host", isDirectory: true)
        let socket = directory.appendingPathComponent("session-host.sock").path
        // Darwin's sun_path reserves one of its 104 bytes for the terminating NUL.
        guard socket.utf8.count < 104 else { throw Rejection.socketPathTooLong }
        return Paths(socket: socket,
                     ownerLock: directory.appendingPathComponent("session-host.lock").path,
                     spawnLock: directory.appendingPathComponent("session-host.spawn.lock").path,
                     pidfile: directory.appendingPathComponent("session-host.pid").path,
                     log: directory.appendingPathComponent("session-host.log").path)
    }

    /// Compares protocol and bundle identity; the runtime must also verify the socket peer.
    public static func handshakeAccepts(local: Hello, remote: Hello) -> Bool {
        guard local.protocolVersion == protocolVersion, remote.protocolVersion == protocolVersion,
              local.bundleID == remote.bundleID,
              (local.bundlePath as NSString).isAbsolutePath,
              (remote.bundlePath as NSString).isAbsolutePath else { return false }
        return canonicalBundlePath(local.bundlePath) == canonicalBundlePath(remote.bundlePath)
    }

    private static func canonicalBundlePath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private enum MessageKey: String, CodingKey {
        case hello, ensure, ok, error, stop, stopped
    }

    private struct Empty: Codable {}
}
