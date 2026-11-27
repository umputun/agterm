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

        #expect(outcome == AgentHooksFiles.Outcome(settingsSkipped: false, codex: .merged, pi: .noPi, agy: .noAgy,
                                                    copilot: .noCopilot))
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

    @Test func appendingKeepsShellRCMode() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let bashrc = home.appendingPathComponent(".bashrc")
        try "export EDITOR=vim\n".write(to: bashrc, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: bashrc.path)
        let files = AgentHooksFiles(source: scripts, home: home, toolPath: toolPath)

        _ = try files.install()

        #expect(AgentHooksInstall.posixMode(ofFile: bashrc.path)?.intValue == 0o600)
        #expect(try read(home, ".bashrc").contains(files.destination.appendingPathComponent(AgentHooksInstall.integrationRelativePath).path))
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

    @Test func agyHooksNeedItsConfigDirectory() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let outcome = try AgentHooksFiles(source: scripts, home: home, toolPath: toolPath).install()

        #expect(outcome.agy == .noAgy)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".gemini").path))
    }

    @Test func agyHooksAreWrittenThroughALinkedHooksFile() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        let config = home.appendingPathComponent(".gemini/config")
        let dotfiles = home.appendingPathComponent("dotfiles")
        try fm.createDirectory(at: config, withIntermediateDirectories: true)
        try fm.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let target = dotfiles.appendingPathComponent("hooks.json")
        let original = #"{"chat": {"Stop": [{"type": "command", "command": "chat.py agy-hook"}]}}"#
        try original.write(to: target, atomically: true, encoding: .utf8)
        let link = config.appendingPathComponent("hooks.json")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        let files = AgentHooksFiles(source: scripts, home: home, toolPath: toolPath)

        #expect(try files.install().agy == .merged)

        #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == target.path)
        let written = try String(contentsOf: target, encoding: .utf8)
        #expect(written.contains("chat.py agy-hook"))
        #expect(written.contains(files.destination.appendingPathComponent(AgentHooksInstall.Agy.wrapperName).path))
        #expect(try read(home, ".gemini/config/hooks.json.bak") == original)
        #expect(fm.isExecutableFile(atPath: files.destination.appendingPathComponent(AgentHooksInstall.Agy.wrapperName).path))

        #expect(try files.install().agy == .alreadyConfigured)
        #expect(try String(contentsOf: target, encoding: .utf8) == written)
    }

    @Test(arguments: [AgentHooksFiles.AgyResult.merged, .alreadyConfigured, .userOwned, .unparseable, .unreadable, .writeFailed, .noAgy])
    func agyResultTextStaysOnOneLine(_ result: AgentHooksFiles.AgyResult) {
        #expect(!result.text.isEmpty)
        #expect(!result.text.contains("\n"))
        #expect(result.isWarning == [.userOwned, .unparseable, .unreadable, .writeFailed].contains(result))
    }

    @Test func agyHooksWriteFailureLeavesTheRestOfTheInstall() throws {
        let home = try makeHome()
        let fm = FileManager.default
        let locked = home.appendingPathComponent("store")
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? fm.removeItem(at: home)
        }
        try fm.createDirectory(at: home.appendingPathComponent(".gemini/config"), withIntermediateDirectories: true)
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        let target = locked.appendingPathComponent("hooks.json")
        try "{}".write(to: target, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        try fm.createSymbolicLink(at: home.appendingPathComponent(".gemini/config/hooks.json"), withDestinationURL: target)

        let outcome = try AgentHooksFiles(source: scripts, home: home, toolPath: toolPath).install()

        #expect(outcome.agy == .writeFailed)
        #expect(outcome.isWarning)
        #expect(try String(contentsOf: target, encoding: .utf8) == "{}")
    }

    @Test func copilotHooksNeedItsConfigDirectory() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let outcome = try AgentHooksFiles(source: scripts, home: home, toolPath: toolPath).install()

        #expect(outcome.copilot == .noCopilot)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".copilot").path))
    }

    @Test func copilotHomeOverridesTheDefaultRootWithoutFallback() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        try fm.createDirectory(at: home.appendingPathComponent(".copilot"), withIntermediateDirectories: true)
        let custom = home.appendingPathComponent("copilot home")

        let missing = try AgentHooksFiles(source: scripts, home: home, toolPath: toolPath, copilotHome: custom).install()
        #expect(missing.copilot == .noCopilot)
        #expect(missing.copilot.text(copilotHome: custom.path).contains("your COPILOT_HOME"))
        #expect(!fm.fileExists(atPath: home.appendingPathComponent(".copilot/hooks").path))

        try fm.createDirectory(at: custom, withIntermediateDirectories: true)
        let present = try AgentHooksFiles(source: scripts, home: home, toolPath: toolPath, copilotHome: custom).install()
        #expect(present.copilot == .installed)
        #expect(fm.fileExists(atPath: custom.appendingPathComponent("hooks/agterm-status.json").path))
        #expect(present.copilot.text(copilotHome: custom.path).contains(custom.path + "/hooks/agterm-status.json"))
    }

    @Test func copilotHooksReplaceTheCookbookRecipeFile() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        let hooks = home.appendingPathComponent(".copilot/hooks")
        try fm.createDirectory(at: hooks, withIntermediateDirectories: true)
        let recipe = AgentHooksInstallTests.copilotCookbookFile
        try recipe.write(to: hooks.appendingPathComponent("copilot-status-hooks.json"), atomically: true, encoding: .utf8)
        let files = AgentHooksFiles(source: scripts, home: home, toolPath: toolPath)

        #expect(try files.install().copilot == .replacedCookbook)

        let written = try read(home, ".copilot/hooks/agterm-status.json")
        #expect(written.contains(files.destination.appendingPathComponent(AgentHooksInstall.Copilot.wrapperName).path))
        #expect(!fm.fileExists(atPath: hooks.appendingPathComponent("copilot-status-hooks.json").path))
        #expect(try read(home, ".copilot/hooks/copilot-status-hooks.json.bak") == recipe)
        #expect(fm.isExecutableFile(atPath: files.destination.appendingPathComponent(AgentHooksInstall.Copilot.wrapperName).path))

        #expect(try files.install().copilot == .alreadyConfigured)
        #expect(try read(home, ".copilot/hooks/agterm-status.json") == written)
    }

    @Test(arguments: [("\"permission_prompt\"", "\"permission_prompt|elicitation_dialog\""),
                      ("agterm-agent-status.sh", "agterm-copilot-status.sh")])
    func copilotHooksKeepAChangedCookbookFile(_ old: String, _ new: String) throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let hooks = home.appendingPathComponent(".copilot/hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let recipe = AgentHooksInstallTests.copilotCookbookFile
        let changed = recipe.replacingOccurrences(of: old, with: new)
        #expect(changed != recipe)
        try changed.write(to: hooks.appendingPathComponent("copilot-status-hooks.json"), atomically: true, encoding: .utf8)

        let outcome = try AgentHooksFiles(source: scripts, home: home, toolPath: toolPath).install()

        #expect(outcome.copilot == .cookbookKept)
        #expect(outcome.isWarning)
        #expect(try read(home, ".copilot/hooks/copilot-status-hooks.json") == changed)
        #expect(FileManager.default.fileExists(atPath: hooks.appendingPathComponent("agterm-status.json").path))
    }

    @Test func copilotHooksIgnoreACookbookNamedFileWithoutAgtermCommands() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let hooks = home.appendingPathComponent(".copilot/hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let own = #"{"version": 1, "hooks": {"agentStop": [{"bash": "say done"}]}}"#
        try own.write(to: hooks.appendingPathComponent("copilot-status-hooks.json"), atomically: true, encoding: .utf8)

        let outcome = try AgentHooksFiles(source: scripts, home: home, toolPath: toolPath).install()

        #expect(outcome.copilot == .installed)
        #expect(try read(home, ".copilot/hooks/copilot-status-hooks.json") == own)
    }

    @Test func copilotHooksLeaveAForeignFileAlone() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let hooks = home.appendingPathComponent(".copilot/hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let own = #"{"version": 1, "hooks": {"agentStop": [{"bash": "say done"}]}}"#
        try own.write(to: hooks.appendingPathComponent("agterm-status.json"), atomically: true, encoding: .utf8)

        #expect(try AgentHooksFiles(source: scripts, home: home, toolPath: toolPath).install().copilot == .userOwned)
        #expect(try read(home, ".copilot/hooks/agterm-status.json") == own)
    }

    @Test(arguments: [AgentHooksFiles.CopilotResult.installed, .alreadyConfigured, .replacedCookbook, .cookbookKept, .userOwned,
                      .unparseable, .unreadable, .writeFailed, .noCopilot])
    func copilotResultTextStaysOnOneLine(_ result: AgentHooksFiles.CopilotResult) {
        #expect(!result.text.isEmpty)
        #expect(!result.text.contains("\n"))
        #expect(result.isWarning == [.cookbookKept, .userOwned, .unparseable, .unreadable, .writeFailed].contains(result))
    }

    @Test func copilotHooksWriteFailureLeavesTheRestOfTheInstall() throws {
        let home = try makeHome()
        let fm = FileManager.default
        let hooks = home.appendingPathComponent(".copilot/hooks")
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hooks.path)
            try? fm.removeItem(at: home)
        }
        try fm.createDirectory(at: hooks, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: hooks.path)

        let outcome = try AgentHooksFiles(source: scripts, home: home, toolPath: toolPath).install()

        #expect(outcome.copilot == .writeFailed)
        #expect(outcome.isWarning)
        #expect(!fm.fileExists(atPath: hooks.appendingPathComponent("agterm-status.json").path))
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
