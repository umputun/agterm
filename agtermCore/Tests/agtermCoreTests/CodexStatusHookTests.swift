import Foundation
import Testing

// Exercises only the Codex hook shipped by the Help-menu installer. Codex-specific lifecycle and
// terminal-output knowledge belongs to this installed hook, not to agterm's runtime status engine.
struct CodexStatusHookTests {
    private static var hook: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("agterm/Resources/agent-status/agterm-codex-status.sh")
            .path
    }

    private func run(_ action: String, screen: String = "", screens: [String] = [], worker: Bool = false,
                     supersedeTokenOnRead: Bool = false) throws -> (statusCalls: [String], controlCalls: [String], exit: Int32) {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agterm-codex-hook-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let statuses = dir.appendingPathComponent("statuses")
        let controls = dir.appendingPathComponent("controls")
        let counter = dir.appendingPathComponent("read-count")
        let tokenFile = dir.appendingPathComponent("watch-token")
        let statusWrapper = dir.appendingPathComponent("status-wrapper")
        let agtermctl = dir.appendingPathComponent("agtermctl")
        // the mock serves one frame per `session text` call (screen.0, screen.1, …), clamping to the
        // last frame once exhausted, so a worker run can be driven through a sequence of screens.
        let frames = screens.isEmpty ? [screen] : screens
        for (i, frame) in frames.enumerated() {
            try frame.write(to: dir.appendingPathComponent("screen.\(i)"), atomically: true, encoding: .utf8)
        }
        try "token\n".write(to: tokenFile, atomically: true, encoding: .utf8)
        try "#!/bin/bash\nprintf '%s\\n' \"$*\" >> '\(statuses.path)'\n".write(to: statusWrapper, atomically: true, encoding: .utf8)
        try """
        #!/bin/bash
        printf '%s\n' "$*" >> '\(controls.path)'
        if [ "$1" = "session" ] && [ "$2" = "text" ]; then
          n=$(cat '\(counter.path)' 2>/dev/null || echo 0)
          if [ -n "${SUPERSEDE_ON_READ:-}" ] && [ "$n" = 0 ]; then echo superseded > '\(tokenFile.path)'; fi
          f='\(dir.path)/screen.'"$n"
          [ -f "$f" ] || f='\(dir.path)/screen.\(frames.count - 1)'
          cat "$f"
          echo "$(( n + 1 ))" > '\(counter.path)'
        fi
        """.write(to: agtermctl, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: statusWrapper.path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agtermctl.path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = worker ? [Self.hook, "__watch-blocked", "token", tokenFile.path] : [Self.hook, action]
        var environment = [
            "AGTERMCTL": agtermctl.path,
            "AGTERM_STATUS_WRAPPER": statusWrapper.path,
            "AGTERM_SESSION_ID": "sid",
            "AGTERM_SOCKET": "/tmp/agterm.sock",
            "AGTERM_PANE": "right",
            "AGTERM_CODEX_WATCH_FILE": tokenFile.path,
            "AGTERM_CODEX_WATCH_MAX_CHECKS": worker ? String(frames.count) : "0",
            "AGTERM_CODEX_WATCH_INTERVAL": "0",
            "PATH": "/usr/bin:/bin",
        ]
        if supersedeTokenOnRead { environment["SUPERSEDE_ON_READ"] = "1" }
        proc.environment = environment
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()

        func lines(_ url: URL) -> [String] {
            ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }
        return (lines(statuses), lines(controls), proc.terminationStatus)
    }

    @Test func lifecycleActionsDriveOnlyTheGenericStatusWrapper() throws {
        #expect(try run("session-start").statusCalls == ["idle"])
        #expect(try run("user-prompt-submit").statusCalls == ["active --blink"])
        #expect(try run("pre-tool-use").statusCalls == ["active --blink"])
        #expect(try run("post-tool-use").statusCalls == ["active --blink"])
        #expect(try run("stop").statusCalls == ["completed --auto-reset"])
    }

    @Test func permissionRequestDoesNotImmediatelySetBlocked() throws {
        let result = try run("permission-request")
        #expect(result.statusCalls.isEmpty)
        #expect(result.exit == 0)
    }

    @Test func hookIsSilentNoOpOutsideAgterm() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [Self.hook, "permission-request"]
        proc.environment = ["PATH": "/usr/bin:/bin"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        #expect(proc.terminationStatus == 0)
        #expect(out.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }

    @Test func watcherIgnoresAutoReviewProgress() throws {
        let result = try run("", screen: "Reviewing approval request (12s · esc to interrupt)\n", worker: true)
        #expect(result.controlCalls == ["session text --target sid --socket /tmp/agterm.sock --pane right"])
        #expect(result.statusCalls.isEmpty)
    }

    @Test func watcherReportsVisibleApprovalPrompt() throws {
        let result = try run("", screen: "Would you like to run this command?\nPress Enter to confirm or Esc to cancel\n", worker: true)
        #expect(result.statusCalls == ["blocked"])
    }

    @Test func watcherReportsVisibleQuestionDialog() throws {
        let result = try run("", screen: "Which option should I use?\nEnter to submit answer\n", worker: true)
        #expect(result.statusCalls == ["blocked"])
    }

    @Test func watcherReportsVisibleSubmitAllPrompt() throws {
        let result = try run("", screen: "Apply all proposed edits?\nEnter to submit all\n", worker: true)
        #expect(result.statusCalls == ["blocked"])
    }

    @Test func watcherReportsVisibleAllowCommandPrompt() throws {
        let result = try run("", screen: "Run the shell command below?\nAllow command?\n", worker: true)
        #expect(result.statusCalls == ["blocked"])
    }

    @Test func watcherReportsBlockedOncePerAppearanceThenRestoresActive() throws {
        let prompt = "Would you like to run this command?\nPress Enter to confirm or Esc to cancel\n"
        let cleared = "Working (12s · esc to interrupt)\n"
        let result = try run("", screens: [prompt, prompt, cleared], worker: true)
        #expect(result.statusCalls == ["blocked", "active --blink"])
    }

    @Test func watcherReChecksTokenBeforeReportingBlocked() throws {
        let prompt = "Would you like to run this command?\nPress Enter to confirm or Esc to cancel\n"
        let result = try run("", screens: [prompt], worker: true, supersedeTokenOnRead: true)
        #expect(result.statusCalls.isEmpty)
    }
}
