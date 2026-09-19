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

    static let originSession = UUID()
    static let sessionEnvironment = SurfaceEnvironment.session(sessionID: originSession, windowID: UUID(),
                                                               workspaceID: UUID(), socketPath: "/tmp/origin.sock",
                                                               programVersion: "9.9.9")

    @Test func theLaunchContextCarriesTheSessionEnvironmentAndTheCommand() {
        let context = OverlayLaunchContext(command: "revdiff", cwd: "/work", sessionEnvironment: Self.sessionEnvironment)

        var expected = Self.sessionEnvironment
        expected[OverlayCapture.cmdEnvKey] = "revdiff"
        #expect(context.environment == expected)
        #expect(context.cwd == "/work")
    }

    @Test func aLocalLaunchDiffersFromTheContextOnlyByTheCodeAndHudFiles() {
        let context = OverlayLaunchContext(command: "revdiff", cwd: "/work", sessionEnvironment: Self.sessionEnvironment)

        let local = context.localEnvironment(codeFile: "/tmp/x.code", hudFile: "/tmp/x.hud")

        #expect(Set(local.keys).subtracting(context.environment.keys) == [OverlayCapture.codeEnvKey, HudLayout.fileEnvKey])
        #expect(local.filter { context.environment.keys.contains($0.key) } == context.environment)
        #expect(context.localEnvironment(codeFile: "/tmp/x.code", hudFile: nil)[HudLayout.fileEnvKey] == nil)
    }

    @Test func theContextNamesOnlyTheOriginsSessionAndSocket() {
        let context = OverlayLaunchContext(command: "revdiff", cwd: "/work", sessionEnvironment: Self.sessionEnvironment)

        #expect(context.environment["AGTERM_SESSION_ID"] == Self.originSession.uuidString)
        #expect(context.environment["AGTERM_SOCKET"] == "/tmp/origin.sock")
        #expect(context.environment["TERM"] == nil)
        #expect(context.environment[OverlayCapture.codeEnvKey] == nil)
    }

    @Test func theContextSurvivesTheWire() throws {
        let context = OverlayLaunchContext(command: "revdiff --x", cwd: "/work", sessionEnvironment: Self.sessionEnvironment)

        let decoded = try JSONDecoder().decode(OverlayLaunchContext.self, from: try JSONEncoder().encode(context))

        #expect(decoded == context)
    }

    @MainActor
    @Test func anExplicitCwdWinsAndOtherwiseTheSessionsIsUsed() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))

        #expect(OverlayLaunchContext.cwd(explicit: "/var", session: session, homeDirectory: "/home") == "/var")
        #expect(OverlayLaunchContext.cwd(explicit: nil, session: session, homeDirectory: "/home") == "/tmp")
    }
}
