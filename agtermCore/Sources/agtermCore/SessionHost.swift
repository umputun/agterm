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

    /// Roots is the live hosts of one socket directory and what is known of the one serving the current key.
    public struct Roots: Equatable, Sendable {
        /// Current is the current key's host: running, known key with no host, or the key could not be read,
        /// which leaves every host's freshness unknown.
        public enum Current: Equatable, Sendable {
            case running(Int32)
            case absent
            case unknown
        }

        public let hosts: Set<Int32>
        public let current: Current

        public init(hosts: Set<Int32>, current: Current) {
            self.hosts = hosts
            self.current = current
        }
    }

    /// Placement is a pane's attribution plus whether its root is a host other than the current one.
    public struct Placement: Equatable, Sendable {
        public let attribution: Attribution
        public let staleHost: Bool

        public init(attribution: Attribution, staleHost: Bool) {
            self.attribution = attribution
            self.staleHost = staleHost
        }
    }

    public static func place(leader: Int32?, responsible: ResponsibleProcess?, roots: Roots, appPid: Int32?) -> Placement {
        var host: Int32?
        if case .live(let pid) = responsible, roots.hosts.contains(pid) { host = pid }
        let attribution = classify(leader: leader, responsible: responsible, hostPid: host, appPid: appPid)
        let stale = switch roots.current {
        case .running(let current): host != current
        case .absent: true
        case .unknown: false
        }
        return Placement(attribution: attribution, staleHost: attribution == .supervisor && stale)
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
        case invalidEndpointKey
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

    /// legacyEndpoint is the one host directory of builds that predate endpoint keys. Its host may still
    /// root daemons, so cleanup and attribution include it.
    public static let legacyEndpoint = "session-host"

    /// endpointKey names the host of one helper build in one login session: a new build or a new login
    /// gets a fresh host, while the earlier one keeps rooting the daemons it created. `imageUUID` is the
    /// helper's loaded Mach-O UUID, `auditSession` the caller's audit session id.
    public static func endpointKey(imageUUID: UUID, auditSession: Int32) -> String {
        let hex = imageUUID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "\(hex.prefix(12))-\(auditSession)"
    }

    /// endpointName is the directory under the socket directory holding the host for `key`.
    public static func endpointName(key: String) throws -> String {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 12, parts[0].allSatisfy(\.isHexDigit), parts[0] == parts[0].lowercased(),
              !parts[1].isEmpty, parts[1].count <= 10, parts[1].allSatisfy(\.isASCII), parts[1].allSatisfy(\.isNumber) else {
            throw Rejection.invalidEndpointKey
        }
        return "\(legacyEndpoint)-\(key)"
    }

    /// isEndpointName accepts the legacy directory and every keyed one, the names cleanup and attribution scan.
    public static func isEndpointName(_ name: String) -> Bool {
        guard name != legacyEndpoint else { return true }
        let prefix = legacyEndpoint + "-"
        guard name.hasPrefix(prefix) else { return false }
        return (try? endpointName(key: String(name.dropFirst(prefix.count)))) == name
    }

    public static func paths(socketDirectory: String, key: String) throws -> Paths {
        try paths(socketDirectory: socketDirectory, endpoint: endpointName(key: key))
    }

    /// paths(socketDirectory:) is the legacy endpoint's.
    public static func paths(socketDirectory: String) throws -> Paths {
        try paths(socketDirectory: socketDirectory, endpoint: legacyEndpoint)
    }

    public static func paths(socketDirectory: String, endpoint: String) throws -> Paths {
        guard isEndpointName(endpoint) else { throw Rejection.invalidEndpointKey }
        guard (socketDirectory as NSString).isAbsolutePath else { throw Rejection.invalidSocketDirectory }
        let directory = URL(fileURLWithPath: socketDirectory, isDirectory: true).appendingPathComponent(endpoint, isDirectory: true)
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
