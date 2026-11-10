import Foundation
import Testing
@testable import agtermCore

struct CodexInstallationTests {
    private let directory: URL
    private var home: URL { directory.appendingPathComponent("home") }
    private var custom: URL { directory.appendingPathComponent("custom codex") }
    private var defaultCodex: URL { home.appendingPathComponent(".codex") }
    private var source: URL { directory.appendingPathComponent("source") }
    private var scripts: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("agterm/Resources/agent-status")
    }

    private func installHooks(codexHome: URL?) throws -> AgentHooksFiles.CodexResult {
        try AgentHooksFiles(source: scripts, home: home, toolPath: nil, codexHome: codexHome).install().codex
    }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-install-\(UUID().uuidString)")
        for folder in [home, custom, defaultCodex, source] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try "\(SkillInstall.marker)\nbundled skill".write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "default config".write(to: defaultCodex.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    }

    @Test func testCustomSkillInstallationAndRefreshPreserveDefaultRoot() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try SkillInstall.install(source: source, home: home, codexHome: custom)
        let installed = custom.appendingPathComponent("skills/agterm/SKILL.md")
        #expect(first.skipped.isEmpty)
        #expect(first.installed == [SkillInstall.Target(agent: "Codex", skillDirectory: custom.path + "/skills/agterm")])
        try "\(SkillInstall.marker)\nupdated".write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let repeated = try SkillInstall.install(source: source, home: home, codexHome: custom)
        #expect(repeated.installed == first.installed)
        #expect(repeated.skipped.isEmpty)
        #expect(try String(contentsOf: installed, encoding: .utf8) == "\(SkillInstall.marker)\nupdated")
        try assertDefaultUntouched()
    }

    @Test func testCustomSkillOwnershipAndWriteFailureMessagesIncludeDestination() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = custom.appendingPathComponent("skills/agterm")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let skill = destination.appendingPathComponent("SKILL.md")
        try "user skill".write(to: skill, atomically: true, encoding: .utf8)
        let owned = try SkillInstall.install(source: source, home: home, codexHome: custom)
        #expect(owned.installed.isEmpty)
        #expect(!owned.skipped.isEmpty)
        #expect(owned.skipped.first?.reason == "\(destination.path): a different 'agterm' skill is already there — left untouched")
        #expect(try String(contentsOf: skill, encoding: .utf8) == "user skill")
        try FileManager.default.removeItem(at: destination.deletingLastPathComponent())
        try "not a directory".write(to: destination.deletingLastPathComponent(), atomically: true, encoding: .utf8)
        let failed = try SkillInstall.install(source: source, home: home, codexHome: custom)
        #expect(failed.installed.isEmpty)
        #expect(!failed.skipped.isEmpty)
        #expect(failed.skipped.first?.reason.hasPrefix("\(destination.path): ") == true)
        try assertDefaultUntouched()
    }

    @Test func testMissingCustomRootSkipsCodexWithoutCreatingItOrUsingDefault() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.removeItem(at: custom)
        let report = try SkillInstall.install(source: source, home: home, codexHome: custom)
        #expect(!report.skipped.isEmpty)
        #expect(report.installed == [SkillInstall.Target(agent: "Claude Code", skillDirectory: home.path + "/.claude/skills/agterm")])
        #expect(report.skipped.first?.reason == "no \(custom.path) found")
        let outcome = try installHooks(codexHome: custom)
        #expect(outcome == .noCodex)
        #expect(!FileManager.default.fileExists(atPath: custom.path))
        try assertDefaultUntouched()
    }

    @Test func testDefaultSkillReportRetainsItsPathsAndReasons() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = try SkillInstall.install(source: source, home: home)
        #expect(report.skipped.isEmpty)
        #expect(report.installed == [SkillInstall.Target(agent: "Codex", skillDirectory: defaultCodex.path + "/skills/agterm")])
        #expect(FileManager.default.fileExists(atPath: defaultCodex.appendingPathComponent("skills/agterm/SKILL.md").path))
        try "user skill".write(to: defaultCodex.appendingPathComponent("skills/agterm/SKILL.md"), atomically: true, encoding: .utf8)
        let skipped = try SkillInstall.install(source: source, home: home)
        #expect(skipped.installed.isEmpty)
        #expect(!skipped.skipped.isEmpty)
        #expect(skipped.skipped.first?.reason == "a different 'agterm' skill is already there — left untouched")
    }

    @Test func testMissingDefaultRootSkipsCodexWithoutCreatingIt() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.removeItem(at: defaultCodex)
        let result = try SkillInstall.install(source: source, home: home)
        #expect(result.installed == [SkillInstall.Target(agent: "Claude Code", skillDirectory: home.path + "/.claude/skills/agterm")])
        #expect(result.skipped.isEmpty)
        #expect(try installHooks(codexHome: nil) == .noCodex)
        #expect(!FileManager.default.fileExists(atPath: defaultCodex.path))
    }

    @Test func testCustomHooksMergeBacksUpPreservesPermissionsAndIsIdempotent() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = custom.appendingPathComponent("config.toml")
        let original = "model = \"test\"\n"
        try original.write(to: config, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        #expect(try installHooks(codexHome: custom) == .merged)
        let backup = URL(fileURLWithPath: AgentHooksInstall.backupPath(for: config.path))
        #expect(try String(contentsOf: backup, encoding: .utf8) == original)
        #expect(AgentHooksInstall.posixMode(ofFile: config.path)?.intValue == 0o600)
        #expect(AgentHooksInstall.posixMode(ofFile: backup.path)?.intValue == 0o600)
        let merged = try String(contentsOf: config, encoding: .utf8)
        #expect(merged.contains(AgentHooksFiles.destination(home: home).path))
        #expect(merged.contains(original))
        #expect(try installHooks(codexHome: custom) == .alreadyConfigured)
        #expect(try String(contentsOf: backup, encoding: .utf8) == original)
        #expect(try String(contentsOf: config, encoding: .utf8) == merged)
        try assertDefaultUntouched()
    }

    @Test func testCustomHooksPreserveSymlinkAndForeignOrUnreadableConfig() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = custom.appendingPathComponent("config.toml")
        let target = directory.appendingPathComponent("linked.toml")
        try "model = \"test\"\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: target)
        #expect(try installHooks(codexHome: custom) == .merged)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: config.path) == target.path)
        for (contents, expected) in [("[[hooks.Stop]]\ncommand = \"mine\"\n", AgentHooksFiles.CodexResult.hooksExist),
                                     ("invalid = [", .unparseable)] {
            try contents.write(to: target, atomically: true, encoding: .utf8)
            #expect(try installHooks(codexHome: custom) == expected)
            #expect(try String(contentsOf: target, encoding: .utf8) == contents)
        }
        try Data([0xff]).write(to: target)
        #expect(try installHooks(codexHome: custom) == .unreadable)
        #expect(try Data(contentsOf: target) == Data([0xff]))
        try assertDefaultUntouched()
    }

    private func assertDefaultUntouched() throws {
        #expect(try String(contentsOf: defaultCodex.appendingPathComponent("config.toml"), encoding: .utf8) == "default config")
        #expect(!FileManager.default.fileExists(atPath: defaultCodex.appendingPathComponent("config.toml.bak").path))
        #expect(!FileManager.default.fileExists(atPath: defaultCodex.appendingPathComponent("skills").path))
    }
}
