import Foundation

/// StateDirectoryLock marks one process as the owner of a state directory for as long as it lives. Every
/// store save rewrites its whole file from memory, so a second process loaded from the same directory
/// overwrites the owner's later changes with its own stale copy (#741).
public final class StateDirectoryLock: Sendable {
    /// Outcome is what `acquire` found. Only `owned` grants the directory; `unavailable` proves nothing
    /// about whether another process owns it.
    public enum Outcome: Sendable {
        case owned(StateDirectoryLock)
        case heldByAnother
        case unavailable(String)
    }

    static let filename = "agterm.lock"

    private let fd: Int32

    private init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        close(fd)
    }

    /// acquire creates a missing directory and takes the exclusive lock without waiting. The lock file is
    /// never removed: the next process would lock a fresh inode and exclude nobody.
    public static func acquire(directory: URL) -> Outcome {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .unavailable("cannot create \(directory.path): \(error.localizedDescription)")
        }
        let path = directory.appendingPathComponent(filename).path
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            return .unavailable("cannot open \(path): \(String(cString: strerror(errno)))")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { return .heldByAnother }
            return .unavailable("cannot lock \(path): \(String(cString: strerror(code)))")
        }
        return .owned(StateDirectoryLock(fd: fd))
    }
}
