import AppKit
import agtermCore

/// Installs the bundled agent skill into the skills directories of the coding agents present on the
/// machine: Claude Code (`~/.claude/skills/agterm/`) and Codex (`~/.codex/skills/agterm/`) — both use
/// the same SKILL.md Agent-Skill format. So an agent running INSIDE an agterm session learns how to
/// drive the app via `agtermctl`. The host-free path/target/ownership logic lives in
/// `agtermCore.SkillInstall`; this type owns the AppKit filesystem glue. Idempotent: re-running
/// refreshes the skill. It refuses to overwrite a same-named skill the user authored themselves.
@MainActor
enum SkillInstaller {
    private struct InstallError: Error { let message: String }

    /// The bundled source folder at `Contents/Resources/agent-skill`, or nil when this build skipped
    /// the resource bundling (e.g. a bare `swift build`).
    private static var bundledFolder: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("agent-skill")
    }

    private struct Report {
        var installed: [(agent: String, path: String)] = []
        var skipped: [(agent: String, reason: String)] = []
        var freshSkillsDir = false
    }

    /// Run the install and show a result alert.
    static func run() {
        do {
            let report = try install()
            let problem = report.installed.isEmpty || !report.skipped.isEmpty
            present(style: problem ? .warning : .informational,
                    title: report.installed.isEmpty ? "Skill Not Installed" : "Agent Skill Installed",
                    text: message(report))
        } catch let error as InstallError {
            present(style: .warning, title: "Install Failed", text: error.message)
        } catch {
            present(style: .warning, title: "Install Failed", text: error.localizedDescription)
        }
    }

    private static func install() throws -> Report {
        guard let source = bundledFolder, FileManager.default.fileExists(atPath: source.path) else {
            throw InstallError(message: "The agent skill is not bundled in this build.")
        }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let targets = SkillInstall.installTargets(home: home,
                                                  claudeExists: fm.fileExists(atPath: home + "/.claude"),
                                                  codexExists: fm.fileExists(atPath: home + "/.codex"))
        var report = Report()
        for target in targets {
            let destination = URL(fileURLWithPath: target.skillDirectory)
            // refuse to clobber a same-named skill the user authored themselves (a present dir whose
            // SKILL.md is absent, unreadable, or lacks the agterm marker). `attributesOfItem` uses lstat
            // semantics (does NOT follow the final symlink), so a dangling/any symlink at the destination
            // counts as present too — unlike `fileExists(atPath:)`, which follows the link and would read a
            // dangling symlink as absent, letting the wipe path delete the user's own symlink.
            let directoryExists = (try? fm.attributesOfItem(atPath: destination.path)) != nil
            let existingSKILL = try? String(contentsOf: destination.appendingPathComponent("SKILL.md"), encoding: .utf8)
            guard SkillInstall.mayOverwrite(directoryExists: directoryExists, existingSKILL: existingSKILL) else {
                report.skipped.append((target.agent, "a different '\(SkillInstall.skillName)' skill is already there — left untouched"))
                continue
            }
            do {
                let skillsDir = destination.deletingLastPathComponent()
                if !fm.fileExists(atPath: skillsDir.path) { report.freshSkillsDir = true }
                try fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)
                try? fm.removeItem(at: destination) // drop a prior agterm install (ignore if absent)
                try fm.copyItem(at: source, to: destination)
                report.installed.append((target.agent, destination.path))
            } catch {
                report.skipped.append((target.agent, error.localizedDescription))
            }
        }
        return report
    }

    private static func message(_ report: Report) -> String {
        var lines: [String] = []
        if report.installed.isEmpty {
            lines.append("The skill was not installed.")
        } else {
            lines.append("Installed for:")
            for entry in report.installed { lines.append("  • \(entry.agent): \(entry.path)") }
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
