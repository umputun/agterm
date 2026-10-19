# Antigravity CLI per-tab session resume

After a restart each pane reopens its own Antigravity CLI (`agy`) conversation instead of starting a fresh one or sharing a single workspace-wide recent session.

## What it does

Pairs an `agy` `SessionStart` hook with a small `zsh` wrapper function so each agterm pane remembers and reopens its own `agy` conversation across terminal restarts:

- When a new conversation starts in `agy`, `agy-pin-resume.sh` reads `conversationId` from the hook's stdin payload and pins `agy --conversation <id>` on that pane with `agtermctl session restore`.
- When you exit an interactive `agy` session and return to the shell, the `agy` function in `agy-resume.zsh` clears the pane's restore pin (`agtermctl session restore --clear`) so a pane where you finished working comes back as a plain shell after a restart.

## Requirements

- agterm 0.16.0 or later (`session restore` with `--pane-id` and sticky per-pane restore overrides shipped in 0.16.0), with **Re-run commands** restore mode enabled under **Settings ▸ General ▸ Restore sessions** (labeled **Restore running commands on restart** in earlier releases).
- Antigravity CLI (`agy`) with `SessionStart` hook support (tested on `agy` 1.4.2).
- `zsh`.
- `agtermctl` on `PATH` (via **Help ▸ Install Command Line Tool…**), set in `AGTERMCTL`, or installed in `~/Applications/agterm.app` or `/Applications/agterm.app`.
- Python 3.8 or later, plus `zsh`, only to run the bundled `test_agy_pin_resume.py`. Using the recipe needs no Python.

## Setup

Copy the hook script and the `zsh` wrapper into place, making only the hook script executable:

```sh
mkdir -p ~/.config/agterm/hooks/agy
cp agy-pin-resume.sh agy-resume.zsh ~/.config/agterm/hooks/agy/
chmod +x ~/.config/agterm/hooks/agy/agy-pin-resume.sh
```

`agy-resume.zsh` is sourced by your interactive shell rather than executed directly, so it is committed without the executable bit.

Merge the `"agterm-session-resume"` block from `agy-resume-hooks.json` into `~/.gemini/config/hooks.json` (or `<project>/.agents/hooks.json` for a workspace-scoped setup). If you installed `agy-pin-resume.sh` at a different path, update `"command"` in `hooks.json` to match.

Source `agy-resume.zsh` from `~/.zshrc` (not `.zshenv` or `.zprofile`, because agterm feeds restored commands into the interactive login shell):

```sh
source ~/.config/agterm/hooks/agy/agy-resume.zsh
```

If `agtermctl` is neither on `PATH` nor in `~/Applications/agterm.app` or `/Applications/agterm.app`, export `AGTERMCTL=/path/to/agtermctl` in `~/.zshrc`.

Ensure **Re-run commands** restore mode is selected in **Settings ▸ General ▸ Restore sessions** (or verify `agtermctl restore mode` prints `rerun`). Open a new shell or run `source ~/.zshrc`.

To remove the recipe, delete the `"agterm-session-resume"` entry from `hooks.json`, remove the `source` line from `~/.zshrc`, and run `agtermctl session restore --clear` in any pane that still holds a pin.

## Usage

Run `agy` as usual and send a prompt. If agterm restarts while `agy` is still running, the pane replays `agy --conversation <id>` and reopens that exact conversation. If you exit `agy` (`/exit`, `/quit`, or `Ctrl+D Ctrl+D`) and return to the shell before restarting agterm, the wrapper clears the pin and the pane restarts as a plain shell.

## How it works

Unlike agents that let the caller supply a session UUID on first launch, `agy` generates its own `conversationId` internally. Rather than maintaining an external mapping file, this recipe uses `agy`'s `SessionStart` hook, which receives `{"conversationId": "<uuid>", ...}` on stdin inside the pane's environment (`AGTERM_SESSION_ID`, `AGTERM_PANE_ID`, `AGTERM_SOCKET`).

`agy-pin-resume.sh` prints `{}` on stdout (required by `agy`'s hook contract), extracts `conversationId` using pure bash string matching (avoiding `jq` and macOS's `/usr/bin/python3` stub), validates that the ID uses only `[A-Za-z0-9_-]` and does not begin with `-` before placing it into the shell command string, and calls `agtermctl session restore "agy --conversation <id>"`.

Because a `session restore` pin is sticky across restarts, the pin alone would keep relaunching `agy` even after you exited `agy` and continued using the pane as a regular shell. `agy-resume.zsh` defines a `zsh` function `agy` that runs `command agy "$@"` with its arguments untouched and, once an interactive run returns to the shell (excluding `SIGHUP`/`SIGTERM` exits `129`/`143`, headless flags, `--help`/`--version`, and non-interactive subcommands such as `agy mcp` or `agy models`), calls `agtermctl session restore --clear` for that pane. When agterm quits or restarts while `agy` is still running in the foreground, the pin stays in place and reopens the conversation on relaunch. Because agterm replays the restored command through the interactive login shell, the `agy` function also intercepts the replayed `agy --conversation <id>` line (a shell alias would not, because agterm single-quotes replayed arguments), and the sticky pin remains active across further restarts until you exit `agy`.

## Limits

- **Exiting `agy` clears any restore pin on that pane.** When an interactive `agy` run returns to the shell, the wrapper runs `agtermctl session restore --clear` on the pane, which removes any custom restore command you pinned by hand in that pane. Starting a new conversation in `agy` also overwrites any existing pin on that pane.
- **One pinned conversation per pane.** Split, scratch, and overlay surfaces share `AGTERM_SESSION_ID`, while the restore override is scoped per `AGTERM_PANE_ID`. The scratch pane is never restored across restarts, and `agtermctl session restore` rejects its pane ID (ignored silently by the hook).
- **`SessionStart` fires only on the first turn of a brand-new conversation.**
  - Launching `agy` and exiting before sending a prompt sets no pin.
  - Launching `agy -c`, `agy --continue`, or `agy --conversation <id>` manually in a pane whose pin was already cleared resumes an existing conversation without firing `SessionStart`, so it does not write a new pin.
  - Running `/clear` inside the TUI starts a new conversation and updates the pane's pin on the first prompt sent after clearing.
  - Switching conversations with `/resume` or branching an existing conversation with `/fork` inside the TUI does not fire `SessionStart` when the target thread already has prior steps, so the pane keeps its existing pin until a fresh conversation starts.
- **Deleted conversations.** If a pinned conversation is deleted before agterm restarts, replaying `agy --conversation <id>` prints `warning: conversation "<id>" not found` and opens a fresh interactive `agy` session instead of exiting. Sending a prompt pins the new conversation ID; exiting `agy` clears the stale pin.
- **Extra launch flags are not pinned.** Command-line flags such as `--model`, `--mode`, or `--effort` are not copied into `agy --conversation <id>`. Persistent preferences saved in `~/.gemini/antigravity-cli/settings.json` (such as `/model`) still apply when the conversation resumes.
- **Headless detection splits `ps` output on whitespace.** `agy-pin-resume.sh` walks up to six parent processes looking for `agy` and skips pinning when `-p`, `--print`, `--prompt`, `--print=*`, or `--prompt=*` appears as a whitespace-separated token on that command line. Because `ps -o command=` strips shell quoting, an interactive launch whose arguments contain a standalone `-p` word is treated as headless, and combined short flags such as `-cp` are not matched.
- **Child-agent guard only checks Claude Code.** Both the hook and the `zsh` wrapper skip restore pin changes when `CLAUDECODE` or `CLAUDE_CODE_SESSION_ID` is set in the environment so an `agy` worker spawned by Claude Code neither overwrites nor clears the outer session's pin. Workers spawned by other orchestrators are not detected.
- **Re-run commands mode only.** Restore pins are used only when **Settings ▸ General ▸ Restore sessions** is set to **Re-run commands**. Live sessions mode is not covered.
- **Plain-text state storage.** Like all `agtermctl session restore` overrides, the pinned command containing the conversation UUID is stored in plain text in agterm's window state file.
