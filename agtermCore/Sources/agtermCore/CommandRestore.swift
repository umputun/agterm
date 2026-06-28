import Foundation

/// Pure, host-free logic for the restore-running-command feature: parsing a macOS `KERN_PROCARGS2`
/// blob into argv, deciding whether a captured foreground command should be re-run, and rendering an
/// argv back into a shell command line. The app target owns the `sysctl`/libghostty calls; every
/// judgement defers here so it stays unit-tested and off the C boundary.
public enum CommandRestore {
    /// The login shells treated as "no program to restore" (the pane was at its prompt).
    private static let knownShells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "csh"]

    /// Stateful programs whose re-run is lossy or harmful (editors, pagers, REPLs); skipped on restore,
    /// leaving a plain shell. Matched on the argv[0] basename.
    private static let denylist: Set<String> = [
        "vim", "nvim", "vi", "view", "nano", "emacs", "emacsclient", "less", "more", "man",
        "python", "python3", "node", "irb", "ipython", "pry", "lua", "ghci",
    ]

    /// The last path component of `path` (basename), or `path` itself when it has no slash.
    public static func basename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Whether `basename` is a login shell to skip, optionally also matching the user's `$SHELL`
    /// basename passed as `extra` (so a non-standard login shell is recognized too).
    public static func isKnownShell(_ basename: String, extra: String? = nil) -> Bool {
        if knownShells.contains(basename) { return true }
        if let extra, !extra.isEmpty, basename == extra { return true }
        return false
    }

    /// Whether a captured argv should be re-run on restore: false for an empty argv or one whose
    /// `argv[0]` basename is denylisted (editors/pagers/REPLs), true otherwise.
    public static func shouldRestore(argv: [String]) -> Bool {
        guard let first = argv.first, !first.isEmpty else { return false }
        return !denylist.contains(basename(first))
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
        guard argc > 0, argc < 4096 else { return nil }

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
