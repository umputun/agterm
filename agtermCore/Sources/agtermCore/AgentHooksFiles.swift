import Foundation

/// AgentHooksFiles installs the agent status hooks from a folder of hook scripts into one home, with `toolPath` baked
/// into the wrappers; the Mac app and agterm-server share it. An unreadable or unparseable config is left alone.
public struct AgentHooksFiles {
    public struct Failure: Error, Equatable {
        public let message: String

        public init(message: String) { self.message = message }
    }

    /// CodexResult is the outcome of the Codex config.toml merge, decided by parsing the existing file.
    public enum CodexResult: Equatable, Sendable {
        case merged, alreadyConfigured, hooksExist, unparseable, unreadable, noCodex
        /// noJq is a skipped merge: the Codex wrapper parses its hook input with jq, which is not installed.
        case noJq

        /// isWarning is an outcome the user must act on: add the block by hand, or fix the config.
        public var isWarning: Bool {
            switch self {
            case .hooksExist, .unparseable, .unreadable, .noJq: true
            case .merged, .alreadyConfigured, .noCodex: false
            }
        }

        /// needsManualMerge is an outcome whose text sends the user to the docs for the block to paste in by hand.
        public var needsManualMerge: Bool {
            switch self {
            case .hooksExist, .unparseable: true
            case .merged, .alreadyConfigured, .unreadable, .noCodex, .noJq: false
            }
        }
    }

    public enum PiResult: Equatable, Sendable {
        case installed, alreadyConfigured, userOwned, unreadable, writeFailed, noPi

        public var isWarning: Bool {
            switch self {
            case .userOwned, .unreadable, .writeFailed: true
            case .installed, .alreadyConfigured, .noPi: false
            }
        }
    }

    /// OpenCodeResult is the OpenCode plugin's outcome; only version-specific results carry a version.
    public enum OpenCodeResult: Equatable, Sendable {
        case installed(AgentHooksInstall.OpenCode.Version, path: String)
        case alreadyConfigured(AgentHooksInstall.OpenCode.Version, path: String)
        case userOwned(AgentHooksInstall.OpenCode.Version, path: String)
        case unreadable(AgentHooksInstall.OpenCode.Version, path: String)
        case writeFailed(AgentHooksInstall.OpenCode.Version, path: String)
        case noOpenCode(directory: String)
        case skipped, v2ConfigUnavailable
        case v1CleanupUserOwned(path: String), v1CleanupUnreadable(path: String), v1CleanupFailed(path: String)

        public var isWarning: Bool {
            switch self {
            case .userOwned, .unreadable, .writeFailed, .v2ConfigUnavailable, .v1CleanupUserOwned, .v1CleanupUnreadable,
                 .v1CleanupFailed: true
            case .installed, .alreadyConfigured, .noOpenCode, .skipped: false
            }
        }
    }

    /// Outcome is every step's result but OpenCode's, whose version its caller decides.
    public struct Outcome: Equatable, Sendable {
        public let settingsSkipped: Bool
        public let codex: CodexResult
        public let pi: PiResult

        public var isWarning: Bool { settingsSkipped || codex.isWarning || pi.isWarning }
    }

    public let source: URL
    public let home: URL
    /// toolPath is the agtermctl baked into the wrappers, nil to leave their PATH fallback.
    public let toolPath: String?

    public init(source: URL, home: URL, toolPath: String?) {
        self.source = source
        self.home = home
        self.toolPath = toolPath
    }

    /// destination is where the scripts are installed and every config points.
    public var destination: URL { Self.destination(home: home) }

    /// destination is where the scripts are installed for `home`.
    public static func destination(home: URL) -> URL { home.appendingPathComponent(".config/agterm/agent-status") }

    /// install runs every step but OpenCode's; each reports its own result, so one refused config never hides another.
    /// `jqAvailable` false skips the Codex merge as `.noJq`.
    public func install(jqAvailable: Bool = true) throws -> Outcome {
        try copyScripts()
        try bakeToolPath()
        let settingsSkipped = try mergeClaudeSettings()
        try appendShellRC()
        let codex = try mergeCodexConfig(jqAvailable: jqAvailable)
        let pi = try installPiExtension()
        return Outcome(settingsSkipped: settingsSkipped, codex: codex, pi: pi)
    }

    private func copyScripts() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { throw Failure(message: "The agent-status scripts are missing at \(source.path).") }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: destination)
        try DirectoryCopy.copy(source, to: destination)
    }

    // the Claude adapter never calls agtermctl, it execs the generic wrapper, which carries the baked path
    private func bakeToolPath() throws {
        guard let toolPath else { return }
        for name in [AgentHooksInstall.wrapperName, AgentHooksInstall.codexWrapperName] {
            let wrapper = destination.appendingPathComponent(name)
            let original = try String(contentsOf: wrapper, encoding: .utf8)
            try writePreservingSymlink(AgentHooksInstall.bakeAgtermctlPath(into: original, toolPath: toolPath), to: wrapper)
        }
    }

    // a dotfiles-managed link is written through to its target, since an atomic rename would replace the link with a
    // regular file; `posixMode` applies to that target, so a chmod-600 file is not widened
    private func writePreservingSymlink(_ text: String, to url: URL, posixMode: NSNumber? = nil) throws {
        try AgentHooksInstall.writeFile(text, toPath: (Self.symlinkTarget(of: url) ?? url).path, posixMode: posixMode)
    }

    private static func symlinkTarget(of url: URL) -> URL? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attrs[.type] as? FileAttributeType) == .typeSymbolicLink else { return nil }
        return url.resolvingSymlinksInPath()
    }

    private struct UnreadableExisting: Error {}

    // nil when absent, the contents when readable, a throw when it exists but cannot be read, so the caller leaves it
    // untouched rather than clobbering it with no backup
    private static func readExisting(at url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw UnreadableExisting()
        }
    }

    /// mergeClaudeSettings returns true when the merge was skipped (unreadable or invalid JSON) and the file left alone.
    private func mergeClaudeSettings() throws -> Bool {
        let claudeDir = home.appendingPathComponent(".claude")
        let settings = claudeDir.appendingPathComponent("settings.json")
        let existing: String?
        do { existing = try Self.readExisting(at: settings) } catch { return true }
        let merged: (json: String, changed: Bool)
        do {
            merged = try AgentHooksInstall.mergeClaudeSettings(existing: existing, scriptDir: destination.path)
        } catch AgentHooksInstall.MergeError.malformedExistingSettings {
            return true
        }
        guard merged.changed else { return false }
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let mode = AgentHooksInstall.posixMode(ofFile: (Self.symlinkTarget(of: settings) ?? settings).path)
        // the .bak sits beside the link, never inside the dotfiles directory it resolves into
        if let existing { try AgentHooksInstall.writeFile(existing, toPath: AgentHooksInstall.backupPath(for: settings.path), posixMode: mode) }
        try writePreservingSymlink(merged.json, to: settings, posixMode: mode)
        return false
    }

    private func appendShellRC() throws {
        for name in [".zshrc", ".bashrc", ".config/fish/config.fish"] {
            let rc = home.appendingPathComponent(name)
            let fish = name.hasSuffix(".fish")
            if fish, !FileManager.default.fileExists(atPath: rc.deletingLastPathComponent().path) { continue }
            let existing = (try? String(contentsOf: rc, encoding: .utf8)) ?? ""
            let scriptName = fish ? AgentHooksInstall.fishIntegrationRelativePath : AgentHooksInstall.integrationRelativePath
            let result = AgentHooksInstall.appendShellRC(existing: existing, scriptDir: destination.path, scriptName: scriptName)
            guard result.changed else { continue }
            try writePreservingSymlink(result.contents, to: rc)
        }
    }

    // an unmarked same-named extension is user-owned and left alone; no backup, the extension carries no user state
    private func installPiExtension() throws -> PiResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: home.appendingPathComponent(".pi/agent").path) else { return .noPi }
        let source = destination.appendingPathComponent(AgentHooksInstall.piExtensionRelativePath)
        guard fm.fileExists(atPath: source.path) else { throw Failure(message: "The Pi status extension is missing from the scripts.") }
        let contents = try String(contentsOf: source, encoding: .utf8)
        guard contents.contains(AgentHooksInstall.piExtensionMarker) else {
            throw Failure(message: "The Pi status extension is missing its ownership marker.")
        }
        let target = URL(fileURLWithPath: AgentHooksInstall.piExtensionPath(home: home.path))
        let existing: String?
        do { existing = try Self.readExisting(at: target) } catch { return .unreadable }
        guard AgentHooksInstall.mayOverwritePiExtension(fileExists: existing != nil, existingContents: existing) else { return .userOwned }
        guard existing != contents else { return .alreadyConfigured }
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let mode = AgentHooksInstall.posixMode(ofFile: (Self.symlinkTarget(of: target) ?? target).path)
            try writePreservingSymlink(contents, to: target, posixMode: mode)
        } catch {
            return .writeFailed
        }
        return .installed
    }

    /// installOpenCodePlugin writes the `version` plugin into `configurationDirectory` from `scriptDirectory`, the
    /// installed scripts unless given, with the same ownership rule as Pi; a v2 install removes a managed v1 plugin.
    public func installOpenCodePlugin(version: AgentHooksInstall.OpenCode.Version, scriptDirectory: URL? = nil,
                                      configurationDirectory: String) throws -> OpenCodeResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: configurationDirectory) else { return .noOpenCode(directory: configurationDirectory) }
        let source = (scriptDirectory ?? destination).appendingPathComponent(AgentHooksInstall.OpenCode.relativePath(version: version))
        guard fm.fileExists(atPath: source.path) else {
            throw Failure(message: "The OpenCode \(version.rawValue) status plugin is missing from the scripts.")
        }
        let contents = try String(contentsOf: source, encoding: .utf8)
        guard contents.contains(AgentHooksInstall.OpenCode.marker(version: version)) else {
            throw Failure(message: "The OpenCode \(version.rawValue) status plugin is missing its ownership marker.")
        }
        let target = URL(fileURLWithPath: AgentHooksInstall.OpenCode.pluginPath(configurationDirectory: configurationDirectory, version: version))
        let existing: String?
        do { existing = try Self.readExisting(at: target) } catch { return .unreadable(version, path: target.path) }
        guard AgentHooksInstall.OpenCode.mayOverwrite(fileExists: existing != nil, existingContents: existing, version: version) else {
            return .userOwned(version, path: target.path)
        }
        let alreadyConfigured = existing == contents
        if !alreadyConfigured {
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let mode = AgentHooksInstall.posixMode(ofFile: (Self.symlinkTarget(of: target) ?? target).path)
                try writePreservingSymlink(contents, to: target, posixMode: mode)
            } catch {
                return .writeFailed(version, path: target.path)
            }
        }
        if version == .v2, let warning = Self.removeManagedV1Plugin(configurationDirectory: configurationDirectory) { return warning }
        return alreadyConfigured ? .alreadyConfigured(version, path: target.path) : .installed(version, path: target.path)
    }

    private static func removeManagedV1Plugin(configurationDirectory: String) -> OpenCodeResult? {
        let path = AgentHooksInstall.OpenCode.pluginPath(configurationDirectory: configurationDirectory, version: .v1)
        var entry = stat()
        guard lstat(path, &entry) == 0 else { return errno == ENOENT ? nil : .v1CleanupUnreadable(path: path) }
        guard let existing = try? String(contentsOfFile: path, encoding: .utf8) else { return .v1CleanupUnreadable(path: path) }
        guard AgentHooksInstall.OpenCode.mayOverwrite(fileExists: true, existingContents: existing, version: .v1) else {
            return .v1CleanupUserOwned(path: path)
        }
        // the plugin entry only, never a symlink target or a directory tree
        guard unlink(path) == 0 else { return .v1CleanupFailed(path: path) }
        return nil
    }

    /// mergeCodexConfig only touches a home that already has `~/.codex`, so a non-Codex home is not seeded.
    private func mergeCodexConfig(jqAvailable: Bool) throws -> CodexResult {
        let codexDir = home.appendingPathComponent(".codex")
        guard FileManager.default.fileExists(atPath: codexDir.path) else { return .noCodex }
        guard jqAvailable else { return .noJq }
        let config = codexDir.appendingPathComponent("config.toml")
        let existing: String?
        do { existing = try Self.readExisting(at: config) } catch { return .unreadable }
        switch AgentHooksInstall.mergeCodexConfig(existing: existing ?? "", scriptDir: destination.path) {
        case .unchanged: return .alreadyConfigured
        case .hooksExist: return .hooksExist
        case .unparseable: return .unparseable
        case .merged(let contents):
            let mode = AgentHooksInstall.posixMode(ofFile: (Self.symlinkTarget(of: config) ?? config).path)
            if let existing, !existing.isEmpty {
                try AgentHooksInstall.writeFile(existing, toPath: AgentHooksInstall.backupPath(for: config.path), posixMode: mode)
            }
            try writePreservingSymlink(contents, to: config, posixMode: mode)
            return .merged
        }
    }
}

extension AgentHooksFiles.Outcome {
    /// claudeText is the one-line report of the Claude Code settings merge.
    public var claudeText: String {
        settingsSkipped
            ? "Your ~/.claude/settings.json couldn't be safely read or merged, so the Claude Code hooks were NOT added "
              + "(the file was left untouched). It is unreadable, not valid JSON, or has a hooks entry in a shape we "
              + "don't recognize. Fix it and run this again, or add the hooks manually."
            : "Claude Code hooks merged into ~/.claude/settings.json."
    }
}

extension AgentHooksFiles.CodexResult {
    /// text is the one-line report of this outcome. It embeds no generated block: an NSAlert sizes itself to fit with
    /// no scroll and no cap (#430), so the two manual-merge cases send the user to the docs instead.
    public var text: String {
        let approve = "Run /hooks in Codex to review and approve them before they take effect."
        let manual = "See the Add Codex hooks by hand section of the agterm docs for the block to add, then run /hooks in Codex."
        switch self {
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
        case .noJq:
            return "jq is not installed, so Codex hooks were skipped: their wrapper needs it. Install jq, then run this again."
        }
    }
}

extension AgentHooksFiles.PiResult {
    /// text is the one-line report of this outcome; Pi loads extensions on its next start or `/reload`.
    public var text: String {
        switch self {
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
}

extension AgentHooksFiles.OpenCodeResult {
    /// text is the one-line report of this outcome; OpenCode loads plugins on its next start.
    public var text: String {
        switch self {
        case .installed(let version, let path):
            return "OpenCode \(version.rawValue) status plugin installed to \(path). Restart OpenCode."
        case .alreadyConfigured(let version, let path):
            return "OpenCode \(version.rawValue) status plugin is already current at \(path)."
        case .userOwned(let version, let path):
            return "\(path) is user-owned, so the OpenCode \(version.rawValue) plugin was left untouched."
        case .unreadable(let version, let path):
            return "\(path) could not be read, so the OpenCode \(version.rawValue) plugin was left untouched."
        case .writeFailed(let version, let path):
            return "OpenCode \(version.rawValue) plugin couldn't be written to \(path) (check permissions), so it was skipped."
        case .noOpenCode(let directory):
            return "No \(directory) found, so the OpenCode plugin was skipped. Start OpenCode once, then run this again. "
                + "Coarse shell detection for opencode is off by default."
        case .skipped:
            return "OpenCode status plugin installation was skipped."
        case .v2ConfigUnavailable:
            return "OpenCode v2 installation was skipped because its configuration directory could not be determined from your login shell. "
                + "Check shell startup and OPENCODE_CONFIG_DIR, then run this again."
        case .v1CleanupUserOwned(let path):
            return "OpenCode v2 status plugin is installed, but \(path) is user-owned and was left untouched."
        case .v1CleanupUnreadable(let path):
            return "OpenCode v2 status plugin is installed, but \(path) could not be read and was left untouched."
        case .v1CleanupFailed(let path):
            return "OpenCode v2 status plugin is installed, but the v1 plugin at \(path) could not be safely removed. "
                + "Check permissions and run this again."
        }
    }
}
