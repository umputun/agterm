import AgtermResponsibility
import Darwin
import Foundation
import agtermCore

final class ClientConnector {
    private let paths: SessionHost.Paths
    private let socketDirectory: String
    private let environment: [String: String]
    private let executable: String
    private let identity: SessionHost.Hello
    private let startupTimeout: TimeInterval
    private let queueTimeout: TimeInterval

    /// `startupTimeout` bounds finding or starting a host; `queueTimeout` bounds the wait for its hello
    /// once connected, since the host answers one client at a time and each creation can take seconds.
    convenience init(socketDirectory: String, environment: [String: String], startupTimeout: TimeInterval = 5,
                     queueTimeout: TimeInterval = 30) throws {
        try self.init(paths: SessionHost.paths(socketDirectory: socketDirectory, key: HostIdentity.endpointKey()),
                      socketDirectory: socketDirectory, environment: environment, startupTimeout: startupTimeout,
                      queueTimeout: queueTimeout)
    }

    init(paths: SessionHost.Paths, socketDirectory: String, environment: [String: String], startupTimeout: TimeInterval = 5,
         queueTimeout: TimeInterval = 30) throws {
        self.paths = paths
        self.socketDirectory = socketDirectory
        self.environment = environment
        self.startupTimeout = startupTimeout
        self.queueTimeout = queueTimeout
        executable = try HostIdentity.executablePath(pid: getpid())
        identity = try HostIdentity.read(pid: getpid())
    }

    func ensureRunning() throws -> any ClientPeer {
        guard Responsibility.system.isAvailable else { throw HostFailure.invalidIdentity }
        let deadline = ProcessInfo.processInfo.systemUptime + startupTimeout
        let connection = try open(deadline: deadline) ?? startHost(deadline: deadline)
        return try handshake(connection, deadline: ProcessInfo.processInfo.systemUptime + queueTimeout)
    }

    /// stopExisting asks the host already serving `paths` to stop and returns its answer; nil when none listens.
    /// The host's image goes unchecked because an update moves or deletes it; a stop carries no pane, and the host
    /// refuses while it roots one.
    func stopExisting(replyTimeout: TimeInterval) throws -> SessionHost.Response? {
        guard let connection = try open(deadline: ProcessInfo.processInfo.systemUptime + startupTimeout) else { return nil }
        defer { close(connection.fd) }
        try greet(connection, pid: HostIdentity.peerPID(fd: connection.fd),
                  deadline: ProcessInfo.processInfo.systemUptime + queueTimeout)
        let deadline = ProcessInfo.processInfo.systemUptime + replyTimeout
        try connection.writeFrame(SessionHost.encodeFrame(SessionHost.Request.stop), deadline: deadline)
        return try connection.readResponse(deadline: deadline)
    }

    /// Holds the spawn lock only until a socket is reachable, so the handshake wait never blocks
    /// other clients from taking the lock, and a waiter joins a host published meanwhile.
    private func startHost(deadline: TimeInterval) throws -> HostConnection {
        try HostEndpoint.privateDirectory(socketDirectory)
        try HostEndpoint.privateDirectory(URL(fileURLWithPath: paths.socket).deletingLastPathComponent().path)
        let spawnLock = try openLock(paths.spawnLock)
        defer { close(spawnLock) }
        while flock(spawnLock, LOCK_EX | LOCK_NB) != 0 {
            if errno != EWOULDBLOCK && errno != EINTR { throw HostFailure.system(errno) }
            if let connection = try open(deadline: deadline) { return connection }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw HostFailure.timeout }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if let connection = try open(deadline: deadline) { return connection }
        let ownerLock = try openLock(paths.ownerLock)
        defer { close(ownerLock) }
        var spawned: Int32?
        defer {
            if let spawned { var status: Int32 = 0; _ = waitpid(spawned, &status, WNOHANG) }
        }
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let connection = try open(deadline: deadline) { return connection }
            if spawned == nil {
                if flock(ownerLock, LOCK_EX | LOCK_NB) == 0 {
                    // The host removes its stale endpoint under its own lifetime lock.
                    try hostCheck(flock(ownerLock, LOCK_UN))
                    spawned = try Responsibility.system.spawnDisclaimed(executable: executable,
                                      argv: [executable, "host", socketDirectory], env: environment)
                } else if errno != EWOULDBLOCK { throw HostFailure.system(errno) }
            }
            if let spawned {
                var status: Int32 = 0
                if waitpid(spawned, &status, WNOHANG) == spawned { throw HostFailure.disconnected }
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw HostFailure.timeout
    }

    private func openLock(_ path: String) throws -> Int32 {
        let fd = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        try hostCheck(fd)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), fchmod(fd, 0o600) == 0 else {
            close(fd)
            throw HostFailure.invalidRequest
        }
        return fd
    }

    private func open(deadline: TimeInterval) throws -> HostConnection? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try hostCheck(fd)
        var transferred = false
        defer { if !transferred { close(fd) } }
        let connection = try HostConnection(fd: fd)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = paths.socket.utf8CString
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in bytes.withUnsafeBytes { buffer.copyMemory(from: $0) } }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result < 0 {
            if errno == ENOENT || errno == ECONNREFUSED { return nil }
            guard errno == EINPROGRESS else { throw HostFailure.system(errno) }
            try hostWait(fd, events: Int16(POLLOUT), deadline: deadline)
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            try hostCheck(getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length))
            guard error == 0 else { throw HostFailure.system(error) }
        }
        transferred = true
        return connection
    }

    private func handshake(_ connection: HostConnection, deadline: TimeInterval) throws -> NativeClientPeer {
        var transferred = false
        defer { if !transferred { close(connection.fd) } }
        let peer = try HostIdentity.peer(fd: connection.fd)
        guard SessionHost.handshakeAccepts(local: identity, remote: peer), let pid = peer.pid else { throw HostFailure.invalidIdentity }
        try greet(connection, pid: pid, deadline: deadline)
        transferred = true
        return NativeClientPeer(connection: connection)
    }

    /// greet exchanges hellos and requires the answer to come from `pid`, a host responsible for itself.
    private func greet(_ connection: HostConnection, pid: Int32, deadline: TimeInterval) throws {
        try connection.writeFrame(SessionHost.encodeFrame(SessionHost.Request.hello(identity)), deadline: deadline)
        guard case .hello(let hello) = try connection.readResponse(deadline: deadline),
              SessionHost.handshakeAccepts(local: identity, remote: hello), hello.pid == pid,
              Responsibility.system.responsibleProcess(of: pid) == pid else { throw HostFailure.invalidIdentity }
    }
}

private final class NativeClientPeer: ClientPeer {
    private let connection: HostConnection
    private var closed = false
    init(connection: HostConnection) { self.connection = connection }
    deinit { close() }
    func send(_ frame: Data, deadline: TimeInterval) throws { try connection.writeFrame(frame, deadline: deadline) }
    func receive(deadline: TimeInterval) throws -> SessionHost.Response { try connection.readResponse(deadline: deadline) }
    func close() { if !closed { Darwin.close(connection.fd); closed = true } }
}
