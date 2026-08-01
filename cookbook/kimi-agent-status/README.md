# Kimi Code agent status

Kimi Code sessions report active, blocked, and completed onto their sidebar row, from four `[[hooks]]` entries and the stock status script.

## What it does

Wires Kimi Code's own lifecycle hooks to agterm's per-session status glyph, the same signal the installer sets up for Claude Code, Codex, Pi, and OpenCode: the row shows active (pulsing) while kimi works, amber blocked when it is waiting on a real approval, and a one-shot completed when the turn ends. Kimi needs none of the installer's app-side machinery — the stock `agterm-agent-status.sh` works unmodified, so the whole recipe is a config snippet.

## Requirements

- agterm 0.3.1 or later, with the hooks package installed via Help ▸ Install Agent Status Hooks… (that provides `~/.config/agterm/agent-status/agterm-agent-status.sh`, which this recipe points kimi at). The status script, `--blink`, and `--auto-reset` all predate the repository's earliest tagged release, so 0.3.1 is the first version that can be named, not the version they arrived in.
- Kimi Code with `[[hooks]]` support in `~/.kimi-code/config.toml` (tested on kimi-code 0.31.0).

## Setup

Run Help ▸ Install Agent Status Hooks… once if you have not already (it is idempotent).

Add to `~/.kimi-code/config.toml`:

```toml
[[hooks]]
event = "UserPromptSubmit"
command = "$HOME/.config/agterm/agent-status/agterm-agent-status.sh active --blink"

[[hooks]]
event = "PostToolUse"
command = "$HOME/.config/agterm/agent-status/agterm-agent-status.sh active --blink"

[[hooks]]
event = "PermissionRequest"
command = "$HOME/.config/agterm/agent-status/agterm-agent-status.sh blocked"

[[hooks]]
event = "Stop"
command = "$HOME/.config/agterm/agent-status/agterm-agent-status.sh completed --auto-reset"
```

`kimi doctor` validates the file. Hooks load at kimi startup, so restart any running kimi sessions.

To remove, delete the four blocks.

## Usage

Run `kimi` inside agterm as usual. The glyph turns active on your prompt, re-asserts on every tool call (so it returns to active after you answer an approval), goes blocked when an approval dialog is up, and flashes completed when the turn ends, clearing when you visit the session.

## How it works

Kimi Code fires each hook with a JSON payload on stdin inside the session's shell, where `AGTERM_SESSION_ID` is already exported — the stock status script reads that and posts over the control socket, and is a silent no-op outside agterm.

Two kimi hook behaviors matter when adapting this:

- A hook's stdout is captured by kimi, not shown to you — it can be fed into the model's context, costing tokens and steering the agent (a blocking hook's message visibly shaped the model's reply in testing). The stock script already suppresses output; keep any replacement silent too.
- A hook exiting with code 2 tells kimi to block the action it fired for — verified: a PreToolUse hook exiting 2 stopped the write and the agent reported the policy block. The stock script always exits 0; a wrapper that can fail incidentally must not leak exit 2, or it silently vetoes tools.

In testing (kimi-code 0.31.0), `PermissionRequest` fired only when the approval dialog was actually on screen, and never for a tool that was auto-approved — so blocked tracked the dialog exactly, with none of the early-candidate ambiguity that makes the installer's Codex adapter watch the pane. If a future kimi moves the event earlier in its tool pipeline, blocked would start false-flagging the same way, and the watcher approach is the known fix.

## Limits

Nothing destructive: the hooks only post status for their own session.

- When kimi does not show the dialog, no event fires and the session never reports blocked; it goes active → completed. That covers prompt (`-p`) runs and everything the auto and yolo modes auto-approve — all three checked on 0.31.0 (file writes and a network shell command under yolo ran with no event).
- A question the agent asks arrives as plain chat, not through a permission dialog, so it does not set blocked: the turn ends and the row reports completed. A completed row can therefore really be a question waiting for you. Verified in an auto session; the only dialog observed in manual mode is tool approval.
- The hook set is per-user config, so kimi runs outside agterm carry the hooks too; the script is a silent no-op there.
