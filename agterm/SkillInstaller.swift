import AppKit
import agtermCore

/// Installs the bundled agent skill into the skills directories of the coding agents present on the machine:
/// Claude Code (`~/.claude/skills/agterm/`) and Codex (`~/.codex/skills/agterm/`), both using the same
/// SKILL.md Agent-Skill format, so an agent running INSIDE an agterm session learns to drive the app via
/// `agtermctl`. The copy is `agtermCore.SkillInstall.install`; this type owns the alert. Idempotent, and it
/// refuses to overwrite a same-named skill the user authored.
@MainActor
enum SkillInstaller {
    /// The bundled source folder at `Contents/Resources/agterm`, or nil when this build skipped the
    /// resource bundling (e.g. a bare `swift build`). The name follows the skill directory's own
    /// basename in `plugins/agterm/skills/agterm`, which `project.yml` copies verbatim.
    private static var bundledFolder: URL? {
        Bundle.main.resourceURL?.appendingPathComponent(SkillInstall.skillName)
    }

    private typealias Report = SkillInstall.Report

    /// Run the install and show a result alert.
    static func run() {
        Task { await AgentInstallers.run(skill: true, hooks: false) }
    }

    static func run(probe: OpenCodeEnvironmentProbe.Result?) {
        // install throws only for a missing source; a failed copy is a per-target skip in the report
        guard let source = bundledFolder,
              let report = try? SkillInstall.install(source: source, home: FileManager.default.homeDirectoryForCurrentUser,
                                                     codexHome: probe?.codexHome.map { URL(fileURLWithPath: $0) }) else {
            present(style: .warning, title: "Install Failed", text: "The agent skill is not bundled in this build.")
            return
        }
        let problem = report.installed.isEmpty || !report.skipped.isEmpty
        present(style: problem ? .warning : .informational,
                title: report.installed.isEmpty ? "Skill Not Installed" : "Agent Skill Installed",
                text: message(report))
    }

    private static func message(_ report: Report) -> String {
        var lines: [String] = []
        if report.installed.isEmpty {
            lines.append("The skill was not installed.")
        } else {
            lines.append("Installed for:")
            for entry in report.installed { lines.append("  • \(entry.agent): \(entry.skillDirectory)") }
            lines.append("")
            lines.append("The agent uses it automatically when you ask it to control agterm. It drives the "
                + "app via the agtermctl CLI, so install that too if you haven't: Help ▸ Install Command Line Tool…")
        }
        if !report.skipped.isEmpty {
            lines.append("")
            lines.append("Skipped:")
            for entry in report.skipped { lines.append("  • \(entry.agent): \(entry.reason)") }
        }
        if report.freshSkillsDir {
            lines.append("")
            lines.append("A skills directory was created for the first time — restart any running agent session "
                + "so it picks up the new skill.")
        }
        return lines.joined(separator: "\n")
    }

    private static func present(style: NSAlert.Style, title: String, text: String) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
