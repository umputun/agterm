import Foundation
import XCTest
import agtermCore
@testable import agterm

@MainActor
final class OpenCodeVersionProbeTests: XCTestCase {
    func testProbeUsesVersionArgumentAndInheritedPath() async throws {
        let version = try await probe(script: """
        [ "$#" -eq 1 ] && [ "$1" = --version ] || exit 2
        [ -z "${AGTERM_SESSION_ID:-}" ] || exit 3
        printf 'opencode v2.0.12\n'
        """)
        XCTAssertEqual(version, .v2)
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

    func testMissingExecutableNeedsManualSelection() async {
        let version = await OpenCodeVersionProbe.detect(environment: [:], executableURL: URL(fileURLWithPath: "/no/such/agterm-probe"))
        XCTAssertNil(version)
    }

    private func probe(script: String, timeout: TimeInterval = 3) async throws -> AgentHooksInstall.OpenCode.Version? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("opencode")
        try ("#!/bin/sh\n" + script + "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return await OpenCodeVersionProbe.detect(environment: ["PATH": directory.path, "AGTERM_SESSION_ID": "not-a-live-session"], timeout: timeout)
    }
}
