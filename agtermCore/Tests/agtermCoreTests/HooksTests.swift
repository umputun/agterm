import Foundation
import Testing
@testable import agtermCore

struct HooksTests {
    @Test func everyRingKindParsesWithItsRemainder() {
        let text = ControlEventKind.allCases.map { "on \($0.rawValue) echo \($0.rawValue)" }.joined(separator: "\n")
        let (hooks, diagnostics) = parseHooksConf(text)
        #expect(diagnostics.isEmpty)
        #expect(hooks.entries.map(\.kind) == ControlEventKind.allCases)
        #expect(hooks.entries.map(\.command) == ControlEventKind.allCases.map { "echo \($0.rawValue)" })
        #expect(hooks.entries.map(\.line) == Array(1...ControlEventKind.allCases.count))
    }

    @Test func severalLinesPerKindKeepFileOrder() {
        let (hooks, diagnostics) = parseHooksConf("""
        on status ~/a.sh
        on session.closed ~/c.sh
        on status ~/b.sh
        """)
        #expect(diagnostics.isEmpty)
        #expect(hooks.entries.map(\.command) == ["~/a.sh", "~/c.sh", "~/b.sh"])
        #expect(hooks.entries.map(\.kind) == [.status, .sessionClosed, .status])
    }

    @Test func blankAndWholeLineCommentsAreIgnoredAndCRLFIsNormalized() {
        let text = "# header\r\n\r\n   # indented comment\r\non status echo a\r\n\r\non notify echo b\r\n"
        let (hooks, diagnostics) = parseHooksConf(text)
        #expect(diagnostics.isEmpty)
        #expect(hooks.entries.map(\.command) == ["echo a", "echo b"])
        #expect(hooks.entries.map(\.line) == [4, 6])
    }

    @Test(arguments: [
        "echo 'fix #42'",
        "echo \"a \\\" b\"",
        "ls | grep x",
        "echo hi >> ~/log.txt",
        "echo $(date) $HOME",
        "printf '%s\\n' a",
        "echo  two  spaces",
        "~/bin/x.sh",
        "echo hi # not a comment",
    ])
    func shellRemainderIsPreservedVerbatim(command: String) {
        let (hooks, diagnostics) = parseHooksConf("on status \t \(command) \t ")
        #expect(diagnostics.isEmpty)
        #expect(hooks.entries.map(\.command) == [command])
    }

    @Test func identityIsKindPlusCommandRegardlessOfSpacingAndLine() {
        let (hooks, diagnostics) = parseHooksConf("""
        on   status\t   echo x
        # a comment between them changes the line number, never the identity
        on status echo x
        on notify echo x
        """)
        #expect(hooks.entries.map(\.command) == ["echo x", "echo x"])
        #expect(hooks.entries.map(\.kind) == [.status, .notify])
        #expect(hooks.entries[0].line == 1)
        #expect(diagnostics == [KeymapDiagnostic(line: 3, message: "hook 'on status echo x' is already defined; hook skipped")])
        #expect(HookIdentity(kind: .status, command: "echo x") == hooks.entries[0].identity)
        #expect(HookEntry(identity: hooks.entries[0].identity, line: 99).identity == hooks.entries[0].identity)
    }

    @Test func malformedLinesAreDiagnosedAndLaterLinesStillParse() {
        let (hooks, diagnostics) = parseHooksConf("""
        map cmd+a toggle_split
        on
        on bogus echo x
        on status
        on status \t
        on notify echo ok
        """)
        #expect(hooks.entries.map(\.command) == ["echo ok"])
        #expect(hooks.entries.map(\.line) == [6])
        #expect(diagnostics == [
            KeymapDiagnostic(line: 1, message: "unknown verb 'map'"),
            KeymapDiagnostic(line: 2, message: "on requires an event kind"),
            KeymapDiagnostic(line: 3, message: "unknown event kind 'bogus'"),
            KeymapDiagnostic(line: 4, message: "hook for 'status' has no shell line"),
            KeymapDiagnostic(line: 5, message: "hook for 'status' has no shell line"),
        ])
    }

    @Test func emptyTextParsesToNothing() {
        let (hooks, diagnostics) = parseHooksConf("")
        #expect(hooks.entries.isEmpty)
        #expect(diagnostics.isEmpty)
    }
}
