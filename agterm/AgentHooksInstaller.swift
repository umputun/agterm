import AppKit
import agtermCore

/// Installs the bundled agent-status hooks package into the user's home: the scripts into
/// `~/.config/agterm/agent-status/`, the bundled `agtermctl`'s absolute path baked into the wrapper, a
/// marker-guarded `source` line in `~/.zshrc`/`~/.bashrc`/`~/.config/fish/config.fish`, the four Claude Code
/// hooks merged into `~/.claude/settings.json`, the six Codex lifecycle hooks into `~/.codex/config.toml`,
/// and — when each is configured — Pi's lifecycle extension into `~/.pi/agent/extensions/` and OpenCode's
/// plugin into `~/.config/opencode/plugins/`. Claude/Codex configs get a `.bak` first; the Codex step parses
/// TOML and points at the docs for a manual merge when that file already has hooks or does not parse. The
/// host-free string/JSON/TOML transforms and the Pi/OpenCode ownership policy live in
/// `agtermCore.AgentHooksInstall`; this type owns the AppKit filesystem glue. Idempotent: a re-run refreshes
/// the baked `agtermctl` path (healing a moved bundle) and no-ops on already-present entries.
@MainActor
enum AgentHooksInstaller {
    private struct InstallError: Error { let message: String }

    /// The bundled `Contents/Resources/agent-status`, nil when the build skipped bundling (a bare
    /// `swift build`).
    private static var bundledFolder: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("agent-status")
    }

    /// The bundled `agtermctl` at `Contents/MacOS/agtermctl`, or nil when this build skipped bundling.
    private static var bundledTool: URL? { Bundle.main.url(forAuxiliaryExecutable: CLIInstall.toolName) }

    private static var destinationFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/agterm/agent-status")
    }

    // the outcome of the Codex config.toml merge, decided by parsing the existing file.
    enum CodexResult {
        case merged, alreadyConfigured, hooksExist, unparseable, unreadable, noCodex

        // warning: agterm could not auto-merge and the user must act (add the block by hand, or fix config).
        var isWarning: Bool {
            switch self {
            case .hooksExist, .unparseable, .unreadable: return true
            case .merged, .alreadyConfigured, .noCodex: return false
            }
        }

        // the two outcomes whose alert text sends the user to the docs for the block to paste in by hand.
        var needsManualMerge: Bool {
            switch self {
            case .hooksExist, .unparseable: return true
            case .merged, .alreadyConfigured, .unreadable, .noCodex: return false
            }
        }
    }

    // the Pi extension-install outcome, mirroring CodexResult.
    private enum PiResult {
        case installed, alreadyConfigured, userOwned, unreadable, writeFailed, noPi

        // warning: the user must act (move the user-owned file, or fix the unreadable/unwritable path).
        var isWarning: Bool {
            switch self {
            case .userOwned, .unreadable, .writeFailed: return true
            case .installed, .alreadyConfigured, .noPi: return false
            }
        }
    }

    // OpenCode plugin-install outcome (same shape as Pi; host term is plugin, not extension).
    private enum OpenCodeResult {
        case installed, alreadyConfigured, userOwned, unreadable, writeFailed, noOpenCode

        var isWarning: Bool {
            switch self {
            case .userOwned, .unreadable, .writeFailed: return true
            case .installed, .alreadyConfigured, .noOpenCode: return false
            }
        }
    }

    // aggregates per-integration outcomes so `install()` stays under the large_tuple lint (max 3 members).
    private struct InstallOutcome {
        let settingsSkipped: Bool
        let codex: CodexResult
        let pi: PiResult
        let opencode: OpenCodeResult

        var isWarning: Bool {
            settingsSkipped || codex.isWarning || pi.isWarning || opencode.isWarning
        }
    }

    /// Run the install and show a result alert.
    static func run() {
        do {
            let outcome = try install()
            present(style: outcome.isWarning ? .warning : .informational,
                    title: outcome.isWarning ? "Agent Status Hooks Installed — with a warning" : "Agent Status Hooks Installed",
                    text: successText(outcome),
                    docs: outcome.codex.needsManualMerge ? codexManualDocsURL : nil)
        } catch let error as InstallError {
            present(style: .warning, title: "Install Failed", text: error.message)
        } catch {
            present(style: .warning, title: "Install Failed", text: error.localizedDescription)
        }
    }

    // every step runs regardless of an earlier one's outcome; each reports its own result.
    private static func install() throws -> InstallOutcome {
        try copyBundledFolder()
        try bakeAgtermctlPath()
        let settingsSkipped = try mergeClaudeSettings()
        try appendShellRC()
        let codex = try mergeCodexConfig()
        let pi = try installPiExtension()
        let opencode = try installOpenCodePlugin()
        return InstallOutcome(settingsSkipped: settingsSkipped, codex: codex, pi: pi, opencode: opencode)
    }

    private static func copyBundledFolder() throws {
        guard let source = bundledFolder, FileManager.default.fileExists(atPath: source.path) else {
            throw InstallError(message: "The agent-status scripts are not bundled in this build.")
        }
        let fm = FileManager.default
        let destination = destinationFolder
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: destination) // drop a prior install so copy can't collide
        try fm.copyItem(at: source, to: destination)
    }

    // bake the bundled agtermctl's absolute path into the installed wrappers so the hooks fire even when the
    // CLI was never symlinked into PATH. The transform itself is host-free in `AgentHooksInstall`.
    // `claudeWrapperName` is deliberately absent: the Claude adapter never calls agtermctl, it `exec`s the
    // generic wrapper — which carries the baked path — so there is nothing to bake into it.
    private static func bakeAgtermctlPath() throws {
        guard let tool = bundledTool else { return } // no bundled CLI: leave the PATH fallback in place
        for name in [AgentHooksInstall.wrapperName, AgentHooksInstall.codexWrapperName] {
            let wrapper = destinationFolder.appendingPathComponent(name)
            let original = try String(contentsOf: wrapper, encoding: .utf8)
            let baked = AgentHooksInstall.bakeAgtermctlPath(into: original, toolPath: tool.path)
            try writePreservingSymlink(baked, to: wrapper)
        }
    }

    // write text PRESERVING an existing symlink: a dotfiles-managed link (`~/.claude/settings.json`,
    // `~/.zshrc`) is written through to its resolved target, since an atomic rename would replace the link
    // with a regular file. `posixMode` applies to that target, so a chmod-600 file isn't widened.
    private static func writePreservingSymlink(_ text: String, to url: URL, posixMode: NSNumber? = nil) throws {
        let target = symlinkTarget(of: url) ?? url
        try AgentHooksInstall.writeFile(text, toPath: target.path, posixMode: posixMode)
    }

    // the resolved target if `url` is itself a symlink (chain followed), else nil. detection uses
    // `attributesOfItem`, which does NOT follow the final link.
    private static func symlinkTarget(of url: URL) -> URL? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attrs[.type] as? FileAttributeType) == .typeSymbolicLink else { return nil }
        return url.resolvingSymlinksInPath()
    }

    // read an existing config file: nil when ABSENT (a fresh install), the contents when readable, a thrown
    // `UnreadableExisting` when it EXISTS but can't be read (permission / non-UTF8) — so callers leave it
    // untouched instead of clobbering it with no backup.
    private struct UnreadableExisting: Error {}
    private static func readExistingConfig(at url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw UnreadableExisting()
        }
    }

    // merge the four Claude Code hooks into ~/.claude/settings.json, writing a .bak first when anything
    // changes. returns true when the merge was SKIPPED (invalid JSON, or unreadable) and the file left as is.
    private static func mergeClaudeSettings() throws -> Bool {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let settings = claudeDir.appendingPathComponent("settings.json")
        let existing: String?
        do {
            existing = try readExistingConfig(at: settings)
        } catch {
            return true // unreadable: leave it untouched rather than clobber it with no backup
        }
        let merged: (json: String, changed: Bool)
        do {
            merged = try AgentHooksInstall.mergeClaudeSettings(existing: existing, scriptDir: destinationFolder.path)
        } catch AgentHooksInstall.MergeError.malformedExistingSettings {
            return true // invalid JSON: leave the user's file untouched
        }
        guard merged.changed else { return false }
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        // resolve the symlink target FIRST (a dotfiles-managed link must survive) and read its mode once, so
        // the rewrite AND the .bak inherit it instead of an atomic rename widening a chmod-600 file to 0644.
        let target = symlinkTarget(of: settings) ?? settings
        let mode = AgentHooksInstall.posixMode(ofFile: target.path)
        if let existing { // back up before overwriting, with the source's mode
            // keep the .bak beside the symlink, NOT the resolved target — that resolves into a git-tracked
            // dotfiles dir we must not litter; only the MODE comes from the target.
            let backup = AgentHooksInstall.backupPath(for: settings.path)
            try AgentHooksInstall.writeFile(existing, toPath: backup, posixMode: mode)
        }
        try writePreservingSymlink(merged.json, to: settings, posixMode: mode)
        return false
    }

    // append the marker-guarded source line to ~/.zshrc, ~/.bashrc, ~/.config/fish/config.fish (idempotent).
    private static func appendShellRC() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for name in [".zshrc", ".bashrc", ".config/fish/config.fish"] {
            let rc = home.appendingPathComponent(name)
            if name.hasSuffix(".fish") {
                // only touch config.fish when the user already has a ~/.config/fish directory
                guard FileManager.default.fileExists(atPath: rc.deletingLastPathComponent().path) else { continue }
            }
            let existing = (try? String(contentsOf: rc, encoding: .utf8)) ?? ""
            let scriptName = name.hasSuffix(".fish") ? AgentHooksInstall.fishIntegrationRelativePath : AgentHooksInstall.integrationRelativePath
            let result = AgentHooksInstall.appendShellRC(existing: existing, scriptDir: destinationFolder.path, scriptName: scriptName)
            guard result.changed else { continue }
            try writePreservingSymlink(result.contents, to: rc)
        }
    }

    // install Pi's auto-discovered global extension only when Pi has already created ~/.pi/agent. an UNMARKED
    // same-named extension is user-owned and left untouched; a marked one refreshes from the copied package.
    // no backup, unlike the Claude/Codex configs: the extension carries no user state.
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
        // nil = absent, throw = exists-but-unreadable (folded to .unreadable): reusing readExistingConfig
        // stops a non-ENOENT stat error masquerading as "absent" and slipping past the ownership-marker gate.
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

        // a filesystem error degrades to a warning like every sibling integration, rather than aborting the
        // whole install and hiding that the Claude/Codex/shell steps ran.
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

    // install OpenCode's auto-discovered global plugin only when ~/.config/opencode exists. same ownership /
    // degrade-to-warning policy as Pi, and no backup.
    private static func installOpenCodePlugin() throws -> OpenCodeResult {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let opencodeDirectory = home.appendingPathComponent(".config/opencode")
        guard fm.fileExists(atPath: opencodeDirectory.path) else { return .noOpenCode }

        let source = destinationFolder.appendingPathComponent(AgentHooksInstall.opencodePluginRelativePath)
        guard fm.fileExists(atPath: source.path) else {
            throw InstallError(message: "The OpenCode status plugin is not bundled in this build.")
        }
        let sourceContents = try String(contentsOf: source, encoding: .utf8)
        guard sourceContents.contains(AgentHooksInstall.opencodePluginMarker) else {
            throw InstallError(message: "The bundled OpenCode status plugin is missing its ownership marker.")
        }

        let destination = URL(fileURLWithPath: AgentHooksInstall.opencodePluginPath(home: home.path))
        let existing: String?
        do {
            existing = try readExistingConfig(at: destination)
        } catch {
            return .unreadable
        }
        guard AgentHooksInstall.mayOverwriteOpenCodePlugin(fileExists: existing != nil, existingContents: existing) else {
            return .userOwned
        }
        guard existing != sourceContents else { return .alreadyConfigured }

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

    // merge the Codex lifecycle hooks into ~/.codex/config.toml, writing a .bak first when anything changes.
    // gated on ~/.codex existing so a non-Codex home isn't seeded with a config.toml. the host-free
    // `AgentHooksInstall.mergeCodexConfig` PARSES the file and decides the outcome; this only reads/writes.
    private static func mergeCodexConfig() throws -> CodexResult {
        let codexDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        guard FileManager.default.fileExists(atPath: codexDir.path) else { return .noCodex }
        let config = codexDir.appendingPathComponent("config.toml")
        let existing: String?
        do {
            existing = try readExistingConfig(at: config)
        } catch {
            return .unreadable // unreadable: leave it untouched rather than clobber it
        }
        switch AgentHooksInstall.mergeCodexConfig(existing: existing ?? "", scriptDir: destinationFolder.path) {
        case .unchanged:
            return .alreadyConfigured
        case .hooksExist:
            return .hooksExist
        case .unparseable:
            return .unparseable
        case .merged(let contents):
            // same symlink-target-then-mode handling as mergeClaudeSettings.
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

    // the success-alert text, calling out anything an integration could not safely update and left alone.
    private static func successText(_ outcome: InstallOutcome) -> String {
        let claudeLine = outcome.settingsSkipped
            ? "Your ~/.claude/settings.json isn't valid JSON (or couldn't be read), so the Claude Code hooks were NOT added "
              + "(the file was left untouched). Fix it and run this again, or add the hooks manually."
            : "Claude Code hooks merged into ~/.claude/settings.json."
        return """
        Scripts installed to \(destinationFolder.path).
        \(claudeLine)
        \(codexText(outcome.codex))
        \(piText(outcome.pi))
        \(opencodeText(outcome.opencode))
        The source line was added to ~/.zshrc, ~/.bashrc (and ~/.config/fish/config.fish if fish is installed).

        Open a new terminal for the shell integration to take effect.
        """
    }

    // the Codex portion of the alert. Every case stays one line and embeds no generated block: NSAlert sizes
    // itself to fit `informativeText` with no scroll and no cap, so the hooks block's long `command =` lines
    // wrapped several times each and grew the window past the bottom of a laptop screen (#430). Sentence
    // count is not the constraint — the two manual-merge cases send the user to the docs instead.
    static func codexText(_ codex: CodexResult) -> String {
        let approve = "Run /hooks in Codex to review and approve them before they take effect."
        let manual = "See the Add Codex hooks by hand section of the agterm docs for the block to add, then run /hooks in Codex."
        switch codex {
        case .merged:
            return "Codex lifecycle hooks merged into ~/.codex/config.toml (any old codex-notify.sh notify line was removed). " + approve
        case .alreadyConfigured:
            return "Codex lifecycle hooks are already present in ~/.codex/config.toml. " + approve
        case .hooksExist:
            return "Your ~/.codex/config.toml already defines its own hooks, so agterm left it untouched. " + manual
        case .unparseable:
            return "Your ~/.codex/config.toml isn't valid TOML, so agterm left it untouched. Fix it and run this again. " + manual
        case .unreadable:
            return "Your ~/.codex/config.toml exists but couldn't be read, so agterm left it untouched."
        case .noCodex:
            return "No ~/.codex found, so Codex hooks were skipped. Install Codex, then run this again."
        }
    }

    // Pi's extension-install outcome. Pi extensions auto-discover on the next startup or `/reload`.
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

    // OpenCode's plugin-install outcome. plugins load on the next OpenCode start.
    private static func opencodeText(_ opencode: OpenCodeResult) -> String {
        switch opencode {
        case .installed:
            return "OpenCode lifecycle plugin installed to ~/.config/opencode/plugins/agterm-status.js. Restart OpenCode."
        case .alreadyConfigured:
            return "OpenCode lifecycle plugin is already current at ~/.config/opencode/plugins/agterm-status.js."
        case .userOwned:
            return "~/.config/opencode/plugins/agterm-status.js is user-owned, so agterm left it untouched."
        case .unreadable:
            return "~/.config/opencode/plugins/agterm-status.js exists but could not be read, so agterm left it untouched."
        case .writeFailed:
            return "OpenCode's lifecycle plugin couldn't be written to ~/.config/opencode/plugins/ (check that directory's permissions), so it was skipped."
        case .noOpenCode:
            return "No ~/.config/opencode found, so OpenCode's lifecycle plugin was skipped. "
                + "Coarse shell detection for opencode is off by default — status comes from the lifecycle plugin "
                + "once ~/.config/opencode exists. Start OpenCode once, then run this again."
        }
    }

    /// The docs anchor covering a manual Codex hooks merge, opened by the alert's second button. An NSAlert
    /// renders `informativeText` as plain, unselectable text, so a printed URL would have to be retyped.
    static let codexManualDocsURL = URL(string: "https://agterm.com/docs#codex-hooks-manual")

    /// The result alert, with a second button when `docs` is set. Split out of `present()` so a hosted test
    /// can check the buttons without running a modal.
    static func makeAlert(style: NSAlert.Style, title: String, text: String, docs: URL?) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = text
        if docs != nil {
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Open Docs")
        }
        return alert
    }

    private static func present(style: NSAlert.Style, title: String, text: String, docs: URL? = nil) {
        let alert = makeAlert(style: style, title: title, text: text, docs: docs)
        guard alert.runModal() == .alertSecondButtonReturn, let docs else { return }
        NSWorkspace.shared.open(docs)
    }
}
