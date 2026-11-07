import AppKit
import agtermCore

/// Installs the bundled agent skill into the skills directories of the coding agents present on the machine:
/// Claude Code (`~/.claude/skills/agterm/`) and Codex (`~/.codex/skills/agterm/`), both using the same
/// SKILL.md Agent-Skill format, so an agent running INSIDE an agterm session learns to drive the app via
/// `agtermctl`. The host-free path/target/ownership logic is `agtermCore.SkillInstall`; this type owns the
/// AppKit filesystem glue. Idempotent, and it refuses to overwrite a same-named skill the user authored.
@MainActor
enum SkillInstaller {
    private struct InstallError: Error { let message: String }

    /// The bundled source folder at `Contents/Resources/agterm`, or nil when this build skipped the
    /// resource bundling (e.g. a bare `swift build`). The name follows the skill directory's own
    /// basename in `plugins/agterm/skills/agterm`, which `project.yml` copies verbatim.
    private static var bundledFolder: URL? {
        Bundle.main.resourceURL?.appendingPathComponent(SkillInstall.skillName)
    }

    private struct Report {
        var installed: [(agent: String, path: String)] = []
        var skipped: [(agent: String, reason: String)] = []
        var freshSkillsDir = false
    }

    /// Run the install and show a result alert.
    static func run() {
        Task { await AgentInstallers.run(skill: true, hooks: false) }
    }

    static func run(probe: OpenCodeEnvironmentProbe.Result?) {
        do {
            let result = try install(codexHome: probe?.codexHome)
            present(style: result.warning ? .warning : .informational,
                    title: result.installed ? "Agent Skill Installed" : "Skill Not Installed",
                    text: result.text)
        } catch let error as InstallError {
            present(style: .warning, title: "Install Failed", text: error.message)
        } catch {
            present(style: .warning, title: "Install Failed", text: error.localizedDescription)
        }
    }

    // Internal so hosted fixtures can install into temporary roots without opening a modal.
    static func install(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                        codexHome: String? = nil, source: URL? = bundledFolder) throws -> (installed: Bool, warning: Bool, text: String) {
        guard let source, FileManager.default.fileExists(atPath: source.path) else {
            throw InstallError(message: "The agent skill is not bundled in this build.")
        }
        let fm = FileManager.default
        let codexDirectory = codexHome ?? home + "/.codex"
        let codexExists = fm.fileExists(atPath: codexDirectory)
        let skipPrefixes = codexHome.map { ["Codex": $0 + "/skills/" + SkillInstall.skillName + ": "] } ?? [:]
        let targets = SkillInstall.installTargets(home: home,
                                                  claudeExists: fm.fileExists(atPath: home + "/.claude"),
                                                  codexExists: codexExists,
                                                  codexHome: codexDirectory)
        var report = Report()
        if codexHome != nil, !codexExists {
            report.skipped.append(("Codex", "no \(codexDirectory) found"))
        }
        for target in targets {
            let destination = URL(fileURLWithPath: target.skillDirectory)
            // refuse to clobber a same-named skill the user authored (a present dir whose SKILL.md is
            // absent, unreadable, or lacks the agterm marker). `attributesOfItem` uses lstat semantics (does
            // NOT follow the final symlink), so any symlink at the destination counts as present —
            // `fileExists(atPath:)` follows it and reads a dangling one as absent, letting the wipe path
            // delete the user's own symlink.
            let directoryExists = (try? fm.attributesOfItem(atPath: destination.path)) != nil
            let existingSKILL = try? String(contentsOf: destination.appendingPathComponent("SKILL.md"), encoding: .utf8)
            guard SkillInstall.mayOverwrite(directoryExists: directoryExists, existingSKILL: existingSKILL) else {
                let reason = "a different '\(SkillInstall.skillName)' skill is already there — left untouched"
                report.skipped.append((target.agent, skipPrefixes[target.agent, default: ""] + reason))
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
                report.skipped.append((target.agent, skipPrefixes[target.agent, default: ""] + error.localizedDescription))
            }
        }
        return (!report.installed.isEmpty, report.installed.isEmpty || !report.skipped.isEmpty, message(report))
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
