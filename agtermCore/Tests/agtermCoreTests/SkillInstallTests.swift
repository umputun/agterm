import Foundation
import Testing
@testable import agtermCore

struct SkillInstallTests {
    @Test func bundledSkillDocumentsEventSubscriptionCommand() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let skillDirectory = repository.appendingPathComponent("agterm/Resources/agent-skill")
        let skill = try String(contentsOf: skillDirectory.appendingPathComponent("SKILL.md"), encoding: .utf8)
        let reference = try String(contentsOf: skillDirectory.appendingPathComponent("reference.md"), encoding: .utf8)
        let examples = try String(contentsOf: skillDirectory.appendingPathComponent("examples.md"), encoding: .utf8)

        #expect(skill.contains("Command summary (65 commands)"))
        #expect(skill.contains("**events**"))
        #expect(reference.contains("## events"))
        #expect(reference.contains("event cursor expired"))
        #expect(examples.contains("agtermctl events --json"))
    }

    @Test func skillDirectoryComposesUnderAgentBase() {
        #expect(SkillInstall.skillDirectory(home: "/Users/x", base: ".claude") == "/Users/x/.claude/skills/agterm")
        #expect(SkillInstall.skillDirectory(home: "/Users/x", base: ".codex") == "/Users/x/.codex/skills/agterm")
        #expect(SkillInstall.skillName == "agterm")
    }

    @Test func targetsCoverBothWhenBothExist() {
        let t = SkillInstall.installTargets(home: "/h", claudeExists: true, codexExists: true)
        #expect(t == [
            .init(agent: "Claude Code", skillDirectory: "/h/.claude/skills/agterm"),
            .init(agent: "Codex", skillDirectory: "/h/.codex/skills/agterm"),
        ])
    }

    @Test func targetsCodexOnlyWhenOnlyCodexExists() {
        let t = SkillInstall.installTargets(home: "/h", claudeExists: false, codexExists: true)
        #expect(t == [.init(agent: "Codex", skillDirectory: "/h/.codex/skills/agterm")])
    }

    @Test func targetsFallBackToClaudeWhenNeitherExists() {
        let t = SkillInstall.installTargets(home: "/h", claudeExists: false, codexExists: false)
        #expect(t == [.init(agent: "Claude Code", skillDirectory: "/h/.claude/skills/agterm")])
    }

    @Test func mayOverwriteWhenDirectoryAbsent() {
        #expect(SkillInstall.mayOverwrite(directoryExists: false, existingSKILL: nil) == true)
    }

    @Test func refusesOverwriteOfDirectoryWithoutSkillFile() {
        #expect(SkillInstall.mayOverwrite(directoryExists: true, existingSKILL: nil) == false)
    }

    @Test func mayOverwriteWhenMarkerPresent() {
        let contents = "---\nx\n---\n\(SkillInstall.marker)\nbody"
        #expect(SkillInstall.mayOverwrite(directoryExists: true, existingSKILL: contents) == true)
    }

    @Test func refusesOverwriteOfForeignSkill() {
        let contents = "---\ndescription: someone else's agterm\n---\nbody"
        #expect(SkillInstall.mayOverwrite(directoryExists: true, existingSKILL: contents) == false)
    }
}
