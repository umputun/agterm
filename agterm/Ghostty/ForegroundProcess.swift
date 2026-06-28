import AppKit
import Darwin
import Foundation
import agtermCore

/// Reads the argv of a pane's foreground process for the restore-running-command capture. The libghostty
/// pid lookup lives on `GhosttySurfaceView.foregroundPid()`; this owns the macOS `sysctl(KERN_PROCARGS2)`
/// syscall and defers every judgement (parse, shell-detection) to the host-free `CommandRestore`.
enum ForegroundProcess {
    /// The foreground command (full argv) of `view`'s pane, or nil when the pane is at its shell prompt
    /// (the foreground process is a login shell), the surface isn't realized, or the syscall fails.
    /// `shellBasename` is the user's `$SHELL` basename so a non-standard login shell is recognized too.
    @MainActor
    static func command(for view: GhosttySurfaceView, shellBasename: String?) -> [String]? {
        guard let pid = view.foregroundPid(), let argv = procArgs(pid: pid), !argv.isEmpty else { return nil }
        // skip a shell ONLY when it's idle at its prompt (no script/command argument); a shell running a
        // script (a #!/bin/sh wrapper like cld) is a real foreground process to restore.
        if CommandRestore.isIdleShell(argv: argv, extra: shellBasename) { return nil }
        return argv
    }

    /// Fetch and parse a process's argv via `sysctl(KERN_PROCARGS2)`; nil on any syscall failure.
    private static func procArgs(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return CommandRestore.parseProcArgs(Data(buffer[0..<size]))
    }
}
