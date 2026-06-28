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
        // argc says 2 but only one arg present -> nil (no overread, no partial result).
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
        // an empty $SHELL basename must not classify an empty argv0 as a shell.
        #expect(!CommandRestore.isKnownShell("", extra: ""))
    }

    @Test func shouldRestoreSkipsDenylistByBasename() {
        let denylist: Set<String> = ["vim", "tmux", "hx"]
        #expect(CommandRestore.shouldRestore(argv: ["ssh", "gate"], denylist: denylist))
        #expect(CommandRestore.shouldRestore(argv: ["top"], denylist: denylist))
        // interpreters / servers are NOT denied (not in the list): usually scripts or servers worth restoring.
        #expect(CommandRestore.shouldRestore(argv: ["python3", "worker.py"], denylist: denylist))
        #expect(CommandRestore.shouldRestore(argv: ["node", "server.js"], denylist: denylist))
        // denylisted entries are matched on the basename.
        #expect(!CommandRestore.shouldRestore(argv: ["/usr/bin/vim", "file"], denylist: denylist))
        #expect(!CommandRestore.shouldRestore(argv: ["tmux"], denylist: denylist))
        #expect(!CommandRestore.shouldRestore(argv: ["/opt/homebrew/bin/hx", "."], denylist: denylist))
        // an empty denylist restores every non-empty argv; an empty argv never restores.
        #expect(CommandRestore.shouldRestore(argv: ["vim", "x"], denylist: []))
        #expect(!CommandRestore.shouldRestore(argv: [], denylist: denylist))
        #expect(!CommandRestore.shouldRestore(argv: [""], denylist: denylist))
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
        // argc=1 but the bytes after it run to EOF with no NUL: the exec-path walk hits EOF, no args
        // are parsed, and the count mismatch returns nil (no overread).
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
}
