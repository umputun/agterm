import AppKit
import agtermCore

/// Installs the bundled agent-status hooks package into the user's home: copies the scripts from the
/// app bundle into `~/.config/agterm/agent-status/`, bakes the bundled `agtermctl`'s absolute path
/// into the wrapper, appends a marker-guarded `source` line to `~/.zshrc`, `~/.bashrc`, and `~/.config/fish/config.fish`, and merges
/// the three Claude Code hooks into `~/.claude/settings.json` (writing a `.bak` first). The Codex
/// `~/.codex/config.toml` line is printed for the user to add manually — never auto-edited. The
/// host-free string/JSON transforms live in `agtermCore.AgentHooksInstall`; this type owns the
/// AppKit filesystem glue. Idempotent and re-runnable: re-running refreshes the baked `agtermctl`
/// path (healing a moved/reinstalled bundle) and is a clean no-op for already-present rc/settings
/// entries.
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

    /// Run the install and show a result alert.
    static func run() {
        do {
            let settingsSkipped = try install()
            present(style: settingsSkipped ? .warning : .informational,
                    title: settingsSkipped ? "Agent Status Hooks Installed — with a warning" : "Agent Status Hooks Installed",
                    text: successText(settingsSkipped: settingsSkipped))
        } catch let error as InstallError {
            present(style: .warning, title: "Install Failed", text: error.message)
        } catch {
            present(style: .warning, title: "Install Failed", text: error.localizedDescription)
        }
    }

    // returns true if the Claude settings merge was SKIPPED because ~/.claude/settings.json isn't valid
    // JSON (it is left untouched); every other step still runs.
    private static func install() throws -> Bool {
        try copyBundledFolder()
        try bakeAgtermctlPath()
        let settingsSkipped = try mergeClaudeSettings()
        try appendShellRC()
        print("agterm agent-status: add this to ~/.codex/config.toml:\n\(codexNotifyLine)")
        return settingsSkipped
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

    // bake the bundled agtermctl's absolute path into the installed wrapper so the hook fires even when
    // the CLI was never symlinked into PATH. `[ -n "${AGTERMCTL:-}" ] || AGTERMCTL='<path>'` sets it only
    // when AGTERMCTL is unset, so an explicit env override still wins (resolution order 1 > 2 > PATH); the
    // path is single-quoted (shellQuote) so spaces / shell metacharacters in the bundle path are inert.
    // refreshed on every run: any prior baked block is stripped first, healing a moved bundle.
    private static func bakeAgtermctlPath() throws {
        guard let tool = bundledTool else { return } // no bundled CLI: leave the PATH fallback in place
        let wrapper = destinationFolder.appendingPathComponent(AgentHooksInstall.wrapperName)
        let original = try String(contentsOf: wrapper, encoding: .utf8)
        let stripped = stripBakedBlock(from: original)
        let block = agtermctlMarker + "\n[ -n \"${AGTERMCTL:-}\" ] || AGTERMCTL=\(AgentHooksInstall.shellQuote(tool.path))\n"
        let baked = insertAfterShebang(stripped, block: block)
        try writePreservingSymlink(baked, to: wrapper)
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

    // merge the three Claude Code hooks into ~/.claude/settings.json, writing a .bak first when the
    // merge changes anything. returns true if the merge was SKIPPED because the existing file is not
    // valid JSON (it is left untouched rather than overwritten).
    private static func mergeClaudeSettings() throws -> Bool {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let settings = claudeDir.appendingPathComponent("settings.json")
        let existing = try? String(contentsOf: settings, encoding: .utf8)
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

    // the `notify` line the user adds to ~/.codex/config.toml to wire Codex into the indicator.
    private static var codexNotifyLine: String {
        "notify = [\"\(destinationFolder.appendingPathComponent("codex-notify.sh").path)\"]"
    }

    // the success-alert text, including the Codex config.toml line to add manually. When the Claude
    // settings merge was skipped (invalid settings.json), explain that the file was left untouched.
    private static func successText(settingsSkipped: Bool) -> String {
        let claudeLine = settingsSkipped
            ? "Your ~/.claude/settings.json isn't valid JSON, so the Claude Code hooks were NOT added (the file was left untouched). Fix the JSON and run this again, or add the hooks manually."
            : "Claude Code hooks merged into ~/.claude/settings.json."
        return """
        Scripts installed to \(destinationFolder.path).
        \(claudeLine)
        The source line was added to ~/.zshrc, ~/.bashrc (and ~/.config/fish/config.fish if fish is installed).

        For Codex, add this line to ~/.codex/config.toml manually:
        \(codexNotifyLine)

        Open a new terminal for the shell integration to take effect.
        """
    }

    private static func present(style: NSAlert.Style, title: String, text: String) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
