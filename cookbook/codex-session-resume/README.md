# Codex CLI per-tab session resume

After a restart each tab reopens its own codex conversation instead of the shared most-recent one.

Author: [@brusnigin](https://github.com/brusnigin), from [discussion #71](https://github.com/umputun/agterm/discussions/71#discussioncomment-17515571).

## What it does

Same idea as the Claude Code recipe next door: each tab reopens its own codex conversation after a restart instead of the shared "most recent" one.

The key difference is in the mechanism. Codex will not accept a session id at launch, so instead of tab id equals session id, the function maps tab id to codex session id in `~/.codex/agterm/<tab-id>` and resumes that. A Codex SessionStart hook writes the mapping, from the session id Codex hands it, and only for the codex the function started in that tab. Everything else matches: agterm-specific, zsh only, and subcommands, `exec` and an explicit `resume` pass through untouched.

## Requirements

- agterm 0.3.1 or later, with **Restore running commands on restart** turned on under Settings ▸ General ▸ Sessions. Both `AGTERM_SESSION_ID` and that setting predate the repository's earliest tagged release, so 0.3.1 is the first version that can be named, not the version the behavior arrived in.
- `zsh`
- Codex CLI with lifecycle hooks and the `--no-daemon` flag, checked against codex-cli 0.167.0, with its conversations in the default `~/.codex/sessions/`. The hook creates `~/.codex/agterm/` for its mapping files.
- Python 3.8 or later, only to run the bundled `test_codex_resume.py`. Using the recipe needs no Python.

## Setup

The functions have to be defined in `~/.zshrc`, the config your interactive login zsh reads. That matters: agterm feeds the restored command into that shell, so `.zshenv` and `.zprofile` are too early to intercept it.

Either paste both functions from `codex-resume.zsh` into `~/.zshrc`, or keep the file and source it from there:

```sh
mkdir -p ~/.zsh
cp codex-resume.zsh ~/.zsh/
```

then add to `~/.zshrc`:

```sh
source ~/.zsh/codex-resume.zsh
```

The file is sourced, never run, so it does not need the executable bit and is committed without one. Its shebang is there to name the shell it is written for.

The hook is a separate script that Codex runs, committed executable. Copy it next to the functions:

```sh
cp codex-resume-hook.zsh ~/.zsh/
```

and register it in `~/.codex/config.toml`, with the full path to where you copied it. Codex runs a hook's command through your login shell, so `~` works:

```toml
[[hooks.SessionStart]]
[[hooks.SessionStart.hooks]]
type = "command"
command = "~/.zsh/codex-resume-hook.zsh"
```

The next codex you start lists it under **Hooks need review**; approve it there, or later in `/hooks`. Until it is approved Codex does not run it, and no tab gets a mapping.

Turn on **Restore running commands on restart** in Settings ▸ General, under Sessions. Without it agterm brings a tab back as a plain shell and there is nothing for the function to intercept.

New tabs and shells pick the functions up on their own. In an already-open shell, run `source ~/.zshrc`.

To remove it, delete the two function blocks, or the `source` line, from `~/.zshrc`, the hook's block from `~/.codex/config.toml`, and `~/.codex/agterm/` with them.

## Usage

Run `codex` the way you always do. Start codex, run a command, then restart agterm: the tab resumes that session.

Launch options remain explicit. `codex --yolo` resumes the mapped conversation with `--yolo`, and agterm preserves that invocation across an app restart. A later plain `codex` resumes the same conversation without `--yolo`; the mapping stores only the conversation id, never permission flags.

Mappings live one file per tab under `~/.codex/agterm/`, each holding a single codex session id. Deleting one unbinds that tab, and the next `codex` in it starts fresh. The mapping follows the conversation the tab shows: after `/clear` inside codex, the tab resumes the new conversation from its first turn on.

## How it works

agterm can remember the command running in a tab and re-run it on restart. It re-runs that command verbatim, and `codex` with no arguments is a new conversation rather than a continuation.

Every agterm tab has a stable identifier, `AGTERM_SESSION_ID`, that survives a restart. Claude Code can be handed a session id at launch and so needs no state at all, but codex cannot, so this function keeps the one piece of state that difference forces: a file named after the tab, holding the codex session id that tab owns.

On each `codex` the function reads `~/.codex/agterm/<tab-id>`. If it holds an id and the matching `rollout-*-<id>.jsonl` is still under `~/.codex/sessions/`, it reads the first line's `session_meta.payload.session_id` and resumes that root conversation. Root rollouts carry their own id there, while multi-agent child rollouts carry the resumable root id; older rollouts without the field fall back to the UUID at the end of the filename. The function also repairs an existing child mapping when it finds one. Codex can keep an older rollout only compressed, as `rollout-*-<id>.jsonl.zst`; the function cannot read that file's first line without decompressing it, so it resumes the mapped id as it is, with no child to root repair. Otherwise it runs codex plainly.

The function never works out afterwards which conversation a run created. A rollout file's name and timestamp say nothing about which process or tab wrote it, so "the newest rollout" is whatever any codex on the machine wrote last: a `codex exec` that another agent in the same tab started for a review, a codex in another tab, a desktop app that embeds codex. Instead every codex the function launches in an agterm tab, other than the passthrough commands, gets `CODEX_AGTERM_TAB=<tab-id>` in its environment, and Codex hands its SessionStart hook the session id of the conversation it is running. The hook writes that id to the tab's mapping file. It does nothing when the variable is unset or empty, and the variable reaches no other codex:

- Codex starts a local command hook from its own process environment, not from the policy it applies to tool commands. So the function also passes `-c 'shell_environment_policy.set.CODEX_AGTERM_TAB=""'`: the hook still sees the tab, while every command codex runs sees it empty, including a `codex exec` it starts.
- `--no-daemon` keeps the conversation, and its hooks, in this codex process. A shared background server would run the hook with the environment of whichever pane started that server.
- A codex started any other way never has the variable, so it never writes a mapping.

The same codex process also runs a background memory session, which fires SessionStart with the tab variable set, a `transcript_path` of `null` and a session id that has no rollout. Recording it would point the tab at a conversation the next `codex` cannot resume, so the hook skips any event without a transcript path.

Codex fires SessionStart at a conversation's first turn, not at launch, so a codex closed before anything was sent records nothing. The mapping exists from the first turn, so a terminal restart while codex is still running brings the tab back to its conversation.

agterm replays the argv the pane was running, so a replayed line starts with the function's own `--no-daemon -c …` and, for a resumed conversation, `resume <id>`. The function drops both and decides again from the mapping, so a replay is not mistaken for an explicit `resume`, which passes through untouched.

On the agterm side the replay is a foreground-process capture. At quit agterm records the argv of whatever the pane was running, and on relaunch it types that line back into the tab's fresh login shell with each argument single-quoted. Quoting suppresses alias expansion but not function lookup, which is why a shell function named `codex` still catches the replayed line and an alias would not.

## Limits

- **agterm-specific.** It needs a stable per-tab identifier and relies on agterm feeding the restored command back through the login shell, which is how the function intercepts it. It will not work as-is in another terminal; you would adapt it to that terminal's equivalent.
- **Rests on restore behavior that is verified empirically, not documented.** It could change between agterm versions.
- **One conversation per tab.** A split pane, a scratch pane and any overlay all run under the same `AGTERM_SESSION_ID` as the main pane, so a second codex started in one of them reads and overwrites the same mapping file as the first.
- **It shadows the `codex` command** with a shell function. Passthrough is handled, but the list of subcommands and flags that must not be touched has to be kept current if the CLI grows new ones.
- **It knows codex's on-disk layout** (`~/.codex/sessions/**/rollout-*.jsonl`, or `.jsonl.zst` when compressed) and the first-line `session_meta.payload.session_id` field. If that layout changes, it falls back to the filename UUID when possible; otherwise a mapped conversation is not found and the tab starts fresh. The hook reads the `session_id` field of a SessionStart event that carries a transcript path; if that field is missing it writes nothing, prints why on stderr and exits non-zero.
- **Every codex the function launches in an agterm tab, other than the passthrough commands, runs with `--no-daemon`**, without the shared background server. The hook needs that to see the right tab. On those launches a `--no-daemon` you type yourself is dropped, because codex refuses the flag twice; a `--no-daemon` after `--` is prompt text and stays.
- **An explicit `codex resume <id>` is not recorded.** It passes through without the tab variable, so the tab keeps its earlier mapping.
- **It needs the hook approved.** Codex runs a new or changed hook definition only after you approve it. Until then the hook writes no mappings; the function still resumes a mapping a tab already has, and repairs a child mapping to its root.
- **zsh only** (`${:l}`, the `(N)` glob qualifier, `emulate`, `setopt local_options`, `=~`). Bash needs a rewrite.
