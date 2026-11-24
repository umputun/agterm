import Foundation
import Testing

// Exercises the agy adapter shipped by the Help-menu installer, run under a real process chain that ends at
// `login`, so the owner walk never reaches the agents running the test suite itself.
struct AgyStatusHookTests {
    private static var hook: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("agterm/Resources/agent-status/agterm-agy-status.sh")
            .path
    }

    private func run(_ action: String, payload: String = "", chain: [String] = ["login", "agy"],
                     sessionID: String? = "sid", extraEnv: [String: String] = [:]) throws -> (stdout: String, calls: [String]) {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agterm-agy-hook-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let calls = dir.appendingPathComponent("calls")
        let wrapper = dir.appendingPathComponent("status-wrapper")
        let spawner = dir.appendingPathComponent("spawn-chain.sh")
        try "#!/bin/bash\nprintf '%s\\n' \"$*\" >> '\(calls.path)'\necho noise\n".writeExecutable(to: wrapper)
        try """
        #!/bin/bash
        levels=()
        while [ "$1" != "--" ]; do levels+=("$1"); shift; done
        shift
        if [ "${#levels[@]}" -eq 0 ]; then
          "$@"
          exit $?
        fi
        ( exec -a "${levels[0]}" /bin/bash "$0" "${levels[@]:1}" -- "$@" )
        exit $?
        """.writeExecutable(to: spawner)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [spawner.path] + chain + ["--", Self.hook, action]
        var environment = ["AGTERM_STATUS_WRAPPER": wrapper.path, "PATH": "/usr/bin:/bin"]
        environment["AGTERM_SESSION_ID"] = sessionID
        environment.merge(extraEnv) { _, new in new }
        proc.environment = environment
        let input = Pipe()
        let output = Pipe()
        proc.standardInput = input
        proc.standardOutput = output
        proc.standardError = Pipe()
        try input.fileHandleForWriting.write(contentsOf: Data(payload.utf8))
        try input.fileHandleForWriting.close()
        try proc.run()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        proc.waitUntilExit()

        let recorded = ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        return (stdout, recorded)
    }

    private static func stop(fullyIdle: Bool, lastUserInput: String = "done") -> String {
        #"{"hookEventName":"Stop","lastUserInput":"\#(lastUserInput)","terminationReason":"NO_TOOL_CALL","fullyIdle":\#(fullyIdle)}"#
    }

    @Test func invocationPostsActive() throws {
        let result = try run("invocation", payload: #"{"hookEventName":"PreInvocation"}"#)
        #expect(result.stdout == "{}\n")
        #expect(result.calls == ["active --blink"])
    }

    @Test(arguments: ["ask_question", "ask_permission"])
    func askAllowsTheToolAndPostsBlocked(_ tool: String) throws {
        let result = try run("ask", payload: #"{"hookEventName":"PreToolUse","toolCall":{"name":"\#(tool)"}}"#)
        #expect(result.stdout == "{\"decision\":\"allow\"}\n")
        #expect(result.calls == ["blocked"])
    }

    @Test func idleStopCompletes() throws {
        let result = try run("stop", payload: Self.stop(fullyIdle: true))
        #expect(result.stdout == "{\"decision\":\"stop\"}\n")
        #expect(result.calls == ["completed --auto-reset"])
    }

    @Test func stopWithBackgroundWorkStaysActive() throws {
        let result = try run("stop", payload: Self.stop(fullyIdle: false))
        #expect(result.stdout == "{\"decision\":\"stop\"}\n")
        #expect(result.calls == ["active --blink"])
    }

    @Test func stopWithBackgroundWorkCompletesWhenBackgroundIsIgnored() throws {
        let result = try run("stop", payload: Self.stop(fullyIdle: false), extraEnv: ["AGTERM_AGY_IGNORE_BACKGROUND": "1"])
        #expect(result.calls == ["completed --auto-reset"])
    }

    @Test(arguments: ["", "0", "yes"])
    func stopWithBackgroundWorkStaysActiveUnlessIgnoreIsOne(_ value: String) throws {
        let result = try run("stop", payload: Self.stop(fullyIdle: false), extraEnv: ["AGTERM_AGY_IGNORE_BACKGROUND": value])
        #expect(result.calls == ["active --blink"])
    }

    @Test func fullyIdleTypedByTheUserIsNotRead() throws {
        let result = try run("stop", payload: Self.stop(fullyIdle: true, lastUserInput: #"say \"fullyIdle\": false"#))
        #expect(result.calls == ["completed --auto-reset"])
    }

    @Test func stopWithoutPayloadCompletes() throws {
        let result = try run("stop")
        #expect(result.stdout == "{\"decision\":\"stop\"}\n")
        #expect(result.calls == ["completed --auto-reset"])
    }

    @Test func outsideAgtermRepliesWithoutPosting() throws {
        let result = try run("ask", sessionID: nil)
        #expect(result.stdout == "{\"decision\":\"allow\"}\n")
        #expect(result.calls.isEmpty)
    }

    @Test func agyWorkerSpawnedByAnotherAgentRepliesWithoutPosting() throws {
        let result = try run("stop", payload: Self.stop(fullyIdle: true), chain: ["login", "claude", "bash", "agy"])
        #expect(result.stdout == "{\"decision\":\"stop\"}\n")
        #expect(result.calls.isEmpty)
    }

    @Test func unknownActionRepliesWithoutPosting() throws {
        let result = try run("session-start")
        #expect(result.stdout == "{}\n")
        #expect(result.calls.isEmpty)
    }
}
