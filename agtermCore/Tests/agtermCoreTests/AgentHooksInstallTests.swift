import Foundation
import Testing
@testable import agtermCore

struct AgentHooksInstallTests {
    private let scriptDir = "/Users/me/.config/agterm/agent-status"

    // decode the merged JSON back to a dictionary for structural assertions
    private func object(_ json: String) -> [String: Any] {
        let data = json.data(using: .utf8)!
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func events(_ json: String) -> [String: [[String: Any]]] {
        let hooks = object(json)["hooks"] as? [String: Any] ?? [:]
        var out: [String: [[String: Any]]] = [:]
        for (event, value) in hooks {
            out[event] = value as? [[String: Any]] ?? []
        }
        return out
    }

    private func command(_ entry: [String: Any]) -> String? {
        (entry["hooks"] as? [[String: Any]])?.first?["command"] as? String
    }

    @Test func mergeWhenAbsentAddsAllFourHooks() throws {
        let result = try AgentHooksInstall.mergeClaudeSettings(existing: nil, scriptDir: scriptDir)
        #expect(result.changed)
        let evts = events(result.json)
        #expect(evts["UserPromptSubmit"]?.count == 1)
        #expect(evts["PostToolUse"]?.count == 1)
        #expect(evts["Stop"]?.count == 1)
        #expect(evts["Notification"]?.count == 1)
        #expect(command(evts["UserPromptSubmit"]![0])?.hasSuffix("agent-status.sh' active --blink") == true)
        // PostToolUse re-asserts active after every tool, clearing a lingering blocked on resume
        #expect(command(evts["PostToolUse"]![0])?.hasSuffix("agent-status.sh' active --blink") == true)
        // only the Stop hook passes --auto-reset (clear-on-visit); active/blocked stay keep-state
        #expect(command(evts["Stop"]![0])?.hasSuffix("agent-status.sh' completed --auto-reset") == true)
        #expect(command(evts["Notification"]![0])?.hasSuffix("agent-status.sh' blocked") == true)
        #expect(command(evts["UserPromptSubmit"]![0])?.contains("--auto-reset") == false)
        #expect(command(evts["Notification"]![0])?.contains("--auto-reset") == false)
        #expect(evts["Notification"]![0]["matcher"] as? String == "permission_prompt")
        // the unmatched events carry no matcher key
        #expect(evts["UserPromptSubmit"]![0]["matcher"] == nil)
        #expect(evts["PostToolUse"]![0]["matcher"] == nil)
    }

    @Test func mergeWhenPresentIsNoOp() throws {
        let first = try AgentHooksInstall.mergeClaudeSettings(existing: nil, scriptDir: scriptDir)
        let second = try AgentHooksInstall.mergeClaudeSettings(existing: first.json, scriptDir: scriptDir)
        #expect(!second.changed)
        #expect(second.json == first.json)
    }

    @Test func mergePreservesUnrelatedHooksAndKeys() throws {
        let existing = """
        {
          "model": "opus",
          "hooks": {
            "UserPromptSubmit": [
              {"hooks": [{"type": "command", "command": "/usr/bin/other-hook.sh"}]}
            ],
            "PreToolUse": [
              {"matcher": "Bash", "hooks": [{"type": "command", "command": "/usr/bin/guard.sh"}]}
            ]
          }
        }
        """
        let result = try AgentHooksInstall.mergeClaudeSettings(existing: existing, scriptDir: scriptDir)
        #expect(result.changed)
        let root = object(result.json)
        #expect(root["model"] as? String == "opus") // unrelated top-level key preserved
        let evts = events(result.json)
        // the pre-existing PreToolUse hook is untouched
        #expect(evts["PreToolUse"]?.count == 1)
        #expect(command(evts["PreToolUse"]![0]) == "/usr/bin/guard.sh")
        // UserPromptSubmit keeps the other hook AND gains the agterm one
        #expect(evts["UserPromptSubmit"]?.count == 2)
        let commands = evts["UserPromptSubmit"]!.compactMap { command($0) }
        #expect(commands.contains("/usr/bin/other-hook.sh"))
        #expect(commands.contains { $0.hasSuffix("agent-status.sh' active --blink") })
        // PostToolUse + Stop + Notification are still added fresh
        #expect(evts["PostToolUse"]?.count == 1)
        #expect(evts["Stop"]?.count == 1)
        #expect(evts["Notification"]?.count == 1)
    }

    @Test func mergeRemergePreservesUnrelatedAndStaysNoOp() throws {
        let existing = """
        {"hooks": {"UserPromptSubmit": [{"hooks": [{"type": "command", "command": "/usr/bin/other.sh"}]}]}}
        """
        let first = try AgentHooksInstall.mergeClaudeSettings(existing: existing, scriptDir: scriptDir)
        let second = try AgentHooksInstall.mergeClaudeSettings(existing: first.json, scriptDir: scriptDir)
        #expect(!second.changed) // re-running is idempotent even with the foreign hook present
        let commands = events(second.json)["UserPromptSubmit"]!.compactMap { command($0) }
        #expect(commands.contains("/usr/bin/other.sh"))
    }

    @Test func mergeRefusesMalformedExisting() {
        // a non-empty file that isn't a valid JSON object must NOT be overwritten — refuse so the
        // installer leaves the user's hand-maintained settings.json untouched
        #expect(throws: AgentHooksInstall.MergeError.self) {
            try AgentHooksInstall.mergeClaudeSettings(existing: "{ this is not json", scriptDir: scriptDir)
        }
        #expect(throws: AgentHooksInstall.MergeError.self) {
            try AgentHooksInstall.mergeClaudeSettings(existing: "[1, 2, 3]", scriptDir: scriptDir)
        }
    }

    @Test func mergeWhitespaceOnlyStartsFresh() throws {
        // a whitespace-only file has no content to lose, so it starts fresh like an empty file
        let result = try AgentHooksInstall.mergeClaudeSettings(existing: "   \n\t\n", scriptDir: scriptDir)
        #expect(result.changed)
        #expect(events(result.json).count == 4)
    }

    @Test func mergeHandlesEmptyExisting() throws {
        let result = try AgentHooksInstall.mergeClaudeSettings(existing: "", scriptDir: scriptDir)
        #expect(result.changed)
        #expect(events(result.json).count == 4)
    }

    @Test func codexHooksBlockContainsAllSixEvents() {
        let block = AgentHooksInstall.codexHooksBlock(scriptDir: scriptDir)
        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop"] {
            #expect(block.contains("[[hooks.\(event)]]"))
            #expect(block.contains("[[hooks.\(event).hooks]]"))
        }
        #expect(block.contains("type = \"command\""))
    }

    @Test func codexHooksBlockMapsActionsAndBakesWrapperPath() {
        let block = AgentHooksInstall.codexHooksBlock(scriptDir: scriptDir)
        let hook = scriptDir + "/agterm-codex-status.sh"
        // Codex-specific behavior stays in the installed Codex hook. agterm only generates the six
        // lifecycle entries and copies the hook package from its app resources.
        #expect(block.contains("command = \"'\(hook)' session-start\""))
        #expect(block.contains("command = \"'\(hook)' user-prompt-submit\""))
        #expect(block.contains("command = \"'\(hook)' pre-tool-use\""))
        #expect(block.contains("command = \"'\(hook)' post-tool-use\""))
        #expect(block.contains("command = \"'\(hook)' permission-request\""))
        #expect(block.contains("command = \"'\(hook)' stop\""))
        #expect(!block.contains("command = \"'\(AgentHooksInstall.wrapperPath(scriptDir: scriptDir))' blocked\""))
    }

    @Test func codexHooksBlockShellQuotesPathWithSpace() {
        let dir = "/Users/my name/.config/agterm/agent-status"
        let block = AgentHooksInstall.codexHooksBlock(scriptDir: dir)
        // the path keeps its space as ONE shell token via single-quoting inside the TOML value
        #expect(block.contains("command = \"'\(dir)/agterm-codex-status.sh' session-start\""))
    }

    @Test func codexHooksBlockEscapesApostropheInPath() {
        // a username with an apostrophe: shellQuote emits '\'' (a backslash), which the TOML basic
        // string must escape as \\ so the parsed value is a valid /bin/sh command again
        let block = AgentHooksInstall.codexHooksBlock(scriptDir: "/Users/O'Brien/agent-status")
        #expect(block.contains("'/Users/O'\\\\''Brien/agent-status/agterm-codex-status.sh' session-start"))
    }

    // extract the written contents from a `.merged` outcome, failing the test otherwise.
    private func mergedContents(_ outcome: AgentHooksInstall.CodexMergeOutcome) -> String {
        guard case .merged(let contents) = outcome else {
            Issue.record("expected .merged, got \(outcome)")
            return ""
        }
        return contents
    }

    @Test func mergeCodexConfigAppendsHooksToEmpty() {
        let contents = mergedContents(AgentHooksInstall.mergeCodexConfig(existing: "", scriptDir: scriptDir))
        #expect(contents.contains(AgentHooksInstall.rcMarkerBegin))
        #expect(contents.contains(AgentHooksInstall.rcMarkerEnd))
        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop"] {
            #expect(contents.contains("[[hooks.\(event)]]"))
        }
    }

    @Test func mergeCodexConfigIsIdempotent() {
        let first = mergedContents(AgentHooksInstall.mergeCodexConfig(existing: "model = \"gpt-5\"\n", scriptDir: scriptDir))
        // second run sees our marker → .unchanged (checked before the hooks-present probe)
        #expect(AgentHooksInstall.mergeCodexConfig(existing: first, scriptDir: scriptDir) == .unchanged)
        #expect(first.components(separatedBy: AgentHooksInstall.rcMarkerBegin).count - 1 == 1)
    }

    @Test func mergeCodexConfigUpgradesManagedHooksAndPreservesTrustState() {
        let legacyWrapper = AgentHooksInstall.wrapperPath(scriptDir: scriptDir)
        let existing = """
        model = "gpt-5"

        \(AgentHooksInstall.rcMarkerBegin)
        [[hooks.SessionStart]]
        [[hooks.SessionStart.hooks]]
        type = "command"
        command = "'\(legacyWrapper)' idle"

        [[hooks.PermissionRequest]]
        [[hooks.PermissionRequest.hooks]]
        type = "command"
        command = "'\(legacyWrapper)' blocked"

        [hooks.state]

        [hooks.state."/Users/me/.codex/config.toml:session_start:0:0"]
        trusted_hash = "sha256:stale-but-preserved"
        \(AgentHooksInstall.rcMarkerEnd)
        """
        let contents = mergedContents(AgentHooksInstall.mergeCodexConfig(existing: existing, scriptDir: scriptDir))
        let hook = scriptDir + "/agterm-codex-status.sh"
        for action in ["session-start", "user-prompt-submit", "pre-tool-use", "post-tool-use", "permission-request", "stop"] {
            #expect(contents.contains("'\(hook)' \(action)"))
        }
        #expect(!contents.contains("'\(legacyWrapper)' blocked"))
        #expect(contents.contains("trusted_hash = \"sha256:stale-but-preserved\""))
        #expect(contents.components(separatedBy: AgentHooksInstall.rcMarkerBegin).count - 1 == 1)
    }

    @Test func mergeCodexConfigDoesNotReplaceForeignMarkerBlock() {
        let existing = """
        \(AgentHooksInstall.rcMarkerBegin)
        # user content that happens to use the same generic markers
        model = "gpt-5"
        \(AgentHooksInstall.rcMarkerEnd)
        """
        #expect(AgentHooksInstall.mergeCodexConfig(existing: existing, scriptDir: scriptDir) == .unchanged)
    }

    @Test func mergeCodexConfigStripsLegacyNotifyLine() {
        let existing = "notify = [\"/Users/me/.config/agterm/agent-status/codex-notify.sh\"]\n"
        let contents = mergedContents(AgentHooksInstall.mergeCodexConfig(existing: existing, scriptDir: scriptDir))
        #expect(!contents.contains("codex-notify.sh")) // the retired notify line is removed
        #expect(contents.contains("[[hooks.Stop]]"))
    }

    @Test func mergeCodexConfigPreservesCommentsAndOtherNotify() {
        let existing = """
        # my codex config
        model = "gpt-5"
        notify = ["/home/me/my-own-notify.sh"]
        """
        let contents = mergedContents(AgentHooksInstall.mergeCodexConfig(existing: existing, scriptDir: scriptDir))
        #expect(contents.contains("# my codex config")) // comments preserved (surgical append, no reserialize)
        #expect(contents.contains("model = \"gpt-5\""))
        #expect(contents.contains("notify = [\"/home/me/my-own-notify.sh\"]")) // user's own notify kept
        #expect(contents.contains("[[hooks.PermissionRequest]]"))
        #expect(contents.contains("my-own-notify.sh\"]\n\n\(AgentHooksInstall.rcMarkerBegin)"))
    }

    @Test func mergeCodexConfigKeepsNotifyWhenCodexNameOnlyInComment() {
        // over-match guard: the notify VALUE is a custom program; codex-notify.sh appears only in a
        // comment, so the parsed value has no codex-notify.sh and the line must be KEPT
        let existing = "notify = [\"/home/me/custom.sh\"] # replaces codex-notify.sh\n"
        let contents = mergedContents(AgentHooksInstall.mergeCodexConfig(existing: existing, scriptDir: scriptDir))
        #expect(contents.contains("notify = [\"/home/me/custom.sh\"]")) // user's notify survives
    }

    @Test func mergeCodexConfigSkipsWhenUserHasOwnHooks() {
        // a config that already defines hooks (its own array-of-tables) must NOT be appended to — that
        // would duplicate/break them; the merge reports .hooksExist so the caller prints the block
        let existing = """
        [[hooks.Stop]]
        [[hooks.Stop.hooks]]
        type = "command"
        command = "echo done"
        """
        #expect(AgentHooksInstall.mergeCodexConfig(existing: existing, scriptDir: scriptDir) == .hooksExist)
    }

    @Test func mergeCodexConfigReportsUnparseable() {
        // a file that is not valid TOML must be left untouched, not rewritten
        #expect(AgentHooksInstall.mergeCodexConfig(existing: "this = is = not = toml\n", scriptDir: scriptDir) == .unparseable)
    }

    @Test func appendShellRCAddsLineAndMarkersOnce() {
        let result = AgentHooksInstall.appendShellRC(existing: "export FOO=1\n", scriptDir: scriptDir)
        #expect(result.changed)
        #expect(result.contents.contains(AgentHooksInstall.rcMarkerBegin))
        #expect(result.contents.contains(AgentHooksInstall.rcMarkerEnd))
        #expect(result.contents.contains("source '\(scriptDir)/shell/integration.sh'"))
        #expect(result.contents.hasPrefix("export FOO=1\n")) // prior content preserved
    }

    @Test func appendShellRCSecondCallIsNoOp() {
        let first = AgentHooksInstall.appendShellRC(existing: "export FOO=1\n", scriptDir: scriptDir)
        let second = AgentHooksInstall.appendShellRC(existing: first.contents, scriptDir: scriptDir)
        #expect(!second.changed)
        #expect(second.contents == first.contents)
        // exactly one occurrence of the begin marker
        let count = first.contents.components(separatedBy: AgentHooksInstall.rcMarkerBegin).count - 1
        #expect(count == 1)
    }

    @Test func appendShellRCToEmptyFile() {
        let result = AgentHooksInstall.appendShellRC(existing: "", scriptDir: scriptDir)
        #expect(result.changed)
        #expect(result.contents.hasPrefix(AgentHooksInstall.rcMarkerBegin))
    }

    @Test func appendShellRCWithCustomScriptName() {
        let result = AgentHooksInstall.appendShellRC(existing: "export FOO=1\n", scriptDir: scriptDir, scriptName: "shell/integration.fish")
        #expect(result.changed)
        #expect(result.contents.contains("source '\(scriptDir)/shell/integration.fish'"))
    }

    @Test func piExtensionPathsUsePiGlobalExtensionsDirectory() {
        #expect(AgentHooksInstall.piExtensionDirectory(home: "/Users/me") == "/Users/me/.pi/agent/extensions")
        #expect(AgentHooksInstall.piExtensionPath(home: "/Users/me") == "/Users/me/.pi/agent/extensions/agterm-status.ts")
    }

    @Test func piExtensionOwnershipProtectsUserExtension() {
        #expect(AgentHooksInstall.mayOverwritePiExtension(fileExists: false, existingContents: nil))
        #expect(AgentHooksInstall.mayOverwritePiExtension(
            fileExists: true,
            existingContents: "// agterm-pi-status-extension\nexport default () => {}\n"
        ))
        #expect(!AgentHooksInstall.mayOverwritePiExtension(fileExists: true, existingContents: "export default () => {}\n"))
        #expect(!AgentHooksInstall.mayOverwritePiExtension(fileExists: true, existingContents: nil))
    }

    @Test func backupPathAppendsBak() {
        #expect(AgentHooksInstall.backupPath(for: "/home/me/.claude/settings.json") == "/home/me/.claude/settings.json.bak")
    }

    @Test func backupPathHandlesPathWithoutExtension() {
        #expect(AgentHooksInstall.backupPath(for: "/home/me/.zshrc") == "/home/me/.zshrc.bak")
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func writeFilePreservesPosixMode() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("settings.json").path
        try "old contents".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: path)
        let mode = AgentHooksInstall.posixMode(ofFile: path)
        try AgentHooksInstall.writeFile("new contents", toPath: path, posixMode: mode)
        #expect(AgentHooksInstall.posixMode(ofFile: path)?.intValue == 0o600) // mode survives the rewrite
        #expect((try? String(contentsOfFile: path, encoding: .utf8)) == "new contents")
    }

    @Test func writeFileWithNilModeCreatesFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("fresh.json").path
        try AgentHooksInstall.writeFile("hello", toPath: path, posixMode: nil)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect((try? String(contentsOfFile: path, encoding: .utf8)) == "hello")
        #expect(AgentHooksInstall.posixMode(ofFile: path) != nil) // some default mode was assigned
    }

    @Test func posixModeReturnsModeAndNilForAbsent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("secret").path
        try "x".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: path)
        #expect(AgentHooksInstall.posixMode(ofFile: path)?.intValue == 0o600)
        #expect(AgentHooksInstall.posixMode(ofFile: dir.appendingPathComponent("nope").path) == nil)
    }
}
