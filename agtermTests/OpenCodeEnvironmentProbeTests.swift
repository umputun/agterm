import Foundation
import XCTest
import agtermCore
@testable import agterm

@MainActor
final class OpenCodeEnvironmentProbeTests: XCTestCase {
    func testProbeUsesVersionArgumentAndPathFromInteractiveLoginShell() async throws {
        let version = try await probe(script: """
        [ "$#" -eq 1 ] && [ "$1" = --version ] || exit 2
        [ -z "${AGTERM_SESSION_ID:-}" ] || exit 3
        [ "$AGTERM_TEST_LOGIN_PROFILE" = loaded ] || exit 4
        printf 'opencode v2.0.12\n'
        """)
        XCTAssertEqual(version, .v2)
    }

    func testStartupOutputDoesNotPolluteTheVersion() async throws {
        let version = try await probe(script: "printf '2.0.12\\n'", startup: "printf '1.18.31\\nstartup message without newline'")
        XCTAssertEqual(version, .v2)
    }

    func testProbeUsesTheConfiguredBashLoginShell() async throws {
        let version = try await probe(script: "printf '1.18.31\\n'", shell: "/bin/bash")
        XCTAssertEqual(version, .v1)
    }

    func testProbeUsesPathFromInteractiveFishLoginConfiguration() async throws {
        guard let fish = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("fish is not installed")
        }
        let version = try await probe(script: "[ \"$AGTERM_TEST_FISH_CONFIG\" = loaded ] || exit 2\nprintf '2.0.12\\n'", startup: """
        status is-interactive; or exit 3
        status is-login; or exit 4
        set -gx AGTERM_TEST_FISH_CONFIG loaded
        printf '1.18.31\\nfish startup message without newline'
        """, shell: fish)
        XCTAssertEqual(version, .v2)
    }

    func testStartupOutputCannotPretendTheProbeRan() async throws {
        let version = try await probe(script: "printf '2.0.12\\n'", startup: "printf '1.18.31\\n'; exit 0")
        XCTAssertNil(version)
    }

    func testMissingCommandNeedsManualSelection() async throws {
        let version = try await probe(script: nil)
        XCTAssertNil(version)
    }

    func testFailedOrUnsupportedVersionNeedsManualSelection() async throws {
        for script in ["printf '3.0.0\\n'", "printf '2.0.12\\n'; exit 1", "printf 'warning\\n2.0.12\\n'"] {
            let version = try await probe(script: script)
            XCTAssertNil(version)
        }
    }

    func testTimeoutKillsAProbeThatIgnoresTermination() async throws {
        let start = Date()
        let version = try await probe(script: "trap '' TERM\nwhile :; do :; done", timeout: 0.05)
        XCTAssertNil(version)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testTimeoutBoundsInteractiveShellStartup() async throws {
        let start = Date()
        let result = try await probeResult(script: "printf '2.0.12\\n'",
                                           startup: "export CODEX_HOME='/custom/codex'; trap '' TERM\nwhile :; do :; done", timeout: 0.1)
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testMissingExecutableNeedsManualSelection() async {
        let result = await OpenCodeEnvironmentProbe.detect(environment: ["CODEX_HOME": "/custom/codex"],
                                                           executableURL: URL(fileURLWithPath: "/no/such/agterm-probe"))
        XCTAssertNil(result)
    }

    func testExportedCodexHomeIsCapturedFromZshAndBashDespiteStartupNoise() async throws {
        for shell in ["/bin/zsh", "/bin/bash"] {
            let result = try await probeResult(script: "printf '2.0.12\\n'", startup: """
            printf 'startup noise without newline'
            export CODEX_HOME='/custom/codex home'
            """, shell: shell)
            XCTAssertEqual(result?.codexHome, "/custom/codex home")
            XCTAssertEqual(result?.version, .v2)
        }
    }

    func testExportedCodexHomeIsCapturedFromFish() async throws {
        guard let fish = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("fish is not installed")
        }
        let result = try await probeResult(script: "exit 1", startup: "set -gx CODEX_HOME '/custom/fish codex'", shell: fish)
        XCTAssertEqual(result?.codexHome, "/custom/fish codex")
        XCTAssertNil(result?.version)
    }

    func testEmptyUnsetAndUnexportedCodexHomeUseDefault() async throws {
        for shell in ["/bin/zsh", "/bin/bash"] {
            for startup in ["unset CODEX_HOME", "export CODEX_HOME=''", "unset CODEX_HOME; CODEX_HOME='/unexported'"] {
                let result = try await probeResult(script: "printf '2.0.12\\n'", startup: startup, shell: shell)
                XCTAssertNotNil(result)
                XCTAssertNil(result?.codexHome)
            }
        }
    }

    func testEmptyUnsetAndUnexportedFishCodexHomeUseDefault() async throws {
        guard let fish = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("fish is not installed")
        }
        for startup in ["set -e CODEX_HOME", "set -gx CODEX_HOME ''", "set -e CODEX_HOME; set -g CODEX_HOME '/unexported'"] {
            let result = try await probeResult(script: "exit 1", startup: startup, shell: fish)
            XCTAssertNotNil(result)
            XCTAssertNil(result?.codexHome)
        }
    }

    func testRelativeCodexHomeUsesCapturedWorkingDirectoryWithoutExpansion() async throws {
        let result = try await probeResult(script: "exit 1", startup: "cd /; export CODEX_HOME='relative dir/../codex $HOME ~'")
        XCTAssertEqual(result?.codexHome, "/codex $HOME ~")
    }

    func testCodexHomeSurvivesMissingFailingAndUnsupportedOpenCode() async throws {
        for script in [nil, "exit 1", "printf '3.0.0\\n'"] {
            let result = try await probeResult(script: script, startup: "export CODEX_HOME='/custom/codex'")
            XCTAssertEqual(result?.codexHome, "/custom/codex")
            XCTAssertNil(result?.version)
        }
    }

    func testTimeoutAfterCaptureDiscardsCodexHome() async throws {
        let result = try await probeResult(script: "trap '' TERM\nwhile :; do :; done",
                                           startup: "export CODEX_HOME='/custom/codex'", timeout: 0.3)
        XCTAssertNotNil(result)
        XCTAssertNil(result?.codexHome)
        XCTAssertNil(result?.version)
    }

    func testFailedStartupDiscardsCodexHome() async throws {
        let result = try await probeResult(script: nil, startup: "export CODEX_HOME='/custom/codex'; exit 0")
        XCTAssertNil(result)
    }

    func testMalformedCaptureDiscardsCodexHome() async throws {
        let executable = FileManager.default.temporaryDirectory.appendingPathComponent("malformed-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: executable) }
        try #"""
        #!/bin/sh
        marker=$(/usr/bin/printf '%s' "$2" | /usr/bin/sed -n 's/.*\(agterm-opencode-version-[A-F0-9-]*\).*/\1/p')
        /usr/bin/printf '\n%s\ntruncated\000' "$marker"
        """#.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let result = await OpenCodeEnvironmentProbe.detect(environment: ["CODEX_HOME": "/custom/codex"], executableURL: executable)
        XCTAssertNil(result)
    }

    private func probe(script: String?, startup: String = "", shell: String = "/bin/zsh", timeout: TimeInterval = 3) async throws -> AgentHooksInstall.OpenCode.Version? {
        try await probeResult(script: script, startup: startup, shell: shell, timeout: timeout)?.version
    }

    private func probeResult(script: String?, startup: String = "", shell: String = "/bin/zsh", timeout: TimeInterval = 3) async throws -> OpenCodeEnvironmentProbe.Result? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-probe-\(UUID().uuidString)")
        let inheritedBin = directory.appendingPathComponent("inherited-bin")
        let fm = FileManager.default
        try fm.createDirectory(at: inheritedBin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let unavailable = inheritedBin.appendingPathComponent("opencode")
        try "#!/bin/sh\nexit 127\n".write(to: unavailable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unavailable.path)
        if let script {
            let executable = directory.appendingPathComponent("opencode")
            try ("#!/bin/sh\n" + script + "\n").write(to: executable, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        let rc = "export PATH=\(CommandRestore.shellQuotedLine([directory.path]))\n" + startup + "\n"
        let profile = "export AGTERM_TEST_LOGIN_PROFILE=loaded\n"
        try profile.write(to: directory.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        try rc.write(to: directory.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        try (profile + rc).write(to: directory.appendingPathComponent(".bash_profile"), atomically: true, encoding: .utf8)
        let fishConfig = directory.appendingPathComponent("fish")
        try fm.createDirectory(at: fishConfig, withIntermediateDirectories: true)
        try ("set -gx PATH \(CommandRestore.shellQuotedLine([directory.path]))\n" + startup + "\n")
            .write(to: fishConfig.appendingPathComponent("config.fish"), atomically: true, encoding: .utf8)
        return await OpenCodeEnvironmentProbe.detect(environment: [
            "PATH": inheritedBin.path, "HOME": directory.path, "ZDOTDIR": directory.path,
            "XDG_CONFIG_HOME": directory.path, "SHELL": shell, "AGTERM_SESSION_ID": "not-a-live-session",
        ], timeout: timeout)
    }
}
