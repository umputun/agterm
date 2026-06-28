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
    }

    @Test func shouldRestoreSkipsDenylistByBasename() {
        #expect(CommandRestore.shouldRestore(argv: ["ssh", "gate"]))
        #expect(CommandRestore.shouldRestore(argv: ["top"]))
        #expect(!CommandRestore.shouldRestore(argv: ["/usr/bin/vim", "file"])) // basename match
        #expect(!CommandRestore.shouldRestore(argv: ["python3"]))
        #expect(!CommandRestore.shouldRestore(argv: []))
        #expect(!CommandRestore.shouldRestore(argv: [""]))
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
