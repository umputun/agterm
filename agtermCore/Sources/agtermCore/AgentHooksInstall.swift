import Foundation
import TOMLDecoder

/// Host-free helpers for installing the agent-status hooks package: idempotent string/JSON/TOML transforms
/// returning the new contents plus a `changed` flag. Plus a mode-preserving write (`writeFile`/`posixMode`) so
/// rewriting a restrictive-mode file (e.g. a chmod-600 `settings.json`) keeps its permissions instead of an
/// atomic rename widening it to 0644. The app side owns copying the bundled scripts and resolving symlinks.
public enum AgentHooksInstall {
    /// The wrapper script the hooks invoke, installed into the script directory.
    public static let wrapperName = "agterm-agent-status.sh"

    /// Codex-specific lifecycle adapter installed beside the generic status wrapper; agent-specific event and
    /// terminal-output knowledge stays in this hook resource, outside agterm's runtime.
    public static let codexWrapperName = "agterm-codex-status.sh"

    /// Claude-specific adapter the four Claude hooks invoke instead of the generic wrapper: a worker agent
    /// spawned from inside a session inherits the spawner's `AGTERM_*` environment, so its hooks would repaint
    /// the SPAWNER's row. The adapter answers that ownership question from process topology and delegates,
    /// keeping the Claude-specific knowledge in the hook resource the way the Codex adapter does.
    static let claudeWrapperName = "agterm-claude-status.sh"

    /// The bundled Pi extension's path relative to the agent-status package, and its destination filename.
    public static let piExtensionRelativePath = "pi/agterm-status.ts"
    static let piExtensionName = "agterm-status.ts"

    /// Ownership sentinel in the bundled Pi extension: a reinstall refuses to overwrite an unmarked same-named
    /// extension, preserving a user-authored integration.
    public static let piExtensionMarker = "// agterm-pi-status-extension"

    /// The bundled OpenCode plugin's path relative to the agent-status package, and its destination filename.
    public static let opencodePluginRelativePath = "opencode/agterm-status.js"
    static let opencodePluginName = "agterm-status.js"

    /// Ownership sentinel in the bundled OpenCode plugin, same policy as `piExtensionMarker`. Named `*Plugin*`
    /// (not `*Extension*`) because OpenCode's host term is plugin — a deliberate divergence from `piExtension*`.
    public static let opencodePluginMarker = "// agterm-opencode-status-plugin"

    /// The shell integration scripts sourced from the user's rc files / config.fish, relative to the script
    /// directory.
    public static let integrationRelativePath = "shell/integration.sh"
    public static let fishIntegrationRelativePath = "shell/integration.fish"

    /// Sentinel opening the installer-baked AGTERMCTL block; a re-bake replaces it instead of duplicating it.
    static let agtermctlMarker = "# >>> agterm agtermctl path (installer-baked) >>>"

    /// Marker lines bracketing the agterm-managed block in a shell rc file; the opening marker is also the
    /// idempotency probe (present → already installed).
    static let rcMarkerBegin = "# >>> agterm agent-status >>>"
    static let rcMarkerEnd = "# <<< agterm agent-status <<<"

    /// The Claude Code hook events the merge installs, paired with the state (plus flags) each maps to.
    /// `UserPromptSubmit` and `PostToolUse` both set `active` — the latter after every tool run, so the status
    /// returns to `active` when work RESUMES after a `blocked` permission prompt: Claude Code has no
    /// "permission answered" event, and the gated tool's `PreToolUse` fired BEFORE `blocked` was set, so its
    /// `PostToolUse` is the first hook afterwards. `Notification` alone carries the `permission_prompt` matcher,
    /// and only `Stop`→`completed` passes `--auto-reset` (it clears on visit); the rest stay keep-state.
    static let claudeHooks: [(event: String, matcher: String?, state: String)] = [
        ("UserPromptSubmit", nil, "active --blink"),
        ("PostToolUse", nil, "active --blink"),
        ("Stop", nil, "completed --auto-reset"),
        ("Notification", "permission_prompt", "blocked"),
    ]

    /// Codex lifecycle events paired with actions the installed Codex hook understands; the adapter, not
    /// agterm's runtime, owns the event-to-status behavior and the Auto Review workaround.
    static let codexHooks: [(event: String, action: String)] = [
        ("SessionStart", "session-start"),
        ("UserPromptSubmit", "user-prompt-submit"),
        ("PreToolUse", "pre-tool-use"),
        ("PostToolUse", "post-tool-use"),
        ("PermissionRequest", "permission-request"),
        ("Stop", "stop"),
    ]

    /// The destination directory for Pi's auto-discovered global extensions.
    static func piExtensionDirectory(home: String) -> String {
        home + "/.pi/agent/extensions"
    }

    public static func piExtensionPath(home: String) -> String {
        piExtensionDirectory(home: home) + "/" + piExtensionName
    }

    /// Whether the Pi extension destination is safe to replace: absent is safe, an existing file must carry the
    /// agterm ownership marker, and an unreadable one counts as user-owned.
    public static func mayOverwritePiExtension(fileExists: Bool, existingContents: String?) -> Bool {
        guard fileExists else { return true }
        guard let existingContents else { return false }
        return existingContents.contains(piExtensionMarker)
    }

    /// The destination directory for OpenCode's auto-discovered global plugins.
    static func opencodePluginDirectory(home: String) -> String {
        home + "/.config/opencode/plugins"
    }

    public static func opencodePluginPath(home: String) -> String {
        opencodePluginDirectory(home: home) + "/" + opencodePluginName
    }

    /// Whether the OpenCode plugin destination is safe to replace; same ownership policy as Pi.
    public static func mayOverwriteOpenCodePlugin(fileExists: Bool, existingContents: String?) -> Bool {
        guard fileExists else { return true }
        guard let existingContents else { return false }
        return existingContents.contains(opencodePluginMarker)
    }

    /// Thrown by `mergeClaudeSettings` when the existing `settings.json` is non-empty but not a valid JSON
    /// object: the installer refuses to overwrite a hand-maintained file it cannot safely parse.
    public enum MergeError: Error { case malformedExistingSettings }

    /// merge the four agent-status hooks into an existing Claude Code `settings.json`.
    ///
    /// `existing` is the current contents (nil/empty = start from a fresh object). Returns the new JSON and
    /// whether it differs; idempotent — hooks already present (detected by the adapter command) return the
    /// input with `changed == false`. Unrelated hooks and keys are preserved; invalid JSON, and a `hooks` or
    /// written-event value of the wrong shape, throw rather than overwrite what could not be read. Entries a
    /// PRIOR install pointed straight at the generic wrapper are migrated onto the Claude adapter first, so
    /// the ownership guard reaches an existing install rather than only a fresh one.
    public static func mergeClaudeSettings(existing: String?, scriptDir: String) throws -> (json: String, changed: Bool) {
        let command = wrapperCommand(scriptDir: scriptDir)
        var root = try parsedObject(existing)

        var hooks = try claudeHooksObject(root)
        var didChange = migrateClaudeEntriesToAdapter(&hooks, scriptDir: scriptDir)
        for hook in claudeHooks {
            var entries = hooks[hook.event] as? [[String: Any]] ?? [] // shape already checked above
            if entries.contains(where: { entryUsesWrapper($0, scriptDir: scriptDir) }) {
                continue
            }
            entries.append(hookEntry(command: command, state: hook.state, matcher: hook.matcher))
            hooks[hook.event] = entries
            didChange = true
        }
        if !didChange {
            return (existing ?? "", false)
        }
        root["hooks"] = hooks
        return (serialize(root), true)
    }

    /// append the marker-guarded `source` line for the shell integration to a shell rc file.
    ///
    /// Returns the new contents and whether anything was appended; idempotent — a begin marker already present
    /// returns `existing` with `changed == false`.
    public static func appendShellRC(existing: String, scriptDir: String, scriptName: String = integrationRelativePath) -> (contents: String, changed: Bool) {
        if existing.contains(rcMarkerBegin) {
            return (existing, false)
        }
        let source = "source \(shellQuote(scriptDir + "/" + scriptName))"
        var block = rcMarkerBegin + "\n" + source + "\n" + rcMarkerEnd + "\n"
        if existing.isEmpty {
            return (block, true)
        }
        // ensure exactly one blank line between prior content and the block
        var prefix = existing
        if !prefix.hasSuffix("\n") {
            prefix += "\n"
        }
        block = "\n" + block
        return (prefix + block, true)
    }

    /// The result of merging the Codex hooks into `~/.codex/config.toml`, decided by parsing the file with
    /// `TOMLDecoder` before touching it.
    public enum CodexMergeOutcome: Equatable {
        /// The hooks block was added (and any stale `codex-notify.sh` notify line removed) — write `contents`.
        case merged(contents: String)
        /// The file already carries the current agterm hooks block — nothing to do.
        case unchanged
        /// The file already defines its OWN `hooks` — appending ours would duplicate (array-of-tables form) or
        /// break (compact form) them, so the merge is skipped; point the user at the docs for a manual merge.
        case hooksExist
        /// The existing file is not valid TOML — leave it untouched and point at the docs for a manual add.
        case unparseable
    }

    /// merge the Codex lifecycle-status hooks into an existing `~/.codex/config.toml` (`existing` empty = no
    /// file yet). The decision is made by PARSING with `TOMLDecoder` rather than string-matching, which is what
    /// keeps the merge safe: marker present → upgrade an older managed block to the currently installed Codex
    /// adapter, preserving Codex's trailing hook trust-state tables, else `.unchanged`; not valid TOML →
    /// `.unparseable`; already defines `hooks` → `.hooksExist`; otherwise `.merged`, appending the
    /// marker-guarded `[[hooks.*]]` array-of-tables at end-of-file (valid because no existing `hooks` was
    /// found) and removing a stale top-level `notify` ONLY when its PARSED value points at the retired
    /// `codex-notify.sh`, so a comment merely naming the file, or the user's own notifier, is never touched.
    /// The surgical append/removal preserves the user's comments and layout.
    public static func mergeCodexConfig(existing: String, scriptDir: String) -> CodexMergeOutcome {
        // marker present → refresh only our managed hook definitions. Codex may append hook trust-state
        // tables before our end marker; the refresh preserves that suffix byte-for-byte.
        if existing.contains(rcMarkerBegin) {
            let refreshed = refreshManagedCodexBlock(in: existing, scriptDir: scriptDir)
            return refreshed == existing ? .unchanged : .merged(contents: refreshed)
        }

        // a genuinely empty/whitespace file has no TOML to parse — start fresh.
        if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .merged(contents: appendCodexBlock(to: existing, scriptDir: scriptDir))
        }

        // parse to make the merge decisions structurally; a parse failure means don't rewrite it.
        guard let probe = try? TOMLDecoder().decode(CodexConfigProbe.self, from: existing) else {
            return .unparseable
        }
        if probe.hooksPresent {
            return .hooksExist
        }

        var text = existing
        if probe.notify.contains(where: { $0.contains("codex-notify.sh") }) {
            text = removeLegacyCodexNotify(from: text)
        }
        return .merged(contents: appendCodexBlock(to: text, scriptDir: scriptDir))
    }

    // the two top-level keys the merge cares about (Codable ignores every other). `hooksPresent` is a presence
    // check across any hooks shape; `notify` is the top-level notify program (array-of-argv or a bare string),
    // so the retired codex-notify.sh is recognized by its PARSED value, not a fragile line match.
    private struct CodexConfigProbe: Decodable {
        let hooksPresent: Bool
        let notify: [String]

        private enum CodingKeys: String, CodingKey { case hooks, notify }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            hooksPresent = container.contains(.hooks)
            if let array = try? container.decodeIfPresent([String].self, forKey: .notify) {
                notify = array
            } else if let single = try? container.decodeIfPresent(String.self, forKey: .notify) {
                notify = [single]
            } else {
                notify = []
            }
        }
    }

    // append the marker-guarded Codex hooks block, one blank line after any prior content.
    private static func appendCodexBlock(to text: String, scriptDir: String) -> String {
        let block = rcMarkerBegin + "\n" + codexHooksBlock(scriptDir: scriptDir) + "\n" + rcMarkerEnd + "\n"
        if text.isEmpty { return block }
        var prefix = text
        if !prefix.hasSuffix("\n") { prefix += "\n" }
        return prefix + "\n" + block
    }

    // replace only the generated definitions inside an existing managed block. Codex writes its
    // `[hooks.state...]` trust records at the end of config.toml, landing inside our EOF marker, so retain that
    // suffix. A coincidental marker block without one of our hook scripts is foreign and left untouched.
    private static func refreshManagedCodexBlock(in text: String, scriptDir: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard let begin = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == rcMarkerBegin }),
              let end = lines.indices.dropFirst(begin + 1).first(where: {
                  lines[$0].trimmingCharacters(in: .whitespaces) == rcMarkerEnd
              }) else { return text }
        let body = lines[(begin + 1)..<end]
        guard body.contains(where: { $0.contains(wrapperName) || $0.contains(codexWrapperName) }) else {
            return text
        }

        var suffix: [String] = []
        if var stateStart = body.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("[hooks.state")
        }) {
            if stateStart > begin + 1, lines[stateStart - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                stateStart -= 1
            }
            suffix = Array(lines[stateStart..<end])
        }

        var replacement = codexHooksBlock(scriptDir: scriptDir).components(separatedBy: "\n")
        if !suffix.isEmpty {
            if suffix.first?.trimmingCharacters(in: .whitespaces).isEmpty == false { replacement.append("") }
            replacement.append(contentsOf: suffix)
        }
        lines.replaceSubrange((begin + 1)..<end, with: replacement)
        return lines.joined(separator: "\n")
    }

    // remove the retired single-line `notify = [...codex-notify.sh...]` — only the old installer wrote that
    // form, and the caller already confirmed the parsed value. Restricted to the TOP-LEVEL region (above the
    // first table header), so a table-scoped notify is untouched, and to codex-notify.sh in the VALUE, so a
    // hand-authored multi-line array isn't half-removed.
    private static func removeLegacyCodexNotify(from text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let limit = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
        guard let idx = lines[..<limit].firstIndex(where: { line in
            guard line.contains("codex-notify.sh"), let eq = line.firstIndex(of: "=") else { return false }
            return line[..<eq].trimmingCharacters(in: .whitespaces) == "notify"
        }) else { return text }
        lines.remove(at: idx)
        return lines.joined(separator: "\n")
    }

    /// bake `toolPath` — the bundled `agtermctl` — into an installed wrapper, replacing the block a previous
    /// install left behind. The `-x` test sits INSIDE the unset branch so an explicit override is never
    /// second-guessed; the wrapper's own header owns why the PATH rung has to stay reachable.
    public static func bakeAgtermctlPath(into text: String, toolPath: String) -> String {
        let block = agtermctlBlockLines(toolPath: toolPath)
        return insertAfterShebang(stripBakedBlock(from: text, bodyLines: block.count - 1), lines: block)
    }

    // the baked block, marker line first.
    private static func agtermctlBlockLines(toolPath: String) -> [String] {
        [
            agtermctlMarker,
            "if [ -z \"${AGTERMCTL:-}\" ]; then",
            "  AGTERMCTL=\(shellQuote(toolPath))",
            "  [ -x \"$AGTERMCTL\" ] || AGTERMCTL=\"$(command -v agtermctl || true)\"",
            "fi",
        ]
    }

    // drop a previously baked block: the marker plus `bodyLines` lines below it. `bodyLines` measures the block
    // being WRITTEN, so an older build's block of another length mis-strips; safe only because
    // `copyBundledFolder` re-copies the pristine wrapper first, leaving no marker to match.
    private static func stripBakedBlock(from text: String, bodyLines: Int) -> String {
        var result: [String] = []
        var skip = 0
        for line in text.components(separatedBy: "\n") {
            if skip > 0 { skip -= 1; continue }
            if line == agtermctlMarker { skip = bodyLines; continue }
            result.append(line)
        }
        return result.joined(separator: "\n")
    }

    private static func insertAfterShebang(_ text: String, lines block: [String]) -> String {
        var lines = text.components(separatedBy: "\n")
        let insertAt = lines.first?.hasPrefix("#!") == true ? 1 : 0
        lines.insert(contentsOf: block, at: insertAt)
        return lines.joined(separator: "\n")
    }

    /// derive a backup path by appending `.bak` to the full path, extension intact (`settings.json.bak`).
    public static func backupPath(for path: String) -> String {
        path + ".bak"
    }

    /// the absolute wrapper-script path the installed hooks invoke (`<scriptDir>/agterm-agent-status.sh`); the
    /// caller's hook entry appends the state.
    static func wrapperPath(scriptDir: String) -> String {
        scriptDir + "/" + wrapperName
    }

    static func codexWrapperPath(scriptDir: String) -> String {
        scriptDir + "/" + codexWrapperName
    }

    static func claudeWrapperPath(scriptDir: String) -> String {
        scriptDir + "/" + claudeWrapperName
    }

    /// render the `~/.codex/config.toml` `[[hooks.*]]` block the installer merges in, wiring Codex's lifecycle
    /// events to the indicator. `site/docs.html#codex-hooks-manual` reproduces this block for the cases the
    /// merge declines, and nothing checks the two against each other.
    /// The wrapper's absolute path is baked into each command — shell-quoted (so a path with spaces stays one
    /// token) inside a TOML basic string — so the hook fires without the CLI on PATH.
    static func codexHooksBlock(scriptDir: String) -> String {
        let wrapper = shellQuote(codexWrapperPath(scriptDir: scriptDir))
        return codexHooks.map { hook in
            """
            [[hooks.\(hook.event)]]
            [[hooks.\(hook.event).hooks]]
            type = "command"
            command = \(tomlBasicString(wrapper + " " + hook.action))
            """
        }.joined(separator: "\n\n")
    }

    /// the POSIX permission bits of the file at `path`, or nil when it is absent or unreadable — captured
    /// before a mode-preserving rewrite.
    public static func posixMode(ofFile path: String) -> NSNumber? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return attrs[.posixPermissions] as? NSNumber
    }

    /// write `text` to `path` atomically, then re-apply `posixMode` when non-nil: the atomic write renames a
    /// fresh 0644 temp over the target, which would otherwise widen a restrictive mode (e.g. a chmod-600
    /// secret). A nil `posixMode` leaves the new file's default permissions.
    public static func writeFile(_ text: String, toPath path: String, posixMode: NSNumber?) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        if let posixMode {
            try FileManager.default.setAttributes([.posixPermissions: posixMode], ofItemAtPath: path)
        }
    }

    // build the command string a Claude hook runs: the quoted CLAUDE ADAPTER path plus the state argument. The
    // adapter forwards the state to the generic wrapper verbatim once it decides the firing agent owns the pane.
    private static func wrapperCommand(scriptDir: String) -> String {
        shellQuote(claudeWrapperPath(scriptDir: scriptDir)) + " "
    }

    // repoint an EARLIER install's four entries from the generic wrapper at the Claude adapter, returning
    // whether anything moved. Without it the guard would reach fresh installs only: the merge below skips an
    // event whose entries already invoke us, and the Claude side has no refresh path (`refreshManagedCodexBlock`
    // is Codex-only), so an existing settings.json would keep its unguarded entries forever.
    //
    // The match is BYTE-EXACT against the command this installer generates for that same event — the quoted
    // wrapper path plus the state — which is what makes the rewrite safe: an entry carrying extra flags and a
    // user's own hook that merely mentions the wrapper both fail the comparison and are left alone, and only
    // the command string is replaced, so a matcher and any sibling keys survive. One hand edit is NOT left
    // alone: deleting `--blink` from UserPromptSubmit reproduces the pre-`a9e678d9` form byte for byte, so it
    // migrates and the flag returns; the installer's `.bak` is the recovery.
    // Idempotent, because a migrated entry names the adapter and no longer matches.
    private static func migrateClaudeEntriesToAdapter(_ hooks: inout [String: Any], scriptDir: String) -> Bool {
        let generated = shellQuote(wrapperPath(scriptDir: scriptDir)) + " "
        let replacement = wrapperCommand(scriptDir: scriptDir)
        var didChange = false
        for hook in claudeHooks {
            guard var entries = hooks[hook.event] as? [[String: Any]] else { continue }
            // the states this installer EVER generated for the event, current form first. UserPromptSubmit
            // predates the --blink promotion (a9e678d9) and an install from that window — source builds only,
            // no tag carries the bare form — still holds `active`; every other event has a single historical
            // form. A stale state migrates onto the adapter AND the current state in one rewrite.
            let generatedStates = hook.event == "UserPromptSubmit" ? [hook.state, "active"] : [hook.state]
            var eventChanged = false
            for index in entries.indices {
                guard var commands = entries[index]["hooks"] as? [[String: Any]] else { continue }
                var entryChanged = false
                for slot in commands.indices where generatedStates.contains(where: { commands[slot]["command"] as? String == generated + $0 }) {
                    commands[slot]["command"] = replacement + hook.state
                    entryChanged = true
                }
                if entryChanged {
                    entries[index]["hooks"] = commands
                    eventChanged = true
                }
            }
            if eventChanged {
                hooks[hook.event] = entries
                didChange = true
            }
        }
        return didChange
    }

    // a single Claude hook entry: { (matcher?), hooks: [{ type: command, command }] }.
    private static func hookEntry(command: String, state: String, matcher: String?) -> [String: Any] {
        var entry: [String: Any] = [
            "hooks": [["type": "command", "command": command + state]],
        ]
        if let matcher {
            entry["matcher"] = matcher
        }
        return entry
    }

    // does a hook entry already invoke us (idempotency probe)? EITHER path counts: the adapter, which is what
    // a current install writes and what the migration leaves behind, and the generic wrapper, which is what an
    // entry the migration declined to rewrite still names. Accepting only the adapter would answer "not
    // installed" for a customized wrapper entry and add a stock one beside it, so both would fire and the row
    // would be posted twice. Its owner keeps the setup they edited, unguarded by their own choice — the same
    // answer this probe has always given.
    private static func entryUsesWrapper(_ entry: [String: Any], scriptDir: String) -> Bool {
        let probes = [claudeWrapperPath(scriptDir: scriptDir), wrapperPath(scriptDir: scriptDir)]
        guard let commands = entry["hooks"] as? [[String: Any]] else { return false }
        return commands.contains { command in
            guard let command = command["command"] as? String else { return false }
            return probes.contains { command.contains($0) }
        }
    }

    // absent/empty/whitespace-only → fresh empty object; a non-empty file that is not a valid JSON object →
    // throw rather than silently discard the user's file.
    // a wrong-TYPED value is not an absent one: `as?` plus an empty default would read it as missing and then
    // write over it, deleting the key the merge could not understand. Only the four events this merge writes
    // are checked; an unrelated event of any shape is never read and round-trips.
    private static func claudeHooksObject(_ root: [String: Any]) throws -> [String: Any] {
        guard let value = root["hooks"] else { return [:] }
        guard let hooks = value as? [String: Any] else { throw MergeError.malformedExistingSettings }
        for hook in claudeHooks where hooks[hook.event] != nil {
            guard hooks[hook.event] is [[String: Any]] else { throw MergeError.malformedExistingSettings }
        }
        return hooks
    }

    private static func parsedObject(_ text: String?) throws -> [String: Any] {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard let data = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any] else {
            throw MergeError.malformedExistingSettings
        }
        return object
    }

    // serialize a dictionary to pretty-printed, sorted JSON text (deterministic for tests + diffs).
    private static func serialize(_ object: [String: Any]) -> String {
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: options),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text + "\n"
    }

    // single-quote a string for safe embedding in a /bin/sh command (mirrors CLIInstall.shellQuote).
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // quote a string as a TOML basic (double-quoted) string: escape backslash then double-quote so an
    // arbitrary shell command embeds safely as a config.toml value (the Codex hook `command` field).
    private static func tomlBasicString(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
