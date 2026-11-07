# Multi-agent Git info

One sidebar Git snapshot for Claude Code, Codex, or both panes of an agterm split.

Author: [@megabyde](https://github.com/megabyde), based on
[Umputun](https://github.com/umputun)'s [claude-git-info](../claude-git-info/) recipe.

## What it does

Each agent reports its working directory through its lifecycle hooks.
The writer combines both panes into one session info line:

- `main ✓ clean`: a clean worktree on a branch with an upstream.
- `feature ● 3 ↑2 ↓1`: three changed or untracked files, two commits ahead and one behind.
- `spike ● 1 local only`: a branch without an upstream.
- `abc1234 detached ✓ clean`: a detached HEAD.
- `L service: main ● 2 | R library: fix ✓ clean`: panes in different worktrees.

Two panes in the same worktree share one snapshot.
Changed files are yellow, clean state green, ahead blue, and behind purple.
Local-only and detached labels are dim.
These are agterm's named system colors, independent of the terminal palette.

The hook updates after tools and at turn end.
An agent's normal exit removes only its contribution; the surviving pane keeps its line.

## Requirements

- agterm 0.40.0 or later, which added `session info`.
- Python 3.11 or later, using only the standard library.
- Git 2.15 or later, for `--no-optional-locks`, and macOS `ps`.
- Claude Code and/or Codex with SessionStart, PostToolUse, Stop, and SessionEnd command hooks.
  Live checks used Claude Code 2.1.318 and Codex 0.167.0 on macOS.

## Setup

Install the script:

```sh
mkdir -p "$HOME/.local/bin"
install -m 755 git-info.py "$HOME/.local/bin/agterm-git-info.py"
```

For Claude Code, merge the groups in `claude-hooks.json` into the matching arrays under `hooks`
in `~/.claude/settings.json`.
For Codex, append the groups in `codex-hooks.toml` to `~/.codex/config.toml`.
Keep unrelated hooks and add each supplied group only once.
Both supplied configurations run the same command:

```sh
python3 "$HOME/.local/bin/agterm-git-info.py"
```

Approve the new Codex hook entries through `/hooks`, then start fresh agent sessions.
Use Codex's `--no-daemon` flag so its hooks inherit the pane's own environment.
A shared app-server daemon can carry another pane's `AGTERM_*` values.
The hook needs `AGTERM_SESSION_ID`, `AGTERM_PANE_ID`, and `AGTERM_SOCKET` preserved in each agent's environment.

The CLI defaults to `agtermctl` on `PATH`.
Set `AGTERMCTL` to its full path in the agents' environment when it lives elsewhere.
Every call passes `--socket "$AGTERM_SOCKET"` explicitly.

Remove another Git-info writer from this session before enabling this one:
`session info` is one replaceable line, so two independent writers would overwrite each other.
This recipe only needs its own script and the hook groups above.

## Usage

Start either agent in a repository and work normally.
In a split, either pane's next hook refreshes the combined snapshot.
**Settings ▸ Interface ▸ Session info** controls whether agterm displays the line.
Read its source and expiry policy back with:

```sh
agtermctl tree --json --socket "$AGTERM_SOCKET"
```

Each session node exposes `info`, `infoMarkdown`, and `infoHideAfter` while the line is set.

Run the regression suite without contacting agterm:

```sh
python3 test_git_info.py
```

The tests use temporary Git repositories, disposable child processes, and stubbed control responses.
The overlap cases use pipes as barriers; they do not depend on sleeps or scheduling delays.

## How it works

The hook records the top-level agent's PID, agent name, conversation ID, and working directory
under its stable pane token in the OS temporary directory.
The state and lock are keyed by socket path and session ID.
Each refresh reads the current pane tokens, so swapping or promoting a pane does not change its owner.
Git reads use `--no-optional-locks`; a rename counts as one changed file, including names with newlines.

**Agent ownership.** An ancestry walk rejects a CLI nested under another Claude or Codex process.
Claude's entrypoint and subagent ID exclude headless and in-process children.
Codex also checks the first transcript record for a matching top-level CLI session;
an in-process subagent can share its parent's PID, so ancestry alone is insufficient.
The registered PID is checked directly, allowing an agent launched through a shell wrapper.

**Hard kills.** Before every publication, `ps` checks each registered PID and command name.
A missing process, a changed command, or a pane no longer in the session removes that entry
before the line is rebuilt.
After a hard kill, the surviving pane's next successful hook therefore prunes the dead contribution
rather than renewing it along with the surviving one.
No per-pane polling timer runs: with no further hooks, the whole line expires after 24 hours.

**Overlapping hooks.** One exclusive `flock` covers the current-tree read, state read, merge,
process checks, Git reads, state write, and synchronous `session info` call.
It is released only after publication returns.
A second pane waits before reading the stored state, so it cannot merge an older copy
or publish an earlier snapshot after an exit clear.
The lock file is kept in place; unlinking it could let two callers lock different inodes.
An exit also checks the conversation ID, so a late exit hook cannot remove a replacement conversation.

**Rendering.** Branch and repository names are escaped before Markdown formatting.
If formatting would exceed the API's 512-byte limit, the line falls back to bounded plain text.
Every set supplies `--hide-after 86400`; an empty combined snapshot sends `--clear`.
Failures print nothing and do not interrupt the agent.

## Limits

The script reads Git state and sets or clears its own session's info line.
It does not edit repository files, fetch refs, type into a terminal, or stop an agent.

- This is a snapshot after agent activity.
  Shell edits made while both agents are idle wait for the next hook.
- Ahead and behind use the locally stored upstream ref, not the remote's live state.
- A hard-killed agent is pruned at the next successful refresh, not immediately.
  If no refresh succeeds, stale information can remain until the whole line expires.
- Process identity is a PID and command name.
  Reuse of a PID by another same-named agent cannot be distinguished from the recorded process.
- Slow Git reads, unavailable process ancestry, or hook timeouts can skip a refresh.
  Normal hooks have a five-second budget; SessionEnd has three seconds.
- Codex's transcript metadata is a CLI implementation detail.
  An unreadable or changed format makes the guard stay silent.
- Only local primary and split panes participate; scratch and attached remote sessions are skipped.
- Another caller of `session info` still replaces this writer's entire line.
