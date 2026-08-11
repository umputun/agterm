# Backlog picker

Pick one of the repo's written-down deferred items in the native picker and hand it to the Claude Code run sitting in the pane.

## What it does

A backlog is a directory of markdown files at the repo root, `docs/backlog/`, one file per item: a defect a change did not introduce, drift with no user-visible symptom, a fix whose blast radius exceeded its value. Writing an item down is cheap. Coming back to it is not, because by then you have to find it, read it, decide whether it still applies, and then explain it to the agent.

One chord does all of that. The picker lists this repo's items newest first, each row showing the triage call, how old the item is and where it lives:

```
reopen fallback ignores the last-frontmost window
worth fixing later · 6d · internal/store/reopen.go:537

palette hover tint goes stale under a parked pointer
worth fixing · 3mo · internal/ui/palette.go:212
```

Choosing one types `/backlog <slug>` into the pane you pressed the chord in, so the agent reads that single item, checks its `where` still says what the item claims, and comes back with fix-or-drop. At a bare shell prompt it types `claude "/backlog <slug>"` instead, which starts Claude Code on that item.

The repo is whichever one the session sits in, so the same chord in another tab lists that project's backlog.

## Requirements

- agterm 0.20.2 or later. `pick` itself shipped in 0.19.0; 0.20.0 is where a caller-supplied picker stopped re-sorting an empty query alphabetically and stopped matching typed text against subtitles, both of which this recipe depends on — newest-first is the order it hands over, and a query must not match the `where` path in a row's subtitle. 0.20.2 is where `tree --json` began reporting `foreground` for a pane started with `session new --command`, which is what keeps the recipe from typing a shell command into a running agent. `{AGT_PANE}`, which routes the typing back into the half of the split you pressed the chord in, shipped in 0.13.0.
- Python 3.9 or later, which macOS ships as `/usr/bin/python3`
- Claude Code, plus the `backlog` skill in this directory. The skill is what makes `/backlog <slug>` mean anything; without it the slash command is typed into a Claude that does not know it.
- `docs/backlog/` in the repos you use it in. The format is in the skill and in *How it works* below.

Set `AGTERMCTL` if your binary is somewhere unusual; the script otherwise finds one itself, described under *How it works*.

## Setup

Copy the script somewhere on your machine, say `~/bin/`, and make it executable:

```sh
mkdir -p ~/bin && cp backlog-picker.py ~/bin/ && chmod +x ~/bin/backlog-picker.py
```

Install the skill by copying `SKILL.md` to `~/.claude/skills/backlog/SKILL.md`:

```sh
mkdir -p ~/.claude/skills/backlog && cp SKILL.md ~/.claude/skills/backlog/SKILL.md
```

It is an ordinary Claude Code skill, so a project copy under `.claude/skills/backlog/` works the same way if you want it in one repo only. Read it before you install it: it tells the agent when to write items, when to leave them alone, and to never commit one on its own.

Add an entry to `~/.config/agterm/keymap.conf` and apply it with File ▸ Reload Keymap or `agtermctl keymap reload`:

```
command "Backlog ›" ctrl+a>b ~/bin/backlog-picker.py
```

The name ends in `›` so the palette shows it opens something rather than doing something. Any chord works, and a `command` line with no chord at all is palette-only.

If your Claude Code launcher is a wrapper rather than `claude` itself, it takes two variables, and both matter. `BACKLOG_FG_MATCH` is how the script recognises the wrapper already running in the pane, without which every pick types a shell command into a live agent; `BACKLOG_CLAUDE_CMD` is what it types at a bare prompt, without which it starts plain `claude` rather than your wrapper:

```
command "Backlog ›" ctrl+a>b BACKLOG_FG_MATCH='(^|/)(claude|mywrapper)$' BACKLOG_CLAUDE_CMD=mywrapper ~/bin/backlog-picker.py
```

`BACKLOG_DIR` moves the item directory, relative to the repo root, if yours is not `docs/backlog`.

## Usage

Press the chord in any session sitting in a repo that has a backlog. Type to filter, Return to pick, Escape to cancel — cancelling types nothing.

Check what the picker will show without opening it:

```sh
./backlog-picker.py --list
```

It prints one line per item, slug first, then the count and the directory it read. This is the first thing to run when the picker says the backlog is empty and you know it is not: the path it prints is the repo root it resolved.

The script also carries its own tests, which is what to run after editing the parser:

```sh
./backlog-picker.py --test
```

Every failure exits nonzero, and agterm banners that by itself as `Backlog › (exit 1)`, because a keybinding has no stdout anyone reads. Four of them post a second banner naming what went wrong: no items in the directory, the picker failing, the picker returning an item that is not there, and the typing failing. A failure with no `agtermctl` to talk to — the binary missing, or an `AGTERMCTL` that is not executable — can only be the bare one. Everything else is in `/tmp/backlog-picker.log`, or wherever `BACKLOG_PICKER_LOG` points: a file skipped for its name, an unreadable file, and a `tree` read that failed are logged there and nowhere else.

## How it works

An item is `docs/backlog/<slug>.md`, and the slug — the file name without its extension — is the identifier the whole recipe passes around. Three optional frontmatter fields carry the triage:

```markdown
---
worth: later
where: internal/store/reopen.go:537
added: 2026-08-05
---
# reopen fallback ignores the last-frontmost window

Body prose: repro, what was tried, the review that surfaced it.
```

The H1 is the row's label and the three fields become its subtitle. All of them are optional and a missing one costs that field only, so a plain markdown note with no frontmatter still lists, under its H1 or its file name. `added` is never rewritten, which is what lets the subtitle show an item's age honestly; a year-old entry says something its title does not.

Items are sorted by `added` and then by mtime, newest first, because a day's granularity cannot separate two items written in one session. That order is handed to `agtermctl pick` on stdin as JSON and shown as-is. `added` being the sort key is why a value that is not an ISO date is dropped rather than kept: `2026-8-5` compares above every well-formed `2026-…` and would park a typo at the top of the list with no age beside it to explain why.

The file name is treated as hostile, because in a repo you cloned it is someone else's. The bare-prompt line is quoted with `shlex`, so `a"; id; :"b.md` reaches the shell as one argument rather than as a second statement, and a name carrying a control character is refused outright and logged — a newline in a slug would otherwise submit a line of its own to whatever is running in the pane. The row shows the H1 while the file name carries the slug, so nothing about such an item looks wrong at the moment you pick it.

The pane's live foreground argv comes from `tree --json --window`: `foreground` for the left pane, `splitForeground` for the right. Any argv element matching `BACKLOG_FG_MATCH` means Claude Code is running there, which is what decides between typing a slash command and typing a launcher. A scratch pane always reads as a shell, because the tree reports the main and split panes only, and so does a read that failed — a session closed while the picker was open, say — which is logged rather than guessed at.

Finding `agtermctl` is the part that cost an hour. Existence is not enough: several installs coexist easily, and a PATH lookup can land on an old **Install Command Line Tool…** symlink pointing at an app that is not the one holding the socket, so a `pick` call fails against a binary that looks perfectly fine. The script asks the running app's own bundle first — read out of the process list, since `pgrep` does not see GUI apps from a keybinding's environment — then falls back through `$GHOSTTY_BIN_DIR`, the usual install paths and `PATH`, probing each candidate's `--help` for a `pick` subcommand rather than trusting a version string. `AGTERMCTL` skips the whole search and is used as given, without the probe: a wrapper script that adds a default `--socket` is exactly what the override is for, and it does not reproduce the help layout the probe reads. Being executable is all that is asked of it, and a path that is not stops the run saying so.

Everything the script needs about where it is comes from the environment agterm exports to a custom command: `AGT_SESSION_PWD` for the repo, `AGT_SESSION_ID` and `AGT_PANE` for where to type, `AGT_WINDOW_ID` for which window shows the picker, and `AGT_SOCKET` for the instance to talk to. The repo root itself is `git rev-parse --show-toplevel` from that directory, so the chord works from a subdirectory.

## Limits

Picking an item types a line and sends Return into the pane. If something other than an agent or a shell prompt is sitting there — a pager, a TUI, a program waiting on input — that line goes into it instead. The recipe never checks what it is typing into beyond the Claude-or-not test.

The typed instruction is where it stops. What happens next is the agent's, and the skill tells it to ask before fixing anything and never to commit on its own, but it is an instruction and not a guarantee.

A session whose repo has no `docs/backlog/` gets a notification saying so, not an empty picker. The recipe never creates the directory.

The picker lists one repo, the session's own. There is no cross-repo view here.
