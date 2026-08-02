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
    static func command(for view: GhosttySurfaceView, shellBasename: String?) -> [String]? {
        guard let pid = view.foregroundPid(), let argv = procArgs(pid: pid) else { return nil }
        return usable(argv, shellBasename: shellBasename)
    }

    /// The pane's foreground command for the `tree` read-side: as `command`, plus a descent into the
    /// process group when the leader's argv is unreadable.
    ///
    /// libghostty's `foreground_pid` is `tcgetpgrp`, a process GROUP id. An interactive shell puts each
    /// job in its own group, so the leader IS the program. A pane with no job-control shell (a
    /// `--command` session) leaves its program in the group led by setuid-root `login`, whose argv
    /// `KERN_PROCARGS2` refuses for a non-root caller — so without the descent every such pane reads as
    /// idle. A leader running setuid under a job-control shell (`top`, `sudo`) still reads as idle: it is
    /// alone in its group, so there is nothing to descend to.
    @MainActor
    static func running(for view: GhosttySurfaceView, shellBasename: String?) -> [String]? {
        guard let pgid = view.foregroundPid() else { return nil }
        if let argv = procArgs(pid: pgid) { return usable(argv, shellBasename: shellBasename) }
        let members = CommandRestore.groupDescentCandidates(pgid: pgid, members: processGroup(pgid: pgid))
        for pid in members {
            if let argv = procArgs(pid: pid) { return usable(argv, shellBasename: shellBasename) }
        }
        return nil
    }

    /// Normalize a raw argv and drop it when it is an idle shell: a shell is skipped ONLY at its prompt (no
    /// script/command argument); a shell running a script (a `#!/bin/sh` wrapper like `cld`) is a real
    /// foreground process to report.
    private static func usable(_ argv: [String], shellBasename: String?) -> [String]? {
        guard !argv.isEmpty else { return nil }
        if CommandRestore.isIdleShell(argv: argv, extra: shellBasename) { return nil }
        return CommandRestore.stripLoginDash(argv)
    }

    /// Fetch and parse a process's argv via `sysctl(KERN_PROCARGS2)`; nil on any syscall failure, which is
    /// what a process owned by another user (setuid `login`, `sudo`) returns.
    private static func procArgs(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return CommandRestore.parseProcArgs(Data(buffer[0..<size]))
    }

    /// Every pid in `pgid`'s process group via `sysctl(KERN_PROC_PGRP)`; empty on any syscall failure. The
    /// size is re-read from the second call because the group can shrink between the two.
    private static func processGroup(pgid: pid_t) -> [Int32] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pgid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
        guard sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / stride).map(\.kp_proc.p_pid)
    }
}
