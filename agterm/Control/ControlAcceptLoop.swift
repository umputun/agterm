import Darwin
import Foundation

/// ControlAcceptLoop owns a listening socket for exactly as long as one accept loop uses it. A descriptor the
/// main thread closed while the loop was busy came back as the next server's listener, or as a lock file, and
/// the stale loop then accepted that server's connections or spun on ENOTSOCK. So `stop()` only wakes the
/// loop, and the loop closes the listener itself through `finish()`, after which the number can be reused.
/// `shutdown` cannot be the wake: on a listening Unix socket it fails with ENOTCONN and leaves `accept`
/// parked, so the loop waits in `poll` on the listener and a wake pipe, and the listener is nonblocking.
final class ControlAcceptLoop: @unchecked Sendable {
    let listenFD: Int32
    private let wakeRead: Int32
    private let wakeWrite: Int32
    private let lock = NSLock()
    private var stopped = false
    private var finished = false

    /// init takes ownership of a bound, listening `listenFD`; nil when the wake pipe cannot be made.
    init?(listenFD: Int32) {
        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else { return nil }
        for fd in [listenFD, pipeFDs[0], pipeFDs[1]] {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        self.listenFD = listenFD
        wakeRead = pipeFDs[0]
        wakeWrite = pipeFDs[1]
    }

    /// stop asks the loop to end and wakes it; it closes nothing, so it may run on any thread.
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
        guard !finished else { return }
        var byte: UInt8 = 1
        while write(wakeWrite, &byte, 1) < 0, errno == EINTR {}
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// next waits for the next connection and returns it as a blocking socket, or nil once the loop must end:
    /// after `stop()`, or on an error the listener cannot recover from.
    func next() -> Int32? {
        while true {
            if isStopped { return nil }
            var fds = [pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
            if poll(&fds, 2, -1) < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if isStopped { return nil }
            if fds[0].revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { return nil }
            guard fds[0].revents & Int16(POLLIN) != 0 else { continue }
            let conn = accept(listenFD, nil, nil)
            if conn >= 0 {
                if isStopped {
                    close(conn)
                    return nil
                }
                // BSD accept hands the listener's O_NONBLOCK to the connection; handleConnection reads blocking
                _ = fcntl(conn, F_SETFL, fcntl(conn, F_GETFL) & ~O_NONBLOCK)
                return conn
            }
            switch errno {
            case EAGAIN, EWOULDBLOCK, EINTR, ECONNABORTED:
                continue
            case EMFILE, ENFILE, ENOBUFS, ENOMEM:
                // descriptor or memory pressure passes; back off rather than spin on a still-readable listener
                usleep(100_000)
            default:
                return nil
            }
        }
    }

    /// finish closes the listener and the wake pipe; only the loop calls it, once `next()` returned nil.
    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        close(listenFD)
        close(wakeRead)
        close(wakeWrite)
    }
}
