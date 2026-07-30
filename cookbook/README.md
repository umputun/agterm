# agterm cookbook

Installable `agtermctl` workflows. Each recipe is a directory holding a README and, where it needs one, its scripts: what it does, what it needs, how to set it up, and where it stops. They are written to be copied into your own setup and edited, not only read.

Recipes come from other people as well as the maintainer. Every one is reviewed before it is accepted, but they are shell scripts you run on your own machine against your own sessions, and several close sessions or delete workspaces, so read a recipe before you run it.

## Recipes

| recipe | what it does | needs |
|---|---|---|
| [project-switcher](project-switcher/) | show only one project's workspaces in the sidebar | 0.18.0, jq |
| [workspace-sets](workspace-sets/) | switch the sidebar between named groups of workspaces, one chord each | 0.18.0, jq |
| [park-and-resume](park-and-resume/) | close a project's workspaces, bring them back later | 0.16.0, jq, zsh |
| [window-per-project](window-per-project/) | park every other window in the Dock and raise one | 0.17.1, jq |
| [fzf-path-picker](fzf-path-picker/) | pick a path with fzf and type it into the shell | 0.8.0, fzf, fd, zsh |
| [native-dir-picker](native-dir-picker/) | pick a directory in the native picker and type it into the shell | 0.19.0, fd, jq |
| [overlay-and-split](overlay-and-split/) | keymap lines: a stateful split toggle and TUI overlays | 0.10.0, jq |
| [status-announcer](status-announcer/) | demo: speak agent status changes from a dedicated session | 0.16.0, jq |
| [claude-session-resume](claude-session-resume/) | each tab reopens its own Claude Code conversation after a restart | 0.3.1, zsh, Claude Code |
| [codex-session-resume](codex-session-resume/) | each tab reopens its own codex conversation after a restart | 0.3.1, zsh, Codex CLI |
| [opencode-session-resume](opencode-session-resume/) | each tab reopens its own opencode conversation after a restart | 0.3.1, zsh, opencode |
| [new-session-in-workspace](new-session-in-workspace/) | pick a workspace with fzf and start a session in it | 0.8.0, jq, fzf |

Most recipes need `agtermctl` on your PATH; **Help ▸ Install Command Line Tool…** puts it there. The three session-resume recipes are shell functions that read the environment agterm gives a session and never call the CLI. Some recipes also need `jq`, `fzf`, or a particular shell, and each recipe's *Requirements* section says which, along with the minimum agterm version it needs. Recipes are snapshots rather than a maintained surface: the control API grows by addition, so they rarely break, and one that does gets fixed when it is reported.

## Contributing a recipe

[CONTRIBUTING.md](CONTRIBUTING.md) in this directory has the rules: ship a workflow you actually run, one kebab-case directory, the six-heading README template, and an index row in the same pull request.

For the command surface itself, the [command reference](https://agterm.com/commands) documents every `agtermctl` command with its arguments and return shape. The bundled agent skill teaches that surface to a coding agent instead of a reader, and carries its own worked examples in [`plugins/agterm/skills/agterm/examples.md`](../plugins/agterm/skills/agterm/examples.md); install it from **Help ▸ Install Agent Skill…** or as a plugin (`claude plugin marketplace add umputun/agterm`).
