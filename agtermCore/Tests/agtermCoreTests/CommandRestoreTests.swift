import Foundation
import Testing
@testable import agtermCore

struct CommandRestoreTests {
    /// Builds a synthetic `KERN_PROCARGS2` blob: host-order argc, NUL-terminated exec path, `padding`
    /// extra NULs, then each arg NUL-terminated.
    private func blob(argc: Int32, execPath: String, padding: Int, args: [String]) -> Data {
        var d = withUnsafeBytes(of: argc) { Data($0) } // host byte order, matching parseProcArgs
        d.append(Data(execPath.utf8)); d.append(0)
        d.append(Data(repeating: 0, count: padding))
        for a in args { d.append(Data(a.utf8)); d.append(0) }
        return d
    }

    @Test func parseProcArgsReadsArgvPastExecPathPadding() {
        let data = blob(argc: 2, execPath: "/usr/bin/ssh", padding: 3, args: ["ssh", "gate"])
        #expect(CommandRestore.parseProcArgs(data) == ["ssh", "gate"])
    }

    @Test func parseProcArgsHandlesArgsWithSpaces() {
        let data = blob(argc: 3, execPath: "/usr/bin/ssh", padding: 1,
                        args: ["ssh", "gate", "-t ssh inner"])
        #expect(CommandRestore.parseProcArgs(data) == ["ssh", "gate", "-t ssh inner"])
    }

    @Test func parseProcArgsRejectsTruncatedAndEmpty() {
        #expect(CommandRestore.parseProcArgs(Data()) == nil)
        let truncated = blob(argc: 2, execPath: "/bin/sh", padding: 0, args: ["sh"])
        #expect(CommandRestore.parseProcArgs(truncated) == nil)
        // a blob shorter than the argc header.
        #expect(CommandRestore.parseProcArgs(Data([1, 2])) == nil)
    }

    @Test func isKnownShellMatchesShellsAndExtra() {
        #expect(CommandRestore.isKnownShell("zsh"))
        #expect(CommandRestore.isKnownShell("bash"))
        #expect(!CommandRestore.isKnownShell("ssh"))
        #expect(!CommandRestore.isKnownShell("vim"))
        #expect(CommandRestore.isKnownShell("xonsh", extra: "xonsh")) // a non-standard $SHELL basename
        #expect(!CommandRestore.isKnownShell("xonsh", extra: nil))
        // login-shell dash forms: a bare-name argv0 keeps the dash through basename, a path form drops it.
        #expect(CommandRestore.isKnownShell("-zsh"))
        #expect(CommandRestore.isKnownShell("-bash", extra: "bash"))
        #expect(CommandRestore.isKnownShell(CommandRestore.basename("-/bin/zsh"))) // path form -> "zsh"
        #expect(!CommandRestore.isKnownShell("", extra: ""))
    }

    @Test func stripLoginDashDropsOnlyTheMark() {
        #expect(CommandRestore.stripLoginDash(["-sleep", "900"]) == ["sleep", "900"])
        #expect(CommandRestore.stripLoginDash(["-/bin/zsh"]) == ["/bin/zsh"])
        #expect(CommandRestore.stripLoginDash(["sleep", "900"]) == ["sleep", "900"])
        #expect(CommandRestore.stripLoginDash(["git", "-C", "/tmp", "status"]) == ["git", "-C", "/tmp", "status"])
        #expect(CommandRestore.stripLoginDash([]) == [])
        #expect(CommandRestore.stripLoginDash(["-"]) == [""])
    }

    @Test func groupDescentCandidatesKeepOnlyTheLeadersChildren() {
        func m(_ pid: Int32, _ ppid: Int32) -> CommandRestore.ProcessGroupMember { .init(pid: pid, ppid: ppid) }
        #expect(CommandRestore.groupDescentCandidates(pgid: 100, members: [m(100, 9), m(102, 100), m(101, 100)])
            == [101, 102])
        #expect(CommandRestore.groupDescentCandidates(pgid: 100, members: [m(100, 9)]).isEmpty)
        #expect(CommandRestore.groupDescentCandidates(pgid: 100, members: []).isEmpty)
        #expect(CommandRestore.groupDescentCandidates(pgid: 100, members: [m(0, 100), m(-1, 100), m(101, 100)])
            == [101])
        // a pipeline parents every element to the SHELL while the group leads on the first, so a sibling of
        // the setuid leader is not the pane's foreground.
        #expect(CommandRestore.groupDescentCandidates(pgid: 100, members: [m(100, 9), m(101, 9)]).isEmpty)
        // a grandchild that took a low pid after the 99999 wrap must not outrank its own parent.
        #expect(CommandRestore.groupDescentCandidates(pgid: 100, members: [m(100, 9), m(99500, 100), m(500, 99500)])
            == [99500])
        // a reaped leader (`cat f | less`) leaves nothing to check parentage against, so survivors qualify.
        #expect(CommandRestore.groupDescentCandidates(pgid: 100, members: [m(101, 9)]) == [101])
        #expect(CommandRestore.groupDescentCandidates(pgid: 100, members: [m(102, 9), m(101, 9)]) == [101, 102])
    }

    @Test func isIdleShellSkipsBarePromptButNotScripts() {
        #expect(CommandRestore.isIdleShell(argv: ["-zsh"]))
        #expect(CommandRestore.isIdleShell(argv: ["/bin/zsh"]))
        #expect(CommandRestore.isIdleShell(argv: ["-/bin/zsh"]))
        #expect(CommandRestore.isIdleShell(argv: ["zsh", "-i", "-l"]))            // only option flags
        #expect(CommandRestore.isIdleShell(argv: ["bash"], extra: "bash"))
        // a shell running a script or -c is NOT idle — the real-world `cld` launcher bug.
        #expect(!CommandRestore.isIdleShell(argv: ["/bin/sh", "/usr/local/bin/cld"]))
        #expect(!CommandRestore.isIdleShell(argv: ["/bin/sh", "/usr/local/bin/cld", "--flag"]))
        #expect(!CommandRestore.isIdleShell(argv: ["bash", "-c", "echo hi"]))
        #expect(!CommandRestore.isIdleShell(argv: ["htop"]))
        #expect(!CommandRestore.isIdleShell(argv: []))
    }

    @Test func shouldRestoreSkipsDenylistByBasename() {
        let denylist: Set<String> = ["vim", "tmux", "hx"]
        #expect(CommandRestore.shouldRestore(argv: ["ssh", "gate"], denylist: denylist))
        #expect(CommandRestore.shouldRestore(argv: ["top"], denylist: denylist))
        // interpreters / servers are NOT denied (not in the list): usually scripts or servers worth restoring.
        #expect(CommandRestore.shouldRestore(argv: ["python3", "worker.py"], denylist: denylist))
        #expect(CommandRestore.shouldRestore(argv: ["node", "server.js"], denylist: denylist))
        #expect(!CommandRestore.shouldRestore(argv: ["/usr/bin/vim", "file"], denylist: denylist))
        #expect(!CommandRestore.shouldRestore(argv: ["tmux"], denylist: denylist))
        #expect(!CommandRestore.shouldRestore(argv: ["/opt/homebrew/bin/hx", "."], denylist: denylist))
        #expect(CommandRestore.shouldRestore(argv: ["vim", "x"], denylist: []))
        #expect(!CommandRestore.shouldRestore(argv: [], denylist: denylist))
        #expect(!CommandRestore.shouldRestore(argv: [""], denylist: denylist))
    }

    @Test func shouldRestoreRefusesControlCharacters() {
        // #454: the rendered line is typed, so a control byte reaches the line editor as an editing
        // command — 0x15 kills the line and runs whatever follows it.
        #expect(!CommandRestore.shouldRestore(argv: ["sed", "s/\u{1B}//"], denylist: []))
        #expect(!CommandRestore.shouldRestore(argv: ["awk", "-F", "\u{09}", "{print $2}"], denylist: []))
        #expect(!CommandRestore.shouldRestore(argv: ["grep", "a\u{15}b"], denylist: []))
        #expect(!CommandRestore.shouldRestore(argv: ["grep", "a\u{0A}rm -rf x"], denylist: []))
        #expect(!CommandRestore.shouldRestore(argv: ["less", "note\u{7F}.txt"], denylist: []))
        // argv[0] carries the byte, so the basename check alone would let it through.
        #expect(!CommandRestore.shouldRestore(argv: ["od\u{1B}d"], denylist: []))
        // the boundary: 0x20 and printable high scalars are ordinary argument bytes.
        #expect(CommandRestore.shouldRestore(argv: ["echo", "a b"], denylist: []))
        #expect(CommandRestore.shouldRestore(argv: ["echo", "naïve — ✓"], denylist: []))
    }

    @Test func shouldRestoreRefusesLossilyDecodedArguments() {
        // the argument bytes must be RAW, not a Swift literal: "\u{FFFD}" encodes as valid UTF-8, which
        // would pin the genuine-U+FFFD case while proving nothing about lossy decoding.
        var raw = withUnsafeBytes(of: Int32(2)) { Data($0) }
        raw.append(Data("/usr/bin/grep".utf8)); raw.append(0)
        raw.append(Data("grep".utf8)); raw.append(0)
        raw.append(Data([0x63, 0x61, 0x66, 0xE9])); raw.append(0) // "caf" + a lone Latin-1 é
        let argv = CommandRestore.parseProcArgs(raw)
        #expect(argv == ["grep", "caf\u{FFFD}"])
        #expect(!CommandRestore.shouldRestore(argv: argv ?? [], denylist: []))
        // a genuine U+FFFD is refused with it, indistinguishable once decoded.
        #expect(!CommandRestore.shouldRestore(argv: ["grep", "caf\u{FFFD}"], denylist: []))
        #expect(!CommandRestore.shouldRestore(argv: ["\u{FFFD}bin", "x"], denylist: []))
    }

    @Test func lossyArgvStillPreemptsStaleInitialCommand() {
        // the refusal is at render, not capture, so hadForeground stays true and a --command session
        // comes back a plain shell rather than re-running its creation command.
        let inputs = CommandRestore.RestoreInputs(wasRestored: true, restoreEnabled: true, hadForeground: true,
                                                  foregroundInput: nil, initialCommand: "ssh prod",
                                                  restoreOverride: nil)
        let plan = CommandRestore.restorePlan(inputs)
        #expect(plan.command == nil)
        #expect(plan.initialInput == nil)
    }

    @Test func restoreInputRefusesOverrideCarryingControlCharacters() {
        // the dispatcher rejects these on write, but a pin loaded from a snapshot never passed that check.
        #expect(CommandRestore.restoreInput(restoreEnabled: true, restoreOverride: "tail -f\u{1B}x",
                                            capturedInput: "'top'\n") == nil)
        #expect(CommandRestore.restoreInput(restoreEnabled: true, restoreOverride: "a\u{0A}rm -rf x",
                                            capturedInput: nil) == nil)
        #expect(CommandRestore.restoreInput(restoreEnabled: true, restoreOverride: "cd x && claude",
                                            capturedInput: nil) == "cd x && claude\n")
    }

    @Test func parseDenylistReadsBasenamesIgnoringCommentsAndBlanks() {
        let text = """
        # programs not to restore
        tmux
          screen\u{0020}\u{0020}
        \u{0020}
        # vim   (commented out, not active)
        zellij
        """
        #expect(CommandRestore.parseDenylist(text) == ["tmux", "screen", "zellij"])
        #expect(CommandRestore.parseDenylist("").isEmpty)
        #expect(CommandRestore.parseDenylist("# only comments\n\n").isEmpty)
    }

    @Test func parseProcArgsRejectsImplausibleArgc() {
        #expect(CommandRestore.parseProcArgs(blob(argc: 0, execPath: "/bin/sh", padding: 0, args: [])) == nil)
        #expect(CommandRestore.parseProcArgs(blob(argc: -1, execPath: "/bin/sh", padding: 1, args: ["sh"])) == nil)
        // argc beyond the sanity cap is rejected before driving a huge reserveCapacity.
        #expect(CommandRestore.parseProcArgs(blob(argc: 5000, execPath: "/bin/sh", padding: 1, args: ["sh", "x"])) == nil)
    }

    @Test func parseProcArgsHandlesEmptyExecPathAndIgnoresEnv() {
        // empty exec path: the exec-path skip is a no-op, the padding skip consumes its NUL.
        #expect(CommandRestore.parseProcArgs(blob(argc: 1, execPath: "", padding: 0, args: ["sh"])) == ["sh"])
        // trailing env bytes after the argc args are ignored (the loop stops at argc).
        var withEnv = blob(argc: 1, execPath: "/bin/sh", padding: 1, args: ["sh"])
        withEnv.append(Data("PATH=/bin".utf8)); withEnv.append(0)
        #expect(CommandRestore.parseProcArgs(withEnv) == ["sh"])
    }

    @Test func parseProcArgsRejectsUnterminatedExecPath() {
        // the exec-path walk hits EOF, so no args are parsed and the count mismatch returns nil.
        var d = withUnsafeBytes(of: Int32(1)) { Data($0) }
        d.append(Data("/bin/shhhhhh".utf8)) // no terminating NUL
        #expect(CommandRestore.parseProcArgs(d) == nil)
    }

    @Test func shellQuotedLineQuotesSpecialChars() {
        #expect(CommandRestore.shellQuotedLine(["ssh", "gate"]) == "'ssh' 'gate'")
        #expect(CommandRestore.shellQuotedLine(["echo", "a b"]) == "'echo' 'a b'")
        #expect(CommandRestore.shellQuotedLine(["echo", "$HOME", "*.txt"]) == "'echo' '$HOME' '*.txt'")
        // an embedded single quote is rendered as '\'' and stays literal.
        #expect(CommandRestore.shellQuotedLine(["echo", "it's"]) == "'echo' 'it'\\''s'")
    }

    @Test func basenameTakesLastPathComponent() {
        #expect(CommandRestore.basename("/usr/bin/vim") == "vim")
        #expect(CommandRestore.basename("ssh") == "ssh")
        #expect(CommandRestore.basename("") == "")
    }

    // MARK: - restorePlan (the surface-seed gate/precedence)

    @Test func freshCommandSessionAlwaysRunsItsCommand() {
        for enabled in [true, false] {
            let plan = CommandRestore.restorePlan(.init(wasRestored: false, restoreEnabled: enabled, hadForeground: false,
                                                        foregroundInput: nil, initialCommand: "ssh host", restoreOverride: nil))
            #expect(plan == CommandRestore.RestorePlan(command: "ssh host", initialInput: nil))
        }
    }

    @Test func restoredCommandSessionRunsCommandOnlyWhenEnabled() {
        let on = CommandRestore.restorePlan(.init(wasRestored: true, restoreEnabled: true, hadForeground: false,
                                                  foregroundInput: nil, initialCommand: "ssh host", restoreOverride: nil))
        #expect(on == CommandRestore.RestorePlan(command: "ssh host", initialInput: nil))
        let off = CommandRestore.restorePlan(.init(wasRestored: true, restoreEnabled: false, hadForeground: false,
                                                   foregroundInput: nil, initialCommand: "ssh host", restoreOverride: nil))
        #expect(off == CommandRestore.RestorePlan(command: nil, initialInput: nil)) // opt-out → plain shell
    }

    @Test func capturedForegroundPreemptsInitialCommand() {
        let plan = CommandRestore.restorePlan(.init(wasRestored: true, restoreEnabled: true, hadForeground: true,
                                                    foregroundInput: "top\n", initialCommand: "ssh host", restoreOverride: nil))
        #expect(plan == CommandRestore.RestorePlan(command: nil, initialInput: "top\n"))
    }

    @Test func suppressedForegroundYieldsPlainShellNotStaleCommand() {
        // hadForeground with a nil input = captured but suppressed (denylisted, or the toggle off)
        let plan = CommandRestore.restorePlan(.init(wasRestored: true, restoreEnabled: true, hadForeground: true,
                                                    foregroundInput: nil, initialCommand: "ssh host", restoreOverride: nil))
        #expect(plan == CommandRestore.RestorePlan(command: nil, initialInput: nil))
    }

    @Test func noCommandAndNoForegroundIsPlainShell() {
        let plan = CommandRestore.restorePlan(.init(wasRestored: true, restoreEnabled: true, hadForeground: false,
                                                    foregroundInput: nil, initialCommand: nil, restoreOverride: nil))
        #expect(plan == CommandRestore.RestorePlan(command: nil, initialInput: nil))
    }

    @Test func waitAfterCommandRequiresAnEffectiveExecCommand() {
        let holding = CommandRestore.restorePlan(.init(
            wasRestored: true, restoreEnabled: true, hadForeground: false,
            foregroundInput: nil, initialCommand: "ssh host", restoreOverride: nil, requestedWait: true
        ))
        #expect(holding.waitAfterCommand)

        let notRequested = CommandRestore.restorePlan(.init(
            wasRestored: true, restoreEnabled: true, hadForeground: false,
            foregroundInput: nil, initialCommand: "ssh host", restoreOverride: nil, requestedWait: false
        ))
        #expect(!notRequested.waitAfterCommand)

        let captured = CommandRestore.restorePlan(.init(
            wasRestored: true, restoreEnabled: true, hadForeground: true,
            foregroundInput: "top\n", initialCommand: "ssh host", restoreOverride: nil, requestedWait: true
        ))
        #expect(captured.command == nil)
        #expect(!captured.waitAfterCommand)

        let overridden = CommandRestore.restorePlan(.init(
            wasRestored: true, restoreEnabled: true, hadForeground: false,
            foregroundInput: nil, initialCommand: "ssh host", restoreOverride: "claude", requestedWait: true
        ))
        #expect(overridden.command == nil)
        #expect(!overridden.waitAfterCommand)
    }

    @MainActor @Test func splitCreationCommandUsesExecPathUnlessOverrideWins() {
        let session = Session(initialCwd: "/tmp")
        session.wasRestored = true
        session.splitInitialCommand = "ssh split-host"
        session.splitCommandWait = true

        let exec = CommandRestore.restorePlan(.init(
            wasRestored: session.wasRestored, restoreEnabled: true, hadForeground: false,
            foregroundInput: nil, initialCommand: session.splitInitialCommand,
            restoreOverride: nil, requestedWait: session.splitCommandWait
        ))
        #expect(exec.command == "ssh split-host")
        #expect(exec.initialInput == nil)
        #expect(exec.waitAfterCommand)

        let overridden = CommandRestore.restorePlan(.init(
            wasRestored: session.wasRestored, restoreEnabled: true, hadForeground: false,
            foregroundInput: nil, initialCommand: session.splitInitialCommand,
            restoreOverride: "claude --resume split", requestedWait: session.splitCommandWait
        ))
        #expect(overridden.command == nil)
        #expect(overridden.initialInput == "claude --resume split\n")
        #expect(!overridden.waitAfterCommand)
    }

    // MARK: - restoreInput (the pinned-override precedence)

    @Test func restoreInputFallsThroughWithoutOverride() {
        // the app side already applied the toggle + denylist to the captured input, so the gate is moot
        for enabled in [true, false] {
            #expect(CommandRestore.restoreInput(restoreEnabled: enabled, restoreOverride: nil,
                                                capturedInput: "top\n") == "top\n")
            #expect(CommandRestore.restoreInput(restoreEnabled: enabled, restoreOverride: nil, capturedInput: nil) == nil)
        }
    }

    @Test func restoreInputRunsPinnedCommandOnlyWhenEnabled() {
        // a pinned command is typed verbatim with a newline, never re-quoted
        #expect(CommandRestore.restoreInput(restoreEnabled: true, restoreOverride: "cd x && claude --resume y",
                                            capturedInput: "top\n") == "cd x && claude --resume y\n")
        #expect(CommandRestore.restoreInput(restoreEnabled: false, restoreOverride: "claude --resume y",
                                            capturedInput: "top\n") == nil)
    }

    @Test func restoreInputTreatsEmptyOverrideAsPinnedToNothing() {
        for enabled in [true, false] {
            #expect(CommandRestore.restoreInput(restoreEnabled: enabled, restoreOverride: "", capturedInput: "top\n") == nil)
            #expect(CommandRestore.restoreInput(restoreEnabled: enabled, restoreOverride: "", capturedInput: nil) == nil)
        }
    }

    @Test func overrideNeverTakesExecPathAndBeatsInitialCommand() {
        let fresh = CommandRestore.restorePlan(.init(wasRestored: false, restoreEnabled: true, hadForeground: false,
                                                     foregroundInput: nil, initialCommand: "ssh host",
                                                     restoreOverride: "claude --resume y"))
        #expect(fresh == CommandRestore.RestorePlan(command: nil, initialInput: "claude --resume y\n"))
        let captured = CommandRestore.restorePlan(.init(wasRestored: true, restoreEnabled: true, hadForeground: true,
                                                        foregroundInput: "top\n", initialCommand: nil,
                                                        restoreOverride: "claude --resume y"))
        #expect(captured == CommandRestore.RestorePlan(command: nil, initialInput: "claude --resume y\n"))
    }

    @Test func emptyOverrideSuppressesInitialCommandAndCapture() {
        // "" pins the pane to nothing: neither the creation command nor the captured foreground runs
        let withInitial = CommandRestore.restorePlan(.init(wasRestored: false, restoreEnabled: true, hadForeground: false,
                                                           foregroundInput: nil, initialCommand: "ssh host",
                                                           restoreOverride: ""))
        #expect(withInitial == CommandRestore.RestorePlan(command: nil, initialInput: nil))
        let withCapture = CommandRestore.restorePlan(.init(wasRestored: true, restoreEnabled: true, hadForeground: true,
                                                           foregroundInput: "top\n", initialCommand: "ssh host",
                                                           restoreOverride: ""))
        #expect(withCapture == CommandRestore.RestorePlan(command: nil, initialInput: nil))
    }

    @Test func disabledSettingSuppressesOverrideEvenOverACapture() {
        let plan = CommandRestore.restorePlan(.init(wasRestored: true, restoreEnabled: false, hadForeground: true,
                                                    foregroundInput: "top\n", initialCommand: "ssh host",
                                                    restoreOverride: "claude --resume y"))
        #expect(plan == CommandRestore.RestorePlan(command: nil, initialInput: nil))
    }
}
