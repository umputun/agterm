# Copilot CLI agent status

Copilot CLI sessions report active, blocked, and completed onto their sidebar row via the bundled agent-status hooks package and Copilot CLI's native hook support.

## What it does

Gives GitHub Copilot CLI the same per-session sidebar glyph behavior the installer already wires up for Claude Code: the row pulses active while Copilot works, goes blocked while it is waiting on a permission prompt, and flashes completed at the end of the turn, clearing when you visit the session. This recipe adds that mapping through Copilot CLI's own `hooks/*.json` support; agterm itself needs no code change, and the bundled installer does not currently set Copilot hooks up for you.

## Requirements

- agterm 0.7.1 or later, with the agent-status hooks package installed via Help ▸ Install Agent Status Hooks… . That installs `~/.config/agterm/agent-status/agterm-agent-status.sh`, which this recipe calls directly, and the shipped wrapper forwards the injected pane markers so a split or scratch pane's status lands on the right pane. This recipe does not touch that package's shell integration or its Claude/Codex-specific files.
- GitHub Copilot CLI with hook support. This recipe was checked against the published hooks reference in August 2026; if a later Copilot CLI release renames the events, update the JSON keys to match.

## Setup

Run Help ▸ Install Agent Status Hooks… once if you have not already; it is idempotent, and this recipe only depends on the wrapper it installs at `~/.config/agterm/agent-status/agterm-agent-status.sh`.

Install the hook file user-wide:

```sh
mkdir -p ~/.copilot/hooks
cp copilot-status-hooks.json ~/.copilot/hooks/
```

You can symlink it there instead of copying it if you prefer. For a repo-scoped install, put the same file in `.github/hooks/` in a trusted repository instead of `~/.copilot/hooks/`.

Copilot CLI loads hook configuration when `copilot` starts, not live while it is running, so start or restart `copilot` after copying the file.

## Usage

Run `copilot` inside agterm as usual. The sidebar glyph pulses active while Copilot works and after each tool call, goes blocked when Copilot is waiting on a permission prompt, and flashes completed at the end of each turn, clearing when you visit the session.

## How it works

This is pure Copilot-CLI-side configuration: a single `hooks.json` file points Copilot's native hooks at the stock `agterm-agent-status.sh` wrapper, with no agterm code change and no custom shell wrapper of its own. Unlike the Kiro recipe's shell-function poller, Copilot maps directly onto the same four states the installer already wires up for Claude Code.

The mapping mirrors Claude's bundled hook set exactly: `userPromptSubmitted` and `postToolUse` set `active --blink`, `agentStop` sets `completed --auto-reset`, and `notification` with `matcher: "permission_prompt"` sets `blocked`. Copilot CLI exposes a native event for each of those transitions, so the recipe is only data. Hook configuration is loaded once at CLI startup, not hot-reloaded, so editing the JSON means restarting `copilot`.

## Limits

Nothing destructive: this recipe only calls the existing status-setting wrapper. It never closes sessions, deletes workspaces, or kills shells.

- Like the Claude Code mapping it mirrors, this is turn-level rather than exact real-time state. A very long single tool call will not refresh the glyph again until that tool finishes.
- If a future Copilot CLI release renames or restructures its hook events or payloads, this recipe's JSON keys will need matching updates before the status changes fire again.
