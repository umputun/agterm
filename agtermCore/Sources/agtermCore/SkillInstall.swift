import Foundation

/// Pure, host-free helpers for installing the bundled agent skill (`agterm`) into the skills
/// directories of Claude Code (`~/.claude/skills`) and Codex (`~/.codex/skills`) — both use the same
/// SKILL.md Agent-Skill format. The app side (`SkillInstaller`) does the filesystem copy and the
/// base-dir existence checks; this type owns the testable path + target-selection + ownership logic.
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

    /// Whether the installer may overwrite a destination. An absent directory is always safe (nothing to
    /// clobber). An existing one is overwritable only when its `SKILL.md` carries `marker` (agterm put it
    /// there); an absent, unreadable, or unmarked `SKILL.md` counts as user-authored and is refused, so a
    /// user's own skill named `agterm` is preserved rather than recursively wiped.
    public static func mayOverwrite(directoryExists: Bool, existingSKILL contents: String?) -> Bool {
        guard directoryExists else { return true }
        guard let contents else { return false }
        return contents.contains(marker)
    }
}
