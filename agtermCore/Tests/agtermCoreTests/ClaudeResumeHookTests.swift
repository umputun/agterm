import Foundation
import Testing

// Runs the shipped resume script against a recording stand-in for agtermctl.
struct ClaudeResumeHookTests {
    private static let resume = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("agterm/Resources/agent-status/agterm-claude-resume.sh").path

    private static let sid = "0b6f1c2e-1111-4a2b-9c3d-123456789abc"

    private func run(payload: String, env extra: [String: String] = [:]) throws -> [String] {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agterm-resume-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let calls = dir.appendingPathComponent("calls")
        let fake = dir.appendingPathComponent("agtermctl")
        try "#!/bin/bash\nprintf '%s\\n' \"$*\" >> '\(calls.path)'\n".write(to: fake, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [Self.resume]
        proc.environment = ["AGTERMCTL": fake.path, "AGTERM_SESSION_ID": "S1", "AGTERM_PANE": "left",
                            "AGTERM_PANE_ID": "P1", "AGTERM_SOCKET": "/tmp/a.sock", "PATH": "/usr/bin:/bin"]
            .merging(extra) { _, new in new }
        let input = Pipe()
        proc.standardInput = input
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        input.fileHandleForWriting.write(Data(payload.utf8))
        try input.fileHandleForWriting.close()
        proc.waitUntilExit()
        #expect(proc.terminationStatus == 0)
        return ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    @Test func pinsTheLiveConversationOnThePane() throws {
        let calls = try run(payload: #"{"session_id":"\#(Self.sid)","hook_event_name":"SessionEnd","reason":"prompt_input_exit"}"#)
        #expect(calls == ["session restore claude --resume \(Self.sid) --target S1 --pane left --pane-id P1 --socket /tmp/a.sock"])
    }

    @Test func refusesAnIdThatIsNotAUUID() throws {
        #expect(try run(payload: #"{"session_id":"x; rm -rf ~"}"#).isEmpty)
        #expect(try run(payload: "not json").isEmpty)
    }

    @Test func staysOffOutsideAgtermOrWhenOptedOut() throws {
        let payload = #"{"session_id":"\#(Self.sid)"}"#
        #expect(try run(payload: payload, env: ["AGTERM_CLAUDE_RESUME": "0"]).isEmpty)
        #expect(try run(payload: payload, env: ["AGTERM_SESSION_ID": ""]).isEmpty)
    }
}
