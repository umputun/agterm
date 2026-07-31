# opencode per-tab session resume

After a restart each tab reopens its own opencode conversation instead of starting a fresh one.

Contributed by [@cherkale](https://github.com/cherkale), from [discussion #71](https://github.com/umputun/agterm/discussions/71#discussioncomment-17845561).

## What it does

Same idea as the Claude Code and codex recipes next door: each tab reopens its own conversation after a restart.

The mechanism follows the codex one, because opencode is also unable to take a session id at launch: the function maps tab id to opencode session id in `~/.local/state/opencode/agterm/<tab-id>` and resumes that. The difference is where the session id comes from. opencode keeps conversations in sqlite rather than one file per conversation, so there is nothing to glob for; the function asks `opencode session list --format json` instead. That list holds the current project's top-level sessions, while `--session` is not scoped at all and takes any session that exists, so everything the list offers is something a resume will accept.

Subcommands, an explicit `--session`/`--continue`, and any launch outside agterm pass through untouched.

## Requirements

- agterm 0.3.1 or later, with **Restore running commands on restart** turned on under Settings ▸ General ▸ Sessions. Both `AGTERM_SESSION_ID` and that setting predate the repository's earliest tagged release, so 0.3.1 is the first version that can be named, not the version the behavior arrived in.
- `zsh`
- opencode 1.18.10 or later, the version its `session list --format json` output shape and `--session` validation were checked against. The function creates `~/.local/state/opencode/agterm/` for its own mapping files, next to opencode's own state directory (`$XDG_STATE_HOME` is honored if you set it).

## Setup

The functions have to be defined in `~/.zshrc`, the config your interactive login zsh reads. That matters: agterm feeds the restored command into that shell, so `.zshenv` and `.zprofile` are too early to intercept it.

Either paste both functions from `opencode-resume.zsh` into `~/.zshrc`, or keep the file and source it from there:

```sh
mkdir -p ~/.zsh
cp opencode-resume.zsh ~/.zsh/
```

then add to `~/.zshrc`:

```sh
source ~/.zsh/opencode-resume.zsh
```

The file is sourced, never run, so it does not need the executable bit and is committed without one. Its shebang is there to name the shell it is written for.

Turn on **Restore running commands on restart** in Settings ▸ General, under Sessions. Without it agterm brings a tab back as a plain shell and there is nothing for the function to intercept.

New tabs and shells pick the functions up on their own. In an already-open shell, run `source ~/.zshrc`.

To remove it, delete the two function blocks, or the `source` line, from `~/.zshrc`, and `~/.local/state/opencode/agterm/` with it.

## Usage

Run `opencode` the way you always do. Start it, send at least one message, quit it, then start it again in the same tab — `ps` shows `opencode --session ses_…`. Restart agterm and the tab comes back to that conversation.

The first message matters. opencode writes the session only once there is something in it, so a tab where you started opencode and typed nothing has nothing to remember and comes back empty-handed.

Mappings live one file per tab under `~/.local/state/opencode/agterm/`, each holding a single opencode session id. Deleting one unbinds that tab, and the next `opencode` you type in it starts fresh — though a tab restored as `opencode --session <id>` still reopens that conversation while it exists, since an explicit id passes through untouched.

## How it works

agterm can remember the command running in a tab and re-run it on restart. It re-runs that command verbatim, and `opencode` with no arguments is a new conversation rather than a continuation.

Every agterm tab has a stable identifier, `AGTERM_SESSION_ID`, that survives a restart. Claude Code can be handed a session id at launch and so needs no state at all. opencode cannot: `--session` is validated against existing sessions, and an id that is not there makes opencode print an error and exit instead of starting. So, like the codex recipe, this one keeps a file named after the tab holding the session id that tab owns — and, unlike it, never passes an id it has not just seen in the session list.

On each `opencode` the function reads `~/.local/state/opencode/agterm/<tab-id>` and lists the current project's sessions. If the mapped id is among them it runs `opencode --session <id>` and is done. Otherwise it runs opencode plainly and, when that returns, lists again: the first id that was not in the "before" list is the conversation this run created, and it goes into the mapping file for next time. The list comes back most recently updated first, which is why the first new id is the right one to take.

Two things about opencode shaped this. Conversations moved into `~/.local/share/opencode/opencode.db`, so the recipe reads them through the CLI rather than through the database — the schema is internal, `session list` is not. And the session row appears only when the first message is sent, not when the TUI starts, so the id cannot be captured right after launch; it has to be adopted after the run.

The restored command line is `opencode --session <id>`, which the function recognizes as its own: it drops the flag and decides again from scratch, so a tab whose conversation was deleted in the meantime comes back to a fresh opencode rather than to an error message.

On the agterm side the replay is a foreground-process capture. At quit agterm records the argv of whatever the pane was running, and on relaunch it types that line back into the tab's fresh login shell with each argument single-quoted. Quoting suppresses alias expansion but not function lookup, which is why a shell function named `opencode` still catches the replayed line and an alias would not.

## Limits

- **agterm-specific.** It needs a stable per-tab identifier and relies on agterm feeding the restored command back through the login shell, which is how the function intercepts it. It will not work as-is in another terminal; you would adapt it to that terminal's equivalent.
- **Rests on restore behavior that is verified empirically, not documented.** It could change between agterm versions.
- **The mapping is written only after opencode exits.** A terminal restart while opencode is still running kills the shell before that line is reached, so a tab that has never exited opencode cleanly comes back to a fresh conversation. From the first clean exit onward the tab is mapped, and after that a restart is covered twice over, by the mapping file and by the replayed `--session` line.
- **One conversation per tab.** A split pane, a scratch pane and any overlay all run under the same `AGTERM_SESSION_ID` as the main pane, so a second opencode started in one of them reads and overwrites the same mapping file as the first.
- **The tab keeps the conversation it first adopted.** Switching to another session inside the TUI does not move the mapping, so the next launch reopens the adopted one.
- **A busy neighbor can be adopted by mistake.** The session list is shared across every tab in the project, so if another tab starts a conversation while this one is running, this one can adopt that id on exit. Outside a git repository the project is `global`, which spans every non-repository directory on the machine, so there the neighbor can be a tab working somewhere else entirely.
- **It shadows the `opencode` command** with a shell function. Passthrough is handled, but the list of subcommands and flags that must not be touched has to be kept current if the CLI grows new ones.
- **It reads the shape of `session list --format json`** — one field per line, ids as `"id": "ses_…"`. If that output becomes single-line JSON the parse finds nothing, no mapping is written and every tab starts fresh. It fails toward a new conversation rather than toward the wrong one.
- **It costs a `session list` call per launch**, the better part of a second, plus a second one after a run that created a conversation. The TUI appears that much later.
- **`opencode <path>` is not mapped.** The session list is taken in the shell's own directory, so a conversation started in another project is never seen there and that tab stays unmapped. A tab that already owns a conversation keeps it, since the path is simply passed along with the `--session` it resumes.
- **The binding follows the project.** The "does it still exist" check is project-scoped, so running `opencode` from the same tab in a different repository starts a fresh conversation there and the mapping moves to it. The tab owns one conversation at a time, not one per project.
- **zsh only** (`${:l}`, `${(f)}`, the `(Ie)` subscript flag, `emulate`). Bash needs a rewrite.
- **Existing conversations are not bound to tabs.** After you install this, the first run in a tab adopts the conversation that run creates; it does not adopt an arbitrary earlier one.
