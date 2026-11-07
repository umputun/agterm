import AppKit
import agtermCore

/// Installs the bundled agent-status hooks package into the user's home: the scripts into
/// `~/.config/agterm/agent-status/`, the bundled `agtermctl`'s absolute path baked into the wrapper, a
/// marker-guarded `source` line in `~/.zshrc`/`~/.bashrc`/`~/.config/fish/config.fish`, the five Claude Code
/// hooks merged into `~/.claude/settings.json`, the six Codex lifecycle hooks into `~/.codex/config.toml`,
/// and — when each is configured — Pi's lifecycle extension into `~/.pi/agent/extensions/` and OpenCode's
/// plugin into `~/.config/opencode/plugins/`. Claude/Codex configs get a `.bak` first; the Codex step parses
/// TOML and points at the docs for a manual merge when that file already has hooks or does not parse. The
/// file work is `agtermCore.AgentHooksFiles`, shared with agterm-server; this type adds the OpenCode version
/// detection, the chooser and the alerts. Idempotent: a re-run refreshes the baked `agtermctl` path (healing a
/// moved bundle) and no-ops on already-present entries.
@MainActor
enum AgentHooksInstaller {
    private static var isRunning = false

    /// The bundled `Contents/Resources/agent-status`, nil when the build skipped bundling (a bare
    /// `swift build`).
    private static var bundledFolder: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("agent-status")
    }

    /// The bundled `agtermctl` at `Contents/MacOS/agtermctl`, or nil when this build skipped bundling.
    private static var bundledTool: URL? { Bundle.main.url(forAuxiliaryExecutable: CLIInstall.toolName) }

    private static var destinationFolder: URL {
        AgentHooksFiles.destination(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    typealias CodexResult = AgentHooksFiles.CodexResult
    typealias OpenCodeResult = AgentHooksFiles.OpenCodeResult

    private struct InstallOutcome {
        let files: AgentHooksFiles.Outcome
        let opencode: OpenCodeResult

        var isWarning: Bool { files.isWarning || opencode.isWarning }
    }

    /// Run the install and show a result alert.
    static func run() {
        guard !isRunning else { return }
        isRunning = true
        Task {
            defer { isRunning = false }
            do {
                let outcome = try await install()
                present(style: outcome.isWarning ? .warning : .informational,
                        title: outcome.isWarning ? "Agent Status Hooks Installed — with a warning" : "Agent Status Hooks Installed",
                        text: successText(outcome),
                        docs: outcome.files.codex.needsManualMerge ? codexManualDocsURL : nil)
            } catch let error as AgentHooksFiles.Failure {
                present(style: .warning, title: "Install Failed", text: error.message)
            } catch {
                present(style: .warning, title: "Install Failed", text: error.localizedDescription)
            }
        }
    }

    private static func install() async throws -> InstallOutcome {
        guard let bundledFolder else { throw AgentHooksFiles.Failure(message: "The agent-status scripts are not bundled in this build.") }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let outcome = try AgentHooksFiles(source: bundledFolder, home: home, toolPath: bundledTool?.path).install()
        let opencode = try await installOpenCodePlugin()
        return InstallOutcome(files: outcome, opencode: opencode)
    }

    // the version comes from the login shell's `opencode --version`, else from the chooser; the file work is shared
    static func installOpenCodePlugin(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        scriptDirectory: URL = destinationFolder,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> OpenCodeResult {
        let fm = FileManager.default
        let legacyDirectory = URL(fileURLWithPath: AgentHooksInstall.opencodePluginPath(home: home.path))
            .deletingLastPathComponent().deletingLastPathComponent().path
        let probe = await OpenCodeEnvironmentProbe.detect(environment: environment)
        var detected = probe?.version
        // no probe result and no default config: neither chooser answer could install anything
        if probe == nil, !fm.fileExists(atPath: legacyDirectory) { return .noOpenCode(directory: legacyDirectory) }
        if detected == nil, !fm.fileExists(atPath: legacyDirectory),
           let v2Directory = probe?.v2ConfigurationDirectory, !fm.fileExists(atPath: v2Directory) {
            return .noOpenCode(directory: v2Directory)
        }
        if detected == nil { detected = chooseOpenCodeVersion() }
        guard let version = detected else { return .skipped }
        let configurationDirectory: String
        switch version {
        case .v1: configurationDirectory = legacyDirectory
        case .v2:
            guard let resolved = probe?.v2ConfigurationDirectory else { return .v2ConfigUnavailable }
            configurationDirectory = resolved
        }
        let installed = AgentHooksFiles(source: scriptDirectory, home: home, toolPath: nil)
        return try installed.installOpenCodePlugin(version: version, scriptDirectory: scriptDirectory,
                                                   configurationDirectory: configurationDirectory)
    }

    // the success-alert text, calling out anything an integration could not safely update and left alone.
    private static func successText(_ outcome: InstallOutcome) -> String {
        """
        Scripts installed to \(destinationFolder.path).
        \(outcome.files.claudeText)
        \(outcome.files.codex.text)
        \(outcome.files.pi.text)
        \(outcome.opencode.text)
        The source line was added to ~/.zshrc, ~/.bashrc (and ~/.config/fish/config.fish if fish is installed).

        Open a new terminal for the shell integration to take effect.
        """
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

    static func makeOpenCodeVersionAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Choose OpenCode Version"
        alert.informativeText = "Could not determine the OpenCode version in your login shell (opencode --version). Choose the version you use, or skip OpenCode and install the other hooks."
        alert.addButton(withTitle: "Skip OpenCode")
        for version in AgentHooksInstall.OpenCode.Version.allCases {
            alert.addButton(withTitle: "OpenCode \(version.rawValue)")
        }
        return alert
    }

    private static func chooseOpenCodeVersion() -> AgentHooksInstall.OpenCode.Version? {
        let response = makeOpenCodeVersionAlert().runModal()
        let index = response.rawValue - NSApplication.ModalResponse.alertSecondButtonReturn.rawValue
        let versions = AgentHooksInstall.OpenCode.Version.allCases
        guard versions.indices.contains(index) else { return nil }
        return versions[index]
    }

    private static func present(style: NSAlert.Style, title: String, text: String, docs: URL? = nil) {
        let alert = makeAlert(style: style, title: title, text: text, docs: docs)
        guard alert.runModal() == .alertSecondButtonReturn, let docs else { return }
        NSWorkspace.shared.open(docs)
    }
}
