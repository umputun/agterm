import Foundation
import Testing
@testable import agtermCore
@testable import AgtermServerKit

struct ServerHookInstallTests {
    private let toolPath = "/home/u/.local/lib/agterm-server/agtermctl"

    private struct Fixture {
        let root: URL
        var home: URL { root.appendingPathComponent("home") }
        var resources: URL { root.appendingPathComponent("resources") }
        var bin: URL { root.appendingPathComponent("bin") }

        func directory(_ relative: String) throws {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(relative), withIntermediateDirectories: true)
        }

        func tool(_ name: String, printing output: String) throws {
            let path = bin.appendingPathComponent(name)
            try writeExecutable(path.path, "#!/bin/sh\necho '\(output)'\n")
        }

        func read(_ relative: String) throws -> String {
            try String(contentsOf: home.appendingPathComponent(relative), encoding: .utf8)
        }
    }

    private func makeFixture() throws -> Fixture {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = Fixture(root: FileManager.default.temporaryDirectory.appendingPathComponent("server-hooks-\(UUID().uuidString)"))
        let fm = FileManager.default
        for directory in [fixture.home, fixture.bin, fixture.resources.appendingPathComponent("skill")] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try DirectoryCopy.copy(repository.appendingPathComponent("agterm/Resources/agent-status"),
                               to: fixture.resources.appendingPathComponent("agent-status"))
        try DirectoryCopy.copy(repository.appendingPathComponent("plugins/agterm/skills/agterm"),
                               to: fixture.resources.appendingPathComponent("skill/agterm"))
        return fixture
    }

    private func install(_ fixture: Fixture, environment: [String: String] = [:],
                         openCode: AgentHooksInstall.OpenCode.Version? = nil) throws -> ServerHookInstall.Report {
        try ServerHookInstall(resourcesDirectory: fixture.resources.path, home: fixture.home, toolPath: toolPath,
                              environment: environment.merging(["PATH": fixture.bin.path]) { own, _ in own },
                              openCode: openCode).run()
    }

    @Test func installsHooksAndSkillWithTheServerTool() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.directory(".codex")
        try fixture.tool("jq", printing: "")

        let report = try install(fixture)

        #expect(report.complete)
        #expect(try fixture.read(".config/agterm/agent-status/\(AgentHooksInstall.wrapperName)").contains(toolPath))
        #expect(try fixture.read(".config/agterm/agent-status/\(AgentHooksInstall.codexWrapperName)").contains(toolPath))
        #expect(try fixture.read(".codex/config.toml").contains(".config/agterm/agent-status"))
        #expect(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".claude/settings.json").path))
        #expect(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".codex/skills/agterm/SKILL.md").path))
        #expect(report.lines.contains { $0.hasPrefix("agterm skill installed for Codex") })
    }

    @Test func installedWrapperCallsTheBakedServerTool() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let calls = fixture.root.appendingPathComponent("calls")
        let tool = fixture.bin.appendingPathComponent("agtermctl")
        try writeExecutable(tool.path, "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '\(calls.path)'\n")
        _ = try ServerHookInstall(resourcesDirectory: fixture.resources.path, home: fixture.home, toolPath: tool.path,
                                  environment: ["PATH": fixture.bin.path], openCode: nil).run()

        let process = Process()
        process.executableURL = fixture.home.appendingPathComponent(".config/agterm/agent-status/\(AgentHooksInstall.wrapperName)")
        process.arguments = ["active"]
        let socket = fixture.root.appendingPathComponent("agterm.sock").path
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": fixture.home.path, "AGTERM_SESSION_ID": "s1", "AGTERM_SOCKET": socket]
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        try #require(finished.wait(timeout: .now() + 5) == .success)

        #expect(process.terminationStatus == 0)
        #expect(try String(contentsOf: calls, encoding: .utf8) == "session status active --target s1 --socket \(socket)\n")
    }

    @Test func missingJqSkipsCodexAndReportsIncomplete() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.directory(".codex")

        let report = try install(fixture)

        #expect(!report.complete)
        #expect(report.lines.contains(AgentHooksFiles.CodexResult.noJq.text))
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".codex/config.toml").path))
        #expect(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".claude/settings.json").path))
    }

    @Test func codexHomeReceivesTheHooksAndTheSkill() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.directory(".codex")
        try fixture.directory("custom-codex")
        try fixture.tool("jq", printing: "")
        let codexHome = fixture.home.appendingPathComponent("custom-codex").path

        let report = try install(fixture, environment: ["CODEX_HOME": codexHome])

        #expect(report.complete)
        #expect(report.lines.contains(AgentHooksFiles.CodexResult.merged.text(codexHome: codexHome)))
        #expect(try fixture.read("custom-codex/config.toml").contains(".config/agterm/agent-status"))
        #expect(FileManager.default.fileExists(atPath: codexHome + "/skills/agterm/SKILL.md"))
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".codex/config.toml").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".codex/skills").path))
    }

    @Test func missingCodexHomeIsReportedWithoutFallingBackToTheDefault() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.directory(".codex")
        try fixture.tool("jq", printing: "")
        let codexHome = fixture.home.appendingPathComponent("absent-codex").path

        let report = try install(fixture, environment: ["CODEX_HOME": codexHome])

        #expect(!report.complete)
        #expect(report.lines.contains(AgentHooksFiles.CodexResult.noCodex.text(codexHome: codexHome)))
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".codex/config.toml").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".codex/skills").path))
    }

    @Test func emptyCodexHomeUsesTheDefault() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.directory(".codex")
        try fixture.tool("jq", printing: "")

        let report = try install(fixture, environment: ["CODEX_HOME": ""])

        #expect(report.complete)
        #expect(report.lines.contains(AgentHooksFiles.CodexResult.merged.text))
        #expect(try fixture.read(".codex/config.toml").contains(".config/agterm/agent-status"))
    }

    @Test func openCodeVersionComesFromItsCommand() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.directory(".config/opencode")
        try fixture.tool("opencode", printing: "1.4.2")

        let report = try install(fixture)

        let plugin = AgentHooksInstall.OpenCode.pluginPath(configurationDirectory: fixture.home.path + "/.config/opencode", version: .v1)
        #expect(report.complete)
        #expect(report.lines.contains(AgentHooksFiles.OpenCodeResult.installed(.v1, path: plugin).text))
    }

    @Test func openCodeWithUnknownVersionIsSkippedNamingTheFlag() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.directory(".config/opencode")

        let report = try install(fixture)

        #expect(!report.complete)
        #expect(report.lines.contains { $0.contains("--opencode v1") })
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".config/opencode/plugins").path))
    }

    @Test func openCodeFlagInstallsV2IntoItsConfigDirectory() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.directory("oc2")
        let config = fixture.home.appendingPathComponent("oc2").path

        let report = try install(fixture, environment: ["OPENCODE_CONFIG_DIR": config], openCode: .v2)

        let plugin = AgentHooksInstall.OpenCode.pluginPath(configurationDirectory: config, version: .v2)
        #expect(report.lines.contains(AgentHooksFiles.OpenCodeResult.installed(.v2, path: plugin).text))
        #expect(FileManager.default.fileExists(atPath: plugin))
    }

    @Test func noOpenCodeConfigLeavesOpenCodeAlone() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let report = try install(fixture, openCode: .v1)

        #expect(report.complete)
        #expect(report.lines.contains(AgentHooksFiles.OpenCodeResult.noOpenCode(directory: fixture.home.path + "/.config/opencode").text))
    }
}
