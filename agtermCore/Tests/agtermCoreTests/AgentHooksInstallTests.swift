import Foundation
import Testing
@testable import agtermCore

struct AgentHooksInstallTests {
    private let scriptDir = "/Users/me/.config/agterm/agent-status"

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
        // the entries invoke the Claude adapter, which guards on ownership and forwards to the wrapper
        let adapter = AgentHooksInstall.claudeWrapperPath(scriptDir: scriptDir)
        #expect(command(evts["UserPromptSubmit"]![0]) == "'\(adapter)' active --blink")
        // PostToolUse re-asserts active after every tool, clearing a lingering blocked on resume
        #expect(command(evts["PostToolUse"]![0]) == "'\(adapter)' active --blink")
        // only the Stop hook passes --auto-reset (clear-on-visit); active/blocked stay keep-state
        #expect(command(evts["Stop"]![0]) == "'\(adapter)' completed --auto-reset")
        #expect(command(evts["Notification"]![0]) == "'\(adapter)' blocked")
        #expect(command(evts["UserPromptSubmit"]![0])?.contains("--auto-reset") == false)
        #expect(command(evts["Notification"]![0])?.contains("--auto-reset") == false)
        #expect(evts["Notification"]![0]["matcher"] as? String == "permission_prompt")
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
        #expect(root["model"] as? String == "opus")
        let evts = events(result.json)
        #expect(evts["PreToolUse"]?.count == 1)
        #expect(command(evts["PreToolUse"]![0]) == "/usr/bin/guard.sh")
        #expect(evts["UserPromptSubmit"]?.count == 2)
        let commands = evts["UserPromptSubmit"]!.compactMap { command($0) }
        #expect(commands.contains("/usr/bin/other-hook.sh"))
        #expect(commands.contains { $0.hasSuffix("claude-status.sh' active --blink") })
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
        #expect(!second.changed)
        let commands = events(second.json)["UserPromptSubmit"]!.compactMap { command($0) }
        #expect(commands.contains("/usr/bin/other.sh"))
    }

    // settings.json exactly as an install BEFORE the Claude adapter left it: four entries invoking the
    // generic wrapper directly.
    private func legacySettings(extraUserHook: String? = nil) -> String {
        let wrapper = AgentHooksInstall.wrapperPath(scriptDir: scriptDir)
        var userHook = ""
        if let extraUserHook {
            userHook = """
            ,
                  {"hooks": [{"type": "command", "command": "\(extraUserHook)"}]}
            """
        }
        return """
        {
          "hooks": {
            "UserPromptSubmit": [
              {"hooks": [{"type": "command", "command": "'\(wrapper)' active --blink"}]}\(userHook)
            ],
            "PostToolUse": [
              {"hooks": [{"type": "command", "command": "'\(wrapper)' active --blink"}]}
            ],
            "Stop": [
              {"hooks": [{"type": "command", "command": "'\(wrapper)' completed --auto-reset"}]}
            ],
            "Notification": [
              {"matcher": "permission_prompt", "hooks": [{"type": "command", "command": "'\(wrapper)' blocked"}]}
            ]
          }
        }
        """
    }

    @Test func mergeMigratesEarlierInstallOntoTheAdapter() throws {
        // the guard has to reach an EXISTING install: without the migration the merge would skip all four
        // events as already-installed and leave them pointing at the unguarded wrapper forever
        let result = try AgentHooksInstall.mergeClaudeSettings(existing: legacySettings(), scriptDir: scriptDir)
        #expect(result.changed)
        let evts = events(result.json)
        let adapter = AgentHooksInstall.claudeWrapperPath(scriptDir: scriptDir)
        #expect(evts["UserPromptSubmit"]?.count == 1)
        #expect(evts["PostToolUse"]?.count == 1)
        #expect(evts["Stop"]?.count == 1)
        #expect(evts["Notification"]?.count == 1)
        #expect(command(evts["UserPromptSubmit"]![0]) == "'\(adapter)' active --blink")
        #expect(command(evts["PostToolUse"]![0]) == "'\(adapter)' active --blink")
        #expect(command(evts["Stop"]![0]) == "'\(adapter)' completed --auto-reset")
        #expect(command(evts["Notification"]![0]) == "'\(adapter)' blocked")
        // rewritten in place: the matcher and the entry's other keys are untouched
        #expect(evts["Notification"]![0]["matcher"] as? String == "permission_prompt")
        #expect((evts["Stop"]![0]["hooks"] as? [[String: Any]])?.first?["type"] as? String == "command")
        // migrated, not appended alongside a fresh set
        #expect(!result.json.contains(AgentHooksInstall.wrapperPath(scriptDir: scriptDir) + "'"))
    }

    @Test func mergeMigratesPreBlinkPromptEntry() throws {
        // installs between 17c8a914 and a9e678d9 wrote `active` for UserPromptSubmit — source builds only,
        // no tag carries the bare form. A byte-exact match against only the current `active --blink` left
        // that entry on the unguarded wrapper while entryUsesWrapper reported the event installed, so
        // nothing ever said the hook was unguarded. The historical form migrates like the current one:
        // onto the adapter AND the current state.
        let wrapper = AgentHooksInstall.wrapperPath(scriptDir: scriptDir)
        let existing = """
        {
          "hooks": {
            "UserPromptSubmit": [
              {"hooks": [{"type": "command", "command": "'\(wrapper)' active"}]}
            ]
          }
        }
        """
        let result = try AgentHooksInstall.mergeClaudeSettings(existing: existing, scriptDir: scriptDir)
        #expect(result.changed)
        let evts = events(result.json)
        let adapter = AgentHooksInstall.claudeWrapperPath(scriptDir: scriptDir)
        #expect(evts["UserPromptSubmit"]?.count == 1)
        #expect(command(evts["UserPromptSubmit"]![0]) == "'\(adapter)' active --blink")
    }

    @Test func mergeMigrationIsIdempotent() throws {
        let first = try AgentHooksInstall.mergeClaudeSettings(existing: legacySettings(), scriptDir: scriptDir)
        let second = try AgentHooksInstall.mergeClaudeSettings(existing: first.json, scriptDir: scriptDir)
        #expect(!second.changed)
        #expect(second.json == first.json)
    }

    @Test func mergeMigrationLeavesCustomizedEntryAlone() throws {
        // one hand-edited entry (an appended flag) plus one entry still in generated form: byte-exactness is
        // the whole safety property, so the edited one must come back identical
        let wrapper = AgentHooksInstall.wrapperPath(scriptDir: scriptDir)
        let customized = "'\(wrapper)' active --blink --pane right"
        let existing = """
        {
          "hooks": {
            "UserPromptSubmit": [
              {"hooks": [{"type": "command", "command": "\(customized)"}]}
            ],
            "Stop": [
              {"hooks": [{"type": "command", "command": "'\(wrapper)' completed --auto-reset"}]}
            ]
          }
        }
        """
        let result = try AgentHooksInstall.mergeClaudeSettings(existing: existing, scriptDir: scriptDir)
        #expect(result.changed)
        let evts = events(result.json)
        let adapter = AgentHooksInstall.claudeWrapperPath(scriptDir: scriptDir)
        // the customized entry survives byte-identical AND still counts as installed, so no stock entry is
        // added beside it: two entries would both fire and post the row twice
        #expect(evts["UserPromptSubmit"]?.count == 1)
        #expect(evts["UserPromptSubmit"]!.compactMap { command($0) } == [customized])
        // the entry that WAS in generated form migrated in place rather than gaining a duplicate
        #expect(evts["Stop"]?.count == 1)
        #expect(command(evts["Stop"]![0]) == "'\(adapter)' completed --auto-reset")
    }

    @Test func mergeMigrationLeavesUserHookNamingTheWrapperAlone() throws {
        // a user's own hook that merely mentions the wrapper path is not something the installer wrote
        let wrapper = AgentHooksInstall.wrapperPath(scriptDir: scriptDir)
        let userHook = "my-notifier.sh && '\(wrapper)' active --blink"
        let result = try AgentHooksInstall.mergeClaudeSettings(existing: legacySettings(extraUserHook: userHook),
                                                               scriptDir: scriptDir)
        #expect(result.changed)
        let prompts = events(result.json)["UserPromptSubmit"]!.compactMap { command($0) }
        #expect(prompts.contains(userHook))
        // only the generated sibling moved onto the adapter
        #expect(prompts.contains("'\(AgentHooksInstall.claudeWrapperPath(scriptDir: scriptDir))' active --blink"))
        #expect(prompts.count == 2)
    }

    @Test func mergeRefusesMalformedExisting() {
        // refusing leaves the user's hand-maintained settings.json untouched
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
        // Codex-specific behavior stays in the installed adapter; agterm only generates the six
        // lifecycle entries.
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
        #expect(!contents.contains("codex-notify.sh"))
        #expect(contents.contains("[[hooks.Stop]]"))
    }

    @Test func mergeCodexConfigPreservesCommentsAndOtherNotify() {
        let existing = """
        # my codex config
        model = "gpt-5"
        notify = ["/home/me/my-own-notify.sh"]
        """
        let contents = mergedContents(AgentHooksInstall.mergeCodexConfig(existing: existing, scriptDir: scriptDir))
        #expect(contents.contains("# my codex config")) // surgical append, no reserialize
        #expect(contents.contains("model = \"gpt-5\""))
        #expect(contents.contains("notify = [\"/home/me/my-own-notify.sh\"]"))
        #expect(contents.contains("[[hooks.PermissionRequest]]"))
        #expect(contents.contains("my-own-notify.sh\"]\n\n\(AgentHooksInstall.rcMarkerBegin)"))
    }

    @Test func mergeCodexConfigKeepsNotifyWhenCodexNameOnlyInComment() {
        // over-match guard: codex-notify.sh appears only in a COMMENT, so the parsed value never names it
        let existing = "notify = [\"/home/me/custom.sh\"] # replaces codex-notify.sh\n"
        let contents = mergedContents(AgentHooksInstall.mergeCodexConfig(existing: existing, scriptDir: scriptDir))
        #expect(contents.contains("notify = [\"/home/me/custom.sh\"]"))
    }

    @Test func mergeCodexConfigSkipsWhenUserHasOwnHooks() {
        // appending to a config that already defines hooks would duplicate/break them
        let existing = """
        [[hooks.Stop]]
        [[hooks.Stop.hooks]]
        type = "command"
        command = "echo done"
        """
        #expect(AgentHooksInstall.mergeCodexConfig(existing: existing, scriptDir: scriptDir) == .hooksExist)
    }

    @Test func mergeCodexConfigReportsUnparseable() {
        #expect(AgentHooksInstall.mergeCodexConfig(existing: "this = is = not = toml\n", scriptDir: scriptDir) == .unparseable)
    }

    @Test func appendShellRCAddsLineAndMarkersOnce() {
        let result = AgentHooksInstall.appendShellRC(existing: "export FOO=1\n", scriptDir: scriptDir)
        #expect(result.changed)
        #expect(result.contents.contains(AgentHooksInstall.rcMarkerBegin))
        #expect(result.contents.contains(AgentHooksInstall.rcMarkerEnd))
        #expect(result.contents.contains("source '\(scriptDir)/shell/integration.sh'"))
        #expect(result.contents.hasPrefix("export FOO=1\n"))
    }

    @Test func appendShellRCSecondCallIsNoOp() {
        let first = AgentHooksInstall.appendShellRC(existing: "export FOO=1\n", scriptDir: scriptDir)
        let second = AgentHooksInstall.appendShellRC(existing: first.contents, scriptDir: scriptDir)
        #expect(!second.changed)
        #expect(second.contents == first.contents)
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

    @Test func opencodePluginPathsUseOpenCodePluginsDirectory() {
        #expect(AgentHooksInstall.opencodePluginDirectory(home: "/Users/me")
                == "/Users/me/.config/opencode/plugins")
        #expect(AgentHooksInstall.opencodePluginPath(home: "/Users/me")
                == "/Users/me/.config/opencode/plugins/agterm-status.js")
        #expect(AgentHooksInstall.opencodePluginRelativePath == "opencode/agterm-status.js")
        #expect(AgentHooksInstall.opencodePluginMarker == "// agterm-opencode-status-plugin")
    }

    @Test func opencodePluginOwnershipProtectsUserPlugin() {
        #expect(AgentHooksInstall.mayOverwriteOpenCodePlugin(fileExists: false, existingContents: nil))
        #expect(AgentHooksInstall.mayOverwriteOpenCodePlugin(
            fileExists: true,
            existingContents: "// agterm-opencode-status-plugin\nexport const AgtermStatusPlugin = async () => ({})\n"
        ))
        #expect(!AgentHooksInstall.mayOverwriteOpenCodePlugin(
            fileExists: true,
            existingContents: "export const Other = async () => ({})\n"
        ))
        #expect(!AgentHooksInstall.mayOverwriteOpenCodePlugin(fileExists: true, existingContents: nil))
    }

    @Test func fishIntegrationExportsAnExistingAgentRegexOverride() throws {
        // the export must run on BOTH branches of the set -q guard: an override set before sourcing —
        // in the `set -g` form this file itself documented until the adapter consumed the value —
        // satisfies set -q with the export bit off, so only a re-export on that branch gets it into
        // the adapter's environment. Exporting just the default is the inverted shape this pins
        // against: that value duplicates the adapter's literal list and needs no export at all.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fish = root.appendingPathComponent("agterm/Resources/agent-status/shell/integration.fish")
        let text = try String(contentsOf: fish, encoding: .utf8)
        #expect(text.contains("set -gx AGTERM_AGENT_RE $AGTERM_AGENT_RE"),
                "integration.fish must re-export a pre-existing AGTERM_AGENT_RE override")
    }

    @Test func shippedShellIntegrationsOmitLifecycleAgentsFromDefaultRegex() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        // Keep local to the test — no production constant; shell scripts are the source of truth.
        let expected = "^(gemini|cursor-agent|aider|crush|goose)([[:space:]]|$)"
        let lifecycleAgents = ["opencode", "claude", "codex"]
        for relative in ["agterm/Resources/agent-status/shell/integration.sh",
                         "agterm/Resources/agent-status/shell/integration.fish"] {
            let text = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            #expect(text.contains(expected), "\(relative) must embed the default agent regex")
            // Match only the default assignment — keyed on the default's literal regex, because an
            // assignment prefix alone also matches fish's re-export of an existing override (which
            // carries no regex literal), and commented override examples are excluded either way.
            let defaultLines = text.split(separator: "\n").filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#") { return false }
                guard trimmed.contains("AGTERM_AGENT_RE:=")
                    || trimmed.hasPrefix("set -g AGTERM_AGENT_RE ")
                    || trimmed.hasPrefix("set -gx AGTERM_AGENT_RE ") else { return false }
                return trimmed.contains(expected)
            }
            #expect(defaultLines.count == 1, "\(relative) must have exactly one default AGTERM_AGENT_RE")
            for line in defaultLines {
                #expect(String(line).contains(expected))
                for name in lifecycleAgents {
                    #expect(
                        !String(line).contains(name),
                        "\(relative) default must not include \(name)"
                    )
                }
                // "pi" is a substring of other tokens; require a command-name boundary match.
                #expect(
                    line.range(of: #"(^|[|(])pi([)|[:space:]]|$)"#, options: .regularExpression) == nil,
                    "\(relative) default must not include pi as an agent name"
                )
            }
        }
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
        #expect(AgentHooksInstall.posixMode(ofFile: path)?.intValue == 0o600)
        #expect((try? String(contentsOfFile: path, encoding: .utf8)) == "new contents")
    }

    @Test func writeFileWithNilModeCreatesFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("fresh.json").path
        try AgentHooksInstall.writeFile("hello", toPath: path, posixMode: nil)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect((try? String(contentsOfFile: path, encoding: .utf8)) == "hello")
        #expect(AgentHooksInstall.posixMode(ofFile: path) != nil)
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

    // MARK: - agtermctl path baking

    private let wrapperStub = """
    #!/usr/bin/env bash
    set -u
    "${AGTERMCTL:-agtermctl}" session status "$1"
    """

    @Test func bakeInsertsTheBlockAfterTheShebang() {
        let baked = AgentHooksInstall.bakeAgtermctlPath(into: wrapperStub, toolPath: "/Applications/agterm.app/Contents/MacOS/agtermctl")
        let lines = baked.components(separatedBy: "\n")
        #expect(lines.first == "#!/usr/bin/env bash")
        #expect(lines[1] == AgentHooksInstall.agtermctlMarker)
        #expect(lines.contains("  AGTERMCTL='/Applications/agterm.app/Contents/MacOS/agtermctl'"))
        #expect(baked.hasSuffix(wrapperStub.components(separatedBy: "\n").dropFirst().joined(separator: "\n")))
    }

    @Test func bakedBlockFallsBackToPathWhenTheBakedBundleIsGone() {
        // pins #472: the wrapper swallows the failure, so the block has to test the path before committing
        let baked = AgentHooksInstall.bakeAgtermctlPath(into: wrapperStub, toolPath: "/Volumes/agterm/agterm.app/Contents/MacOS/agtermctl")
        #expect(baked.contains(#"  [ -x "$AGTERMCTL" ] || AGTERMCTL="$(command -v agtermctl || true)""#))
        #expect(baked.contains(#"if [ -z "${AGTERMCTL:-}" ]; then"#))
    }

    @Test func rebakingReplacesTheBlockInsteadOfStackingIt() {
        let dmg = AgentHooksInstall.bakeAgtermctlPath(into: wrapperStub, toolPath: "/Volumes/agterm/agterm.app/Contents/MacOS/agtermctl")
        let moved = AgentHooksInstall.bakeAgtermctlPath(into: dmg, toolPath: "/Applications/agterm.app/Contents/MacOS/agtermctl")
        let lines = moved.components(separatedBy: "\n")
        #expect(lines.filter { $0 == AgentHooksInstall.agtermctlMarker }.count == 1)
        #expect(lines.filter { $0.contains("command -v agtermctl") }.count == 1)
        #expect(!moved.contains("/Volumes/agterm"))
        #expect(moved == AgentHooksInstall.bakeAgtermctlPath(into: wrapperStub, toolPath: "/Applications/agterm.app/Contents/MacOS/agtermctl"))
    }
}
