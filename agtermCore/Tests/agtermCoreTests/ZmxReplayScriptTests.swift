import Darwin
import Foundation
import Testing
@testable import agtermCore

private let fishRequired = ProcessInfo.processInfo.environment["AGTERM_REQUIRE_FISH"] != nil

private let fishPath: String? = {
    if let path = ProcessInfo.processInfo.environment["PATH"], let executable = path.split(separator: ":").map(String.init).first(where: { directory in
        FileManager.default.isExecutableFile(atPath: URL(fileURLWithPath: directory).appending(path: "fish").path)
    }) {
        return URL(fileURLWithPath: executable).appending(path: "fish").path
    }
    return ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"].first(where: FileManager.default.isExecutableFile)
}()

private func resolvedFish() throws -> String {
    guard let fishPath else {
        Issue.record("AGTERM_REQUIRE_FISH is set but fish is absent from PATH")
        throw RequiredFishFailure.fishUnavailable
    }
    return fishPath
}

private enum RequiredFishFailure: Error {
    case fishUnavailable
}

struct ZmxReplayScriptTests {
    @Test func customZdotdirIsRearmedBeforeTheFinalShell() {
        let script = ZmxReplayScript.render(
            argv: ["printf", "a b"],
            integrationDirectory: "/Applications/agterm resources/zsh",
            inheritedZdotdir: "/Users/test/.config/zsh",
            shell: "/bin/zsh"
        )

        #expect(script == "{ 'printf' 'a b' ; } always { 'builtin' 'export' " +
                "ZDOTDIR='/Applications/agterm resources/zsh' ; 'builtin' 'export' " +
                "GHOSTTY_ZSH_ZDOTDIR='/Users/test/.config/zsh' ; " +
                "'builtin' 'exec' -- '/bin/zsh' -il ; }")
    }

    @Test func missingOriginalZdotdirIsUnsetBeforeTheFinalShell() {
        let script = ZmxReplayScript.render(
            argv: ["top"], integrationDirectory: "/bundle/zsh",
            inheritedZdotdir: nil, shell: "/bin/zsh"
        )

        #expect(script == "{ 'top' ; } always { 'builtin' 'export' ZDOTDIR='/bundle/zsh' ; " +
                "'builtin' 'unset' GHOSTTY_ZSH_ZDOTDIR ; 'builtin' 'exec' -- '/bin/zsh' -il ; }")
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

    @Test func endingCommandRunsItsLineAndExitsWithItsStatus() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let result = fixture.appending(path: "ending")
        let output = CommandRestore.shellQuotedLine([result.path])
        let script = ZmxReplayScript.renderEnding(commandLine: "printf '%s' 'two words' > \(output) && exit 7")

        #expect(script == "'builtin' 'eval' -- " + CommandRestore.shellQuotedLine(["printf '%s' 'two words' > \(output) && exit 7"]))
        #expect(try runZsh(script: script) == 7)
        #expect(try String(contentsOf: result, encoding: .utf8) == "two words")
    }

    @Test func aDuplicatedProgramsCreationCommandKeepsItsArgvThroughZsh() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let result = fixture.appending(path: "argv")
        let probe = fixture.appending(path: "record-argv")
        try makeArgumentProbe(probe)
        let expected = ["can't", "two words", "", "$HOME", "semi;colon"]
        let command = try #require(DuplicateReplay.Plan.program(argv: [probe.path, result.path] + expected, workingDirectory: "/").command)

        #expect(try runZsh(script: ZmxReplayScript.renderEnding(commandLine: command)) == 0)
        #expect(try nullSeparatedValues(at: result) == expected)
    }

    @Test func endingCommandStartsNoShellAfterIt() {
        let script = ZmxReplayScript.renderEnding(commandLine: "lazygit")
        let fishScript = ZmxReplayScript.renderFishEnding(commandLine: "printf '%s' 'two words'")

        #expect(!script.contains("exec"))
        #expect(!script.contains("ZDOTDIR"))
        #expect(fishScript == "builtin status job-control full; builtin eval 'printf \\'%s\\' \\'two words\\''")
    }

    @Test(.enabled(if: fishPath != nil || fishRequired, "fish is unavailable; real-fish tests are skipped"))
    func fishEndingCommandRunsItsLineAndStartsNoShell() throws {
        let fish = try resolvedFish()
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let result = fixture.appending(path: "ending")
        let script = ZmxReplayScript.renderFishEnding(
            commandLine: "printf '%s' 'two words' > " + CommandRestore.shellQuotedLine([result.path])
        )

        try runFish(executable: fish, script: script, fixture: fixture)
        #expect(try String(contentsOf: result, encoding: .utf8) == "two words")
    }

    @Test func fishRenderersUseFishEscapingAndRearmBeforeTheFinalShell() {
        let root = "/Applications/agterm resources/shell-integration"
        let argv = ["/tmp/tool $name;*", "two words", "can't", ""]
        let argvScript = ZmxReplayScript.renderFish(argv: argv, integrationRoot: root, shell: "/bin/fish")
        let commandScript = ZmxReplayScript.renderFish(
            commandLine: "printf '%s' 'two words'", integrationRoot: root, shell: "/bin/fish"
        )

        let argvStatement = "'/tmp/tool $name;*' 'two words' 'can\\'t' ''"
        #expect(argvScript.hasPrefix("builtin status job-control full; builtin eval " + fishLiteral(argvStatement) + "; "))
        #expect(commandScript.hasPrefix("builtin status job-control full; builtin eval 'printf \\'%s\\' \\'two words\\''; "))
        for script in [argvScript, commandScript] {
            #expect(script.contains("builtin set -gx GHOSTTY_SHELL_INTEGRATION_XDG_DIR '" + root + "'"))
            #expect(script.contains("builtin set --global --export --path XDG_DATA_DIRS '" + root + "'"))
            #expect(script.hasSuffix("exec '/bin/fish' -il"))
        }
    }

    @Test func fishQuotingCoversRequiredAndHostileArguments() {
        let cases: [(String, String)] = [
            ("trailing\\", "'trailing\\\\'"),
            ("two\\\\slashes", "'two\\\\\\\\slashes'"),
            ("can't", "'can\\'t'"),
            ("", "''"),
            ("\\'", "'" + String(repeating: "\\", count: 3) + "''"),
            ("many\\\\\\slashes", "'many" + String(repeating: "\\", count: 6) + "slashes'"),
            ("two words", "'two words'"),
            ("\u{00E9}\u{043B}\u{0435}\u{043D}\u{0430}", "'\u{00E9}\u{043B}\u{0435}\u{043D}\u{0430}'"),
            ("$literal", "'$literal'"),
            ("(parentheses)", "'(parentheses)'"),
            ("*.swift", "'*.swift'"),
            ("semi;colon", "'semi;colon'"),
            (">redirect", "'>redirect'"),
            ("--option", "'--option'"),
            ("line one\nline two", "'line one\nline two'"),
        ]

        for (argument, expected) in cases {
            let script = ZmxReplayScript.renderFish(argv: [argument], integrationRoot: "/root", shell: "/bin/fish")
            #expect(script.hasPrefix("builtin status job-control full; builtin eval " + fishLiteral(expected) + "; "))
        }
    }

    @Test(.enabled(if: fishPath != nil || fishRequired, "fish is unavailable; real-fish tests are skipped"))
    func fishCapturedArgumentsSurviveTheParserRoundTrip() throws {
        let fish = try resolvedFish()
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let argvResult = fixture.appending(path: "argv")
        let environmentResult = fixture.appending(path: "environment")
        let replay = fixture.appending(path: "record-argv")
        let finalShell = fixture.appending(path: "record-environment")
        try makeArgumentProbe(replay)
        try makeEnvironmentProbe(finalShell)
        let expected = [
            "trailing\\", "two\\\\slashes", "can't", "\\'", "many\\\\\\slashes", "two words",
            "\u{00E9}\u{043B}\u{0435}\u{043D}\u{0430}", "$literal", "(parentheses)", "*.swift", "semi;colon",
            ">redirect", "--option", "", "line one\nline two",
        ]
        let script = ZmxReplayScript.renderFish(
            argv: [replay.path, argvResult.path] + expected,
            integrationRoot: "/integration root", shell: finalShell.path
        )

        try runFish(executable: fish, script: script, fixture: fixture, environment: ["RESULT_FILE": environmentResult.path])
        #expect(try nullSeparatedValues(at: argvResult) == expected)
        let environment = try nullSeparatedValues(at: environmentResult)
        #expect(environment == [
            "/integration root:/usr/local/share:/usr/share", "/integration root",
        ])
    }

    @Test(.enabled(if: fishPath != nil || fishRequired, "fish is unavailable; real-fish tests are skipped"))
    func aDuplicatedProgramsCreationCommandKeepsItsArgvThroughFish() throws {
        let fish = try resolvedFish()
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let result = fixture.appending(path: "argv")
        let probe = fixture.appending(path: "record-argv")
        try makeArgumentProbe(probe)
        let expected = ["can't", "two words", "", "$HOME", "semi;colon"]
        let command = try #require(DuplicateReplay.Plan.program(argv: [probe.path, result.path] + expected, workingDirectory: "/").command)

        try runFish(executable: fish, script: ZmxReplayScript.renderFishEnding(commandLine: command), fixture: fixture,
                    environment: ["RESULT_FILE": result.path])
        #expect(try nullSeparatedValues(at: result) == expected)
    }

    @Test(.enabled(if: fishPath != nil || fishRequired, "fish is unavailable; real-fish tests are skipped"))
    func fishDurableCommandLineSurvivesTheParserRoundTrip() throws {
        let fish = try resolvedFish()
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let argvResult = fixture.appending(path: "argv")
        let environmentResult = fixture.appending(path: "environment")
        let replay = fixture.appending(path: "record-argv")
        let finalShell = fixture.appending(path: "record-environment")
        try makeArgumentProbe(replay)
        try makeEnvironmentProbe(finalShell)
        let expected = ["durable words", "", "$literal", "line one\nline two"]
        let commandLine = ([replay.path, argvResult.path] + expected).map(fishLiteral).joined(separator: " ")
        let script = ZmxReplayScript.renderFish(
            commandLine: commandLine, integrationRoot: "/integration root", shell: finalShell.path
        )

        try runFish(executable: fish, script: script, fixture: fixture, environment: ["RESULT_FILE": environmentResult.path])
        #expect(try nullSeparatedValues(at: argvResult) == expected)
        let environment = try nullSeparatedValues(at: environmentResult)
        #expect(environment.first == "/integration root:/usr/local/share:/usr/share")
    }

    @Test(.enabled(if: fishPath != nil || fishRequired, "fish is unavailable; real-fish tests are skipped"))
    func fishReplayReachesTheFinalShellAfterFailedPayloads() throws {
        let fish = try resolvedFish()
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let finalShell = fixture.appending(path: "record-environment")
        try makeEnvironmentProbe(finalShell)

        for payload in [["/definitely/missing/agterm-fish-payload"], ["/usr/bin/false"]] {
            let scripts = [
                ZmxReplayScript.renderFish(argv: payload, integrationRoot: "/integration root", shell: finalShell.path),
                ZmxReplayScript.renderFish(
                    commandLine: payload.map(fishLiteral).joined(separator: " "),
                    integrationRoot: "/integration root", shell: finalShell.path
                ),
            ]
            for script in scripts {
                let result = fixture.appending(path: "environment-\(UUID().uuidString)")
                try runFish(executable: fish, script: script, fixture: fixture, environment: ["RESULT_FILE": result.path])
                let environment = try nullSeparatedValues(at: result)
                #expect(environment == [
                    "/integration root:/usr/local/share:/usr/share", "/integration root",
                ])
            }
        }
    }

    @Test(.enabled(if: fishPath != nil || fishRequired, "fish is unavailable; real-fish tests are skipped"))
    func fishReplayRearmsXDGDataDirectoriesFromTheLivePayloadState() throws {
        let fish = try resolvedFish()
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let finalShell = fixture.appending(path: "record-environment")
        try makeEnvironmentProbe(finalShell)
        let root = "/integration root"
        let cases: [([String], String)] = [
            (["set", "-gx", "XDG_DATA_DIRS", "/new/one:/new/two"], root + ":/new/one:/new/two"),
            (["set", "-gx", "XDG_DATA_DIRS", ""], root + ":/usr/local/share:/usr/share"),
            (["set", "-e", "XDG_DATA_DIRS"], root + ":/usr/local/share:/usr/share"),
            (["set", "-gx", "XDG_DATA_DIRS", root + ":/new/one:" + root], root + ":/new/one"),
            (["set", "-gx", "XDG_DATA_DIRS", "/new with space:/new/two"], root + ":/new with space:/new/two"),
        ]

        for (argv, expected) in cases {
            let result = fixture.appending(path: "environment-\(UUID().uuidString)")
            let script = ZmxReplayScript.renderFish(argv: argv, integrationRoot: root, shell: finalShell.path)
            try runFish(executable: fish,
                script: script, fixture: fixture,
                environment: ["RESULT_FILE": result.path, "XDG_DATA_DIRS": "/original/one:/original/two"]
            )
            let environment = try nullSeparatedValues(at: result)
            #expect(environment == [expected, root])
        }
    }

    enum PayloadForm: CaseIterable, Sendable {
        case argv, commandLine
    }

    // regression: a Ctrl-C'd payload ends the interactive -c list before the exec, leaving the pane without a shell.
    @Test(arguments: PayloadForm.allCases)
    func interruptedPayloadStillExecsTheFinalShell(form: PayloadForm) throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let payloadLog = fixture.appending(path: "payload-log")
        let result = fixture.appending(path: "result")
        let payload = fixture.appending(path: "interrupted-payload")
        try makeExecutable(payload, contents: """
        #!/bin/sh
        printf 'ran\\n' >> "$PAYLOAD_LOG"
        kill -INT 0
        """)
        let finalShell = fixture.appending(path: "final-shell")
        try makeExecutable(finalShell, contents: """
        #!/bin/sh
        printf '%s\\n%s\\n%s\\n' "$ZDOTDIR" "${GHOSTTY_ZSH_ZDOTDIR-unset}" "$1" >> "$RESULT_FILE"
        """)
        let script = switch form {
        case .argv:
            ZmxReplayScript.render(argv: [payload.path], integrationDirectory: "/bundle/integration",
                                   inheritedZdotdir: "/user/zsh", shell: finalShell.path)
        case .commandLine:
            ZmxReplayScript.render(commandLine: CommandRestore.shellQuotedLine([payload.path]),
                                   integrationDirectory: "/bundle/integration",
                                   inheritedZdotdir: "/user/zsh", shell: finalShell.path)
        }

        try runZshInTerminal(script: script, environment: [
            "HOME": fixture.path,
            "ZDOTDIR": fixture.path,
            "PAYLOAD_LOG": payloadLog.path,
            "RESULT_FILE": result.path,
        ])

        #expect(try String(contentsOf: payloadLog, encoding: .utf8) == "ran\n")
        #expect(try String(contentsOf: result, encoding: .utf8) == "/bundle/integration\n/user/zsh\n-il\n")
    }

    @Test(.enabled(if: fishPath != nil || fishRequired, "fish is unavailable; real-fish tests are skipped"),
          arguments: PayloadForm.allCases)
    func fishInterruptedPayloadStillExecsTheFinalShell(form: PayloadForm) throws {
        let fish = try resolvedFish()
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let payloadLog = fixture.appending(path: "payload-log")
        let result = fixture.appending(path: "result")
        let payload = fixture.appending(path: "interrupted-payload")
        try makeExecutable(payload, contents: """
        #!/bin/sh
        printf 'ran\\n' >> "$PAYLOAD_LOG"
        kill -INT 0
        """)
        let finalShell = fixture.appending(path: "final-shell")
        try makeEnvironmentProbe(finalShell)
        let script = switch form {
        case .argv:
            ZmxReplayScript.renderFish(argv: [payload.path], integrationRoot: "/integration root", shell: finalShell.path)
        case .commandLine:
            ZmxReplayScript.renderFish(commandLine: fishLiteral(payload.path),
                                      integrationRoot: "/integration root", shell: finalShell.path)
        }

        try runFish(executable: fish, script: script, fixture: fixture, inTerminal: true, environment: [
            "PAYLOAD_LOG": payloadLog.path,
            "RESULT_FILE": result.path,
            "XDG_DATA_DIRS": "/user/share",
        ])

        #expect(try String(contentsOf: payloadLog, encoding: .utf8) == "ran\n")
        #expect(try nullSeparatedValues(at: result) == ["/integration root:/user/share", "/integration root"])
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

    private func makeArgumentProbe(_ url: URL) throws {
        try makeExecutable(url, contents: """
        #!/bin/sh
        result=$1
        shift
        printf '%s\\0' "$@" > "$result"
        """)
    }

    private func makeEnvironmentProbe(_ url: URL) throws {
        try makeExecutable(url, contents: """
        #!/bin/sh
        printf '%s\\0%s\\0' "$XDG_DATA_DIRS" "${GHOSTTY_SHELL_INTEGRATION_XDG_DIR-unset}" > "$RESULT_FILE"
        """)
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

    private func runFish(executable: String, script: String, fixture: URL, inTerminal: Bool = false,
                         environment overrides: [String: String] = [:]) throws {
        let home = fixture.appending(path: "home")
        let config = fixture.appending(path: "config")
        let data = fixture.appending(path: "data")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: inTerminal ? "/usr/bin/script" : executable)
        process.arguments = (inTerminal ? ["-q", "/dev/null", executable] : []) + ["--no-config", "-lic", script]
        if inTerminal { process.standardInput = FileHandle.nullDevice }
        var processEnvironment = ProcessInfo.processInfo.environment
        processEnvironment.removeValue(forKey: "XDG_DATA_DIRS")
        process.environment = processEnvironment.merging([
            "HOME": home.path,
            "XDG_CONFIG_HOME": config.path,
            "XDG_DATA_HOME": data.path,
        ].merging(overrides) { _, new in new }) { _, new in new }
        process.standardOutput = FileHandle.nullDevice
        let standardError = Pipe()
        process.standardError = standardError
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + 20) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .success { throw ReplayFailure.timedOut }
            _ = kill(process.processIdentifier, SIGKILL)
            guard finished.wait(timeout: .now() + 2) == .success else { throw ReplayFailure.didNotTerminate }
            throw ReplayFailure.timedOut
        }
        guard process.terminationStatus == 0 else {
            throw ReplayFailure.failed(
                status: process.terminationStatus,
                standardError: String(decoding: standardError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            )
        }
    }

    private func fishLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    private func nullSeparatedValues(at url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        var values: [String] = []
        var start = data.startIndex
        for index in data.indices where data[index] == 0 {
            values.append(try #require(String(data: data[start..<index], encoding: .utf8)))
            start = data.index(after: index)
        }
        #expect(start == data.endIndex)
        return values
    }

    private enum ReplayFailure: Error {
        case timedOut
        case didNotTerminate
        case failed(status: Int32, standardError: String)
    }

    /// Runs `zsh -lic` under `script(1)` so zsh has a terminal and job control, as in a pane.
    private func runZshInTerminal(script: String, environment overrides: [String: String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/bin/zsh", "-lic", script]
        process.environment = ProcessInfo.processInfo.environment.merging(overrides) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            Issue.record("zsh under script(1) did not exit within 10 s")
        }
    }
}
