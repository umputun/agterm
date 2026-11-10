# Subagent status

A Claude Code session's sidebar row counts the subagents its agent started and stays active until the last one finishes, and a chord pages any one subagent's transcript over the session.

Author: [@bubakanov](https://github.com/bubakanov)

## What it does

From the sidebar a session running subagents looks the same as one that does not: there is one status per session, and Claude Code shows its subagents only inside the chat. Worse, the stock `Stop` hook posts `completed` when the parent's turn ends, while background subagents keep working.

This recipe fixes both through hooks and the session info line under the row:

- The line shows how many subagents are running and how many are done, plus the tool call the busiest one is running now. It is refreshed while any subagent runs and expires a minute after the last one finishes.
- The `Stop` entry is replaced. When the parent's turn ends with subagents still running, the row stays active, and `completed --auto-reset` is posted when the last of them stops.
- **Subagents** (a custom command) opens a picker of the conversation's subagents with their status glyphs, and pages the one you pick in an overlay. A running subagent's page keeps appending what it writes.

`/clear` switches the line to the new conversation's subagents, and `--resume` brings back the ones this recipe recorded for that conversation earlier.

## Requirements

- agterm 0.40.0 or later, which shipped `agtermctl session info` with `--markdown` and `--hide-after` (#864). The rest is older: `pick` with per-item `status` glyphs, `session overlay open` with a program, and the `{AGT_SESSION_ID}` keymap token.
- Claude Code with `SubagentStart` and `SubagentStop` hooks, verified against 2.1.299. The recipe reads undocumented payload fields and the transcript layout, see *Limits*.
- The agent-status hooks package (Help ▸ Install Agent Status Hooks…), optional but recommended: the held-back `completed` is posted through its `agterm-claude-status.sh`, which keeps a worker agent from repainting the spawner's row. Without the package the recipe calls `agtermctl session status` itself.
- `plutil`, `osascript` and `less`, all part of macOS. No `jq`.

## Setup

Copy the recipe somewhere stable:

```sh
mkdir -p ~/.config/agterm/subagent-status
cp subagent-status/*.sh ~/.config/agterm/subagent-status/
chmod +x ~/.config/agterm/subagent-status/*.sh
chmod -x ~/.config/agterm/subagent-status/subagent-common.sh
```

`subagent-common.sh` is sourced by the other scripts, never run. Its variables have defaults and can be exported from `~/.claude/settings.json`'s `env` block. That block reaches the hooks but not the chord, which agterm runs, so set `AGTERMCTL` and `AGT_SUBAGENT_STATE` on the keymap line too (shown below), or the picker reads another state directory and finds no subagents:

| variable | default | what it is |
|---|---|---|
| `AGTERMCTL` | `agtermctl` | the CLI |
| `AGT_SUBAGENT_STATE` | `~/.local/state/agterm-subagents` | one directory per session and conversation |
| `AGT_STATUS_SCRIPT` | the hooks package's `agterm-claude-status.sh` | what posts the held-back `completed` |
| `AGT_SUBAGENT_REFRESH` | 10 | seconds between refreshes of the line |
| `AGT_SUBAGENT_HIDE_AFTER` | 30 | the line's `--hide-after` while a subagent runs |
| `AGT_SUBAGENT_LINGER` | 60 | how long the line stays after the last subagent finishes |

Merge into `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "~/.config/agterm/subagent-status/subagent-hook.sh conversation" }] }
    ],
    "SubagentStart": [
      { "hooks": [{ "type": "command", "command": "~/.config/agterm/subagent-status/subagent-hook.sh start" }] }
    ],
    "PreToolUse": [
      { "hooks": [{ "type": "command", "command": "~/.config/agterm/subagent-status/subagent-hook.sh activity" }] }
    ],
    "SubagentStop": [
      { "hooks": [{ "type": "command", "command": "~/.config/agterm/subagent-status/subagent-hook.sh stop" }] }
    ],
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "~/.config/agterm/subagent-status/subagent-hook.sh prompt" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "~/.config/agterm/subagent-status/subagent-hook.sh turn-end" }] }
    ],
    "SessionEnd": [
      { "hooks": [{ "type": "command", "command": "~/.config/agterm/subagent-status/subagent-hook.sh end" }] }
    ]
  }
}
```

Keep the hooks package's `UserPromptSubmit`, `PostToolUse`, `PermissionRequest` and `Notification` entries beside these, but **remove its `Stop` entry**. With both `Stop` entries the stock one posts `completed` at every turn end and the hold does nothing. Running Help ▸ Install Agent Status Hooks… again writes the stock `Stop` back, because the installer looks for its own script path in each command; remove it again after a reinstall.

Add the chord to `keymap.conf` and run `agtermctl keymap reload`:

```
command "Subagents" ctrl+a>s ~/.config/agterm/subagent-status/subagent-pick.sh {AGT_SESSION_ID}
```

With either variable changed, the line names it before the script, for example `AGT_SUBAGENT_STATE=~/state/subagents ~/.config/agterm/subagent-status/subagent-pick.sh {AGT_SESSION_ID}`.

To remove: delete the seven entries from `settings.json`, run Help ▸ Install Agent Status Hooks… once to restore the stock `Stop`, delete the `keymap.conf` line, then the state and recipe directories.

## Usage

Ask the agent for work that fans out to subagents. While they run, the line under the session's row reads like **2** subagents running · 1 done · `Bash: make test`, the last part being the latest tool call, and the row keeps its active glyph after the parent's reply ends. When the last one stops the row turns green, and the line goes away a minute later.

Press the chord in that session to pick a subagent, or pick **Subagents** from Navigate ▸ Custom Commands, which lists it without the chord. Running ones carry the active glyph and their current tool call, finished ones the completed glyph. The overlay opens on the compact rendering, where long tool output is cut; `:n` shows the full one and `:p` returns. `q` closes the overlay and returns to the chat.

## How it works

Claude Code fires `SubagentStart` and `SubagentStop` with the subagent's `agent_id` and the parent's `session_id`, and a subagent's own tool calls reach `PreToolUse` with the same `agent_id`; the parent's calls carry none, so the `activity` mode ignores them. Claude Code also runs helper agents of its own, which fire `SubagentStop` and tool hooks without ever firing `SubagentStart`; only an id that started is counted, so they never show. A worker agent that another agent starts inside the session, such as `claude -p` from a tool call, inherits the session's `AGTERM_SESSION_ID`; the hook walks its own process ancestry, as the hooks package's Claude adapter does and reading a runtime's first argument so an npm-installed `claude` under `node` counts, and stays silent when a second agent sits above the `claude` that fired it, so a worker never takes over the line or clears it on exit. Each fact goes in its own file under `<state>/conversations/<conversation>/`, apart from the agterm session, because `--resume` can bring a conversation back in another session; the session's own directory holds only which conversation it shows and the pids. Each file is written to a temporary name and renamed, so parallel subagents finishing together never rewrite one file.

Each start and stop sets the line at once. A start also launches one background refresher per session, which sets the line again every ten seconds with a thirty-second `--hide-after`, because `session info` expects its caller to refresh before the timeout. The refresher stops on its own: when no subagent runs, it sets the final line with the one-minute linger and exits; when the `claude` process it recorded is gone, or no hook has fired for half an hour, it clears the line and exits. A killed agent therefore leaves no line behind.

The turn-end hold is two markers. `Stop` with a subagent still running writes `turn-ended` instead of posting `completed`; `SubagentStop` that leaves nothing running finds the marker and posts `completed --auto-reset`. `UserPromptSubmit` removes the marker, so a new prompt is never followed by a stale `completed`. A `claude` killed mid-run never sends `SubagentStop`, so each start records the `claude` pid beside the status, and a running subagent whose `claude` is gone counts as finished in the line, the hold and the picker; resuming that conversation therefore never leaves the row active.

The transcript path is `<parent transcript without .jsonl>/subagents/agent-<id>.jsonl`, and the description comes from the `.meta.json` beside it. `transcript-view.sh` renders the JSONL through JavaScript for Automation into two files and pages both with `less`.

## Limits

- **The recipe reads Claude Code internals.** The `agent_id` field on tool hooks, the `subagents/agent-<id>.jsonl` layout and the `description` in `.meta.json` are not a documented interface; they were verified against 2.1.299. If they change, the line stops counting or the picker shows ids instead of descriptions, without an error.
- A subagent that sends its own command to the background ends its turn before the command does, so it reads as done until the command finishes and the subagent resumes.
- Only Claude Code. Codex sends similar payloads, but its rollouts and its shared daemon need different handling; `transcript-view.sh` already reads Codex rollouts.
- Subagents that ran before the recipe was installed, or while agterm was not running, are not in the state and do not show after `--resume`.
- The line is one summary, not one row per subagent; the picker is where each one is listed.
- The line belongs to the session, not to a pane. A second Claude Code in the session's split or scratch pane takes over the line and the picker, and the one that ran a hook last wins.
- Any other caller of `session info` on the same session, such as `claude-git-info`, overwrites, and is overwritten by, this recipe.
- The state directory holds transcript paths, which name the directories you work in, and is created 0700. Each Claude Code start removes sessions and conversations untouched for 30 days, so resuming an older conversation shows none of its earlier subagents.
