# Copilot CLI per-pane session resume

After a restart each pane reopens its own GitHub Copilot CLI conversation instead of starting a fresh one.

Author: [@stn1slv](https://github.com/stn1slv), based on [@rychkov](https://github.com/rychkov)'s [#469](https://github.com/umputun/agterm/pull/469)

## What it does

Pairs a `zsh` wrapper function with a Copilot `sessionStart` hook so each agterm pane remembers the Copilot conversation it shows and reopens it when agterm brings the pane back:

- The hook records the conversation's session id for the pane, at its first prompt and again whenever `/clear` or `/resume` switches the pane to another conversation.
- The `copilot` function resumes the recorded conversation, both when you start `copilot` in the pane and when agterm replays it after a restart.

## Requirements

- agterm 0.26.0 or later (pane identities that survive a restart shipped in it), with **Re-run commands** or **Live sessions** under **Settings ▸ General ▸ Restore sessions**.
- GitHub Copilot CLI with hook support, installed as the native binary: the Homebrew cask or GitHub's install script (tested on 1.0.117). An npm install runs as typed; see *Limits*.
- `zsh` as the pane's shell.
- Python 3.8 or later, plus `zsh`, only to run the bundled `test_copilot_resume.py`. Using the recipe needs no Python.

## Setup

Copy the hook and its hook file into Copilot's user hooks folder, making only the hook executable. `COPILOT_HOME` moves that folder, and the commands follow it when it is set:

```sh
hooks=${COPILOT_HOME:-$HOME/.copilot}/hooks
mkdir -p "$hooks"
cp copilot-resume-hook.sh "$hooks/"
cp copilot-resume-hooks.json "$hooks/agterm-resume.json"
chmod +x "$hooks/copilot-resume-hook.sh"
```

Keep the hook file's own name, `agterm-resume.json`: the agent-status installer (Help ▸ Install Agent Status Hooks) owns `agterm-status.json` in the same folder, and the two run side by side.

Source the wrapper from `~/.zshrc`, not `.zshenv` or `.zprofile`, because agterm types a restored command into the interactive shell:

```sh
mkdir -p ~/.config/agterm/copilot
cp copilot-resume.zsh ~/.config/agterm/copilot/
echo 'source ~/.config/agterm/copilot/copilot-resume.zsh' >> ~/.zshrc
```

`copilot-resume.zsh` is sourced, never run, so it is committed without the executable bit. Copilot loads hooks when it starts, so restart a running `copilot` after copying them, and open a new shell or run `source ~/.zshrc`.

To remove the recipe, delete `agterm-resume.json` and `copilot-resume-hook.sh` from the hooks folder, remove the `source` line from `~/.zshrc`, and delete `agterm/` in `${COPILOT_HOME:-$HOME/.copilot}`.

## Usage

Run `copilot` in a pane as usual and send a prompt. Quit agterm while `copilot` is still running in that pane: on the next launch the pane reopens the same conversation. Run `/clear` or `/resume` inside Copilot and the pane follows: a restart reopens the conversation it showed last.

To check it, run `copilot`, send a prompt, and quit agterm without leaving Copilot. After the relaunch `ps` shows `copilot --secret-env-vars=AGTERM_COPILOT_RESUME --session-id <id>` in that pane, and `~/.copilot/agterm/<pane id>` holds the same id.

## How it works

agterm can bring back what a pane was running. In **Re-run commands** mode it records the pane's foreground command at a clean quit and types it into the new shell at the next launch. In **Live sessions** mode the program keeps running through a restart, and the recorded command is the fallback after the program is gone, for example after the Mac restarts. Either way agterm replays the argv the pane was running, and `copilot` with no arguments is a new conversation, not a continuation.

Every agterm pane has a stable identifier, `AGTERM_PANE_ID`, that survives a restart, and Copilot passes it on to its hooks. The hook receives the session id on stdin (`{"sessionId": "...", "source": "new" | "resume", ...}`) and writes it to `~/.copilot/agterm/<pane id>`. Copilot fires `sessionStart` at a conversation's first prompt, not at launch, and fires it again after `/clear` (`source: "new"`) and after `/resume` (`source: "resume"`), so the file follows the conversation on screen.

The function reads that file and runs `copilot --session-id <id>`, which resumes that session, or creates a session with that id if it no longer exists. It also adds `--secret-env-vars=AGTERM_COPILOT_RESUME`, a marker that changes nothing because no variable of that name exists. The marker does two jobs:

- **Replay.** A replayed line starts with the marker and the `--session-id` of the original launch. The function drops both and decides again from the file, because `/clear` or `/resume` may have moved the pane since then. It also drops `-i`/`--interactive` and its prompt, so a restart never sends that prompt again.
- **Which copilot may move the mapping.** Other copilots inherit `AGTERM_PANE_ID` too: a `copilot -p` typed in the pane, or a worker an agent starts. The hook finds the copilot that fired it, its nearest ancestor that is not a shell, and records only when that command line starts with `copilot` and the marker, the way the function launches it. After `/restart` Copilot runs again from its full path with the same arguments, so a path before `copilot` is accepted too. A worker is that nearest copilot itself and has no marker, whether a tool shell sits between it and the pane's copilot or not. A variable cannot do this job: it would reach the worker through the tool shell, and `--secret-env-vars` hides a variable from hooks as well.

The function also leaves `copilot` alone in a Copilot tool shell, which Copilot marks with `COPILOT_CLI` and `COPILOT_AGENT_SESSION_ID`, so a worker never gets the marker even when that shell loads `~/.zshrc`. It does the same when stdin is not a terminal (`echo question | copilot`), because Copilot treats piped input as a headless run, like `-p`. A replay in a pane with no mapping of its own starts a new conversation rather than reuse the session in the replayed line.

agterm types the replayed line with each argument single-quoted. Quoting suppresses alias expansion but not function lookup, which is why a function named `copilot` catches the replayed line and an alias would not.

## Limits

Nothing destructive: the recipe writes one small file per pane under `~/.copilot/agterm/` and never closes sessions or kills processes.

- **A pane must have sent a prompt.** Copilot fires `sessionStart` at the first prompt, so a `copilot` closed before anything was sent records nothing, and a `/clear` with no prompt after it leaves the pane on the previous conversation.
- **Explicit session choices pass through untouched.** `--resume`, `--continue`, `--session-id`, `--new-session-id`, `--connect`, `--name`, `--worktree`, `--cloud`, `-p`/`--prompt`, `--acp`, `--server`, `--headless`, `--help`, `--version` and every subcommand (`mcp`, `sessions`, `plugin`, and so on) run exactly as typed, without the marker, so they never change what the pane resumes. A replayed `copilot --resume <id>` still reopens that id.
- **`/restart` inside Copilot breaks the next restore.** Copilot keeps the original process as a supervisor whose command line is only the binary's path, and that is what agterm records for the pane. A restart after that opens a new conversation. The mapping still follows the pane, so the next `copilot` typed there reopens the right conversation, and from then on restores work again.
- **An npm install is left as typed.** Its `copilot` is a `node` script, so agterm records `node …/copilot` as the pane's command and a restart would replay it without the function. The function therefore runs an npm-installed `copilot` unchanged, which restores a new conversation as before.
- **A launcher script bypasses the function.** The function exists only in an interactive zsh, so a script that runs `copilot` itself, such as a `#!/bin/sh` wrapper that adds your usual flags, starts it without the marker. The hook then records nothing, so a restart reopens the conversation an earlier `copilot` recorded for that pane, or starts a new one when there is none. Define the wrapper as a zsh function or alias in `~/.zshrc` instead, for example `cop() { copilot --add-dir .. "$@"; }`.
- **One conversation per pane, kept until you change it.** Leaving Copilot does not clear the mapping, so the next `copilot` in that pane resumes the same conversation. Run `/clear` inside Copilot to start a new one, or `command copilot` to bypass the function once.
- **The scratch pane is not restored** by agterm, so its mapping is never used after a restart.
- **zsh only.** The function is `zsh`; a bash or fish pane runs `copilot` without it.
- **Flags are replayed as typed.** Apart from `-i`, the flags of the original launch, such as `--model`, are replayed with it.
- **Future Copilot releases** may rename events, flags or subcommands. The passthrough list follows `copilot --help` of 1.0.117. An option that accepts several values, such as `--allow-tool a b`, is read as taking one, so a subcommand typed after its second value gets the marker. When that second value is the first word that is not an option and has a subcommand's name, such as `skill` in `--excluded-tools task skill`, it is read as the subcommand, and the launch runs without the marker and is not resumed.
- **Duplicate as Companion copies the source pane's launch line.** agterm starts the copy by the program's full path, so the line runs without the function. When the source pane was resumed, its line holds `--session-id <id>`, and the copy reopens that launch conversation. If the source pane still shows it, two copilots share one session, and the copy's pane records that id too. Every later restore of the copy repeats the same line, so `/clear` or `/resume` in the copy does not carry over a restart. When the source pane was a first launch, its line has no `--session-id`, and the copy starts a new conversation.
- **Set `COPILOT_HOME` in `~/.zshrc`, not for one command or one pane.** agterm replays the command line, not the environment, and a restored pane starts a new shell. A restore of `COPILOT_HOME=~/x copilot`, or of a `copilot` run after an `export` typed in the pane, runs Copilot with the default home: it reopens the default home's mapping for that pane, or starts a new conversation there if it has none.
