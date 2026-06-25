import Foundation

/// Pure, host-free helpers for installing the bundled agent skill (`agterm`) into the skills
/// directories of Claude Code (`~/.claude/skills`) and Codex (`~/.codex/skills`) — both use the same
/// SKILL.md Agent-Skill format. The app side (`SkillInstaller`) does the filesystem copy and the
/// base-dir existence checks; this type owns the testable path + target-selection + ownership logic.
public enum SkillInstall {
    /// The skill's directory name under each agent's `skills/`, also its command name.
    public static let skillName = "agterm"

    /// A sentinel embedded in the bundled `SKILL.md` (an HTML comment, invisible when rendered) so a
    /// reinstall can tell an agterm-authored skill from a same-named skill the user wrote themselves,
    /// and refuse to clobber the latter.
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

    /// The install targets given which agent base dirs exist. Install into each agent that is present
    /// (Claude Code and/or Codex); if NEITHER is present, fall back to creating Claude Code's (the
    /// primary), so the install is never a no-op. Caller supplies the existence flags (a filesystem
    /// check), keeping this pure and testable.
    public static func installTargets(home: String, claudeExists: Bool, codexExists: Bool) -> [Target] {
        var targets: [Target] = []
        if claudeExists {
            targets.append(Target(agent: "Claude Code", skillDirectory: skillDirectory(home: home, base: ".claude")))
        }
        if codexExists {
            targets.append(Target(agent: "Codex", skillDirectory: skillDirectory(home: home, base: ".codex")))
        }
        if targets.isEmpty {
            targets.append(Target(agent: "Claude Code", skillDirectory: skillDirectory(home: home, base: ".claude")))
        }
        return targets
    }

    /// Whether the installer may overwrite a destination. An absent directory is always safe to write
    /// (nothing to clobber). When the directory already exists, it is overwritable only when its
    /// `SKILL.md` carries `marker` (i.e. agterm put it there) — a present directory with an absent,
    /// unreadable, or unmarked `SKILL.md` is treated as user-authored content and refused, so a user's
    /// own skill named `agterm` is preserved rather than recursively wiped.
    public static func mayOverwrite(directoryExists: Bool, existingSKILL contents: String?) -> Bool {
        guard directoryExists else { return true }
        guard let contents else { return false }
        return contents.contains(marker)
    }
}
