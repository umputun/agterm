import agtermCore
import Darwin
import Foundation

/// ZmxDaemonForeground finds a wrapped pane's foreground process group from the kernel alone: the daemon's
/// pid from its socket, then its single pty child. No daemon has to answer, so a stalled one costs only its
/// own pane.
struct ZmxDaemonForeground {
    let foregroundPID: (String) -> pid_t?

    static func socket(directory: String) -> ZmxDaemonForeground {
        ZmxDaemonForeground { name in lookup(socketPath: directory + "/" + name) }
    }

    /// leaderPID is the pid of the pty shell of the daemon listening at `directory`/`name`, so a restart sees its new
    /// shell run without `zmx list`, which waits on every other daemon.
    static func leaderPID(directory: String, name: String) -> pid_t? {
        withDaemon(socketPath: directory + "/" + name) { ZmxDaemonLeader.leader(ofDaemon: $0, children: children(of: $0), row: row(of:)) }
    }

    /// leaders maps every agterm daemon socket in `directory` to its shell pid; a socket with no leader found is left
    /// out. An absent directory has no daemons; nil means the directory could not be read.
    static func leaders(directory: String) -> [String: pid_t]? {
        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: directory)
        } catch CocoaError.fileReadNoSuchFile {
            return [:]
        } catch {
            return nil
        }
        return Dictionary(uniqueKeysWithValues: entries.filter(ZmxSupport.isDaemonName).compactMap { name in
            leaderPID(directory: directory, name: name).map { (name, $0) }
        })
    }

    /// probe reports `pane`'s daemon in `directory`: its leader, or absent when no socket exists at the pane's name.
    /// A socket left with no leader found, or a lookup that fails otherwise, is unknown.
    static func probe(directory: String, pane: UUID) -> DaemonProbe {
        let name = ZmxSupport.daemonName(for: pane)
        if let leader = leaderPID(directory: directory, name: name) { return .running(leader: leader) }
        return access(directory + "/" + name, F_OK) != 0 && errno == ENOENT ? .absent : .unknown
    }

    private static func lookup(socketPath: String) -> pid_t? {
        withDaemon(socketPath: socketPath) { ZmxDaemonLeader.foreground(ofDaemon: $0, children: children(of: $0), row: row(of:)) }
    }

    // the kernel answers the peer pid from the listener before the daemon accepts, so a stopped daemon still
    // resolves; the connection stays open until the child is matched
    private static func withDaemon(socketPath: String, _ body: (pid_t) -> pid_t?) -> pid_t? {
        guard let fd = UnixSocket.connected(path: socketPath) else { return nil }
        defer { close(fd) }
        guard let daemon = peerPID(fd: fd) else { return nil }
        return body(daemon)
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
