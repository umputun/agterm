# agterm cookbook

Installable `agtermctl` workflows. Each recipe is a directory holding a README and, where it needs one, its scripts: what it does, what it needs, how to set it up, and where it stops. They are written to be copied into your own setup and edited, not only read.

Recipes come from other people as well as the maintainer. Every one is reviewed before it is accepted, but they are scripts you run on your own machine against your own sessions, and several close sessions or delete workspaces, so read a recipe before you run it.

## Recipes

Grouped by what you are trying to do, alphabetical within each group. Which agent a recipe needs is in
its *needs* column, so searching this page for `claude` or `kiro` finds those directly.

### Workspaces and projects

| recipe | what it does | needs | author |
|---|---|---|---|
| [new-session-in-workspace](new-session-in-workspace/) | pick a workspace with fzf and start a session in it | 0.8.0, jq, fzf | [@skripalschikov](https://github.com/skripalschikov) |
| [park-and-resume](park-and-resume/) | close a project's workspaces, bring them back later | 0.16.0, jq, zsh | [@umputun](https://github.com/umputun) |
| [project-launcher](project-launcher/) | pick a project anywhere — or type "project + prompt" — and get a session in its workspace | 0.19.0, jq | [@x9x9x9x9x9x91](https://github.com/x9x9x9x9x9x91) |
| [project-switcher](project-switcher/) | show only one project's workspaces in the sidebar | 0.18.0, jq | [@umputun](https://github.com/umputun) |
| [session-snapshot](session-snapshot/) | snapshot every open session into a browsable page, close them, and restore any one later with its own Claude conversation | 0.7.1, jq, python3 | [@ne0r0mancer](https://github.com/ne0r0mancer) |
| [window-per-project](window-per-project/) | park every other window in the Dock and raise one | 0.17.1, jq | [@umputun](https://github.com/umputun) |
| [window-switcher](window-switcher/) | jump to a window by number, or pick one with its waiting sessions in view | 0.28.0, jq | [@anadale](https://github.com/anadale) |
| [workspace-sets](workspace-sets/) | switch the sidebar between named groups of workspaces, one chord each | 0.18.0, jq | [@umputun](https://github.com/umputun) |

### Sessions across restarts

| recipe | what it does | needs | author |
|---|---|---|---|
| [antigravity-session-resume](antigravity-session-resume/) | each tab reopens its own Antigravity CLI conversation after a restart | 0.16.0, zsh, Antigravity CLI | [@stn1slv](https://github.com/stn1slv) |
| [claude-session-resume](claude-session-resume/) | each tab reopens its own Claude Code conversation after a restart | 0.3.1, zsh or fish, Claude Code | [@ssgreg](https://github.com/ssgreg) |
| [codex-session-resume](codex-session-resume/) | each tab reopens its own codex conversation after a restart | 0.3.1, zsh, Codex CLI | [@brusnigin](https://github.com/brusnigin) |
| [kimi-session-resume](kimi-session-resume/) | each tab reopens its own Kimi Code conversation after a restart | 0.16.0, Kimi Code, python3 | [@x9x9x9x9x9x91](https://github.com/x9x9x9x9x9x91) |
| [opencode-session-resume](opencode-session-resume/) | each tab reopens its own opencode conversation after a restart | 0.3.1, zsh, opencode | [@cherkale](https://github.com/cherkale) |

### Agent status and workflows

| recipe | what it does | needs | author |
|---|---|---|---|
| [agent-reset](agent-reset/) | one chord clears the pane's Claude Code or codex run, and nothing when neither is running | 0.26.0, python3, Claude Code or Codex | [@umputun](https://github.com/umputun) |
| [annotate-claude-replies](annotate-claude-replies/) | mark up Claude's answers in revdiff and send the notes back | 0.13.0, revdiff, python3, Claude Code | [@p4elkin](https://github.com/p4elkin) |
| [annotate-document](annotate-document/) | review a plan, a document or a draft as a rendered page, and hand the notes back to Claude Code | 0.38.1, python3, Claude Code | [@umputun](https://github.com/umputun) |
| [annotate-pane-output](annotate-pane-output/) | mark up what the pane just printed in revdiff and send the notes back to whatever is running there | 0.13.0, revdiff, python3 | [@umputun](https://github.com/umputun) |
| [antigravity-agent-status](antigravity-agent-status/) | Antigravity CLI sessions report active, blocked, and completed onto their sidebar row | 0.7.1, Antigravity CLI | [@stn1slv](https://github.com/stn1slv) |
| [backlog-picker](backlog-picker/) | pick one of the repo's written-down deferred items and hand it to the agent in the pane | 0.20.2, python3, Claude Code | [@umputun](https://github.com/umputun) |
| [claude-account-swap](claude-account-swap/) | switch the left pane's Claude account with a conversation summary | 0.26.0, python3, jq, Claude Code, Codex CLI, Git | [@umputun](https://github.com/umputun) |
| [claude-conversation-picker](claude-conversation-picker/) | pick a past Claude Code conversation by what it was about and resume it in the pane | 0.21.0, python3, Claude Code | [@umputun](https://github.com/umputun) |
| [claude-git-info](claude-git-info/) | Claude Code keeps its branch, changed-file count and unpushed commits on a line under the sidebar row | 0.40.0, jq, git, Claude Code | [@umputun](https://github.com/umputun) |
| [claude-recap](claude-recap/) | one key lists what the Claude Code run in a session was working on | 0.10.0, zsh, jq, Claude Code | [@umputun](https://github.com/umputun) |
| [close-tab-when-done](close-tab-when-done/) | arm a tab with a chord and it closes itself when the agent stops replying | 0.22.0, jq, Claude Code | [@andr81](https://github.com/andr81) |
| [container-agent-status](container-agent-status/) | a containerized agent reports status onto its sidebar row via a TCP notification to the host | 0.7.1, nc, timeout, Claude Code | [@nquo](https://github.com/nquo) |
| [copilot-agent-status](copilot-agent-status/) | Copilot CLI sessions report active, blocked, and completed onto their sidebar row | 0.7.1, Copilot CLI | [@rychkov](https://github.com/rychkov) |
| [end-of-task-offer](end-of-task-offer/) | once the agent clears the title-bar line, offer to clear its conversation or close the session | 0.39.0, jq, session-context-nudge, Claude Code or Codex | [@umputun](https://github.com/umputun) |
| [flag-recent-agents](flag-recent-agents/) | one chord lists the sessions whose agents reported a status lately, lets you untick any, and flags the rest | 0.38.0, jq | [@umputun](https://github.com/umputun) |
| [html-doc-overlay](html-doc-overlay/) | ask Claude Code for a page about the issue, PR, plan or topic in hand, read it in an overlay, and optionally share it on an expiring link | 0.33.0, jq, python3, Claude Code, cloudflared for sharing | [@umputun](https://github.com/umputun) |
| [kimi-agent-status](kimi-agent-status/) | Kimi Code sessions report agent status onto their sidebar row | 0.3.1, Kimi Code | [@x9x9x9x9x9x91](https://github.com/x9x9x9x9x9x91) |
| [kiro-agent-status](kiro-agent-status/) | Kiro CLI sessions report active, blocked, and completed onto their sidebar row | 0.7.1, Kiro CLI | [@bitcldr](https://github.com/bitcldr) |
| [long-commands-status](long-commands-status/) | wrap any long shell command so the row reports active while it runs and completed or blocked when it finishes | 0.17.0 | [@Rulexec](https://github.com/Rulexec) |
| [named-companion](named-companion/) | one chord duplicates the session as a tinted companion named from a dialog, or by its Claude Code when left blank | 0.39.0, python3 | [@umputun](https://github.com/umputun) |
| [remote-claude-session](remote-claude-session/) | one chord runs Claude Code in a tmux session on a remote host, reconnecting and reporting status onto its own tab | 0.22.0, jq, ssh, tmux, Claude Code | [@andr81](https://github.com/andr81) |
| [scheduled-jobs](scheduled-jobs/) | an agent installs cronn, schedules and reports on jobs, and jobs can open agterm sessions running an agent on a prompt | 0.37.0, Homebrew, jq, Claude Code | [@umputun](https://github.com/umputun) |
| [session-context-nudge](session-context-nudge/) | Claude Code keeps the title bar saying what the session is working on | 0.26.0, jq, Claude Code | [@umputun](https://github.com/umputun) |
| [status-announcer](status-announcer/) | demo: speak agent status changes from a dedicated session | 0.16.0, jq | [@umputun](https://github.com/umputun) |
| [subagent-status](subagent-status/) | the row counts a Claude Code session's subagents, stays active until the last one finishes, and a chord pages one's transcript | 0.40.0, Claude Code | [@bubakanov](https://github.com/bubakanov) |
| [truthful-agent-lights](truthful-agent-lights/) | the row reports what is still running after the turn ends, and stops claiming work that is gone | 0.17.0, jq, Claude Code | [@x9x9x9x9x9x91](https://github.com/x9x9x9x9x9x91) |
| [two-agent-chat](two-agent-chat/) | let Claude Code and Codex talk to each other in one split by typing into each other's composer | 0.24.0, python3, Claude Code, Codex | [@umputun](https://github.com/umputun) |
| [two-agent-mailbox-chat](two-agent-mailbox-chat/) | let two agents in one split talk through pane mailboxes and agent hooks, never typing into a composer; replaces two-agent-chat | 0.40.0, python3, Claude Code and/or Codex | [@umputun](https://github.com/umputun) |

### Panes, pickers and input

| recipe | what it does | needs | author |
|---|---|---|---|
| [claude-pasted-images](claude-pasted-images/) | draw an image pasted into Claude Code under the prompt that carried it | 0.3.1, Claude Code | [@umputun](https://github.com/umputun) |
| [container-overlays](container-overlays/) | open program, page and URL overlays from inside a docker container | 0.39.0, docker, python3 | [@Rulexec](https://github.com/Rulexec) |
| [flagged-dashboard](flagged-dashboard/) | grid the flagged panes that are running something, one chord to show and dismiss | 0.20.0, jq | [@umputun](https://github.com/umputun) |
| [fzf-path-picker](fzf-path-picker/) | pick a path with fzf and type it into the shell | 0.8.0, fzf, fd, zsh | [@umputun](https://github.com/umputun) |
| [image-path-gallery](image-path-gallery/) | show the image paths on a pane's screen in a gallery, copied from the session's host when attached | 0.36.0, perl, ssh | [@wildsurfer](https://github.com/wildsurfer) |
| [native-dir-picker](native-dir-picker/) | pick a directory in the native picker and type it into the shell | 0.19.0, fd, jq | [@umputun](https://github.com/umputun) |
| [overlay-and-split](overlay-and-split/) | keymap lines: a stateful split toggle and TUI overlays | 0.10.0, jq | [@umputun](https://github.com/umputun) |
| [remote-image-paste](remote-image-paste/) | copy a screenshot to a remote session's Mac so ctrl+v there pastes it | 0.31.0 | [@umputun](https://github.com/umputun) |
| [remote-session-picker](remote-session-picker/) | pick a session running on another Mac and attach it here | 0.26.0, jq | [@umputun](https://github.com/umputun) |
| [same-dir](same-dir/) | sync working directory to target split pane | 0.10.0, jq, zsh | [@vladislav-yevtushenko](https://github.com/vladislav-yevtushenko) |
| [sqlite-browser](sqlite-browser/) | pick one of the repo's SQLite databases and browse it in an overlay | 0.22.0, python3, tabiew | [@umputun](https://github.com/umputun) |

Most recipes need `agtermctl` on your PATH; **Help ▸ Install Command Line Tool…** puts it there. Three of the five session-resume recipes are shell functions that read the environment agterm gives a session and never call the CLI; the Kimi and Antigravity ones use lifecycle hooks that pin the pane's restore command through `agtermctl`. Some recipes also need `jq`, `fzf`, or a particular shell, and each recipe's *Requirements* section says which, along with the minimum agterm version it needs. Recipes are snapshots rather than a maintained surface: the control API grows by addition, so they rarely break. Who fixes one that does depends on its author; see [Bugs and improvements](CONTRIBUTING.md#bugs-and-improvements).

## Contributing a recipe

[CONTRIBUTING.md](CONTRIBUTING.md) in this directory has the rules: ship a workflow you actually run, one kebab-case directory, the six-heading README template with its Author line, and an index row in the same pull request.

For the command surface itself, the [command reference](https://agterm.com/commands) documents every `agtermctl` command with its arguments and return shape. The bundled agent skill teaches that surface to a coding agent instead of a reader, and carries its own worked examples in [`plugins/agterm/skills/agterm/examples.md`](../plugins/agterm/skills/agterm/examples.md); install it from **Help ▸ Install Agent Skill…** or as a plugin (`claude plugin marketplace add umputun/agterm`).
