import Darwin
import Foundation
import agtermCore

enum HostFailure: Error {
    case system(Int32)
    case timeout
    case disconnected
    case invalidIdentity
    case invalidRequest
    case alreadyRunning
    case outputTooLarge
    case cleanupIncomplete
}

func hostCheck(_ result: Int32) throws {
    if result < 0 { throw HostFailure.system(errno) }
}

func hostNonblocking(_ fd: Int32) throws {
    let flags = fcntl(fd, F_GETFL)
    try hostCheck(flags)
    try hostCheck(fcntl(fd, F_SETFL, flags | O_NONBLOCK))
}

func hostCloseOnExec(_ fd: Int32) throws {
    let flags = fcntl(fd, F_GETFD)
    try hostCheck(flags)
    try hostCheck(fcntl(fd, F_SETFD, flags | FD_CLOEXEC))
}

func hostWait(_ fd: Int32, events: Int16, deadline: TimeInterval) throws {
    while true {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw HostFailure.timeout }
        var entry = pollfd(fd: fd, events: events, revents: 0)
        let result = poll(&entry, 1, Int32(min(remaining * 1000 + 1, Double(Int32.max))))
        if result > 0 { return }
        if result < 0 && errno != EINTR { throw HostFailure.system(errno) }
    }
}

final class HostEndpoint {
    let paths: SessionHost.Paths
    private(set) var listener: Int32 = -1
    private var owner: Int32 = -1
    private var ownsPath = false

    init(socketDirectory: String) throws {
        paths = try SessionHost.paths(socketDirectory: socketDirectory)
        do {
            try Self.privateDirectory(socketDirectory)
            try Self.privateDirectory(URL(fileURLWithPath: paths.socket).deletingLastPathComponent().path)
            owner = open(paths.ownerLock, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
            try hostCheck(owner)
            guard flock(owner, LOCK_EX | LOCK_NB) == 0 else { throw HostFailure.alreadyRunning }
            ownsPath = true
            unlink(paths.socket)
            listener = socket(AF_UNIX, SOCK_STREAM, 0)
            try hostCheck(listener)
            try hostCloseOnExec(listener)
            try hostNonblocking(listener)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let bytes = paths.socket.utf8CString
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in bytes.withUnsafeBytes { buffer.copyMemory(from: $0) } }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            try hostCheck(bound)
            try hostCheck(chmod(paths.socket, 0o600))
            try hostCheck(listen(listener, 128))
            let pidFile = open(paths.pidfile, O_CREAT | O_WRONLY | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0o600)
            try hostCheck(pidFile)
            defer { Darwin.close(pidFile) }
            let pid = Array("\(getpid())\n".utf8)
            let written = pid.withUnsafeBytes { write(pidFile, $0.baseAddress, $0.count) }
            guard written == pid.count else { throw HostFailure.system(errno) }
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    func close() {
        if listener >= 0 { Darwin.close(listener); listener = -1 }
        if ownsPath { unlink(paths.socket); unlink(paths.pidfile); ownsPath = false }
        if owner >= 0 { Darwin.close(owner); owner = -1 }
    }

    static func privateDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else { throw HostFailure.invalidRequest }
        try hostCheck(chmod(path, 0o700))
    }
}

final class HostConnection {
    let fd: Int32
    private var buffered = Data()

    init(fd: Int32) throws {
        self.fd = fd
        try hostCloseOnExec(fd)
        try hostNonblocking(fd)
        var enabled: Int32 = 1
        try hostCheck(setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)))
    }

    func readRequest(deadline: TimeInterval) throws -> SessionHost.Request {
        try readFrame(SessionHost.Request.self, deadline: deadline)
    }

    func readResponse(deadline: TimeInterval) throws -> SessionHost.Response {
        try readFrame(SessionHost.Response.self, deadline: deadline)
    }

    private func readFrame<Value: Decodable>(_ type: Value.Type, deadline: TimeInterval) throws -> Value {
        while true {
            if let newline = buffered.firstIndex(of: 0x0A) {
                let frame = Data(buffered[...newline])
                buffered.removeSubrange(...newline)
                return try SessionHost.decodeFrame(type, from: frame)
            }
            guard buffered.count < SessionHost.maximumFrameBytes else { throw SessionHost.Rejection.frameTooLarge }
            try hostWait(fd, events: Int16(POLLIN), deadline: deadline)
            var bytes = [UInt8](repeating: 0, count: min(4096, SessionHost.maximumFrameBytes - buffered.count))
            let count = read(fd, &bytes, bytes.count)
            if count > 0 { buffered.append(contentsOf: bytes.prefix(count)); continue }
            if count == 0 { throw HostFailure.disconnected }
            if errno != EINTR && errno != EAGAIN { throw HostFailure.system(errno) }
        }
    }

    func writeResponse(_ response: SessionHost.Response, deadline: TimeInterval) throws {
        try writeFrame(SessionHost.encodeFrame(response), deadline: deadline)
    }

    func writeFrame(_ frame: Data, deadline: TimeInterval) throws {
        var offset = 0
        while offset < frame.count {
            try hostWait(fd, events: Int16(POLLOUT), deadline: deadline)
            let count = frame.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if count > 0 { offset += count; continue }
            if count == 0 { throw HostFailure.disconnected }
            if errno != EINTR && errno != EAGAIN { throw HostFailure.system(errno) }
        }
    }
}
