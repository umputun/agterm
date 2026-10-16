# Copilot CLI per-tab session resume

After a restart each tab reopens its own Copilot CLI session instead of starting a fresh one.

## What it does

Same idea as the other session-resume recipes: multiple parallel Copilot CLI sessions survive a restart, each tab reopening exactly its own conversation.

The mechanism is closer to Claude Code's than to Codex's or opencode's, and simpler than either: Copilot CLI's `--session-id <id>` both sets the id for a brand-new session and resumes an existing one under that id in a single flag, so there is nothing to branch on and no state to keep. The function wraps `copilot` and always passes `--session-id "$AGTERM_SESSION_ID"` unless the invocation is one it should leave alone (a subcommand, an explicit `--resume`/`--session-id`/`--continue`, `-p`/headless, or similar).

- Zero state: the conversation id **is** the tab's uuid (`AGTERM_SESSION_ID`). No mapping file to keep in sync or let go stale, and no on-disk existence check either — `--session-id` handles "new" and "resume" itself.
- Idempotent: every launch in a tab, restored or interactive, resolves to the same `copilot --session-id <tab-id>` call, so a restore replay of that exact line passes straight through unchanged instead of needing to be recognized and re-decided.
- Stays out of the way: `copilot mcp`, `copilot -p`, an explicit `copilot --resume <other-id>`, and any launch outside agterm pass through untouched.
- Small, dependency-free, pure shell (no zsh-only syntax); the same function file works sourced from `~/.zshrc` or `~/.bashrc`.

## Requirements

- agterm 0.3.1 or later, with **Restore running commands on restart** turned on under Settings ▸ General ▸ Sessions. Both `AGTERM_SESSION_ID` and that setting predate the repository's earliest tagged release, so 0.3.1 is the first version that can be named, not the version the behavior arrived in.
- `zsh` or `bash`.
- GitHub Copilot CLI with `--session-id` support (checked against 1.0.80). Sessions are read from the default `~/.copilot/session-state/`.

## Setup

The function has to be defined in `~/.zshrc` or `~/.bashrc`, the config your interactive login shell reads. That matters: agterm feeds the restored command into that shell, so earlier-loading files like `.zshenv`/`.zprofile`/`.bash_profile` are too early to intercept it.

Either paste the function from `copilot-resume.sh` into your rc file, or keep the file and source it from there:

```sh
mkdir -p ~/.zsh
cp copilot-resume.sh ~/.zsh/
```

then add to `~/.zshrc` (or `~/.bashrc`):

```sh
source ~/.zsh/copilot-resume.sh
```

The file is sourced, never run, so it does not need the executable bit and is committed without one. Its shebang names a shell only to satisfy tooling that expects one; the function itself avoids zsh- or bash-only syntax.

Turn on **Restore running commands on restart** in Settings ▸ General, under Sessions. Without it agterm brings a tab back as a plain shell and there is nothing for the function to intercept.

New tabs and shells pick the function up on their own. In an already-open shell, run `source ~/.zshrc` (or `~/.bashrc`).

To remove it, delete the function block, or the `source` line, from your rc file.

## Usage

Run `copilot` the way you always do. The first launch in a tab starts a session pinned to that tab, and every later launch in the same tab continues it.

To check it: open a tab, run `copilot`, say a few words, quit it, then restart the terminal. The tab should come back to the same conversation, and `ps` shows `copilot --session-id <tab-id>`.

## How it works

agterm can remember the command running in a tab and re-run it on restart. The catch: it re-runs the command verbatim, and `copilot` with no arguments is a *new* session, not a continuation.

The trick rests on two facts. Every agterm tab has a stable identifier (`AGTERM_SESSION_ID`) that survives a restart. And Copilot CLI's `--session-id <id>` is documented to "resume an existing session or task by ID, or set the UUID for a new session" — one flag covers both cases, so the function never needs to check whether a session file already exists the way the Claude Code recipe does. It just always calls `copilot --session-id "$sid" "$@"` once it has decided the invocation isn't one to leave alone.

On restart agterm replays the remembered command, which is already `copilot --session-id <tab-id> ...` from the run that produced it. The function sees `--session-id` among the arguments, recognizes it as one of the flags a user (or a previous run of this very function) supplies to steer the session explicitly, and passes the line through unchanged — which happens to be exactly the call that reopens that tab's conversation, with no special-casing for "is this my own replayed flag" the way the Claude Code recipe needs.

On the agterm side that replay is a foreground-process capture. At quit agterm records the argv of whatever the pane was running, and on relaunch it types that line back into the tab's fresh login shell with each argument single-quoted. Quoting suppresses alias expansion but not function lookup, which is why a shell function named `copilot` still catches the replayed line.

## Limits

- **agterm-specific.** It needs a stable per-tab identifier and relies on agterm feeding the restored command back *through the login shell*, which is how the function intercepts it. It will not work as-is in another terminal; you would adapt it to that terminal's equivalent.
- **Rests on restore behavior its author verified empirically rather than from documentation.** It could change between agterm versions.
- **One conversation per tab.** Since conversation id equals tab id, two live `copilot` processes in the same tab would read and write the same session-state directory. A split pane, a scratch pane and any overlay all run under the same `AGTERM_SESSION_ID` as the main pane, so a second `copilot` in any of them targets the same id as the first.
- **It shadows the `copilot` command** with a shell function. Passthrough is handled for the flags and subcommands documented in `copilot --help` as of 1.0.80; a future release renaming or adding to that surface needs the passthrough list updated to match.
- **Headless one-shot calls (`-p`/`--prompt`) are never pinned**, on purpose, matching the Claude Code recipe's convention: a scripted `copilot -p "..."` in a tab that also hosts a pinned interactive conversation runs as its own unrelated session rather than continuing (or corrupting) the pinned one.
- **Existing sessions are not bound to tabs.** After you install this, the first launch in a tab starts a new session pinned to that tab; it does not adopt an arbitrary earlier one.
