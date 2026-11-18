import agtermCore
import Darwin

/// ZmxDaemonForeground finds a wrapped pane's foreground process group from the kernel alone: the daemon's
/// pid from its socket, then its single pty child. No daemon has to answer, so a stalled one costs only its
/// own pane.
struct ZmxDaemonForeground {
    let foregroundPID: (String) -> pid_t?

    static func socket(directory: String) -> ZmxDaemonForeground {
        ZmxDaemonForeground { name in lookup(socketPath: directory + "/" + name) }
    }

    // the kernel answers the peer pid from the listener before the daemon accepts, so a stopped daemon still
    // resolves; the connection stays open until the child is matched
    private static func lookup(socketPath: String) -> pid_t? {
        guard var address = UnixSocket.address(for: socketPath) else { return nil }
        let fd = Darwin.socket(AF_UNIX, UnixSocket.streamType, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                UnixSocket.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0, let daemon = peerPID(fd: fd) else { return nil }
        return ZmxDaemonLeader.foreground(ofDaemon: daemon, children: children(of: daemon), row: row(of:))
    }

    private static func peerPID(fd: Int32) -> pid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { return nil }
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }
        return pid
    }

    // room for two, so a second child shows as one too many rather than being cut off
    private static func children(of pid: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 2)
        let count = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return count > 0 ? Array(pids.prefix(Int(count))) : []
    }

    private static func row(of pid: pid_t) -> ZmxDaemonLeader.Row? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid
        else { return nil }
        let ownsTerminal = info.kp_proc.p_flag & P_CONTROLT != 0 && info.kp_eproc.e_flag & EPROC_SLEADER != 0
        return ZmxDaemonLeader.Row(parent: info.kp_eproc.e_ppid, ownsTerminal: ownsTerminal,
                                   foreground: info.kp_eproc.e_tpgid)
    }
}
