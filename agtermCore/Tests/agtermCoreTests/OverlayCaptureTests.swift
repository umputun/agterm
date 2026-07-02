import Foundation
import Testing
@testable import agtermCore

struct OverlayCaptureTests {
    @Test func constantsMatchOverlayContract() {
        #expect(OverlayCapture.cmdEnvKey == "AGTERM_OVL_CMD")
        #expect(OverlayCapture.codeEnvKey == "AGTERM_OVL_CODE")
        #expect(OverlayCapture.shellLine == #"( eval "$AGTERM_OVL_CMD" ); echo $? > "$AGTERM_OVL_CODE""#)
    }

    @Test func shellLineRunsCommandAndWritesStatus() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-overlay-capture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", OverlayCapture.shellLine]
        var env = ProcessInfo.processInfo.environment
        env[OverlayCapture.cmdEnvKey] = "exit 7"
        env[OverlayCapture.codeEnvKey] = tmp.path
        proc.environment = env

        try proc.run()
        proc.waitUntilExit()

        #expect(proc.terminationStatus == 0)
        let text = try String(contentsOf: tmp, encoding: .utf8)
        #expect(OverlayCapture.parseExitCode(text) == 7)
    }

    @Test func parseExitCodeTrimsWhitespaceAndRejectsInvalidText() {
        #expect(OverlayCapture.parseExitCode("3\n") == 3)
        #expect(OverlayCapture.parseExitCode("  0  ") == 0)
        #expect(OverlayCapture.parseExitCode("") == nil)
        #expect(OverlayCapture.parseExitCode("not a code") == nil)
    }
}
