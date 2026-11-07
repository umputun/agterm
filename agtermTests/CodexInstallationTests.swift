import Foundation
import XCTest
import agtermCore
@testable import agterm

@MainActor
final class CodexInstallationTests: XCTestCase {
    private var directory: URL!
    private var home: URL { directory.appendingPathComponent("home") }
    private var custom: URL { directory.appendingPathComponent("custom codex") }
    private var defaultCodex: URL { home.appendingPathComponent(".codex") }
    private var source: URL { directory.appendingPathComponent("source") }
    private var scripts: URL { directory.appendingPathComponent("scripts") }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-install-\(UUID().uuidString)")
        for folder in [home, custom, defaultCodex, source] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try "\(SkillInstall.marker)\nbundled skill".write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "default config".write(to: defaultCodex.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testCustomSkillInstallationAndRefreshPreserveDefaultRoot() throws {
        let first = try SkillInstaller.install(home: home.path, codexHome: custom.path, source: source)
        let installed = custom.appendingPathComponent("skills/agterm/SKILL.md")
        XCTAssertTrue(first.installed)
        XCTAssertFalse(first.warning)
        XCTAssertTrue(first.text.contains("  • Codex: \(custom.path)/skills/agterm"))
        try "\(SkillInstall.marker)\nupdated".write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let repeated = try SkillInstaller.install(home: home.path, codexHome: custom.path, source: source)
        XCTAssertTrue(repeated.installed)
        XCTAssertFalse(repeated.warning)
        XCTAssertEqual(try String(contentsOf: installed, encoding: .utf8), "\(SkillInstall.marker)\nupdated")
        try assertDefaultUntouched()
    }

    func testCustomSkillOwnershipAndWriteFailureMessagesIncludeDestination() throws {
        let destination = custom.appendingPathComponent("skills/agterm")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let skill = destination.appendingPathComponent("SKILL.md")
        try "user skill".write(to: skill, atomically: true, encoding: .utf8)
        let owned = try SkillInstaller.install(home: home.path, codexHome: custom.path, source: source)
        XCTAssertFalse(owned.installed)
        XCTAssertTrue(owned.warning)
        XCTAssertTrue(owned.text.contains("  • Codex: \(destination.path): a different 'agterm' skill is already there — left untouched"))
        XCTAssertEqual(try String(contentsOf: skill, encoding: .utf8), "user skill")
        try FileManager.default.removeItem(at: destination.deletingLastPathComponent())
        try "not a directory".write(to: destination.deletingLastPathComponent(), atomically: true, encoding: .utf8)
        let failed = try SkillInstaller.install(home: home.path, codexHome: custom.path, source: source)
        XCTAssertFalse(failed.installed)
        XCTAssertTrue(failed.warning)
        XCTAssertTrue(failed.text.contains("  • Codex: \(destination.path): "))
        try assertDefaultUntouched()
    }

    func testMissingCustomRootSkipsCodexWithoutCreatingItOrUsingDefault() throws {
        try FileManager.default.removeItem(at: custom)
        let report = try SkillInstaller.install(home: home.path, codexHome: custom.path, source: source)
        XCTAssertTrue(report.installed)
        XCTAssertTrue(report.warning)
        XCTAssertTrue(report.text.contains("  • Claude Code: \(home.path)/.claude/skills/agterm"))
        XCTAssertTrue(report.text.contains("  • Codex: no \(custom.path) found"))
        let outcome = try AgentHooksInstaller.mergeCodexConfig(codexDirectory: custom, scriptDirectory: scripts)
        XCTAssertEqual(outcome, .noCodex)
        XCTAssertFalse(FileManager.default.fileExists(atPath: custom.path))
        try assertDefaultUntouched()
    }

    func testDefaultSkillMessagesRetainTheirWording() throws {
        let report = try SkillInstaller.install(home: home.path, source: source)
        XCTAssertTrue(report.installed)
        XCTAssertFalse(report.warning)
        XCTAssertTrue(report.text.contains("  • Codex: \(defaultCodex.path)/skills/agterm"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: defaultCodex.appendingPathComponent("skills/agterm/SKILL.md").path))
        try "user skill".write(to: defaultCodex.appendingPathComponent("skills/agterm/SKILL.md"), atomically: true, encoding: .utf8)
        let skipped = try SkillInstaller.install(home: home.path, source: source)
        XCTAssertFalse(skipped.installed)
        XCTAssertTrue(skipped.warning)
        XCTAssertTrue(skipped.text.contains("  • Codex: a different 'agterm' skill is already there — left untouched"))
    }

    func testMissingDefaultRootSkipsCodexWithoutCreatingIt() throws {
        try FileManager.default.removeItem(at: defaultCodex)
        let result = try SkillInstaller.install(home: home.path, source: source)
        XCTAssertTrue(result.installed)
        XCTAssertFalse(result.warning)
        XCTAssertTrue(result.text.contains("  • Claude Code: \(home.path)/.claude/skills/agterm"))
        XCTAssertFalse(result.text.contains("  • Codex:"))
        XCTAssertEqual(try AgentHooksInstaller.mergeCodexConfig(codexDirectory: defaultCodex, scriptDirectory: scripts), .noCodex)
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultCodex.path))
    }

    func testCustomHooksMergeBacksUpPreservesPermissionsAndIsIdempotent() throws {
        let config = custom.appendingPathComponent("config.toml")
        let original = "model = \"test\"\n"
        try original.write(to: config, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        XCTAssertEqual(try AgentHooksInstaller.mergeCodexConfig(codexDirectory: custom, scriptDirectory: scripts), .merged)
        let backup = URL(fileURLWithPath: AgentHooksInstall.backupPath(for: config.path))
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), original)
        XCTAssertEqual(AgentHooksInstall.posixMode(ofFile: config.path)?.intValue, 0o600)
        XCTAssertEqual(AgentHooksInstall.posixMode(ofFile: backup.path)?.intValue, 0o600)
        let merged = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(merged.contains(scripts.path))
        XCTAssertTrue(merged.contains(original))
        XCTAssertEqual(try AgentHooksInstaller.mergeCodexConfig(codexDirectory: custom, scriptDirectory: scripts), .alreadyConfigured)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), original)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), merged)
        try assertDefaultUntouched()
    }

    func testCustomHooksPreserveSymlinkAndForeignOrUnreadableConfig() throws {
        let config = custom.appendingPathComponent("config.toml")
        let target = directory.appendingPathComponent("linked.toml")
        try "model = \"test\"\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: target)
        XCTAssertEqual(try AgentHooksInstaller.mergeCodexConfig(codexDirectory: custom, scriptDirectory: scripts), .merged)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: config.path), target.path)
        for (contents, expected) in [("[[hooks.Stop]]\ncommand = \"mine\"\n", AgentHooksInstaller.CodexResult.hooksExist),
                                     ("invalid = [", .unparseable)] {
            try contents.write(to: target, atomically: true, encoding: .utf8)
            XCTAssertEqual(try AgentHooksInstaller.mergeCodexConfig(codexDirectory: custom, scriptDirectory: scripts), expected)
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), contents)
        }
        try Data([0xff]).write(to: target)
        XCTAssertEqual(try AgentHooksInstaller.mergeCodexConfig(codexDirectory: custom, scriptDirectory: scripts), .unreadable)
        XCTAssertEqual(try Data(contentsOf: target), Data([0xff]))
        try assertDefaultUntouched()
    }

    private func assertDefaultUntouched() throws {
        XCTAssertEqual(try String(contentsOf: defaultCodex.appendingPathComponent("config.toml"), encoding: .utf8), "default config")
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultCodex.appendingPathComponent("config.toml.bak").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultCodex.appendingPathComponent("skills").path))
    }
}
