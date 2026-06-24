import Testing
@testable import agtermCore

struct SkillInstallTests {
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

    @Test func mayOverwriteWhenNoExistingFile() {
        #expect(SkillInstall.mayOverwrite(existingSKILL: nil) == true)
    }

    @Test func mayOverwriteWhenMarkerPresent() {
        #expect(SkillInstall.mayOverwrite(existingSKILL: "---\nx\n---\n\(SkillInstall.marker)\nbody") == true)
    }

    @Test func refusesOverwriteOfForeignSkill() {
        #expect(SkillInstall.mayOverwrite(existingSKILL: "---\ndescription: someone else's agterm\n---\nbody") == false)
    }
}
