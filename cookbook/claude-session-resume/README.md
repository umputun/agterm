# Claude Code per-tab session resume

After a restart each tab reopens its own Claude Code conversation instead of a shared most-recent one.

Contributed by [@ssgreg](https://github.com/ssgreg), from [discussion #71](https://github.com/umputun/agterm/discussions/71). Fish port by [@Arelav](https://github.com/Arelav).

## What it does

Keep several Claude Code sessions open at once, and after the terminal restarts each tab resumes its own conversation instead of a shared "most recent" one.

- Solves a concrete pain: multiple parallel Claude Code sessions survive a restart, each reopening exactly its own conversation.
- Zero state: the conversation id **is** the tab's uuid (`AGTERM_SESSION_ID`). No mapping file to keep in sync or let go stale.
- Idempotent: the first launch pins the conversation to the tab (`--session-id`); later launches continue it (`--resume`), and it flips automatically.
- Stays out of the way: `claude mcp`, `-p`, an explicit `claude --resume <other-id>`, and any launch outside agterm pass through untouched.
- Small, dependency-free, pure shell; options are function-local (zsh's `emulate -L`, fish's implicit function scoping), so nothing leaks into your interactive shell.

## Requirements

- agterm 0.3.1 or later, with **Restore running commands on restart** turned on under Settings ▸ General ▸ Sessions. Both `AGTERM_SESSION_ID` and that setting predate the repository's earliest tagged release, so 0.3.1 is the first version that can be named, not the version the behavior arrived in.
- `zsh`, or `fish`
- Claude Code, with its conversations in the default `~/.claude/projects/`

## Setup

### zsh

The function has to be defined in `~/.zshrc`, the config your interactive login zsh reads. That matters: agterm feeds the restored command into that shell, so `.zshenv` and `.zprofile` are too early to intercept it.

Either paste the function from `claude-resume.zsh` into `~/.zshrc`, or keep the file and source it from there:

```sh
mkdir -p ~/.zsh
cp claude-resume.zsh ~/.zsh/
```

then add to `~/.zshrc`:

```sh
source ~/.zsh/claude-resume.zsh
```

The file is sourced, never run, so it does not need the executable bit and is committed without one. Its shebang is there to name the shell it is written for.

Turn on **Restore running commands on restart** in Settings ▸ General, under Sessions. Without it agterm brings a tab back as a plain shell and there is nothing for the function to intercept.

New tabs and shells pick the function up on their own. In an already-open shell, run `source ~/.zshrc`.

To remove it, delete the function block, or the `source` line, from `~/.zshrc`.

### fish

Drop `claude-resume.fish` into fish's autoload directory, under the name the function is defined with:

```sh
mkdir -p ~/.config/fish/functions
cp claude-resume.fish ~/.config/fish/functions/claude.fish
```

Fish autoloads a function from that directory by filename on first call, in any shell, interactive or not, so there is no config file to source and no restart to arrange. This file too is sourced by fish's autoloader, never run, so it does not need the executable bit and is committed without one.

Turn on **Restore running commands on restart** in Settings ▸ General, under Sessions. Without it agterm brings a tab back as a plain shell and there is nothing for the function to intercept.

New tabs and shells pick the function up on their own; an already-open shell does too, since fish resolves `claude` against the autoload path on next call.

To remove it, delete `~/.config/fish/functions/claude.fish`.

## Usage

Run `claude` the way you always do. The first launch in a tab starts a conversation pinned to that tab, and every later launch in the same tab continues it.

To check it: open a tab, run `claude`, say a few words, then restart the terminal. The tab should come back to the same conversation, and `ps` shows `claude --resume <tab-id>`.

## How it works

agterm can remember the command running in a tab and re-run it on restart. The catch: it re-runs the command verbatim, and `claude` with no arguments is a *new* conversation, not a continuation.

The trick rests on two facts. Every agterm tab has a stable identifier (`AGTERM_SESSION_ID`) that survives a restart. And Claude Code lets you supply a session id from the outside (`--session-id`). So you can use the tab's id as the conversation id, and the tab permanently "owns" one conversation.

The function then wraps `claude`: on the first launch in a tab it pins the conversation to the tab id (`--session-id`); if that conversation's file already exists on disk it continues it (`--resume`). The whole decision is one check: is `<tab-id>.jsonl` present under `~/.claude/projects/`?

On restart agterm replays the remembered command, the function recognizes "its own" id, sees the conversation already exists, and reopens exactly that one. Each tab, its own.

On the agterm side that replay is a foreground-process capture. At quit agterm records the argv of whatever the pane was running, and on relaunch it types that line back into the tab's fresh login shell with each argument single-quoted. Quoting suppresses alias expansion but not function lookup, which is why a shell function named `claude` still catches the replayed line and an alias would not.

## Limits

- **agterm-specific.** It needs a stable per-tab identifier and relies on agterm feeding the restored command back *through the login shell*, which is how the function intercepts it. It will not work as-is in another terminal; you would adapt it to that terminal's equivalent.
- **Rests on restore behavior its author verified empirically rather than from documentation.** It could change between agterm versions.
- **One conversation per tab.** Since conversation id equals tab id, two live `claude` processes in the same tab collide with `Session ID ... is already in use`. A split pane, a scratch pane and any overlay all run under the same `AGTERM_SESSION_ID` as the main pane, so a second `claude` in any of them hits this.
- **It shadows the `claude` command** with a shell function. Passthrough is handled, but the list of subcommands and flags that must not be touched has to be kept current if the CLI grows new ones.
- **It knows Claude Code's on-disk layout** (`~/.claude/projects/*/<id>.jsonl`). If that storage location changes, the "does this conversation exist" check breaks: it would always create, then hit "already in use" on restart. A one-line fix, but worth knowing.
- **zsh or fish only** (the zsh version uses `${:l}`, the `(N)` glob qualifier, and `emulate`; the fish version uses fish-only syntax throughout). Bash needs a rewrite.
- **Existing conversations are not bound to tabs.** After you install this, the first launch in a tab starts a new conversation pinned to that tab; it does not adopt an arbitrary earlier one.
