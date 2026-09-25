import Foundation

/// The ssh command lines that reach another agterm's zmx daemons. Pure and host-free: callers run what
/// these return, and the app target owns process execution.
public enum RemoteSession {
    public enum InvocationError: Error, Equatable {
        case emptyHost
        case invalidHost
        case invalidSession
        case invalidEndpoint
    }

    /// One ssh invocation running the far side's own `zmx tree`, which returns its attachable sessions
    /// across every open window as a single document.
    ///
    /// `-T` because no pty is wanted, `BatchMode=yes` because a host-key or password prompt would hang a
    /// dispatcher with no way to answer it. `ConnectTimeout` bounds the handshake only — the caller still
    /// needs its own deadline for a remote command that never returns.
    public static func treeCommand(host: String, connectTimeout: Int = 5) throws -> [String] {
        try validate(host: host)
        // the far side runs the BARE form of the same command, which does the whole join in one
        // main-actor walk of its own windows and answers with one document
        let chain = cliPathPrefix + " && agtermctl zmx tree --json"
        // sshd runs the remote command through the ACCOUNT's shell, where a bare `VAR=value` assignment is
        // a syntax error in fish and tcsh; wrapped, every login shell sees one ordinary command, as
        // `attachCommand` already sends.
        let remote = CommandRestore.shellQuotedLine(["/bin/sh", "-c", chain])
        return sshArguments(host: host, connectTimeout: connectTimeout, interactive: false) + [remote]
    }

    /// One ssh invocation carrying `session`'s presentation stream, for as long as the row is shown.
    ///
    /// `-T` because frames travel on plain stdio and a pty would mangle them, and no lifetime deadline:
    /// the stream is meant to stay up. `exec` so the far-side shell does not linger between ssh and the
    /// bridge, which would keep a dead bridge's stdio open.
    public static func presentCommand(host: String, session: String, connectTimeout: Int = 5) throws -> [String] {
        try validate(host: host)
        guard isPlain(session) else { throw InvocationError.invalidSession }
        let chain = cliPathPrefix + " && exec agtermctl zmx present " + CommandRestore.shellQuotedLine([session])
        let remote = CommandRestore.shellQuotedLine(["/bin/sh", "-c", chain])
        return sshArguments(host: host, connectTimeout: connectTimeout, interactive: false) + [remote]
    }

    /// One ssh invocation running the helper for `job`, an overlay the origin handed to this Mac, for as long
    /// as the overlay is up. `-tt` because the program is the user's and reads the pty; `exec` so the helper's
    /// hangup check sees the ssh session's own pty close.
    public static func runJobCommand(host: String, job: String, connectTimeout: Int = 5) throws -> [String] {
        try validate(host: host)
        guard isPlain(job) else { throw InvocationError.invalidSession }
        let chain = cliPathPrefix + " && exec agtermctl session overlay run-job " + CommandRestore.shellQuotedLine([job])
        let remote = CommandRestore.shellQuotedLine(["/bin/sh", "-c", chain])
        return sshArguments(host: host, connectTimeout: connectTimeout, interactive: true) + [remote]
    }

    /// sshd runs a remote command with `/usr/bin:/bin:/usr/sbin:/sbin` and a non-interactive shell reads no
    /// profile, so an installed CLI is otherwise not found and every command exits 127. `CommandPath` owns
    /// where it can live; APPENDED, so a user's own `agtermctl` earlier on PATH still wins.
    static var cliPathPrefix: String {
        "PATH=\"$PATH:" + CommandPath.standardDirectories.joined(separator: ":") + "\""
    }

    /// One ssh invocation attaching to `daemon` on `host`, for the lifetime of the pane.
    ///
    /// `-tt` forces a pty: a remote command does not reliably get one, and zmx reads termios and the
    /// window size. There is no lifetime deadline — this is meant to stay connected.
    ///
    /// The trailing `/bin/sh -c` is a create-only guard, not a command we expect to run. Stock
    /// `zmx attach` CREATES the daemon when the name is absent, so a daemon that vanished since the tree
    /// was read would otherwise hand the user a fresh remote shell wearing the old session's name. An
    /// existing daemon ignores the command; a vanished one runs this and fails, saying so.
    ///
    /// `env` and `sh` are spelled absolutely because they are implementation primitives. The remote
    /// `agtermctl` in `treeCommand` is deliberately PATH-resolved instead — that one IS the user's
    /// installed CLI.
    ///
    /// `lead` opts the far zmx client into explicit leadership; an origin whose zmx predates it ignores
    /// the two variables and the pane behaves as it did before.
    public static func attachCommand(host: String, endpoint: ControlZmxEndpoint, daemon: String,
                                     lead: ZmxLeadAttachment? = nil,
                                     connectTimeout: Int = 5) throws -> [String] {
        try validate(host: host)
        guard ZmxSupport.isDaemonName(daemon) else { throw InvocationError.invalidSession }
        guard isPath(endpoint.executable), isPath(endpoint.socketDirectory) else {
            throw InvocationError.invalidEndpoint
        }
        let guardScript = "printf '%s\\n' 'agterm: remote session is gone'; exit 1"
        let remote = CommandRestore.shellQuotedLine([
            // the four the LOCAL pane sets in `ZmxSupport`, empty being unset to zmx: an inherited
            // `ZMX_SESSION` makes attach SWITCH session instead, never reaching the create-only guard,
            // and an inherited prefix resolves a name agterm never created.
            "/usr/bin/env", "ZMX_SESSION=", "ZMX_SESSION_PREFIX=", "ZMX_NO_DETACH_KEY=1",
            "ZMX_DIR=" + endpoint.socketDirectory,
        ] + (lead?.assignments ?? []) + [
            endpoint.executable, "attach", daemon, "/bin/sh", "-c", guardScript,
        ])
        var argv = sshArguments(host: host, connectTimeout: connectTimeout, interactive: true) + [remote]
        // ssh's own disconnect chatter lands wherever the remote program left the cursor; the pane command
        // prints the one line that matters
        argv.insert(contentsOf: ["-o", "LogLevel=QUIET"], at: argv.count - 2)
        return argv
    }

    /// The pane's command: the attach, then one line saying what died. `commandWait` holds the pane on
    /// Ghostty's own press-any-key prompt, so this sits under the last remote screen until it is read.
    ///
    /// It names the host, the session and the exit status. On ssh's own failure, 255, it shows a reconnecting
    /// bar, reports that under `RemoteLinkNotice` and waits on `cat` for the app to attach the pane again;
    /// `cat` ends with the app's pty. The mouse and focus reporting a remote program left on is switched off
    /// first, or those reports would echo onto the kept screen. Without a lead nonce nothing could be
    /// believed, so it exits.
    public static func attachPaneCommand(host: String, endpoint: ControlZmxEndpoint, daemon: String,
                                         session: String, pane: ZmxPaneRole,
                                         lead: ZmxLeadAttachment? = nil,
                                         connectTimeout: Int = 5) throws -> String {
        let attach = CommandRestore.shellQuotedLine(
            try attachCommand(host: host, endpoint: endpoint, daemon: daemon, lead: lead,
                              connectTimeout: connectTimeout))
        let label = CommandRestore.shellQuotedLine(
            ["agterm: \(session) (\(pane.rawValue)) on \(host) disconnected, exit"])
        // the pane must exit with SSH's status, not printf's zero, or a failed connection reads as a
        // clean one to anything that looks at the exit code
        let report = "printf '%s %s\\n' \(label) \"$status\""
        var script = "\(attach); status=$?; \(report); exit \"$status\""
        if let lead {
            let bar = CommandRestore.shellQuotedLine(["Connection to \(host) lost · reconnecting… · any key retries now"])
            let title = CommandRestore.shellQuotedLine([RemoteLinkNotice.title(nonce: lead.nonce)])
            let reset = "\\033[0m\\033[?1000l\\033[?1002l\\033[?1003l\\033[?1006l\\033[?1004l\\033[?2004l\\033[?2031l\\033[?2048l"
            script = "\(attach); status=$?; if [ \"$status\" -eq 255 ]; then "
                + "printf '\(reset)\\r\\n\\033[30;43m %s \\033[K\\033[0m\\n' \(bar); printf '\\033]2;%s\\007' \(title); "
                + "cat >/dev/null; else \(report); fi; exit \"$status\""
        }
        // libghostty runs this as `exec -l <command>`: bare, the exec replaces the shell with ssh and nothing
        // after it runs. `env` takes the exec instead, and a plain `sh` beneath it reads no login profile.
        return CommandRestore.shellQuotedLine(["/usr/bin/env", "/bin/sh", "-c", script])
    }

    /// One ssh invocation that only proves the host answers again, before a waiting pane is attached anew.
    public static func probeCommand(host: String) throws -> [String] {
        try validate(host: host)
        return sshArguments(host: host, connectTimeout: 5, interactive: false) + ["true"]
    }

    private static func sshArguments(host: String, connectTimeout: Int, interactive: Bool) -> [String] {
        ["ssh", interactive ? "-tt" : "-T",
         "-o", "BatchMode=yes",
         "-o", "ConnectTimeout=\(connectTimeout)",
         host]
    }

    /// Refused rather than escaped, and a leading `-` with it: ssh would read that as an option.
    private static func validate(host: String) throws {
        guard !host.isEmpty else { throw InvocationError.emptyHost }
        guard isPlain(host), !host.hasPrefix("-") else { throw InvocationError.invalidHost }
    }

    /// A host or remote-session token: no whitespace, no control characters. Shared with the dispatcher,
    /// so one predicate decides what may reach both an argv and an error message.
    static func isPlain(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return !value.unicodeScalars.contains { $0.properties.isWhitespace || $0.value < 0x20 || $0.value == 0x7f }
    }

    /// A filesystem path, which may legitimately contain spaces — `/Users/me/My Apps/agterm.app/…` is an
    /// ordinary install. `shellQuotedLine` keeps it one argument through the remote shell, so only
    /// control characters and NUL are refused, neither of which survives a path anyway.
    private static func isPath(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }
}
