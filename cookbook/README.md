# agterm cookbook

Installable `agtermctl` workflows. Each recipe is a directory holding a README and, where it needs one, its scripts: what it does, what it needs, how to set it up, and where it stops. They are written to be copied into your own setup and edited, not only read.

Recipes come from other people as well as the maintainer. Every one is reviewed before it is accepted, but they are scripts you run on your own machine against your own sessions, and several close sessions or delete workspaces, so read a recipe before you run it.

## Recipes

Grouped by what you are trying to do, alphabetical within each group. Which agent a recipe needs is in
its *needs* column, so searching this page for `claude` or `kiro` finds those directly.

### Workspaces and projects

| recipe | what it does | needs |
|---|---|---|
| [new-session-in-workspace](new-session-in-workspace/) | pick a workspace with fzf and start a session in it | 0.8.0, jq, fzf |
| [park-and-resume](park-and-resume/) | close a project's workspaces, bring them back later | 0.16.0, jq, zsh |
| [project-launcher](project-launcher/) | pick a project anywhere — or type "project + prompt" — and get a session in its workspace | 0.19.0, jq |
| [project-switcher](project-switcher/) | show only one project's workspaces in the sidebar | 0.18.0, jq |
| [window-per-project](window-per-project/) | park every other window in the Dock and raise one | 0.17.1, jq |
| [workspace-sets](workspace-sets/) | switch the sidebar between named groups of workspaces, one chord each | 0.18.0, jq |

### Sessions across restarts

| recipe | what it does | needs |
|---|---|---|
| [claude-session-resume](claude-session-resume/) | each tab reopens its own Claude Code conversation after a restart | 0.3.1, zsh or fish, Claude Code |
| [codex-session-resume](codex-session-resume/) | each tab reopens its own codex conversation after a restart | 0.3.1, zsh, Codex CLI |
| [kimi-session-resume](kimi-session-resume/) | each tab reopens its own Kimi Code conversation after a restart | 0.16.0, Kimi Code, python3 |
| [opencode-session-resume](opencode-session-resume/) | each tab reopens its own opencode conversation after a restart | 0.3.1, zsh, opencode |

### Agent status and workflows

| recipe | what it does | needs |
|---|---|---|
| [annotate-claude-replies](annotate-claude-replies/) | mark up Claude's answers in revdiff and send the notes back | 0.13.0, revdiff, python3, Claude Code |
| [annotate-pane-output](annotate-pane-output/) | mark up what the pane just printed in revdiff and send the notes back to whatever is running there | 0.13.0, revdiff, python3 |
| [backlog-picker](backlog-picker/) | pick one of the repo's written-down deferred items and hand it to the agent in the pane | 0.20.2, python3, Claude Code |
| [claude-clear](claude-clear/) | one chord sends /clear to the pane's Claude Code run, and nothing when it is not running | 0.13.0, python3, Claude Code |
| [claude-conversation-picker](claude-conversation-picker/) | pick a past Claude Code conversation by what it was about and resume it in the pane | 0.21.0, python3, Claude Code |
| [claude-recap](claude-recap/) | one key lists what the Claude Code run in a session was working on | 0.10.0, zsh, jq, Claude Code |
| [close-tab-when-done](close-tab-when-done/) | arm a tab with a chord and it closes itself when the agent stops replying | 0.22.0, jq, Claude Code |
| [container-agent-status](container-agent-status/) | a containerized agent reports status onto its sidebar row via a TCP notification to the host | 0.7.1, nc, timeout, Claude Code |
| [copilot-agent-status](copilot-agent-status/) | Copilot CLI sessions report active, blocked, and completed onto their sidebar row | 0.7.1, Copilot CLI |
| [kimi-agent-status](kimi-agent-status/) | Kimi Code sessions report agent status onto their sidebar row | 0.3.1, Kimi Code |
| [kiro-agent-status](kiro-agent-status/) | Kiro CLI sessions report active, blocked, and completed onto their sidebar row | 0.7.1, Kiro CLI |
| [status-announcer](status-announcer/) | demo: speak agent status changes from a dedicated session | 0.16.0, jq |
| [two-agent-chat](two-agent-chat/) | let Claude Code and Codex talk to each other in one split | 0.24.0, python3, Claude Code, Codex |

### Panes, pickers and input

| recipe | what it does | needs |
|---|---|---|
| [flagged-dashboard](flagged-dashboard/) | grid the flagged panes that are running something, one chord to show and dismiss | 0.20.0, jq |
| [fzf-path-picker](fzf-path-picker/) | pick a path with fzf and type it into the shell | 0.8.0, fzf, fd, zsh |
| [native-dir-picker](native-dir-picker/) | pick a directory in the native picker and type it into the shell | 0.19.0, fd, jq |
| [overlay-and-split](overlay-and-split/) | keymap lines: a stateful split toggle and TUI overlays | 0.10.0, jq |
| [same-dir](same-dir/) | sync working directory to target split pane | 0.10.0, jq, zsh |
| [sqlite-browser](sqlite-browser/) | pick one of the repo's SQLite databases and browse it in an overlay | 0.22.0, python3, tabiew |

Most recipes need `agtermctl` on your PATH; **Help ▸ Install Command Line Tool…** puts it there. Three of the four session-resume recipes are shell functions that read the environment agterm gives a session and never call the CLI; the Kimi one is a lifecycle hook that pins its tab's restore command through `agtermctl`. Some recipes also need `jq`, `fzf`, or a particular shell, and each recipe's *Requirements* section says which, along with the minimum agterm version it needs. Recipes are snapshots rather than a maintained surface: the control API grows by addition, so they rarely break, and one that does gets fixed when it is reported.

## Contributing a recipe

[CONTRIBUTING.md](CONTRIBUTING.md) in this directory has the rules: ship a workflow you actually run, one kebab-case directory, the six-heading README template, and an index row in the same pull request.

For the command surface itself, the [command reference](https://agterm.com/commands) documents every `agtermctl` command with its arguments and return shape. The bundled agent skill teaches that surface to a coding agent instead of a reader, and carries its own worked examples in [`plugins/agterm/skills/agterm/examples.md`](../plugins/agterm/skills/agterm/examples.md); install it from **Help ▸ Install Agent Skill…** or as a plugin (`claude plugin marketplace add umputun/agterm`).
