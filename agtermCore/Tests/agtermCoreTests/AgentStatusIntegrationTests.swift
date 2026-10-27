import Foundation
import Testing

// Runs the shipped bash/zsh shell integration `agterm/Resources/agent-status/shell/integration.sh` under
// bash, with a stub agent-status binary that records its argv.
struct AgentStatusIntegrationTests {
    private static var integration: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("agterm/Resources/agent-status/shell/integration.sh")
            .path
    }

    // sources the integration into a bash whose PROMPT_COMMAND already holds a user entry, leaves the
    // user's last command with `status`, then evaluates PROMPT_COMMAND as bash does before a prompt.
    // returns what the user entry saw and the stub's recorded calls.
    private func runPrompt(agentRan: Bool, status: Int32) throws -> (seen: String, calls: [String]) {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agterm-integration-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let calls = dir.appendingPathComponent("calls")
        let stub = dir.appendingPathComponent("agent-status")
        try "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '\(calls.path)'\n".write(to: stub, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let script = """
        PROMPT_COMMAND='echo "status=$? active=${_ags_active-unset}"'
        source '\(Self.integration)'
        \(agentRan ? "_ags_active=1" : ":")
        (exit \(status))
        eval "$PROMPT_COMMAND"
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["--noprofile", "--norc", "-c", script]
        proc.environment = ["PATH": "/usr/bin:/bin", "AGTERM_SESSION_ID": "sid", "AGTERM_AGENT_BIN": stub.path]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()

        let seen = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let recorded = (try? String(contentsOf: calls, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        return (seen.trimmingCharacters(in: .whitespacesAndNewlines), recorded)
    }

    @Test(arguments: [false, true], [0, 3] as [Int32])
    func precmdKeepsTheLastCommandStatusForLaterPromptCommandEntries(agentRan: Bool, status: Int32) throws {
        let result = try runPrompt(agentRan: agentRan, status: status)
        #expect(result.seen == "status=\(status) active=unset")
        #expect(result.calls == (agentRan ? ["idle"] : []))
    }
}
