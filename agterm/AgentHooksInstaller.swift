import AppKit
import agtermCore

/// Installs the bundled agent-status hooks package into the user's home: copies the scripts from the
/// app bundle into `~/.config/agterm/agent-status/`, bakes the bundled `agtermctl`'s absolute path
/// into the wrapper, appends a marker-guarded `source` line to `~/.zshrc`, `~/.bashrc`, and `~/.config/fish/config.fish`, merges
/// the four Claude Code hooks into `~/.claude/settings.json`, merges the six Codex lifecycle hooks into
/// `~/.codex/config.toml`, and installs Pi's lifecycle extension into `~/.pi/agent/extensions/` when Pi
/// is configured. Claude/Codex configs write a `.bak` first; the Codex step parses TOML and falls back to
/// surfacing a manual block when the file already has hooks or does not parse. The host-free string/JSON/
/// TOML transforms and Pi ownership policy live in `agtermCore.AgentHooksInstall`; this type owns the
/// AppKit filesystem glue.
/// Idempotent and re-runnable: re-running refreshes the baked `agtermctl` path (healing a
/// moved/reinstalled bundle) and is a clean no-op for already-present rc/settings/config entries.
@MainActor
enum AgentHooksInstaller {
    private struct InstallError: Error { let message: String }

    /// The bundled source folder at `Contents/Resources/agent-status`, or nil when this build skipped
    /// the resource bundling (e.g. a bare `swift build`).
    private static var bundledFolder: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("agent-status")
    }

    /// The bundled `agtermctl` at `Contents/MacOS/agtermctl`, or nil when this build skipped bundling.
    private static var bundledTool: URL? { Bundle.main.url(forAuxiliaryExecutable: CLIInstall.toolName) }

    /// The install destination, `~/.config/agterm/agent-status/`.
    private static var destinationFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/agterm/agent-status")
    }

    // the outcome of the Codex config.toml merge, decided by parsing the existing file.
    private enum CodexResult {
        case merged, alreadyConfigured, hooksExist, unparseable, unreadable, noCodex

        // a warning-level outcome: agterm could not auto-merge and the user must act (add the block by
        // hand, or fix/inspect their config). merged/already/noCodex are informational.
        var isWarning: Bool {
            switch self {
            case .hooksExist, .unparseable, .unreadable: return true
            case .merged, .alreadyConfigured, .noCodex: return false
            }
        }
    }

    // the Pi extension-install outcome, mirroring CodexResult: installed/alreadyConfigured/noPi are
    // informational; the warning cases mean agterm could not safely write and left the destination as-is.
    private enum PiResult {
        case installed, alreadyConfigured, userOwned, unreadable, writeFailed, noPi

        // a warning-level outcome: agterm could not update the extension and the user must act (move the
        // user-owned file, or fix the unreadable/unwritable path). installed/already/noPi are informational.
        var isWarning: Bool {
            switch self {
            case .userOwned, .unreadable, .writeFailed: return true
            case .installed, .alreadyConfigured, .noPi: return false
            }
        }
    }

    /// Run the install and show a result alert.
    static func run() {
        do {
            let outcome = try install()
            let warned = outcome.settingsSkipped || outcome.codex.isWarning || outcome.pi.isWarning
            present(style: warned ? .warning : .informational,
                    title: warned ? "Agent Status Hooks Installed — with a warning" : "Agent Status Hooks Installed",
                    text: successText(settingsSkipped: outcome.settingsSkipped, codex: outcome.codex, pi: outcome.pi))
        } catch let error as InstallError {
            present(style: .warning, title: "Install Failed", text: error.message)
        } catch {
            present(style: .warning, title: "Install Failed", text: error.localizedDescription)
        }
    }

    // settingsSkipped is true when the Claude settings merge was SKIPPED because ~/.claude/settings.json
    // isn't valid JSON or couldn't be read (it is left untouched); codex and pi report their respective
    // integration outcomes. Every step still runs regardless.
    private static func install() throws -> (settingsSkipped: Bool, codex: CodexResult, pi: PiResult) {
        try copyBundledFolder()
        try bakeAgtermctlPath()
        let settingsSkipped = try mergeClaudeSettings()
        try appendShellRC()
        let codex = try mergeCodexConfig()
        let pi = try installPiExtension()
        return (settingsSkipped, codex, pi)
    }

    // copy the bundled agent-status folder into ~/.config/agterm/agent-status, overwriting any prior
    // install so a re-run is clean.
    private static func copyBundledFolder() throws {
        guard let source = bundledFolder, FileManager.default.fileExists(atPath: source.path) else {
            throw InstallError(message: "The agent-status scripts are not bundled in this build.")
        }
        let fm = FileManager.default
        let destination = destinationFolder
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: destination) // drop a prior install (ignore if absent) so copy can't collide
        try fm.copyItem(at: source, to: destination)
    }

    // the sentinel line marking the installer-baked AGTERMCTL default in the wrapper; a re-run finds
    // and replaces it so the path is refreshed rather than duplicated.
    private static let agtermctlMarker = "# >>> agterm agtermctl path (installer-baked) >>>"

    // bake the bundled agtermctl's absolute path into the installed wrappers so the hooks fire even when
    // the CLI was never symlinked into PATH. `[ -n "${AGTERMCTL:-}" ] || AGTERMCTL='<path>'` sets it only
    // when AGTERMCTL is unset, so an explicit env override still wins (resolution order 1 > 2 > PATH); the
    // path is single-quoted (shellQuote) so spaces / shell metacharacters in the bundle path are inert.
    // refreshed on every run: any prior baked block is stripped first, healing a moved bundle.
    private static func bakeAgtermctlPath() throws {
        guard let tool = bundledTool else { return } // no bundled CLI: leave the PATH fallback in place
        for name in [AgentHooksInstall.wrapperName, AgentHooksInstall.codexWrapperName] {
            let wrapper = destinationFolder.appendingPathComponent(name)
            let original = try String(contentsOf: wrapper, encoding: .utf8)
            let stripped = stripBakedBlock(from: original)
            let block = agtermctlMarker + "\n[ -n \"${AGTERMCTL:-}\" ] || AGTERMCTL=\(AgentHooksInstall.shellQuote(tool.path))\n"
            let baked = insertAfterShebang(stripped, block: block)
            try writePreservingSymlink(baked, to: wrapper)
        }
    }

    // remove a previously baked AGTERMCTL block (the marker line plus the assignment line under it).
    private static func stripBakedBlock(from text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var result: [String] = []
        var skip = 0
        for line in lines {
            if skip > 0 { skip -= 1; continue }
            if line == agtermctlMarker { skip = 1; continue } // drop the marker and the assignment below it
            result.append(line)
        }
        return result.joined(separator: "\n")
    }

    // insert the baked block right after the shebang (or at the top when there is none).
    private static func insertAfterShebang(_ text: String, block: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let insertAt = lines.first?.hasPrefix("#!") == true ? 1 : 0
        lines.insert(contentsOf: block.components(separatedBy: "\n").dropLast(), at: insertAt)
        return lines.joined(separator: "\n")
    }

    // write text to a path, PRESERVING an existing symlink: when the path is a symlink (e.g. a
    // dotfiles-managed `~/.claude/settings.json` or `~/.zshrc`), write atomically to its resolved
    // target so the symlink and the user's dotfiles stay intact, instead of an atomic rename
    // replacing the symlink with a standalone regular file. when `posixMode` is non-nil the resolved
    // target inherits that mode so a restrictive (chmod-600) file isn't widened by the atomic rewrite.
    private static func writePreservingSymlink(_ text: String, to url: URL, posixMode: NSNumber? = nil) throws {
        let target = symlinkTarget(of: url) ?? url
        try AgentHooksInstall.writeFile(text, toPath: target.path, posixMode: posixMode)
    }

    // the resolved target if `url` itself is a symlink (following a chain), else nil. Uses
    // `attributesOfItem` (which does NOT follow the final link) to detect the symlink.
    private static func symlinkTarget(of url: URL) -> URL? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attrs[.type] as? FileAttributeType) == .typeSymbolicLink else { return nil }
        return url.resolvingSymlinksInPath()
    }

    // read an existing config file's contents. Returns nil when the file is ABSENT (a fresh install);
    // the raw contents when present and readable; and THROWS `UnreadableExisting` when the file EXISTS
    // but cannot be read (permission / non-UTF8), so callers leave it untouched instead of clobbering it
    // with no backup — the destructive path that `(try? String(contentsOf:)) ?? ""` silently took.
    private struct UnreadableExisting: Error {}
    private static func readExistingConfig(at url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw UnreadableExisting()
        }
    }

    // merge the four Claude Code hooks into ~/.claude/settings.json, writing a .bak first when the
    // merge changes anything. returns true if the merge was SKIPPED because the existing file is not
    // valid JSON, or exists but can't be read (it is left untouched rather than overwritten).
    private static func mergeClaudeSettings() throws -> Bool {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let settings = claudeDir.appendingPathComponent("settings.json")
        let existing: String?
        do {
            existing = try readExistingConfig(at: settings)
        } catch {
            return true // exists but unreadable: leave it untouched rather than clobber it with no backup
        }
        let merged: (json: String, changed: Bool)
        do {
            merged = try AgentHooksInstall.mergeClaudeSettings(existing: existing, scriptDir: destinationFolder.path)
        } catch AgentHooksInstall.MergeError.malformedExistingSettings {
            return true // invalid settings.json: leave it untouched rather than overwrite the user's file
        }
        guard merged.changed else { return false }
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        // resolve the symlink target FIRST (so a dotfiles-managed settings.json link survives) and read
        // its mode once, so the rewrite AND the .bak inherit the original (possibly chmod-600) mode
        // instead of an atomic rename widening a secret file to 0644.
        let target = symlinkTarget(of: settings) ?? settings
        let mode = AgentHooksInstall.posixMode(ofFile: target.path)
        if let existing { // back up the prior file before overwriting it, with the source's mode
            // keep the .bak next to ~/.claude/settings.json (the symlink), NOT next to the resolved
            // target — a dotfiles-managed link resolves into a git-tracked dir we must not litter; only
            // the MODE comes from the resolved target.
            let backup = AgentHooksInstall.backupPath(for: settings.path)
            try AgentHooksInstall.writeFile(existing, toPath: backup, posixMode: mode)
        }
        try writePreservingSymlink(merged.json, to: settings, posixMode: mode)
        return false
    }

    // append the marker-guarded source line to ~/.zshrc, ~/.bashrc, and ~/.config/fish/config.fish (idempotent per file).
    private static func appendShellRC() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for name in [".zshrc", ".bashrc", ".config/fish/config.fish"] {
            let rc = home.appendingPathComponent(name)
            if name.hasSuffix(".fish") {
                // Only create/append to config.fish if the user already has a ~/.config/fish directory
                guard FileManager.default.fileExists(atPath: rc.deletingLastPathComponent().path) else { continue }
            }
            let existing = (try? String(contentsOf: rc, encoding: .utf8)) ?? ""
            let scriptName = name.hasSuffix(".fish") ? AgentHooksInstall.fishIntegrationRelativePath : AgentHooksInstall.integrationRelativePath
            let result = AgentHooksInstall.appendShellRC(existing: existing, scriptDir: destinationFolder.path, scriptName: scriptName)
            guard result.changed else { continue }
            try writePreservingSymlink(result.contents, to: rc)
        }
    }

    // Install Pi's auto-discovered global extension only when Pi has already created ~/.pi/agent. A
    // same-named, unmarked extension is user-owned and left untouched; an agterm-managed one refreshes
    // from the newly copied package. Pi has no config merge, and its extension carries no user state, so
    // unlike Claude/Codex config we do not create a backup for a managed refresh.
    private static func installPiExtension() throws -> PiResult {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let piAgentDirectory = home.appendingPathComponent(".pi/agent")
        guard fm.fileExists(atPath: piAgentDirectory.path) else { return .noPi }

        let source = destinationFolder.appendingPathComponent(AgentHooksInstall.piExtensionRelativePath)
        guard fm.fileExists(atPath: source.path) else {
            throw InstallError(message: "The Pi status extension is not bundled in this build.")
        }
        let sourceContents = try String(contentsOf: source, encoding: .utf8)
        guard sourceContents.contains(AgentHooksInstall.piExtensionMarker) else {
            throw InstallError(message: "The bundled Pi status extension is missing its ownership marker.")
        }

        let destination = URL(fileURLWithPath: AgentHooksInstall.piExtensionPath(home: home.path))
        // read the destination the same way the Claude/Codex merges read their configs: nil = absent,
        // throw = exists-but-unreadable (folded to .unreadable). Reusing readExistingConfig means a
        // non-ENOENT stat error can't masquerade as "absent" and slip past the ownership-marker gate.
        let existing: String?
        do {
            existing = try readExistingConfig(at: destination)
        } catch {
            return .unreadable
        }
        guard AgentHooksInstall.mayOverwritePiExtension(fileExists: existing != nil, existingContents: existing) else {
            return .userOwned
        }
        guard existing != sourceContents else { return .alreadyConfigured }

        // a filesystem error on ~/.pi/agent/extensions degrades to a warning like every sibling
        // integration, rather than throwing and aborting the whole install (which would hide that the
        // Claude/Codex/shell steps already ran).
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let target = symlinkTarget(of: destination) ?? destination
            let mode = AgentHooksInstall.posixMode(ofFile: target.path)
            try writePreservingSymlink(sourceContents, to: destination, posixMode: mode)
        } catch {
            return .writeFailed
        }
        return .installed
    }

    // merge the Codex lifecycle hooks into ~/.codex/config.toml, writing a .bak first when the merge
    // changes anything. Gated on ~/.codex existing (like the fish rc gate) so a non-Codex user's home
    // isn't seeded with a config.toml. The host-free `AgentHooksInstall.mergeCodexConfig` PARSES the file
    // to decide the outcome; this method only reads/writes and maps the outcome to a `CodexResult`.
    private static func mergeCodexConfig() throws -> CodexResult {
        let codexDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        guard FileManager.default.fileExists(atPath: codexDir.path) else { return .noCodex }
        let config = codexDir.appendingPathComponent("config.toml")
        let existing: String?
        do {
            existing = try readExistingConfig(at: config)
        } catch {
            return .unreadable // exists but unreadable: leave it untouched rather than clobber it
        }
        switch AgentHooksInstall.mergeCodexConfig(existing: existing ?? "", scriptDir: destinationFolder.path) {
        case .unchanged:
            return .alreadyConfigured
        case .hooksExist:
            return .hooksExist
        case .unparseable:
            return .unparseable
        case .merged(let contents):
            // resolve the symlink target FIRST (so a dotfiles-managed config.toml link survives) and read
            // its mode once, so the rewrite AND the .bak inherit the original mode instead of widening it.
            let target = symlinkTarget(of: config) ?? config
            let mode = AgentHooksInstall.posixMode(ofFile: target.path)
            if let existing, !existing.isEmpty { // back up the prior file before overwriting it
                let backup = AgentHooksInstall.backupPath(for: config.path)
                try AgentHooksInstall.writeFile(existing, toPath: backup, posixMode: mode)
            }
            try writePreservingSymlink(contents, to: config, posixMode: mode)
            return .merged
        }
    }

    // the success-alert text. Explains what was left out when the Claude settings merge was skipped, or
    // when the Codex/Pi integrations could not safely update a user-owned or unreadable file.
    private static func successText(settingsSkipped: Bool, codex: CodexResult, pi: PiResult) -> String {
        let claudeLine = settingsSkipped
            ? "Your ~/.claude/settings.json isn't valid JSON (or couldn't be read), so the Claude Code hooks were NOT added "
              + "(the file was left untouched). Fix it and run this again, or add the hooks manually."
            : "Claude Code hooks merged into ~/.claude/settings.json."
        return """
        Scripts installed to \(destinationFolder.path).
        \(claudeLine)
        \(codexText(codex))
        \(piText(pi))
        The source line was added to ~/.zshrc, ~/.bashrc (and ~/.config/fish/config.fish if fish is installed).

        Open a new terminal for the shell integration to take effect.
        """
    }

    // the Codex portion of the alert, per merge outcome. The hooks-exist and unparseable cases include
    // the block so the user can add it by hand.
    private static func codexText(_ codex: CodexResult) -> String {
        let approve = "Run /hooks in Codex to review and approve them before they take effect."
        switch codex {
        case .merged:
            return "Codex lifecycle hooks merged into ~/.codex/config.toml (any old codex-notify.sh notify line was removed). " + approve
        case .alreadyConfigured:
            return "Codex lifecycle hooks are already present in ~/.codex/config.toml. " + approve
        case .hooksExist:
            return "Your ~/.codex/config.toml already defines its own hooks, so agterm left it untouched. "
                + "Add these lifecycle hooks yourself, then run /hooks in Codex:\n\n" + codexBlock
        case .unparseable:
            return "Your ~/.codex/config.toml isn't valid TOML, so agterm left it untouched. "
                + "Fix it, or add these lifecycle hooks yourself, then run /hooks in Codex:\n\n" + codexBlock
        case .unreadable:
            return "Your ~/.codex/config.toml exists but couldn't be read, so agterm left it untouched."
        case .noCodex:
            return "No ~/.codex found, so Codex hooks were skipped. Install Codex, then run this again."
        }
    }

    // Describe Pi's extension-install outcome. Pi extensions auto-discover on the next startup or `/reload`.
    private static func piText(_ pi: PiResult) -> String {
        switch pi {
        case .installed:
            return "Pi lifecycle extension installed to ~/.pi/agent/extensions/agterm-status.ts. Restart Pi or run /reload."
        case .alreadyConfigured:
            return "Pi lifecycle extension is already current at ~/.pi/agent/extensions/agterm-status.ts."
        case .userOwned:
            return "~/.pi/agent/extensions/agterm-status.ts is user-owned, so agterm left it untouched."
        case .unreadable:
            return "~/.pi/agent/extensions/agterm-status.ts exists but could not be read, so agterm left it untouched."
        case .writeFailed:
            return "Pi's lifecycle extension couldn't be written to ~/.pi/agent/extensions/ (check that directory's permissions), so it was skipped."
        case .noPi:
            return "No ~/.pi/agent found, so Pi's lifecycle extension was skipped. Start Pi once, then run this again."
        }
    }

    // the Codex lifecycle-hooks block, for the alert's manual-add fallback cases.
    private static var codexBlock: String {
        AgentHooksInstall.codexHooksBlock(scriptDir: destinationFolder.path)
    }

    private static func present(style: NSAlert.Style, title: String, text: String) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
