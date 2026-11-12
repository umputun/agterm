import Foundation
import Testing
@testable import agtermCore

struct AgentHooksFilesTests {
    private let toolPath = "/opt/agterm/bin/agtermctl"

    private var scripts: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("agterm/Resources/agent-status")
    }

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agent-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func read(_ home: URL, _ relative: String) throws -> String {
        try String(contentsOf: home.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test func installWritesScriptsConfigsAndBakedTool() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        let files = AgentHooksFiles(source: scripts, home: home, toolPath: toolPath)

        let outcome = try files.install()

        #expect(outcome == AgentHooksFiles.Outcome(settingsSkipped: false, codex: .merged, pi: .noPi))
        for wrapper in [AgentHooksInstall.wrapperName, AgentHooksInstall.codexWrapperName] {
            #expect(try read(home, ".config/agterm/agent-status/\(wrapper)").contains(toolPath))
        }
        #expect(try read(home, ".claude/settings.json").replacingOccurrences(of: "\\/", with: "/").contains(files.destination.path))
        #expect(try read(home, ".codex/config.toml").contains(files.destination.path))
        for rc in [".zshrc", ".bashrc"] {
            #expect(try read(home, rc).contains(files.destination.appendingPathComponent(AgentHooksInstall.integrationRelativePath).path))
        }
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/fish/config.fish").path))
    }

    @Test func secondInstallChangesNothing() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        let files = AgentHooksFiles(source: scripts, home: home, toolPath: toolPath)
        _ = try files.install()
        let before = try [".zshrc", ".bashrc", ".claude/settings.json", ".codex/config.toml"].map { try read(home, $0) }

        let outcome = try files.install()

        #expect(outcome.codex == .alreadyConfigured)
        #expect(try [".zshrc", ".bashrc", ".claude/settings.json", ".codex/config.toml"].map { try read(home, $0) } == before)
    }

    @Test func bakingPreservesWrapperModesAcrossReinstall() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let source = home.appendingPathComponent("resources/agent-status")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DirectoryCopy.copy(scripts, to: source)
        let wrappers = [(AgentHooksInstall.wrapperName, 0o700), (AgentHooksInstall.codexWrapperName, 0o750)]
        for (name, mode) in wrappers {
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: source.appendingPathComponent(name).path)
        }
        let files = AgentHooksFiles(source: source, home: home, toolPath: toolPath)

        for installation in 1...2 {
            _ = try files.install()
            for (name, mode) in wrappers {
                let wrapper = files.destination.appendingPathComponent(name)
                #expect(AgentHooksInstall.posixMode(ofFile: wrapper.path)?.intValue == mode, "Installation \(installation): \(name)")
                #expect(try String(contentsOf: wrapper, encoding: .utf8).contains(toolPath))
            }
        }
    }

    @Test func missingJqSkipsOnlyCodex() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)

        let outcome = try AgentHooksFiles(source: scripts, home: home, toolPath: toolPath).install(jqAvailable: false)

        #expect(outcome.codex == .noJq)
        #expect(outcome.isWarning)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/config.toml").path))
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/settings.json").path))
    }

    @Test func invalidClaudeSettingsAreLeftAlone() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let claude = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try "{ not json".write(to: claude.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

        let outcome = try AgentHooksFiles(source: scripts, home: home, toolPath: toolPath).install()

        #expect(outcome.settingsSkipped)
        #expect(try read(home, ".claude/settings.json") == "{ not json")
        #expect(outcome.codex == .noCodex)
    }

    @Test func missingSourceFails() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let files = AgentHooksFiles(source: home.appendingPathComponent("absent"), home: home, toolPath: nil)

        #expect(throws: AgentHooksFiles.Failure.self) { try files.install() }
    }

    @Test func installsPiExtensionWhenPiIsPresent() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".pi/agent"), withIntermediateDirectories: true)

        let outcome = try AgentHooksFiles(source: scripts, home: home, toolPath: toolPath).install()

        #expect(outcome.pi == .installed)
        #expect(try read(home, ".pi/agent/extensions/agterm-status.ts").contains(AgentHooksInstall.piExtensionMarker))
    }

    @Test func openCodePluginNeedsItsConfigDirectory() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let files = AgentHooksFiles(source: scripts, home: home, toolPath: toolPath)
        _ = try files.install()
        let config = home.appendingPathComponent(".config/opencode").path

        #expect(try files.installOpenCodePlugin(version: .v1, configurationDirectory: config) == .noOpenCode(directory: config))

        try FileManager.default.createDirectory(atPath: config, withIntermediateDirectories: true)
        let plugin = AgentHooksInstall.OpenCode.pluginPath(configurationDirectory: config, version: .v1)
        #expect(try files.installOpenCodePlugin(version: .v1, configurationDirectory: config) == .installed(.v1, path: plugin))
        #expect(try files.installOpenCodePlugin(version: .v1, configurationDirectory: config) == .alreadyConfigured(.v1, path: plugin))
    }
}
