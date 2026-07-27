# Codex CLI per-tab session resume

After a restart each tab reopens its own codex conversation instead of the shared most-recent one.

Contributed by [@brusnigin](https://github.com/brusnigin), from [discussion #71](https://github.com/umputun/agterm/discussions/71#discussioncomment-17515571).

## What it does

Same idea as the Claude Code recipe next door: each tab reopens its own codex conversation after a restart instead of the shared "most recent" one.

The key difference is in the mechanism. Codex will not accept a session id at launch, so instead of tab id equals session id, the function maps tab id to codex session id in `~/.codex/agterm/<tab-id>` and resumes that. Everything else matches: agterm-specific, zsh only, and subcommands, `exec` and an explicit `resume` pass through untouched.

## Requirements

- agterm 0.3.1 or later, with **Restore running commands on restart** turned on under Settings ▸ General ▸ Sessions. Both `AGTERM_SESSION_ID` and that setting predate the repository's earliest tagged release, so 0.3.1 is the first version that can be named, not the version the behavior arrived in.
- `zsh`
- Codex CLI, with its conversations in the default `~/.codex/sessions/`. The function creates `~/.codex/agterm/` for its own mapping files.

## Setup

The function has to be defined in `~/.zshrc`, the config your interactive login zsh reads. That matters: agterm feeds the restored command into that shell, so `.zshenv` and `.zprofile` are too early to intercept it.

Either paste the function from `codex-resume.zsh` into `~/.zshrc`, or keep the file and source it from there:

```sh
mkdir -p ~/.zsh
cp codex-resume.zsh ~/.zsh/
```

then add to `~/.zshrc`:

```sh
source ~/.zsh/codex-resume.zsh
```

The file is sourced, never run, so it does not need the executable bit and is committed without one. Its shebang is there to name the shell it is written for.

Turn on **Restore running commands on restart** in Settings ▸ General, under Sessions. Without it agterm brings a tab back as a plain shell and there is nothing for the function to intercept.

New tabs and shells pick the function up on their own. In an already-open shell, run `source ~/.zshrc`.

To remove it, delete the function block, or the `source` line, from `~/.zshrc`, and `~/.codex/agterm/` with it.

## Usage

Run `codex` the way you always do. Start codex, run a command, then restart agterm: the tab resumes that session.

Mappings live one file per tab under `~/.codex/agterm/`, each holding a single codex session id. Deleting one unbinds that tab, and the next `codex` in it starts fresh.

## How it works

agterm can remember the command running in a tab and re-run it on restart. It re-runs that command verbatim, and `codex` with no arguments is a new conversation rather than a continuation.

Every agterm tab has a stable identifier, `AGTERM_SESSION_ID`, that survives a restart. Claude Code can be handed a session id at launch and so needs no state at all, but codex cannot, so this function keeps the one piece of state that difference forces: a file named after the tab, holding the codex session id that tab owns.

On each `codex` the function reads `~/.codex/agterm/<tab-id>`. If it holds an id and the matching `rollout-*-<id>.jsonl` is still under `~/.codex/sessions/`, it runs `codex resume <id>` and is done. Otherwise it records a timestamp, runs codex plainly, and afterwards takes the newest rollout file. If that file is newer than the timestamp it is the conversation this run created, so the function pulls the uuid off the end of the filename, checks the shape, and writes it to the mapping file for next time.

On the agterm side the replay is a foreground-process capture. At quit agterm records the argv of whatever the pane was running, and on relaunch it types that line back into the tab's fresh login shell with each argument single-quoted. Quoting suppresses alias expansion but not function lookup, which is why a shell function named `codex` still catches the replayed line and an alias would not.

## Limits

- **agterm-specific.** It needs a stable per-tab identifier and relies on agterm feeding the restored command back through the login shell, which is how the function intercepts it. It will not work as-is in another terminal; you would adapt it to that terminal's equivalent.
- **Rests on restore behavior that is verified empirically, not documented.** It could change between agterm versions.
- **One conversation per tab.** A split pane, a scratch pane and any overlay all run under the same `AGTERM_SESSION_ID` as the main pane, so a second codex started in one of them reads and overwrites the same mapping file as the first.
- **It shadows the `codex` command** with a shell function. Passthrough is handled, but the list of subcommands and flags that must not be touched has to be kept current if the CLI grows new ones.
- **It knows codex's on-disk layout** (`~/.codex/sessions/**/rollout-*.jsonl`). If that storage location or the filename shape changes, the mapping stops being written and every tab starts fresh.
- **zsh only** (`${:l}`, the `(N)` and `(om)` glob qualifiers, `emulate`, `setopt local_options`). Bash needs a rewrite.

Two observations from reading the function rather than claims by its author:

- The mapping is written only after codex exits and control returns to the function. A terminal restart while codex is still running kills the shell before that line is reached, so a tab whose codex has never exited cleanly has nothing mapped and comes back to a fresh conversation. From the first clean exit onward it resumes as described. The Claude Code recipe does not have this shape, because it decides the id before launching instead of capturing it afterward.
- The capture picks the newest rollout file in the whole `~/.codex/sessions/` tree. If codex in another tab writes a rollout between this tab's own launch and its exit, the wrong id can be recorded for this tab.
