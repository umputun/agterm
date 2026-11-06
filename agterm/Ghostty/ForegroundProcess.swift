import AppKit
import Darwin
import Foundation
import agtermCore

/// Reads the argv of a pane's foreground process. The libghostty pid lookup lives on
/// `GhosttySurfaceView.foregroundPid()`; this owns the macOS `sysctl` syscalls and defers every judgement
/// (parse, shell-detection, dash-stripping) to the host-free `CommandRestore`.
///
/// Two entry points, because the restore capture and the `tree` read-side ask different questions. See
/// `running(for:shellBasename:)` for why only one of them descends into the process group.
enum ForegroundProcess {
    /// The pane's foreground command for the RESTORE capture: the process-group leader's argv only, or nil
    /// when the pane is at its shell prompt, the surface isn't realized, or the syscall fails.
    /// `shellBasename` is the user's `$SHELL` basename so a non-standard login shell is recognized too.
    ///
    /// Deliberately does NOT descend the group. A non-nil capture sets `hadForeground`, which preempts
    /// `initialCommand` in `CommandRestore.restorePlan` — so a descending capture would restore a
    /// `--command` session by typing its command into a login shell instead of taking the exec path,
    /// losing the `--wait` hold and the close-on-exit shape.
    @MainActor
    static func command(for view: GhosttySurfaceView, shellBasename: String?,
                        zmxSnapshot: ZmxForegroundResolver.Snapshot? = nil) -> [String]? {
        let pid: pid_t?
        if view.backedByZmx, let sessionName = view.zmxSessionName {
            pid = zmxSnapshot?.foregroundPID(sessionName: sessionName)
        } else {
            pid = view.foregroundPid()
        }
        guard let pid, let argv = procArgs(pid: pid) else { return nil }
        guard case .program(let command) = CommandRestore.paneForeground(argv: argv, extra: shellBasename)
        else { return nil }
        return command
    }

    /// The pane's foreground state for the `tree` read-side: as `command`, plus a descent into the
    /// process group when the leader's argv is unreadable, and it KEEPS the shell case that `command`
    /// discards, so the tree can name the shell holding the foreground. Nil means unreadable.
    ///
    /// libghostty's `foreground_pid` is `tcgetpgrp`, a process GROUP id. An interactive shell puts each
    /// job in its own group, so the leader IS the program. A pane with no job-control shell (a
    /// `--command` session) runs its program as a child of setuid-root `login`, whose argv
    /// `KERN_PROCARGS2` refuses for a non-root caller — so without the descent every such pane reads as
    /// idle. A setuid leader under a job-control shell (`top`, `sudo`) still reads as idle while it is
    /// alive, because the descent takes only the leader's own children: `sudo`'s child runs as root and
    /// stays unreadable, and a pipeline's other elements are children of the shell rather than of the
    /// leader. Once the leader is reaped there is no parentage to test and every survivor qualifies, so a
    /// pipeline that outlives its `sudo` does report — see `groupDescentCandidates`.
    @MainActor
    static func running(for view: GhosttySurfaceView, shellBasename: String?,
                        zmxResolver: ZmxForegroundResolver? = nil) -> CommandRestore.PaneForeground? {
        observed(for: view, shellBasename: shellBasename, zmxResolver: zmxResolver)?.foreground
    }

    /// `running`, with the pid whose argv it read, the group leader or the child the descent settled on, and that
    /// process's PATH from the same read.
    @MainActor
    static func observed(for view: GhosttySurfaceView, shellBasename: String?, zmxResolver: ZmxForegroundResolver? = nil)
        -> (pid: pid_t, foreground: CommandRestore.PaneForeground, searchPath: String?)? {
        let pgid: pid_t?
        if view.backedByZmx, let sessionName = view.zmxSessionName {
            pgid = zmxResolver?.foregroundPID(sessionName: sessionName)
        } else {
            pgid = view.foregroundPid()
        }
        guard let pgid else { return nil }
        if let found = foreground(of: pgid, shellBasename: shellBasename) { return found }
        for pid in CommandRestore.groupDescentCandidates(pgid: pgid, members: processGroup(pgid: pgid)) {
            if let found = foreground(of: pid, shellBasename: shellBasename) { return found }
        }
        return nil
    }

    /// foreground reads `pid`'s argv and PATH from one `KERN_PROCARGS2` blob: nil when the argv is unreadable,
    /// otherwise its classification, itself nil when `paneForeground` does not classify it.
    private static func foreground(of pid: pid_t, shellBasename: String?)
        -> (pid: pid_t, foreground: CommandRestore.PaneForeground, searchPath: String?)?? {
        guard let blob = procArgsBlob(pid: pid), let argv = CommandRestore.parseProcArgs(blob) else { return nil }
        let path = CommandRestore.parseProcEnvironment(blob)?["PATH"]
        return .some(CommandRestore.paneForeground(argv: argv, extra: shellBasename).map { (pid, $0, path) })
    }

    /// replayObservation reads a pane's foreground program and the directory it runs in, for a replay of it.
    /// `leader` is the pane daemon's root pid, nil outside Live.
    @MainActor
    static func replayObservation(for view: GhosttySurfaceView, shellBasename: String?, zmxResolver: ZmxForegroundResolver?,
                                  leader: pid_t?) -> RestartReplay.Observation {
        let observed = observed(for: view, shellBasename: shellBasename, zmxResolver: zmxResolver)
        var isDirectory: ObjCBool = false
        let directory = observed.flatMap { workingDirectory(of: $0.pid) }
            .flatMap { FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) && isDirectory.boolValue ? $0 : nil }
        return RestartReplay.Observation(foreground: observed?.foreground,
                                         isDaemonLeader: leader != nil && observed?.pid == leader, workingDirectory: directory,
                                         executablePath: observed.flatMap { executablePath(of: $0.pid) },
                                         searchPath: observed?.searchPath)
    }

    static func executablePath(of pid: pid_t) -> String? {
        var bytes = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// workingDirectory returns nil when `proc_pidinfo` cannot read the process's cwd, as for one owned
    /// by another user.
    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    /// Fetch and parse a process's argv via `sysctl(KERN_PROCARGS2)`; nil on any syscall failure, which is
    /// what a process owned by another user (setuid `login`, `sudo`) returns.
    private static func procArgs(pid: pid_t) -> [String]? {
        procArgsBlob(pid: pid).flatMap(CommandRestore.parseProcArgs)
    }

    private static func procArgsBlob(pid: pid_t) -> Data? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return Data(buffer[0..<size])
    }

    /// Every member of `pgid`'s process group via `sysctl(KERN_PROC_PGRP)`, with each one's parent; empty
    /// on any syscall failure. The count comes from the second call, because the group can shrink between
    /// the two and leave fewer entries than the buffer holds.
    ///
    /// A group that GROWS past the sizing call's slop (a fixed handful of entries) returns ENOMEM, and
    /// macOS reports `oldlen` 0 there, so nothing can be salvaged from the buffer however full it is.
    /// Retry with a widening margin instead, rather than reporting a busy pane as idle.
    private static func processGroup(pgid: pid_t) -> [CommandRestore.ProcessGroupMember] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pgid]
        let stride = MemoryLayout<kinfo_proc>.stride
        for margin in [0, 32, 256] {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + margin)
            guard !procs.isEmpty else { return [] }
            size = procs.count * stride
            if sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) == 0 {
                return procs.prefix(size / stride).map { .init(pid: $0.kp_proc.p_pid, ppid: $0.kp_eproc.e_ppid) }
            }
            if errno != ENOMEM { return [] }
        }
        return []
    }
}
