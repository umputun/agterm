import Foundation

/// Pure, host-free logic for the restore-running-command feature: parsing a macOS `KERN_PROCARGS2`
/// blob into argv, deciding whether a captured foreground command should be re-run, and rendering an
/// argv back into a shell command line. The app target owns the `sysctl`/libghostty calls; every
/// judgement defers here so it stays unit-tested and off the C boundary.
public enum CommandRestore {
    /// The login shells treated as "no program to restore" (the pane was at its prompt).
    private static let knownShells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "csh"]

    /// Sanity cap on argc: a corrupt header must not drive `reserveCapacity` into a huge allocation.
    private static let maxArgCount: Int32 = 4096

    /// The last path component of `path` (basename), or `path` itself when it has no slash.
    public static func basename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Whether `basename` is a login shell to skip, optionally also matching the user's `$SHELL`
    /// basename passed as `extra` (so a non-standard login shell is recognized too). A leading `-` is
    /// stripped first: macOS marks a login shell with a dash in argv[0], which for a bare-name argv0
    /// (`-zsh`) survives `basename` (a path form like `-/bin/zsh` already loses it on the `/` split).
    public static func isKnownShell(_ basename: String, extra: String? = nil) -> Bool {
        let name = basename.hasPrefix("-") ? String(basename.dropFirst()) : basename
        if knownShells.contains(name) { return true }
        if let extra, !extra.isEmpty, name == extra { return true }
        return false
    }

    /// Whether `argv` is an interactive shell sitting at its prompt — the "idle pane, nothing to restore"
    /// case: `argv[0]` is a known shell (or `$SHELL`, passed as `extra`) AND there is no payload argument
    /// after it, only option flags. A shell RUNNING something is NOT idle and IS captured: a script path
    /// (`/bin/sh /usr/local/bin/cld`, the foreground of any `#!/bin/sh` wrapper) or a `-c` command leaves a
    /// non-flag argument after `argv[0]`. Without this, every shell-script wrapper was wrongly skipped as a
    /// prompt while a plain binary (`htop`) restored.
    public static func isIdleShell(argv: [String], extra: String? = nil) -> Bool {
        guard let first = argv.first, isKnownShell(basename(first), extra: extra) else { return false }
        return !argv.dropFirst().contains { !$0.hasPrefix("-") }
    }

    /// Whether a captured argv should be re-run on restore: false for an empty argv or one whose
    /// `argv[0]` basename is in `denylist`, true otherwise. The denylist is the user-editable
    /// `restore-denylist.conf` (no built-in entries) — `parseDenylist` builds it.
    public static func shouldRestore(argv: [String], denylist: Set<String>) -> Bool {
        guard let first = argv.first, !first.isEmpty else { return false }
        return !denylist.contains(basename(first))
    }

    /// The mutually-exclusive surface seed a pane restores/creates with. `command` != nil → the exec path
    /// (replaces the shell, closes on exit); else `initialInput` is typed into a login shell, or both nil =
    /// a plain shell.
    public struct RestorePlan: Equatable, Sendable {
        public let command: String?
        public let initialInput: String?
        public init(command: String?, initialInput: String?) {
            self.command = command
            self.initialInput = initialInput
        }
    }

    /// Decide a pane's seed on create/restore. Pure so the gate + precedence is unit-tested off the C
    /// boundary; the app target owns only the libghostty seeding.
    /// - `wasRestored`: the session came from a restore (a FRESH command session always runs its command; a
    ///   RESTORED one only when the opt-in is on).
    /// - `restoreEnabled`: the `restoreRunningCommand` opt-in.
    /// - `hadForeground`: a foreground command was CAPTURED at the last quit. A captured foreground PREEMPTS
    ///   `initialCommand` even when suppressed (denylisted/off → `foregroundInput` nil), yielding a plain
    ///   shell rather than the stale creation command — so gate on capture, not on whether the input survived.
    /// - `foregroundInput`: the rendered foreground command line to type, or nil (none / suppressed).
    /// - `initialCommand`: the session's persisted `--command`.
    public static func restorePlan(wasRestored: Bool, restoreEnabled: Bool, hadForeground: Bool,
                                   foregroundInput: String?, initialCommand: String?) -> RestorePlan {
        let mayRunInitial = !wasRestored || restoreEnabled
        let command = (!hadForeground && mayRunInitial) ? initialCommand : nil
        return RestorePlan(command: command, initialInput: command == nil ? foregroundInput : nil)
    }

    /// Parse `restore-denylist.conf` into a set of program basenames NOT to re-run on restore: one entry
    /// per line, trimmed; blank lines and `#` comments ignored. There is NO built-in list — the file is
    /// the whole source (seeded with the terminal multiplexers on first launch).
    public static func parseDenylist(_ text: String) -> Set<String> {
        var result: Set<String> = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            result.insert(line)
        }
        return result
    }

    /// Render an argv into a single POSIX shell command line by single-quoting each argument (so spaces,
    /// `$`, globs, and quotes survive intact), space-joined. The inverse of capture; fed to a restored
    /// login shell via `initial_input`.
    public static func shellQuotedLine(_ argv: [String]) -> String {
        argv.map(shellQuote).joined(separator: " ")
    }

    /// POSIX single-quote one argument: wrap in `'…'`, and render each embedded `'` as `'\''`.
    private static func shellQuote(_ arg: String) -> String {
        "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Parse a macOS `KERN_PROCARGS2` blob into the process's argv. Layout: a host-order `Int32` argc,
    /// the NUL-terminated executable path, zero or more NUL padding bytes, then `argc` NUL-terminated
    /// argument strings (env follows, ignored). Returns nil on a truncated or implausible blob.
    public static func parseProcArgs(_ data: Data) -> [String]? {
        let bytes = [UInt8](data)
        guard bytes.count > 4 else { return nil }
        let argc = bytes.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < maxArgCount else { return nil }

        var i = 4
        // skip the executable path up to its NUL...
        while i < bytes.count, bytes[i] != 0 { i += 1 }
        // ...then the NUL padding between exec path and argv[0].
        while i < bytes.count, bytes[i] == 0 { i += 1 }

        var args: [String] = []
        args.reserveCapacity(Int(argc))
        while args.count < Int(argc), i < bytes.count {
            let start = i
            while i < bytes.count, bytes[i] != 0 { i += 1 }
            args.append(String(decoding: bytes[start..<i], as: UTF8.self))
            if i < bytes.count { i += 1 } // step over the terminating NUL
        }
        return args.count == Int(argc) ? args : nil
    }
}
