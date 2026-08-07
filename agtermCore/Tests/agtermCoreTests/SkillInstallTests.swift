import Foundation
import Testing
@testable import agtermCore

struct SkillInstallTests {
    // the repo root, four levels up from agtermCore/Tests/agtermCoreTests/<this file>
    private var repository: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func json(_ relative: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repository.appendingPathComponent(relative))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func bundledSkillDocumentsEventSubscriptionCommand() throws {
        let skillDirectory = repository.appendingPathComponent("plugins/agterm/skills/agterm")
        let skill = try String(contentsOf: skillDirectory.appendingPathComponent("SKILL.md"), encoding: .utf8)
        let reference = try String(contentsOf: skillDirectory.appendingPathComponent("reference.md"), encoding: .utf8)
        let examples = try String(contentsOf: skillDirectory.appendingPathComponent("examples.md"), encoding: .utf8)

        #expect(skill.contains("Command summary (76 commands)"))
        #expect(skill.contains("`keymap list`"))
        #expect(reference.contains("`agtermctl keymap list`"))
        #expect(examples.contains("agtermctl keymap list"))
        #expect(skill.contains("**events**"))
        #expect(reference.contains("## events"))
        #expect(reference.contains("event cursor expired"))
        #expect(examples.contains("agtermctl events --json"))
        #expect(skill.contains("minimize <id> [on|off|toggle]"))
        #expect(reference.contains("`window minimize <id> [on|off|toggle]`"))
        #expect(examples.contains("agtermctl window minimize"))
        #expect(skill.contains("focus [on|off|toggle|add]"))
        #expect(skill.contains("filter [on|off|toggle]"))
        #expect(reference.contains("`workspace focus [on|off|toggle|add] [--target] [--window W]`"))
        #expect(reference.contains("`workspace filter [on|off|toggle] [--window W]`"))
        #expect(reference.contains("`workspaceFilter`"))
        #expect(examples.contains("agtermctl workspace focus add"))
        #expect(examples.contains("agtermctl workspace filter on"))
    }

    // the plugin manifests and the app bundle read the SAME directory, so a moved skill or a renamed leaf
    // breaks one consumer silently while the others keep working.
    @Test func pluginManifestsPointAtTheBundledSkillDirectory() throws {
        let pluginRoot = "plugins/agterm"
        let skillLeaf = "skills/\(SkillInstall.skillName)"

        let claudePlugin = try json("\(pluginRoot)/.claude-plugin/plugin.json")
        let claudeSkills = try #require(claudePlugin["skills"] as? [String])
        #expect(claudeSkills == ["./\(skillLeaf)"])

        // codex takes a single parent directory and scans below it for SKILL.md
        let codexPlugin = try json("\(pluginRoot)/.codex-plugin/plugin.json")
        #expect(codexPlugin["skills"] as? String == "./skills/")

        // naming the plugin after the skill is what makes the codex namespace `agterm:agterm` and keeps
        // the claude install name stable
        #expect(claudePlugin["name"] as? String == SkillInstall.skillName)
        #expect(codexPlugin["name"] as? String == SkillInstall.skillName)

        let skill = repository.appendingPathComponent("\(pluginRoot)/\(skillLeaf)")
        for file in ["SKILL.md", "reference.md", "examples.md", "troubleshooting.md", "scripts/show-image.sh"] {
            #expect(FileManager.default.fileExists(atPath: skill.appendingPathComponent(file).path),
                    "missing \(file) in \(pluginRoot)/\(skillLeaf)")
        }
    }

    @Test func marketplacesPointAtThePluginRootAndAgreeOnVersion() throws {
        let claudeMarketplace = try json(".claude-plugin/marketplace.json")
        let claudeEntries = try #require(claudeMarketplace["plugins"] as? [[String: Any]])
        let claudeEntry = try #require(claudeEntries.first)
        #expect(claudeEntry["source"] as? String == "./plugins/agterm")

        // codex's marketplace manifest lives at .agents/plugins/, NOT alongside .codex-plugin/, and takes
        // a source object rather than a bare path
        let codexMarketplace = try json(".agents/plugins/marketplace.json")
        let codexEntries = try #require(codexMarketplace["plugins"] as? [[String: Any]])
        let codexSource = try #require(codexEntries.first?["source"] as? [String: Any])
        #expect(codexSource["source"] as? String == "local")
        #expect(codexSource["path"] as? String == "./plugins/agterm")

        // the plugin managers key their install cache on the manifest version, so bumping one and not the
        // other leaves an agent pinned to a stale skill
        let version = try #require(claudeEntry["version"] as? String)
        #expect(try json("plugins/agterm/.claude-plugin/plugin.json")["version"] as? String == version)
        #expect(try json("plugins/agterm/.codex-plugin/plugin.json")["version"] as? String == version)
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
