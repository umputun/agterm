# Antigravity CLI agent status

Antigravity CLI (`agy`) sessions report active, blocked, and completed onto their sidebar row via `agy` lifecycle hooks and the bundled agent-status script.

## What it does

Gives Antigravity CLI (`agy`) per-turn sidebar status indicators matching the built-in Claude Code hook mapping: the session row pulses `active` while the model runs and after each tool call, switches to `blocked` when `agy` asks a question or requests a scoped permission via tool call, and sets `completed` when `Stop` reports `fullyIdle: true`.

## Requirements

- agterm 0.7.1 or later, with the agent-status hooks package installed via **Help ▸ Install Agent Status Hooks…**. That installs `~/.config/agterm/agent-status/agterm-agent-status.sh`, which forwards `AGTERM_PANE` from 0.7.1 onward so split and scratch panes target their own slot; agterm 0.13.0 or later is recommended if you use split panes because it also forwards `AGTERM_PANE_ID`, keeping status writes on the right pane even after a split pane is promoted to main.
- Antigravity CLI (`agy`) with lifecycle hook support (tested on `agy` 1.4.2).
- Python 3.8 or later, only to run the bundled `test_agy_status_hook.py`. Using the recipe needs no Python.

## Setup

Run **Help ▸ Install Agent Status Hooks…** once in agterm if you have not already. That installs `~/.config/agterm/agent-status/agterm-agent-status.sh`, which this recipe calls.

Copy the hook adapter script into place and make it executable:

```sh
mkdir -p ~/.config/agterm/hooks/agy
cp agy-status-hook.sh ~/.config/agterm/hooks/agy/
chmod +x ~/.config/agterm/hooks/agy/agy-status-hook.sh
```

Merge the `"agterm-status"` block from `agy-status-hooks.json` into `~/.gemini/config/hooks.json` (create the file if it does not exist, or add the `"agterm-status"` key alongside your existing hook entries). For a workspace-only install, merge it into `<project>/.agents/hooks.json` instead.

If you store `agy-status-hook.sh` at a different path, update the `"command"` paths in `hooks.json` to match. You can also override the path to agterm's status script by setting `AGTERM_STATUS_WRAPPER` or `AGTERM_STATUS_SCRIPT` in the hook environment (default: `$HOME/.config/agterm/agent-status/agterm-agent-status.sh`).

Do **not** also add `agy` to `AGTERM_AGENT_RE` in agterm's shell integration. The shell integration sets `active` when a command starts and `idle` when it exits back to the shell prompt, which for an interactive REPL pins `active` across the entire session, including while `agy` sits idle between turns. The two approaches are alternatives, not layers.

## Usage

Run `agy` inside agterm as usual. The sidebar row pulses `active` during model invocations and after tool calls, turns `blocked` when `ask_question` or `ask_permission` runs, and turns `completed` at the end of a turn, clearing when you focus or type in the session. Headless runs (`agy -p`, `--print`, `--prompt`) are ignored so one-shot background invocations do not overwrite the pane's interactive status.

## How it works

The gotcha with `agy` hooks is stdout. agterm's stock `agterm-agent-status.sh` suppresses all stdout and stderr because Claude Code injects hook output into the prompt context. `agy`, by contrast, requires every lifecycle hook to print a single JSON object on stdout, and requires specific fields from `PreToolUse` (`{"decision":"allow"}`) and `Stop` (`{"decision":"stop"}`). Calling `agterm-agent-status.sh` directly from `hooks.json` produces empty stdout and fails the hook parsing in `agy`.

`agy-status-hook.sh` is a thin adapter that drains stdin, prints the exact JSON object `agy` expects for each action, and then invokes `agterm-agent-status.sh`:

- `PreInvocation` (`invocation`) and `PostToolUse` (`tool-done`) print `{}` and set `active --blink`.
- `PreToolUse` (`ask`, matched against `ask_question|ask_permission`) prints `{"decision":"allow"}` and sets `blocked`. Per the [Antigravity CLI hook docs](https://antigravity.google/docs/hooks), returning `allow` passes the call through to the normal permission policy without weakening permissions; returning `auto_approve` would bypass interactive approval prompts and must never be used here.
- `Stop` (`stop`) prints `{"decision":"stop"}` (any value other than `"continue"` lets the turn end) and checks `fullyIdle` in the stdin payload using pure bash string matching (avoiding `jq` and macOS's `/usr/bin/python3` developer-tools stub). It sets `completed --auto-reset` only when `fullyIdle` is not `false`, leaving the indicator alone while background tasks are still running.

## Limits

Nothing destructive: this recipe only updates the session's sidebar status glyph and never closes sessions, deletes workspaces, or kills shells.

- **No `blocked` state on command approval prompts.** `agy` has no hook event for "waiting on user approval to run a command or edit a file". `PreToolUse` fires before `agy` evaluates its permission policy, so matching `run_command` in `PreToolUse` would report `blocked` on every auto-approved command too. Only dedicated prompt tools (`ask_question` and `ask_permission`) set `blocked`.
- **Interrupted turns, `fullyIdle: false`, or exiting while active.** `agy` has no `SessionEnd` hook, and `Stop` does not fire if a turn is aborted mid-flight or `agy` is closed while `active` or `blocked`. Likewise, when `Stop` fires with `fullyIdle: false` (background work still running), the script leaves the row `active` until the background work finishes and triggers a follow-up turn's `Stop` with `fullyIdle: true`; if that background work never wakes the agent again, the row keeps its last status until the next prompt or manual reset.
- **Child-agent guard only checks Claude Code.** The hook skips status updates when `CLAUDECODE` or `CLAUDE_CODE_SESSION_ID` is set in the environment so an `agy` worker spawned by Claude Code does not overwrite the outer session's status.
- **Headless detection splits `ps` output on whitespace.** The script walks up to six parent processes looking for `agy` and skips status updates when `-p`, `--print`, `--prompt`, `--print=*`, or `--prompt=*` appears as a whitespace-separated token on that command line. Because `ps -o command=` strips shell quoting, an interactive launch whose arguments contain a standalone `-p` word is treated as headless, and combined short flags such as `-cp` are not matched.
- **Tool and event names are tied to `agy` 1.4.2.** If a later `agy` version renames `ask_question`, `ask_permission`, or the hook events, update `agy-status-hooks.json` to match.
