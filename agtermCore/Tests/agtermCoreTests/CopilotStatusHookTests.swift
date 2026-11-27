import Foundation
import Testing

// Exercises the GitHub Copilot CLI adapter shipped by the Help-menu installer, run under a real process chain that
// ends at `login`, so the owner walk never reaches the agents running the test suite itself.
struct CopilotStatusHookTests {
    private static var hook: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("agterm/Resources/agent-status/agterm-copilot-status.sh")
            .path
    }

    private func run(_ action: String, payload: String = "", chain: [String] = ["login", "copilot"], sessionID: String? = "sid",
                     extraEnv: [String: String] = [:]) throws -> (stdout: String, calls: [String]) {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agterm-copilot-hook-\(UUID().uuidString)")
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
        let errors = Pipe()
        proc.standardInput = input
        proc.standardOutput = output
        proc.standardError = errors
        try input.fileHandleForWriting.write(contentsOf: Data(payload.utf8))
        try input.fileHandleForWriting.close()
        try proc.run()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        proc.waitUntilExit()
        #expect(proc.terminationStatus == 0)
        #expect(stderr.isEmpty, "\(stderr)")

        let recorded = ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        return (stdout, recorded)
    }

    private static func tool(agentID: String? = nil) -> String {
        let agent = agentID.map { #","agentId":"\#($0)""# } ?? ""
        return #"{"sessionId":"s1","timestamp":1,"toolName":"view","toolArgs":{"note":null}\#(agent)}"#
    }

    private static func end(_ reason: String) -> String {
        #"{"sessionId":"s1","timestamp":1,"reason":"\#(reason)"}"#
    }

    @Test func promptPostsActiveAndPrintsNothing() throws {
        let result = try run("work", payload: #"{"sessionId":"s1","timestamp":1,"prompt":"hi"}"#)
        #expect(result.stdout.isEmpty)
        #expect(result.calls == ["active --blink"])
    }

    @Test func subagentToolPostsActiveOnlyWhileIdle() throws {
        let result = try run("work", payload: Self.tool(agentID: "a1"))
        #expect(result.calls == ["active --blink --if-idle"])
    }

    @Test(arguments: [
        #"{"sessionId":"s1","timestamp":1,"prompt":"say \"agentId\": \"x\""}"#,
        #"{"sessionId":"s1","timestamp":1,"toolName":"start_agent","toolArgs":{"agentId":"x"}}"#,
        #"{"sessionId":"s1","timestamp":1,"toolName":"view","toolArgs":{},"agentId":""}"#,
        #"{"sessionId":"s1","timestamp":1,"toolName":"view","toolArgs":{},"agentId":null}"#,
    ])
    func onlyATopLevelAgentIdMarksASubagent(_ payload: String) throws {
        let result = try run("work", payload: payload)
        #expect(result.calls == ["active --blink"])
    }

    @Test func permissionPromptPostsBlocked() throws {
        let payload = #"{"sessionId":"s1","timestamp":1,"hook_event_name":"Notification","notification_type":"permission_prompt"}"#
        let result = try run("ask", payload: payload)
        #expect(result.stdout.isEmpty)
        #expect(result.calls == ["blocked"])
    }

    @Test func mainAgentStopCompletes() throws {
        let result = try run("stop", payload: #"{"sessionId":"s1","timestamp":1,"stopReason":"end_turn"}"#)
        #expect(result.stdout.isEmpty)
        #expect(result.calls == ["completed --auto-reset"])
    }

    @Test(arguments: ["stop", "end"])
    func subagentStopAndEndAreIgnored(_ action: String) throws {
        let payload = #"{"sessionId":"a1","timestamp":1,"stopReason":"end_turn","reason":"user_exit","agentId":"a1"}"#
        let result = try run(action, payload: payload)
        #expect(result.calls.isEmpty)
    }

    @Test func completedRunKeepsItsStatusAtSessionEnd() throws {
        let result = try run("end", payload: Self.end("complete"))
        #expect(result.calls.isEmpty)
    }

    @Test(arguments: ["user_exit", "abort", "error", "timeout"])
    func otherSessionEndPostsIdle(_ reason: String) throws {
        let result = try run("end", payload: Self.end(reason))
        #expect(result.calls == ["idle"])
    }

    @Test func linuxReadsThePayloadWithJq() throws {
        // a GNUstep plutil at /usr/bin rejects -extract raw, and the adapter took it over an installed jq
        let fm = FileManager.default
        let bin = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agterm-jq-\(UUID().uuidString)")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: bin) }
        try "#!/bin/sh\ncat >/dev/null\necho a1\n".writeExecutable(to: bin.appendingPathComponent("jq"))

        let result = try run("work", payload: Self.tool(), extraEnv: ["OSTYPE": "linux-gnu", "PATH": "\(bin.path):/usr/bin:/bin"])

        #expect(result.calls == ["active --blink --if-idle"])
    }

    @Test func withoutAParserSubagentsAreNotToldApart() throws {
        let fm = FileManager.default
        let bin = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agterm-nojq-\(UUID().uuidString)")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: bin) }
        for tool in ["ps", "dirname"] {
            try fm.createSymbolicLink(at: bin.appendingPathComponent(tool), withDestinationURL: URL(fileURLWithPath: "/usr/bin/\(tool)"))
        }
        try fm.createSymbolicLink(at: bin.appendingPathComponent("bash"), withDestinationURL: URL(fileURLWithPath: "/bin/bash"))

        let result = try run("work", payload: Self.tool(agentID: "a1"), extraEnv: ["OSTYPE": "linux-gnu", "PATH": bin.path])

        #expect(result.calls == ["active --blink"])
    }

    @Test func outsideAgtermPostsNothing() throws {
        let result = try run("work", sessionID: nil)
        #expect(result.stdout.isEmpty)
        #expect(result.calls.isEmpty)
    }

    @Test func copilotWorkerSpawnedByAnotherAgentPostsNothing() throws {
        let result = try run("stop", chain: ["login", "claude", "bash", "copilot"])
        #expect(result.calls.isEmpty)
    }

    @Test func unknownActionPostsNothing() throws {
        let result = try run("session-start")
        #expect(result.calls.isEmpty)
    }
}
