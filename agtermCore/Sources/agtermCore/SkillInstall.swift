import Foundation

/// SkillInstall installs the agent skill (`agterm`) into Claude Code's and Codex's skills directories, which share
/// the SKILL.md format; the Mac app and agterm-server share it.
public enum SkillInstall {
    /// The skill's directory name under each agent's `skills/`, also its command name.
    public static let skillName = "agterm"

    /// A sentinel embedded in the bundled `SKILL.md` (an HTML comment, invisible when rendered) so a
    /// reinstall can tell an agterm-authored skill from a user's own same-named one, and refuse to
    /// clobber the latter.
    public static let marker = "<!-- agterm-skill -->"

    /// One install destination: which agent, and the `…/skills/agterm` directory to write.
    public struct Target: Equatable, Sendable {
        public let agent: String          // human label, e.g. "Claude Code"
        public let skillDirectory: String // the install path, e.g. <home>/.claude/skills/agterm
        public init(agent: String, skillDirectory: String) {
            self.agent = agent
            self.skillDirectory = skillDirectory
        }
    }

    /// The skill destination under an agent base dir. `base` is the dotted directory name (e.g.
    /// `.claude` or `.codex`), so the result is `<home>/<base>/skills/agterm`.
    public static func skillDirectory(home: String, base: String) -> String {
        home + "/" + base + "/skills/" + skillName
    }

    /// The install targets given which agent base dirs exist: each agent that is present (Claude Code
    /// and/or Codex), falling back to creating Claude Code's (the primary) when NEITHER is, so the install
    /// is never a no-op. The caller supplies the existence flags (a filesystem check), keeping this pure.
    public static func installTargets(home: String, claudeExists: Bool, codexExists: Bool) -> [Target] {
        installTargets(home: home, claudeExists: claudeExists, codexExists: codexExists, codexHome: home + "/.codex")
    }

    /// Uses the resolved Codex root; `codexExists` describes that root, not the default directory.
    public static func installTargets(home: String, claudeExists: Bool, codexExists: Bool, codexHome: String) -> [Target] {
        var targets: [Target] = []
        if claudeExists {
            targets.append(Target(agent: "Claude Code", skillDirectory: skillDirectory(home: home, base: ".claude")))
        }
        if codexExists {
            targets.append(Target(agent: "Codex", skillDirectory: codexHome + "/skills/" + skillName))
        }
        if targets.isEmpty {
            targets.append(Target(agent: "Claude Code", skillDirectory: skillDirectory(home: home, base: ".claude")))
        }
        return targets
    }

    /// Whether the installer may overwrite a destination. An absent directory is always safe (nothing to
    /// clobber). An existing one is overwritable only when its `SKILL.md` carries `marker` (agterm put it
    /// there); an absent, unreadable, or unmarked `SKILL.md` counts as user-authored and is refused, so a
    /// user's own skill named `agterm` is preserved rather than recursively wiped.
    public static func mayOverwrite(directoryExists: Bool, existingSKILL contents: String?) -> Bool {
        guard directoryExists else { return true }
        guard let contents else { return false }
        return contents.contains(marker)
    }

    /// Report is what one install did per target.
    public struct Report: Equatable, Sendable {
        public struct Skip: Equatable, Sendable {
            public let agent: String
            public let reason: String
        }

        public internal(set) var installed: [Target] = []
        public internal(set) var skipped: [Skip] = []
        /// freshSkillsDir is true when a skills directory was created, which a running agent notices only on restart.
        public internal(set) var freshSkillsDir = false
    }

    /// MissingSource is thrown when the skill directory to copy does not exist.
    public struct MissingSource: Error, Equatable {}

    /// `codexHome` selects an existing custom root; a missing root is reported and never falls back.
    /// install copies `source` into every target `installTargets` picks for `home`, leaving a user-authored skill alone.
    public static func install(source: URL, home: URL, codexHome: URL? = nil) throws -> Report {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { throw MissingSource() }
        let codexDirectory = codexHome ?? home.appendingPathComponent(".codex")
        let codexExists = fm.fileExists(atPath: codexDirectory.path)
        let targets = installTargets(home: home.path,
                                     claudeExists: fm.fileExists(atPath: home.path + "/.claude"),
                                     codexExists: codexExists, codexHome: codexDirectory.path)
        var report = Report()
        if codexHome != nil, !codexExists {
            report.skipped.append(Report.Skip(agent: "Codex", reason: "no \(codexDirectory.path) found"))
        }
        for target in targets {
            let destination = URL(fileURLWithPath: target.skillDirectory)
            let prefix = target.agent == "Codex" && codexHome != nil ? target.skillDirectory + ": " : ""
            // lstat semantics: a dangling symlink counts as present, where `fileExists` would read it as absent
            // and let the wipe below delete the user's link
            let directoryExists = (try? fm.attributesOfItem(atPath: destination.path)) != nil
            let existingSKILL = try? String(contentsOf: destination.appendingPathComponent("SKILL.md"), encoding: .utf8)
            guard mayOverwrite(directoryExists: directoryExists, existingSKILL: existingSKILL) else {
                report.skipped.append(Report.Skip(agent: target.agent, reason: prefix + "a different '\(skillName)' skill is already there — left untouched"))
                continue
            }
            do {
                let skillsDir = destination.deletingLastPathComponent()
                if !fm.fileExists(atPath: skillsDir.path) { report.freshSkillsDir = true }
                try fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)
                try? fm.removeItem(at: destination)
                try DirectoryCopy.copy(source, to: destination)
                report.installed.append(target)
            } catch {
                report.skipped.append(Report.Skip(agent: target.agent, reason: prefix + error.localizedDescription))
            }
        }
        return report
    }
}
