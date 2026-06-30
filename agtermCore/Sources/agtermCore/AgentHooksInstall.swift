import Foundation

/// Host-free helpers for installing the agent-status hooks package. Most are testable string/JSON
/// transforms — given the current file contents and the installed script directory they return the new
/// contents plus a `changed` flag, all idempotent. It also provides a small mode-preserving file write
/// (`writeFile`/`posixMode`) so rewriting a restrictive-mode file (e.g. a chmod-600 `settings.json`)
/// keeps its permissions instead of an atomic rename widening it to 0644. The app side still owns
/// copying the bundled scripts and resolving symlinks.
public enum AgentHooksInstall {
    /// The wrapper script the hooks invoke, installed into the script directory.
    public static let wrapperName = "agterm-agent-status.sh"

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
}
