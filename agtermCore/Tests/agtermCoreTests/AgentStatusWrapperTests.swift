import Foundation
import Testing
@testable import agtermCore

// Tests the shipped hook wrapper `agterm/Resources/agent-status/agterm-agent-status.sh` by running it
// with a stub `agtermctl` that records its argv. It reaches the app target's resource on purpose: the
// wrapper is the shell half of the agtermCore agent-status model.
struct AgentStatusWrapperTests {
    // the shipped wrapper, located relative to this test source file (fixed repo layout).
    private static var wrapper: String {
        URL(fileURLWithPath: #filePath)      // …/agtermCore/Tests/agtermCoreTests/AgentStatusWrapperTests.swift
            .deletingLastPathComponent()     // agtermCoreTests
            .deletingLastPathComponent()     // Tests
            .deletingLastPathComponent()     // agtermCore
            .deletingLastPathComponent()     // repo root
            .appendingPathComponent("agterm/Resources/agent-status/agterm-agent-status.sh")
            .path
    }

    // run the wrapper with a stub agtermctl. the stub records each received arg on its own line, prints
    // `stubStdout`, and exits `stubExit`. returns the recorded argv, the wrapper's own stdout, and its exit.
    private func runWrapper(_ args: [String], env: [String: String],
                            stubStdout: String = "ok", stubExit: Int = 0) throws -> (argv: [String], stdout: String, exit: Int32) {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agterm-wrapper-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let record = dir.appendingPathComponent("argv")
        let stub = dir.appendingPathComponent("agtermctl")
        let stubScript = """
        #!/bin/bash
        printf '%s\\n' "$@" > '\(record.path)'
        printf '%s' '\(stubStdout)'
        exit \(stubExit)
        """
        try stubScript.write(to: stub, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [Self.wrapper] + args
        var fullEnv = env
        fullEnv["AGTERMCTL"] = stub.path
        proc.environment = fullEnv
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()

        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let argv = (try? String(contentsOf: record, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty } ?? []
        return (argv, stdout, proc.terminationStatus)
    }

    @Test func socketComesAfterTheSubcommand() throws {
        let r = try runWrapper(["active"], env: ["AGTERM_SESSION_ID": "sid", "AGTERM_SOCKET": "/tmp/s.sock"])
        // --socket is a subcommand option, so it MUST follow `session status <state> --target <id>`
        #expect(r.argv == ["session", "status", "active", "--target", "sid", "--socket", "/tmp/s.sock"])
        #expect(r.exit == 0)
    }

    @Test func extraArgsForwardedAfterTargetAndSocket() throws {
        let r = try runWrapper(["blocked", "--blink"], env: ["AGTERM_SESSION_ID": "sid", "AGTERM_SOCKET": "/tmp/s.sock"])
        #expect(r.argv == ["session", "status", "blocked", "--target", "sid", "--socket", "/tmp/s.sock", "--blink"])
    }

    @Test func noSocketFlagWhenSocketUnset() throws {
        let r = try runWrapper(["active"], env: ["AGTERM_SESSION_ID": "sid"])
        #expect(r.argv == ["session", "status", "active", "--target", "sid"])
        #expect(!r.argv.contains("--socket"))
    }

    @Test func noOpOutsideAgterm() throws {
        let r = try runWrapper(["active"], env: [:])
        #expect(r.argv.isEmpty)
        #expect(r.exit == 0)
    }

    @Test func suppressesStdoutSoItCannotPolluteThePrompt() throws {
        // UserPromptSubmit injects a hook's stdout, so the wrapper must swallow agtermctl's "ok"
        let r = try runWrapper(["active"], env: ["AGTERM_SESSION_ID": "sid", "AGTERM_SOCKET": "/tmp/s.sock"], stubStdout: "ok")
        #expect(r.stdout.isEmpty)
    }

    @Test func alwaysExitsZeroEvenWhenAgtermctlFails() throws {
        let r = try runWrapper(["active"], env: ["AGTERM_SESSION_ID": "sid", "AGTERM_SOCKET": "/tmp/s.sock"], stubExit: 64)
        #expect(r.exit == 0)
    }

    @Test func paneForwardedWhenAgtermPaneSet() throws {
        // the app injects AGTERM_PANE per surface
        let r = try runWrapper(["blocked"], env: ["AGTERM_SESSION_ID": "sid", "AGTERM_SOCKET": "/tmp/s.sock", "AGTERM_PANE": "right"])
        #expect(r.argv == ["session", "status", "blocked", "--target", "sid", "--socket", "/tmp/s.sock", "--pane", "right"])
        #expect(r.exit == 0)
    }

    @Test func paneForwardedWithoutSocket() throws {
        let r = try runWrapper(["blocked"], env: ["AGTERM_SESSION_ID": "sid", "AGTERM_PANE": "scratch"])
        #expect(r.argv == ["session", "status", "blocked", "--target", "sid", "--pane", "scratch"])
    }

    @Test func paneSplicedBeforeExtraArgs() throws {
        let r = try runWrapper(["blocked", "--blink"], env: ["AGTERM_SESSION_ID": "sid", "AGTERM_SOCKET": "/tmp/s.sock", "AGTERM_PANE": "right"])
        #expect(r.argv == ["session", "status", "blocked", "--target", "sid", "--socket", "/tmp/s.sock", "--pane", "right", "--blink"])
    }

    @Test func paneOmittedWhenAgtermPaneUnset() throws {
        let r = try runWrapper(["active"], env: ["AGTERM_SESSION_ID": "sid", "AGTERM_SOCKET": "/tmp/s.sock"])
        #expect(!r.argv.contains("--pane"))
    }

    @Test func paneNoOpWithoutSessionID() throws {
        let r = try runWrapper(["active"], env: ["AGTERM_PANE": "right"])
        #expect(r.argv.isEmpty)
        #expect(r.exit == 0)
    }

    @Test func paneIDForwardedWithRole() throws {
        // AGTERM_PANE_ID is a stable per-surface token beside AGTERM_PANE's role, so the app can
        // resolve the live slot even when the baked role went stale (#199).
        let r = try runWrapper(["blocked"], env: ["AGTERM_SESSION_ID": "sid", "AGTERM_SOCKET": "/tmp/s.sock",
                                                  "AGTERM_PANE": "right", "AGTERM_PANE_ID": "agent-tok"])
        #expect(r.argv == ["session", "status", "blocked", "--target", "sid", "--socket", "/tmp/s.sock",
                           "--pane", "right", "--pane-id", "agent-tok"])
    }

    @Test func paneIDSplicedBeforeExtraArgs() throws {
        let r = try runWrapper(["blocked", "--blink"], env: ["AGTERM_SESSION_ID": "sid",
                                                             "AGTERM_PANE": "right", "AGTERM_PANE_ID": "agent-tok"])
        #expect(r.argv == ["session", "status", "blocked", "--target", "sid",
                           "--pane", "right", "--pane-id", "agent-tok", "--blink"])
    }

    @Test func paneIDForwardedWithoutRole() throws {
        let r = try runWrapper(["blocked"], env: ["AGTERM_SESSION_ID": "sid", "AGTERM_PANE_ID": "agent-tok"])
        #expect(r.argv == ["session", "status", "blocked", "--target", "sid", "--pane-id", "agent-tok"])
    }

    @Test func paneIDOmittedWhenUnset() throws {
        let r = try runWrapper(["active"], env: ["AGTERM_SESSION_ID": "sid", "AGTERM_PANE": "right"])
        #expect(!r.argv.contains("--pane-id"))
    }

    // run the wrapper AS THE INSTALLER WRITES IT: `AgentHooksInstall.bakeAgtermctlPath` applied to the shipped
    // script, a stub `agtermctl` reachable on PATH, and no AGTERMCTL in the environment unless `override` asks
    // for one. Every stub records its own path first, so the caller can tell WHICH one ran. `bakedToolExists`
    // false is the bundle that moved away after the install.
    private func runBaked(bakedToolExists: Bool, override: Bool = false) throws -> [String] {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agterm-baked-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let record = dir.appendingPathComponent("argv")
        let onPath = dir.appendingPathComponent("bin/agtermctl")
        let baked = dir.appendingPathComponent("baked/agtermctl")
        let explicit = dir.appendingPathComponent("explicit/agtermctl")
        for stub in [onPath, baked, explicit] {
            try fm.createDirectory(at: stub.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "#!/bin/bash\nprintf '%s\\n' \"$0\" \"$@\" > '\(record.path)'\n"
                .write(to: stub, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        }
        if !bakedToolExists { try fm.removeItem(at: baked) }

        let script = dir.appendingPathComponent(AgentHooksInstall.wrapperName)
        let shipped = try String(contentsOfFile: Self.wrapper, encoding: .utf8)
        try AgentHooksInstall.bakeAgtermctlPath(into: shipped, toolPath: baked.path)
            .write(to: script, atomically: true, encoding: .utf8)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [script.path, "active"]
        var env = ["AGTERM_SESSION_ID": "sid",
                   "PATH": onPath.deletingLastPathComponent().path + ":/usr/bin:/bin"]
        if override { env["AGTERMCTL"] = explicit.path }
        proc.environment = env
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()

        return (try? String(contentsOf: record, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
    }

    @Test func bakedWrapperCallsTheBundledBinary() throws {
        let argv = try runBaked(bakedToolExists: true)
        #expect(argv.first?.hasSuffix("/baked/agtermctl") == true)
        #expect(Array(argv.dropFirst()) == ["session", "status", "active", "--target", "sid"])
    }

    @Test func bakedWrapperFallsBackToPathWhenTheBundleMoved() throws {
        // installing the hooks from the mounted DMG bakes a /Volumes path that dies on eject, and the wrapper
        // suppresses the failure and exits 0, so the status simply stops appearing with no error (#472)
        let argv = try runBaked(bakedToolExists: false)
        #expect(argv.first?.hasSuffix("/bin/agtermctl") == true)
        #expect(Array(argv.dropFirst()) == ["session", "status", "active", "--target", "sid"])
    }

    @Test func explicitOverrideStillBeatsTheBakedPath() throws {
        let argv = try runBaked(bakedToolExists: true, override: true)
        #expect(argv.first?.hasSuffix("/explicit/agtermctl") == true)
    }
}
