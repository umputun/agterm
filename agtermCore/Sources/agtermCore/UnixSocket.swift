import Foundation

/// UnixSocket is the portable spelling of a local stream socket: Glibc types `SOCK_STREAM` as an enum, and
/// `sun_path` is 104 bytes on Darwin and 108 on Linux.
public enum UnixSocket {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case pathTooLong(String)
        case system(String)

        public var description: String {
            switch self {
            case .pathTooLong(let path): "socket path too long (\(path.utf8.count) bytes): \(path)"
            case .system(let message): message
            }
        }
    }

    #if canImport(Glibc) || canImport(Musl)
    public static let streamType = Int32(SOCK_STREAM.rawValue)
    #else
    public static let streamType = SOCK_STREAM
    #endif

    /// address is `path` as a `sockaddr_un`, nil when it does not fit with its terminator.
    public static func address(for path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = path.utf8CString
        guard bytes.count <= capacity else { return nil }
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            bytes.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        return addr
    }

    /// listening binds `path` with `mode` and listens with the system's largest backlog. A file already at
    /// `path` is removed first, so the caller must own the path, as a state-directory lock makes it.
    public static func listening(path: String, mode: mode_t = 0o600) throws -> Int32 {
        guard var addr = address(for: path) else { throw Failure.pathTooLong(path) }
        let fd = socket(AF_UNIX, streamType, 0)
        guard fd >= 0 else { throw Failure.system("socket() failed: \(errnoText())") }
        unlink(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let message = errnoText()
            close(fd)
            throw Failure.system("bind(\(path)) failed: \(message)")
        }
        chmod(path, mode)
        guard listen(fd, SOMAXCONN) == 0 else {
            let message = errnoText()
            close(fd)
            unlink(path)
            throw Failure.system("listen(\(path)) failed: \(message)")
        }
        return fd
    }

    /// connected is a blocking connection to `path`, nil when nothing accepts there.
    public static func connected(path: String) -> Int32? {
        guard var addr = address(for: path) else { return nil }
        let fd = socket(AF_UNIX, streamType, 0)
        guard fd >= 0 else { return nil }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    private static func errnoText() -> String { String(cString: strerror(errno)) }
}
