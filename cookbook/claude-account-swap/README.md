# Switch Claude accounts

Pick another Claude Code account and carry the left pane's conversation into it as a summary.

Author: [@umputun](https://github.com/umputun)

## What it does

The custom command opens an account picker. Selecting an account quits Claude in the left pane and
starts a new conversation under that account's config directory. Codex writes a handoff summary
before the old agent exits. The new agent receives it as context and is asked to wait for you.

The right pane stays available while the command runs. Escape in the picker cancels the switch.

## Requirements

- agterm **0.26.0 or later**, which added the tree's `foregroundShell` field used before relaunching.
  From 0.26.2, progress panels can stay over the left pane. If pane placement is unavailable or the
  pane is hidden, the script falls back to a session-wide panel.
- macOS, Python **3.10 or later**, `jq`, and the system `bash`, `ps`, `env`, and `cat` commands.
- Claude Code's native executable, available as `claude`, with a separate authenticated config
  directory for each account. Launch Claude from a shell with job control, directly or through an
  exec wrapper as described below.
- Codex CLI, authenticated and able to run `codex exec --ephemeral --ignore-user-config --json`
  with `gpt-5.6-luna`. This is the default summarizing model; access to it is required unless you
  change `CLAUDE_SWAP_MODEL`.
- Git, used to add the current branch, commit and changed filenames to the summary when the
  conversation's directory is a repository.

## Setup

1. Copy both scripts into the same directory:

   ```bash
   mkdir -p ~/.config/agterm/scripts
   cp claude-account-swap.py pane-map-hook.sh ~/.config/agterm/scripts/
   chmod +x ~/.config/agterm/scripts/{claude-account-swap.py,pane-map-hook.sh}
   ```

2. Sign into each account using Claude's own config directory selection. For example, run these
   separately and complete `/login` in each:

   ```bash
   CLAUDE_CONFIG_DIR="$HOME/.claude" claude
   CLAUDE_CONFIG_DIR="$HOME/.claude-work" claude
   ```

   Confirm the intended account with `/status` in each directory. `CLAUDE_CONFIG_DIR` selects a
   configuration, including its settings and transcript directory; the recipe does not change
   credentials or log you in. See Claude Code's [configuration directory reference](https://code.claude.com/docs/en/claude-directory).

3. Create `~/.config/agterm/claude-accounts.json` with the directories you just configured:

   ```json
   [
     {"label": "Personal", "config_dir": "~/.claude"},
     {"label": "Work", "config_dir": "~/.claude-work"}
   ]
   ```

   Add more entries for more accounts. Labels must be unique. Directories must exist and must not
   resolve to the same location or contain one another. JSON keeps paths with spaces unambiguous;
   `~` expands to your home directory. Shell variables such as `$HOME` are not expanded here.

4. Merge these hooks into `settings.json` in **every account's config directory**. Preserve any
   existing hooks under the same events:

   ```json
   {
     "hooks": {
       "SessionStart": [{"hooks": [{"type": "command", "command": "\"$HOME/.config/agterm/scripts/pane-map-hook.sh\""}]}],
       "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "\"$HOME/.config/agterm/scripts/pane-map-hook.sh\""}]}],
       "PostToolUse": [{"hooks": [{"type": "command", "command": "\"$HOME/.config/agterm/scripts/pane-map-hook.sh\""}]}],
       "Stop": [{"hooks": [{"type": "command", "command": "\"$HOME/.config/agterm/scripts/pane-map-hook.sh\""}]}]
     }
   }
   ```

   The [hook input](https://code.claude.com/docs/en/hooks) supplies the conversation ID and transcript
   path. The hook records them without replacing your status line. If your status line already
   writes `/tmp/claude/panes/SESSION.PANE`, remove that recording block: it would erase the process
   metadata this hook adds. Readers that use only the first line remain compatible.

5. Add this palette command to `~/.config/agterm/keymap.conf`:

   ```text
   command "Swap Claude Account" ~/.config/agterm/scripts/claude-account-swap.py
   ```

6. Reload the keymap:

   ```bash
   agtermctl keymap reload
   ```

7. Restart Claude directly in the left pane with the chosen `CLAUDE_CONFIG_DIR` so its new hooks run.

Optional overrides are `AGTERMCTL`, `CLAUDE_BIN`, and `CODEX_BIN` for executable paths;
`CLAUDE_SWAP_MODEL` for the summarizing model; and `PANE_MAP_DIR` for the map directory, default
`/tmp/claude/panes`. Set `PANE_MAP_DIR` in both the hook's environment and the custom command's
environment. Executable overrides are single paths or names, without arguments. Custom commands
inherit the app's environment; shell startup exports alone do not configure them. An override can
be placed before the script on the `command` line, such as `CODEX_BIN=/path/to/codex`.

To add flags such as `--append-system-prompt` to every replacement, set `CLAUDE_BIN` on the custom
command to an executable wrapper containing:

```sh
#!/bin/sh
exec /absolute/path/to/native/claude --append-system-prompt "Your instruction." "$@"
```

Use the native binary's absolute path to avoid calling the wrapper recursively. Forward `"$@"`
and leave `CLAUDE_CONFIG_DIR` unchanged so the selected account and handoff argument reach Claude.
`exec` replaces the shell with Claude while preserving its process ID. The wrapper's filename
need not be `claude`.

Pass `--accounts /path/to/accounts.json` on the command line to use another account list.

## Usage

Let Claude finish its turn, wait ten seconds, and leave its composer empty. Open the command palette
and choose **Swap Claude Account**, then choose the destination account. That selection confirms
quitting the left pane's current agent. Leave the pane alone until the replacement starts.

After the replacement acknowledges the context, tell it what to do next. The summary itself asks
it to wait; it does not authorize the unfinished work.

For a check that neither opens a picker nor calls a model, run
`~/.config/agterm/scripts/claude-account-swap.py --dry-run` from the sibling pane. It checks the
left pane's map and input gates and prints the source and available destinations.

## How it works

The hook walks its parent processes to find the native Claude process. It records the transcript
path, Claude's PID and process start time, and the conversation ID in
`$PANE_MAP_DIR/SESSION.PANE`. The first line is the transcript path; the second is JSON metadata.
Writes replace the file atomically. Background invocations cannot publish a record.

The script requires that exact process to still exist, with the same start time, and to lead its
terminal's foreground process group. This rejects an exited Claude's leftover map, PID reuse with
a different start time, and a backgrounded agent. A map does not expire merely because Claude has
been idle. The transcript must be inside exactly one configured account's `projects` directory.
There is no search for the newest conversation when the map is missing or unusable.

The destination picker excludes the source account. Before quitting, the script rechecks the map,
transcript size and modification time, foreground program, reported activity, and cursor column.
It refuses a transcript written within ten seconds. These checks detect ordinary activity and
changes during summarization; they cannot make reading the pane and typing `/exit` atomic.

The transcript parser and digest builder are included in the script. They keep user prompts and
assistant text, omit tool traffic, trim assistant replies to 1,500 characters, and keep the last
120,000 characters. The last recorded working directory follows Claude into a worktree. Codex
receives that digest and Git's working-tree state with its shell and multi-agent tools disabled.

The summary is stored in a private temporary file. After `/exit` returns the pane to a foreground
shell, the script types a quoted launch line using `env CLAUDE_CONFIG_DIR=... claude` and reads the
packet into one launch argument. The summary is never pasted into Claude's composer. Success
requires the replacement's hook to report a new live process and transcript under the selected
account's directory. A retained packet's path is printed on success and included in later errors.

## Limits

**This quits the running Claude agent in the left pane.** A failed launch can leave that pane at
its shell. The original transcript and the temporary summary remain on disk; delete the summary
when you no longer need it. There is no automatic rollback or retry after typing a command.

This recipe supports a native Claude executable in a local agterm pane with shell job control.
A wrapper must replace itself with Claude using `exec`; keeping the wrapper shell alive fails
both the foreground-program and process-group checks. Node-based installs, SSH, tmux, nested
agents, and moving/swapping panes after Claude starts are unsupported. Those can break the
relationship between the inherited session/pane ID and the terminal that owns the process. Restart
Claude after a pane move.
Do not run two instances of this custom command against the same pane at once.

A foreground shell is not proof that its prompt is ready. The cursor at column 2 is also not proof
that a Claude composer is empty if you moved the caret to the start of a draft. Status is shared
across a session's panes, and a long tool call can leave the transcript unchanged. Confirm that the
agent has finished and leave its pane untouched during the switch.

Each switch sends conversation text and repository metadata to Codex. The handoff then crosses
into the destination Claude account. Only switch conversations that belong in both accounts.
Model summaries can omit or misstate context; the packet includes the original transcript path.

Config directories can hold different tools, permissions and hooks. The launch does not copy the
old account's settings or command-line flags. Authentication environment variables can override
the account associated with a config directory. The startup check verifies the directory and
process, not the signed-in person's identity or the model's acknowledgement of the summary.
