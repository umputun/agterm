import Foundation
import agtermCore

/// ServerHookInstall installs the agent status hooks and the agterm skill for the user running it, from the server's
/// resources, with the server's agtermctl baked into the hook wrappers.
public struct ServerHookInstall {
    public var resourcesDirectory: String
    public var home: URL
    public var toolPath: String
    /// environment supplies PATH, for jq and opencode, OpenCode's config directory variables and `CODEX_HOME`.
    public var environment: [String: String]
    /// openCode is the version the caller named; nil reads `opencode --version`.
    public var openCode: AgentHooksInstall.OpenCode.Version?

    public init(resourcesDirectory: String, home: URL, toolPath: String, environment: [String: String],
                openCode: AgentHooksInstall.OpenCode.Version?) {
        self.resourcesDirectory = resourcesDirectory
        self.home = home
        self.toolPath = toolPath
        self.environment = environment
        self.openCode = openCode
    }

    /// Report is the printed result; incomplete when a step was skipped or refused in a way the user has to fix.
    public struct Report: Equatable, Sendable {
        public let lines: [String]
        public let complete: Bool
    }

    public func run() throws -> Report {
        let resources = URL(fileURLWithPath: resourcesDirectory)
        let codexHome = AgentHooksInstall.Codex.home(codexHome: environment["CODEX_HOME"],
                                                     workingDirectory: FileManager.default.currentDirectoryPath)
        let codexRoot = codexHome.map { URL(fileURLWithPath: $0) }
        let files = AgentHooksFiles(source: resources.appendingPathComponent("agent-status"), home: home, toolPath: toolPath,
                                    codexHome: codexRoot)
        let outcome = try files.install(jqAvailable: executable(named: "jq") != nil)
        let openCodeResult = try installOpenCode(files)
        let skill = try SkillInstall.install(source: resources.appendingPathComponent("skill/\(SkillInstall.skillName)"), home: home,
                                             codexHome: codexRoot)
        var lines = ["Scripts installed to \(files.destination.path).", outcome.claudeText, outcome.codex.text(codexHome: codexHome),
                     outcome.pi.text, openCodeResult.text]
        lines += skill.installed.map { "agterm skill installed for \($0.agent) at \($0.skillDirectory)." }
        lines += skill.skipped.map { "agterm skill not installed for \($0.agent): \($0.reason)." }
        lines.append("The source line was added to ~/.zshrc and ~/.bashrc (and config.fish when fish is set up); "
            + "open a new shell for it to take effect.")
        return Report(lines: lines, complete: !outcome.isWarning && !openCodeResult.warning && skill.skipped.isEmpty)
    }

    // installed only where an OpenCode config directory exists, and never for a guessed version
    private func installOpenCode(_ files: AgentHooksFiles) throws -> (text: String, warning: Bool) {
        let fm = FileManager.default
        let legacy = home.path + "/.config/opencode"
        let v2 = AgentHooksInstall.OpenCode.configurationDirectory(
            home: home.path, opencodeConfigDirectory: environment["OPENCODE_CONFIG_DIR"], xdgConfigHome: environment["XDG_CONFIG_HOME"])
        guard fm.fileExists(atPath: legacy) || v2.map({ fm.fileExists(atPath: $0) }) == true else {
            let result = AgentHooksFiles.OpenCodeResult.noOpenCode(directory: legacy)
            return (result.text, result.isWarning)
        }
        guard let version = openCode ?? detectedOpenCodeVersion() else {
            return ("OpenCode's version could not be read from `opencode --version`, so its status plugin was skipped. "
                + "Run `agterm-server install-hooks --opencode v1` or `--opencode v2`.", true)
        }
        let result: AgentHooksFiles.OpenCodeResult
        switch version {
        case .v1:
            result = try files.installOpenCodePlugin(version: .v1, configurationDirectory: legacy)
        case .v2:
            guard let v2 else { return (AgentHooksFiles.OpenCodeResult.v2ConfigUnavailable.text, true) }
            result = try files.installOpenCodePlugin(version: .v2, configurationDirectory: v2)
        }
        return (result.text, result.isWarning)
    }

    private func detectedOpenCodeVersion() -> AgentHooksInstall.OpenCode.Version? {
        guard let opencode = executable(named: "opencode") else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: opencode)
        process.arguments = ["--version"]
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        guard finished.wait(timeout: .now() + 5) == .success else {
            process.terminate()
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return nil }
        return AgentHooksInstall.OpenCode.Version(versionOutput: text)
    }

    private func executable(named name: String) -> String? {
        let path = environment["PATH"] ?? ""
        return path.split(separator: ":").map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
