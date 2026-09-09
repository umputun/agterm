import AgtermResponsibility
import Darwin
import Foundation
import agtermCore

enum HostChildState {
    case running
    case exited
    case failed
}

protocol HostChild: AnyObject {
    var pid: Int32 { get }
    var hasExited: Bool { get }
    func poll() -> HostChildState
    func terminate(grace: TimeInterval) throws
}

protocol HostBackend: AnyObject {
    func list(deadline: TimeInterval) throws -> [ZmxSessionRecord]
    func spawn(_ request: SessionHost.Ensure) throws -> any HostChild
    func responsibleProcess(of pid: Int32) -> Int32?
    func daemonPID(for leader: Int32) -> Int32?
    func isAlive(_ pid: Int32) -> Bool
}

public final class Host {
    struct Configuration {
        let socketDirectory: String
        let identity: SessionHost.Hello
        let zmxPath: String
        var ensureTimeout: TimeInterval = 10
        var pollInterval: TimeInterval = 0.1
        var terminationGrace: TimeInterval = 0.25
    }

    private let configuration: Configuration
    private let backend: any HostBackend
    private let now: () -> TimeInterval
    private let pause: (TimeInterval) -> Void
    private var pendingChildren: [any HostChild] = []
    private(set) var shouldStop = false

    init(configuration: Configuration, backend: any HostBackend,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         pause: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws {
        _ = try SessionHost.paths(socketDirectory: configuration.socketDirectory)
        self.configuration = configuration
        self.backend = backend
        self.now = now
        self.pause = pause
    }

    public static func run(socketDirectory: String) throws {
        let identity = try HostIdentity.read(pid: getpid())
        guard Responsibility.system.isAvailable else { throw Responsibility.SpawnError.unavailable }
        let executable = URL(fileURLWithPath: identity.bundlePath).appendingPathComponent("Contents/MacOS/zmx").path
        let endpoint = try HostEndpoint(socketDirectory: socketDirectory)
        defer { endpoint.close() }
        try hostCheck(setsid())
        try redirectStandardIO(logPath: endpoint.paths.log)
        let backend = NativeHostBackend(socketDirectory: socketDirectory, zmxPath: executable, environment: ProcessInfo.processInfo.environment)
        let host = try Host(configuration: .init(socketDirectory: socketDirectory, identity: identity, zmxPath: executable), backend: backend)
        try host.serve(endpoint)
    }

    func handle(ensure request: SessionHost.Ensure) -> SessionHost.Response {
        maintainChildren()
        guard valid(request) else { return failure(.before, "invalid daemon creation request") }
        let deadline = now() + configuration.ensureTimeout
        do {
            let records = try backend.list(deadline: deadline).filter { $0.name == request.name }
            if !records.isEmpty {
                guard records.count == 1, records[0].clients != nil, let pid = records[0].leaderPID, backend.isAlive(pid) else {
                    return failure(.before, "existing daemon could not be verified")
                }
                return .ok(.init(state: .existing, leaderPid: pid))
            }
        } catch { return failure(.before, "daemon inventory could not be read") }
        guard now() < deadline else { return failure(.before, "deadline expired before creation") }

        let child: any HostChild
        do { child = try backend.spawn(request) } catch { return failure(.started, "attach client startup could not be confirmed") }
        var response = awaitLeader(name: request.name, child: child, deadline: deadline)
        do { try child.terminate(grace: configuration.terminationGrace) } catch {
            pendingChildren.append(child)
            response = failure(.started, "attach client cleanup is incomplete")
        }
        return response
    }

    func handleStop() -> SessionHost.Response {
        maintainChildren()
        guard pendingChildren.isEmpty else { return failure(.before, "client cleanup is still pending") }
        do {
            for record in try backend.list(deadline: now() + configuration.ensureTimeout) {
                guard record.clients != nil, let leader = record.leaderPID, backend.isAlive(leader),
                      let daemon = backend.daemonPID(for: leader), backend.isAlive(daemon),
                      let responsible = backend.responsibleProcess(of: daemon) else {
                    return failure(.before, "daemon ownership could not be established")
                }
                if responsible == configuration.identity.pid {
                    return failure(.before, "live rooted daemons remain")
                }
            }
        } catch { return failure(.before, "daemon inventory could not be read") }
        shouldStop = true
        return .stopped
    }

    private func awaitLeader(name: String, child: any HostChild, deadline: TimeInterval) -> SessionHost.Response {
        while now() < deadline {
            guard case .running = child.poll() else { return failure(.started, "attach client exited or failed before readiness") }
            do {
                let matches = try backend.list(deadline: deadline).filter { $0.name == name }
                if matches.count == 1, matches[0].clients != nil, let pid = matches[0].leaderPID, backend.isAlive(pid),
                   backend.responsibleProcess(of: pid) == configuration.identity.pid {
                    return .ok(.init(state: .created, leaderPid: pid))
                }
            } catch { return failure(.started, "daemon readiness could not be inspected") }
            pause(min(configuration.pollInterval, max(0, deadline - now())))
        }
        return failure(.started, "timeout waiting for daemon leader")
    }

    private func valid(_ request: SessionHost.Ensure) -> Bool {
        guard ZmxSupport.isDaemonName(request.name), request.argv.count >= 3,
              (request.argv[0] as NSString).isAbsolutePath,
              HostIdentity.canonical(request.argv[0]) == HostIdentity.canonical(configuration.zmxPath),
              request.argv[1] == "attach", request.argv[2] == request.name,
              (request.cwd as NSString).isAbsolutePath,
              let directory = request.env["ZMX_DIR"], (directory as NSString).isAbsolutePath,
              HostIdentity.canonical(directory) == HostIdentity.canonical(configuration.socketDirectory),
              request.env["ZMX_SESSION", default: ""].isEmpty, request.env["ZMX_SESSION_PREFIX", default: ""].isEmpty else { return false }
        return true
    }

    private func maintainChildren() {
        pendingChildren.removeAll { child in
            _ = child.poll()
            return child.hasExited
        }
    }

    private func serve(_ endpoint: HostEndpoint) throws {
        while !shouldStop {
            maintainChildren()
            var ready = pollfd(fd: endpoint.listener, events: Int16(POLLIN), revents: 0)
            let result = poll(&ready, 1, 100)
            if result == 0 || (result < 0 && errno == EINTR) { continue }
            try hostCheck(result)
            let connection = accept(endpoint.listener, nil, nil)
            if connection < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            try hostCheck(connection)
            do { try handleConnection(connection) } catch { Self.log("connection rejected: \(error)") }
        }
    }

    private func handleConnection(_ fd: Int32) throws {
        defer { close(fd) }
        let connection = try HostConnection(fd: fd)
        let handshakeDeadline = now() + 2
        guard case .hello(let hello) = try connection.readRequest(deadline: handshakeDeadline) else { throw HostFailure.invalidRequest }
        let peer = try HostIdentity.peer(fd: fd)
        guard SessionHost.handshakeAccepts(local: configuration.identity, remote: hello),
              SessionHost.handshakeAccepts(local: hello, remote: peer), hello.pid == nil || hello.pid == peer.pid else {
            throw HostFailure.invalidIdentity
        }
        try connection.writeResponse(.hello(configuration.identity), deadline: handshakeDeadline)
        let response: SessionHost.Response
        switch try connection.readRequest(deadline: now() + 2) {
        case .ensure(let request): response = handle(ensure: request)
        case .stop: response = handleStop()
        case .hello: throw HostFailure.invalidRequest
        }
        try connection.writeResponse(response, deadline: now() + 2)
    }

    private func failure(_ stage: SessionHost.Failure.Stage, _ message: String) -> SessionHost.Response {
        .error(.init(stage: stage, message: message))
    }

    private static func redirectStandardIO(logPath: String) throws {
        let empty = open("/dev/null", O_RDWR | O_CLOEXEC)
        try hostCheck(empty)
        defer { if empty > STDERR_FILENO { close(empty) } }
        let log = open(logPath, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        try hostCheck(log)
        defer { if log > STDERR_FILENO { close(log) } }
        try hostCheck(dup2(empty, STDIN_FILENO))
        try hostCheck(dup2(empty, STDOUT_FILENO))
        try hostCheck(dup2(log, STDERR_FILENO))
    }

    private static func log(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
    }
}
