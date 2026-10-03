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
        let version = try await probe(script: "printf '2.0.12\\n'", startup: "trap '' TERM\nwhile :; do :; done", timeout: 0.1)
        XCTAssertNil(version)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testMissingExecutableNeedsManualSelection() async {
        let version = await OpenCodeEnvironmentProbe.detect(environment: [:], executableURL: URL(fileURLWithPath: "/no/such/agterm-probe"))
        XCTAssertNil(version)
    }

    private func probe(script: String?, startup: String = "", shell: String = "/bin/zsh", timeout: TimeInterval = 3) async throws -> AgentHooksInstall.OpenCode.Version? {
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
        ], timeout: timeout)?.version
    }
}
