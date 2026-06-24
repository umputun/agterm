---
name: agterm
description: >
  Drive agterm, a native macOS terminal app, programmatically via its agtermctl CLI and a local
  control socket. Use when running inside an agterm session and asked to control the terminal:
  create, rename, close, select, or reorder sessions and workspaces; split panes; toggle the
  per-session scratch terminal; open or close overlay terminals and read their exit status; type
  into a session, copy its selection, or search its scrollback; post desktop notifications; manage windows (new, list,
  select, close, resize, move); change font size; or reload and edit the keymap. Also covers the
  window/workspace/session addressing model and the AGTERM_* environment a spawned shell sees.
when_to_use: >
  Trigger on: agterm, agtermctl, agterm control socket, session.new, session.close, session.type,
  session.split, session.scratch, session.focus, session.go, session.copy, session.search, session.status,
  session.overlay, workspace.new, workspace.select, workspace.move, window.new, window.list,
  window.select, window.resize, window.move, quick terminal, notify, font.inc, keymap.reload,
  edit keymap, AGTERM_SESSION_ID, AGTERM_SOCKET, and asks to drive or script agterm.
user-invocable: false
allowed-tools: Bash(agtermctl *)
---

<!-- agterm-skill -->

# Driving agterm

agterm is a native macOS terminal. It exposes a programmatic control channel over a local unix
socket, driven by the companion CLI `agtermctl`. Use it to build and steer terminal layouts, run
programs in overlays, type into sessions, and notify the user in the exact session you are working
in. Fire-and-forget commands only: there is no terminal-output streaming and no event subscription.

## Am I inside agterm?

Each shell agterm spawns gets these environment variables. Check `AGTERM_ENABLED` before assuming
the control channel is available:

- `AGTERM_ENABLED=1` — this shell runs inside agterm.
- `AGTERM_SESSION_ID` — the current session's UUID (the session this shell belongs to).
- `AGTERM_WINDOW_ID` / `AGTERM_WORKSPACE_ID` — the owning window / workspace UUIDs.
- `AGTERM_SOCKET` — the absolute path to the control socket this app bound.

The quick terminal is scratch (not in the tree), so it only gets `AGTERM_ENABLED`, `AGTERM_WINDOW_ID`,
and `AGTERM_SOCKET` (no session/workspace ids).

## Running agtermctl

`agtermctl` must be on PATH (install it from agterm's **Help ▸ Install Command Line Tool…**). If it
is not on PATH, the user can install it, or you invoke it by absolute path.

- The socket path auto-resolves; usually no `--socket` is needed. To be explicit, pass
  `--socket "$AGTERM_SOCKET"`.
- `--socket` and other options go **after** the subcommand: `agtermctl tree --json`, not
  `agtermctl --json tree`.
- Add `--json` to any command to get the raw JSON response (machine-readable). Without it, mutations
  print `ok` and `tree`/`list` print a human listing.
- One request per invocation. Mutating commands return the affected/new id; create commands
  (`session new`, `workspace new`, `window new`) print the new id.

## The model

A **window** is the top level: a named bundle rendered in its own on-screen macOS window. Each window
holds a tree of **workspaces**, each holding **sessions**. A session has a primary shell and can also
have: a **split** pane (a second shell side by side), a **scratch** terminal (a third full-coverage
shell, toggled like the split), and an ephemeral **overlay** (runs one program on top, then vanishes).
Separately, each window has one **quick terminal** (a scratch overlay at 90% of the window, not part
of the tree).

Inspect the live tree any time with `agtermctl tree --json` (workspaces → sessions, each with
`id`, `name`, `cwd`, `active`, `split`, `overlay`, `scratch`). List windows with
`agtermctl window list --json`.

## Addressing

Commands that target a session or workspace take `--target` (default `active`):

- `active` — the selected session / current workspace.
- a full UUID (case-insensitive), or a unique **prefix** of one (git-style). Zero matches → `notFound`
  error; two or more → `ambiguous` error listing candidates.

`window.*` commands take the window id/prefix/`active` as a positional argument. Other commands accept
a global `--window <id|prefix|active>` to operate on a specific window's tree (default: the frontmost).

Scripts rarely type ids: create with `*.new` (capture the returned id), or act on `active`.

## Command summary (36 commands)

Run `agtermctl <area> <cmd> --help` for exact flags. Full detail in **reference.md**; recipes in
**examples.md**.

**tree** — print the workspace/session tree (`--json` for structured).

**workspace** — `new [name]` · `rename <name>` · `delete` · `select` · `move --to up|down|top|bottom`.

**session**
- `new [--cwd DIR] [--workspace W] [--command CMD]` — create (and focus) a session; `--command` runs
  that program as the session process instead of a login shell.
- `close` · `select` · `rename <name>`.
- `go --to next|prev|first|last|next-attention|prev-attention` — move the selection between sessions.
- `move <workspace>` (relocate) or `move --to up|down|top|bottom` (reorder within the workspace).
- `type <text> [--stdin] [--select]` — inject keystrokes (real typing, Enter included).
- `copy` — print the session's selected text (does NOT touch the system clipboard).
- `search [needle] [--next|--prev|--close]` — search the terminal scrollback; prints the "N of M" counter.
- `split [on|off|toggle]` — side-by-side second shell (hide keeps it alive).
- `scratch [on|off|toggle]` — full-coverage third shell (hide keeps it alive; `exit` recreates).
- `focus [left|right|other]` — move focus between split panes.
- `status <idle|active|completed|blocked> [--blink] [--auto-reset]` — set the sidebar agent glyph.
- `overlay open <command> [--cwd DIR] [--wait] [--block] [--size-percent N]` · `overlay close` ·
  `overlay result` — run a program on top of a session; `--block` waits and exits with its status.

**window** — `new [name]` · `list` · `select <id>` · `close <id>` · `rename <id> <name>` ·
`delete <id>` · `resize <id> --width W --height H` · `move <id> --x X --y Y [--display N]`.

**quick** — `[show|hide|toggle]` — the window's quick terminal.

**notify** — `notify <body> [--title T]` — post a desktop notification attributed to a session.

**font** — `font inc|dec|reset` — font size on the focused surface.

**keymap** — `keymap reload` — re-read `keymap.conf` (prints the parse-diagnostic count).

## Reference files

- **reference.md** — full per-command detail: every flag, the JSON return shapes
  (`result.id`/`text`/`exitCode`/`count`/`tree`/`windows`), error strings, the scratch/overlay/split
  lifecycle, and the keymap.conf format (`map` / `command`, chords, leaders, `{AGT_X}` tokens).
- **examples.md** — copy-paste agtermctl recipes for common tasks (build a layout, run a program in a
  blocking overlay and read its status, type into a fresh session, notify, inspect the tree).

Read those files when you need exact flags, return shapes, or worked examples.
