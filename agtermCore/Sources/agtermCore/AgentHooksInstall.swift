import Foundation
import TOMLDecoder

/// Host-free helpers for installing the agent-status hooks package. Most are testable string/JSON/TOML
/// transforms — given the current file contents and the installed script directory they return the new
/// contents plus a `changed` flag, all idempotent. It also provides a small mode-preserving file write
/// (`writeFile`/`posixMode`) so rewriting a restrictive-mode file (e.g. a chmod-600 `settings.json`)
/// keeps its permissions instead of an atomic rename widening it to 0644. The app side still owns
/// copying the bundled scripts and resolving symlinks.
public enum AgentHooksInstall {
    /// The wrapper script the hooks invoke, installed into the script directory.
    public static let wrapperName = "agterm-agent-status.sh"

    /// Codex-specific lifecycle adapter installed beside the generic status wrapper. Agent-specific
    /// event and terminal-output knowledge stays in this hook resource, outside agterm's runtime.
    public static let codexWrapperName = "agterm-codex-status.sh"

    /// The shell integration script sourced from the user's rc files, relative to the script directory.
    public static let integrationRelativePath = "shell/integration.sh"

    /// The fish shell integration script sourced from the user's config.fish, relative to the script directory.
    public static let fishIntegrationRelativePath = "shell/integration.fish"

    /// Marker lines bracketing the agterm-managed block in a shell rc file. The opening marker is also
    /// the idempotency probe (present → already installed).
    public static let rcMarkerBegin = "# >>> agterm agent-status >>>"
    public static let rcMarkerEnd = "# <<< agterm agent-status <<<"

    /// The Claude Code hook events the merge installs, paired with the agent state (plus any flags)
    /// each maps to. `UserPromptSubmit` and `PostToolUse` both set `active`: the former on a new prompt,
    /// the latter after every tool runs so the status returns to `active` when work RESUMES after a
    /// `blocked` permission prompt (Claude Code has no "permission answered" event, and the gated tool's
    /// own `PreToolUse` already fired BEFORE `blocked` was set — so the approved tool's `PostToolUse` is
    /// the first hook to fire afterwards). `Notification` additionally carries the `permission_prompt`
    /// matcher (the others are unmatched). Only the `Stop`→`completed` hook passes `--auto-reset` (it
    /// clears on visit); `active` and `blocked` stay keep-state.
    static let claudeHooks: [(event: String, matcher: String?, state: String)] = [
        ("UserPromptSubmit", nil, "active --blink"),
        ("PostToolUse", nil, "active --blink"),
        ("Stop", nil, "completed --auto-reset"),
        ("Notification", "permission_prompt", "blocked"),
    ]

    /// Codex lifecycle events paired with actions understood by the installed Codex hook. The adapter,
    /// rather than agterm's runtime, owns the event-to-status behavior and Auto Review workaround.
    static let codexHooks: [(event: String, action: String)] = [
        ("SessionStart", "session-start"),
        ("UserPromptSubmit", "user-prompt-submit"),
        ("PreToolUse", "pre-tool-use"),
        ("PostToolUse", "post-tool-use"),
        ("PermissionRequest", "permission-request"),
        ("Stop", "stop"),
    ]

    /// Thrown by `mergeClaudeSettings` when the existing `settings.json` is non-empty but not a valid
    /// JSON object: the installer refuses to overwrite a hand-maintained file it cannot safely parse.
    public enum MergeError: Error { case malformedExistingSettings }

    /// merge the four agent-status hooks into an existing Claude Code `settings.json`.
    ///
    /// `existing` is the current file contents (nil or empty = no file yet); `scriptDir` is the
    /// directory the wrapper script was installed into. Returns the new JSON text and whether it
    /// differs from `existing`. Idempotent: when the agterm hooks (detected by the wrapper command)
    /// are already present, returns the input unchanged with `changed == false`. Unrelated hooks and
    /// keys are preserved; an absent/empty existing file starts from a fresh object, but a non-empty
    /// file that is not valid JSON throws `MergeError.malformedExistingSettings` so the caller can leave
    /// the user's hand-maintained file untouched rather than overwrite it.
    public static func mergeClaudeSettings(existing: String?, scriptDir: String) throws -> (json: String, changed: Bool) {
        let command = wrapperCommand(scriptDir: scriptDir)
        var root = try parsedObject(existing)

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var didChange = false
        for hook in claudeHooks {
            var entries = hooks[hook.event] as? [[String: Any]] ?? []
            if entries.contains(where: { entryUsesWrapper($0, scriptDir: scriptDir) }) {
                continue // already installed for this event
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
    /// `existing` is the rc file's current contents; `scriptDir` is the installed script directory.
    /// Returns the new contents and whether anything was appended. Idempotent: if the begin marker is
    /// already present the input is returned unchanged with `changed == false`.
    public static func appendShellRC(existing: String, scriptDir: String, scriptName: String = integrationRelativePath) -> (contents: String, changed: Bool) {
        if existing.contains(rcMarkerBegin) {
            return (existing, false) // already installed
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

    /// The result of merging the Codex hooks into `~/.codex/config.toml`, decided by parsing the existing
    /// file with `TOMLDecoder` before touching it.
    public enum CodexMergeOutcome: Equatable {
        /// The hooks block was added (and any stale `codex-notify.sh` notify line removed) — write `contents`.
        case merged(contents: String)
        /// The file already carries the current agterm hooks block — nothing to do.
        case unchanged
        /// The file already defines its OWN `hooks` — auto-appending ours would duplicate (array-of-tables
        /// form) or break (compact form) them, so the merge is skipped; surface `codexHooksBlock` for a
        /// manual merge.
        case hooksExist
        /// The existing file is not valid TOML — leave it untouched and surface the block for a manual add.
        case unparseable
    }

    /// merge the Codex lifecycle-status hooks into an existing `~/.codex/config.toml`.
    ///
    /// `existing` is the file's current contents (empty = no file yet); `scriptDir` is the installed
    /// script directory. The decision is made by PARSING `existing` with `TOMLDecoder` (a pure-Swift,
    /// spec-compliant parser) rather than string-matching, which is what keeps the merge safe:
    /// - marker already present → upgrade an older managed block to the current installed Codex adapter,
    ///   preserving Codex's trailing hook trust-state tables; otherwise `.unchanged`;
    /// - the file does not parse as TOML → `.unparseable` (never rewrite a file we can't understand);
    /// - the file already defines `hooks` → `.hooksExist` (appending ours would duplicate or break them);
    /// - otherwise → `.merged`, appending the marker-guarded `[[hooks.*]]` block (a new array-of-tables at
    ///   end-of-file, valid because we verified the file has no existing `hooks`) and removing a stale
    ///   top-level `notify` ONLY when its PARSED value points at the retired `codex-notify.sh` (so a
    ///   comment merely naming the file, or the user's own notifier, is never touched). The surgical
    ///   append/removal preserves the user's comments and layout.
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

        // strip a stale top-level `notify` ONLY when its PARSED value points at the retired codex-notify.sh.
        var text = existing
        if probe.notify.contains(where: { $0.contains("codex-notify.sh") }) {
            text = removeLegacyCodexNotify(from: text)
        }
        return .merged(contents: appendCodexBlock(to: text, scriptDir: scriptDir))
    }

    // the two top-level keys the merge cares about, decoded from an arbitrary config (Codable ignores
    // every other key). `hooksPresent` is a pure presence check across any hooks shape; `notify` is the
    // top-level notify program (array-of-argv, or a bare string) so the retired codex-notify.sh entry is
    // recognized by its PARSED value, not a fragile line match.
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

    // Replace only the generated definitions inside an existing managed block. Codex writes its
    // `[hooks.state...]` trust records at the end of config.toml, which lands inside our EOF marker;
    // retain that entire suffix. A coincidental marker block without one of our hook scripts is foreign
    // and remains untouched.
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

    // remove the retired single-line `notify = [...codex-notify.sh...]` assignment (only ever written by
    // the old installer in the single-line form). Restricted to the TOP-LEVEL region (above the first
    // table header) so a table-scoped notify is never touched, and to a line carrying codex-notify.sh in
    // its VALUE so a hand-authored multi-line array is left intact rather than half-removed (the caller
    // already confirmed via the parsed value that the stale entry exists).
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

    /// derive a backup path for a file by appending `.bak` to its full path. `settings.json` →
    /// `settings.json.bak`; the extension is left intact (the `.bak` is appended to the whole name).
    public static func backupPath(for path: String) -> String {
        path + ".bak"
    }

    /// the absolute wrapper-script path the installed hooks invoke, with state appended by the caller's
    /// hook entry. e.g. `<scriptDir>/agterm-agent-status.sh`.
    public static func wrapperPath(scriptDir: String) -> String {
        scriptDir + "/" + wrapperName
    }

    /// The absolute installed Codex lifecycle-adapter path.
    public static func codexWrapperPath(scriptDir: String) -> String {
        scriptDir + "/" + codexWrapperName
    }

    /// render the `~/.codex/config.toml` `[[hooks.*]]` block the installer merges into the user's config
    /// (or surfaces for a manual add when the file already has hooks or doesn't parse), wiring Codex's
    /// lifecycle events to the indicator. `scriptDir` is the installed script directory; the wrapper's
    /// absolute path is baked into each command — shell-quoted (so a path with spaces is one token)
    /// inside a TOML basic string — so the hook fires without the CLI on PATH.
    public static func codexHooksBlock(scriptDir: String) -> String {
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

    /// the POSIX permission bits of the file at `path`, or nil when the file is absent or its
    /// attributes can't be read. Used to capture a file's mode before a mode-preserving rewrite.
    public static func posixMode(ofFile path: String) -> NSNumber? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return attrs[.posixPermissions] as? NSNumber
    }

    /// write `text` to `path` atomically, then re-apply `posixMode` when non-nil so the rewrite keeps
    /// the original file's permissions. An atomic write renames a fresh 0644 temp over the target, which
    /// would otherwise widen a restrictive mode (e.g. a chmod-600 secret) to 0644; re-applying the
    /// captured mode restores it. A nil `posixMode` leaves the new file's default permissions untouched.
    public static func writeFile(_ text: String, toPath path: String, posixMode: NSNumber?) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        if let posixMode {
            try FileManager.default.setAttributes([.posixPermissions: posixMode], ofItemAtPath: path)
        }
    }

    // build the command string a Claude hook runs: the quoted wrapper path plus the state argument.
    private static func wrapperCommand(scriptDir: String) -> String {
        shellQuote(wrapperPath(scriptDir: scriptDir)) + " "
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

    // does a hook entry already invoke our wrapper (idempotency probe, by wrapper path)?
    private static func entryUsesWrapper(_ entry: [String: Any], scriptDir: String) -> Bool {
        let probe = wrapperPath(scriptDir: scriptDir)
        guard let commands = entry["hooks"] as? [[String: Any]] else { return false }
        return commands.contains { ($0["command"] as? String)?.contains(probe) == true }
    }

    // parse existing JSON into a dictionary. absent/empty/whitespace-only → fresh empty object; a
    // non-empty file that is not a valid JSON object → throw rather than silently discard the user's file.
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
