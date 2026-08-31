import Foundation
import Testing
@testable import agtermCore

struct ZmxReplayScriptTests {
    @Test func customZdotdirIsRearmedBeforeTheFinalShell() {
        let script = ZmxReplayScript.render(
            argv: ["printf", "a b"],
            integrationDirectory: "/Applications/agterm resources/zsh",
            inheritedZdotdir: "/Users/test/.config/zsh",
            shell: "/bin/zsh"
        )

        #expect(script == "'printf' 'a b' ; 'builtin' 'export' " +
                "ZDOTDIR='/Applications/agterm resources/zsh' ; 'builtin' 'export' " +
                "GHOSTTY_ZSH_ZDOTDIR='/Users/test/.config/zsh' ; " +
                "'builtin' 'exec' -- '/bin/zsh' -il")
    }

    @Test func missingOriginalZdotdirIsUnsetBeforeTheFinalShell() {
        let script = ZmxReplayScript.render(
            argv: ["top"], integrationDirectory: "/bundle/zsh",
            inheritedZdotdir: nil, shell: "/bin/zsh"
        )

        #expect(script == "'top' ; 'builtin' 'export' ZDOTDIR='/bundle/zsh' ; " +
                "'builtin' 'unset' GHOSTTY_ZSH_ZDOTDIR ; 'builtin' 'exec' -- '/bin/zsh' -il")
    }

    @Test func quotedBuiltinsSurviveHostileAliasesAndFailureStillExecsTheShell() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let zshrc = fixture.appending(path: ".zshrc")
        try """
        alias builtin='false'
        alias export='false'
        alias exec='false'
        printf loaded > "$ALIAS_MARKER"
        """.write(to: zshrc, atomically: true, encoding: .utf8)

        let aliasMarker = fixture.appending(path: "aliases-loaded")
        let result = fixture.appending(path: "result")
        let finalShell = fixture.appending(path: "final-shell")
        try makeExecutable(finalShell, contents: """
        #!/bin/sh
        printf '%s\n%s\n%s\n' "$ZDOTDIR" "${GHOSTTY_ZSH_ZDOTDIR-unset}" "$1" > "$RESULT_FILE"
        """)
        let script = ZmxReplayScript.render(
            argv: ["/usr/bin/false"], integrationDirectory: "/bundle/integration",
            inheritedZdotdir: "/user/zsh", shell: finalShell.path
        )

        let status = try runZsh(script: script, environment: [
            "ZDOTDIR": fixture.path,
            "RESULT_FILE": result.path,
            "ALIAS_MARKER": aliasMarker.path,
        ], interactive: true)

        #expect(status == 0)
        #expect(try String(contentsOf: aliasMarker, encoding: .utf8) == "loaded")
        #expect(try String(contentsOf: result, encoding: .utf8) == "/bundle/integration\n/user/zsh\n-il\n")
    }

    @Test func capturedArgumentsSurviveTheShellRoundTrip() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let result = fixture.appending(path: "argv")
        let replay = fixture.appending(path: "record-argv")
        try makeExecutable(replay, contents: """
        #!/bin/sh
        result=$1
        shift
        printf '%s\n' "$@" > "$result"
        """)
        let expected = ["two words", "$HOME", "single'quote", "semi;colon"]
        let script = ZmxReplayScript.render(
            argv: [replay.path, result.path] + expected,
            integrationDirectory: "/bundle/zsh", inheritedZdotdir: nil,
            shell: "/usr/bin/true"
        )

        #expect(try runZsh(script: script) == 0)
        #expect(try String(contentsOf: result, encoding: .utf8).split(separator: "\n").map(String.init) == expected)
    }

    @Test func durableShellLineKeepsItsOperatorsAndWordParsing() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let result = fixture.appending(path: "shell-line")
        let output = CommandRestore.shellQuotedLine([result.path])
        let script = ZmxReplayScript.render(
            commandLine: "printf '%s' 'two words' > \(output) && printf ' and more' >> \(output)",
            integrationDirectory: "/bundle/zsh", inheritedZdotdir: nil,
            shell: "/usr/bin/true"
        )

        #expect(try runZsh(script: script) == 0)
        #expect(try String(contentsOf: result, encoding: .utf8) == "two words and more")
    }

    private func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "agterm-zmx-replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeExecutable(_ url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func runZsh(script: String, environment overrides: [String: String] = [:],
                        interactive: Bool = false) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [interactive ? "-ic" : "-fc", script]
        process.environment = ProcessInfo.processInfo.environment.merging(overrides) { _, new in new }
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
