---
name: agterm
description: >
  Drive agterm, a native macOS terminal app, programmatically via its agtermctl CLI and a local
  control socket. Use when running inside an agterm session and asked to control the terminal:
  create, rename, close, select, or reorder sessions and workspaces; split panes; toggle the
  per-session scratch terminal; open or close overlay terminals and read their exit status; display
  an image inline via a bundled helper script; type
  into a session, copy its selection, or search its scrollback; post desktop notifications; manage windows (new, list,
  select, close, resize, move); change font size; or reload and edit the keymap and the agterm-scoped
  ghostty config. Also covers the
  window/workspace/session addressing model and the AGTERM_* environment a spawned shell sees, plus
  diagnosing problems (keymap editor, custom actions, logs) and filing a bug as a GitHub issue or a
  feature request / question as a GitHub Discussion.
when_to_use: >
  Trigger on: agterm, agtermctl, agterm control socket, session.new, session.close, session.type,
  session.split, session.scratch, session.focus, session.resize, surface.zoom, dashboard, session.go, session.copy, session.paste, session.selectall, session.text, session.search, session.status,
  session.flag, session.seen, session.reveal, session.background, session.overlay, workspace.new, workspace.select, workspace.move, workspace.focus, window.new, window.list,
  window.select, window.resize, window.move, window.zoom, window.fullscreen, quick terminal, sidebar, sidebar.mode, sidebar.expand, sidebar.collapse, flagged, notify, font.inc, keymap.reload, config.reload,
  theme.set, theme.list, select theme, edit keymap, show an image, display an image inline, show-image,
  AGTERM_SESSION_ID, AGTERM_SOCKET, and asks to drive or script agterm. Also: troubleshoot agterm,
  keymap editor won't open, custom action / custom command not working, agterm logs, file an agterm
  bug, report an agterm issue, open an agterm discussion / feature request.
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

These variables are inherited by every process the session's shell spawns — including long-lived
daemons that outlive the shell. A tmux/screen server, a session manager (agent-deck and the like), or
any background service started from inside a session captures the spawning session's `AGTERM_*` and
passes it to every child it ever creates, so status hooks running in those children resolve
`$AGTERM_SESSION_ID` to the session that happened to start the daemon and report to the WRONG session.
Before starting such a process from inside agterm, scrub the variables
(`env -u AGTERM_ENABLED -u AGTERM_PANE -u AGTERM_SESSION_ID -u AGTERM_SOCKET -u AGTERM_WINDOW_ID -u AGTERM_WORKSPACE_ID <cmd>`);
see troubleshooting.md ("agent-status glyph updates the wrong session") for diagnosing and fixing an
already-poisoned tmux server.

## Running agtermctl

`agtermctl` must be on PATH (install it from agterm's **Help ▸ Install Command Line Tool…**). If it
is not on PATH, the user can install it, or you invoke it by absolute path.

- The socket path auto-resolves; usually no `--socket` is needed. To be explicit, pass
  `--socket "$AGTERM_SOCKET"`.
- `--socket` and other options go **after** the subcommand: `agtermctl tree --json`, not
  `agtermctl --json tree`.
- Add `--json` to any command to get the raw JSON response (machine-readable). Without it, ordinary
  mutations print `ok`, batch close/move prints the affected session count, and `tree`/`list` print a
  human listing.
- One request per invocation. Mutating commands return the affected/new id; batch session mutations return
  the number actually changed. Create commands (`session new`, `workspace new`, `window new`) print the new id.

## The model

A **window** is the top level: a named bundle rendered in its own on-screen macOS window. Each window
holds a tree of **workspaces**, each holding **sessions**. A session has a primary shell and can also
have: a **split** pane (a second shell side by side), a **scratch** terminal (a third full-coverage
shell, toggled like the split), and an ephemeral **overlay** (runs one program on top, then vanishes).
Separately, each window has one **quick terminal** (a scratch overlay at 90% of the window, not part
of the tree).

Inspect the live tree any time with `agtermctl tree --json` (workspaces → sessions, each with
`id`, `name`, `cwd`, `title`, `active`, `split`, `overlay`, `scratch`, `status`, `background`, `surfaces`). `title` is the raw OSC
terminal title (e.g. a remote host over SSH), omitted when none was reported — read it when a
session's local `cwd` is stale because it's connected to a remote. `surfaces[].id` is the
control address for `surface zoom` (`left`, `right`, `scratch`, or `overlay`), including
hidden-but-alive split/scratch surfaces. The tree object also carries five
read-only top-level fields: `idleMs` (ms since the last user input in the window), `autoFollowMs`
(the Auto-follow timeout in ms, omitted when Disabled), `sidebarVisible` (whether the window's
sidebar is currently shown — the read side of the write-only `sidebar` command), `sidebarMode`
(`tree` or `flagged` — the read side of `sidebar mode`), and `quickVisible` (whether the window's quick
terminal is shown — the read side of the write-only `quick` command). List windows with
`agtermctl window list --json`; each window also reports `autoFollowMs`, `sidebarVisible`, `geometry`
(the live frame `{x, y, width, height, display}` in the units `window move`/`window resize` take — the
read side, so record it then restore the exact frame), and `fullscreen`/`zoomed` (the read side of
`window fullscreen`/`window zoom`, so a script can make those toggles idempotent) — all omitted for a
closed window, but not the live `idleMs`, which is `tree`-only.

## Addressing

Commands that target a session or workspace take `--target` (default `active`):

- `active` — the selected session / current workspace.
- a full UUID (case-insensitive), or a unique **prefix** of one (git-style). Zero matches → `notFound`
  error; two or more → `ambiguous` error listing candidates.

`window.*` commands take the window id/prefix/`active` as a positional argument. Other commands accept
a global `--window <id|prefix|active>` to operate on a specific window's tree (default: the frontmost).

Scripts rarely type ids: create with `*.new` (capture the returned id), or act on `active`.

**Agents: `active` is almost never your own session.** `active` is the session the USER has selected in
the GUI; your shell runs in `$AGTERM_SESSION_ID`, and the user is usually on a different session while
you work. For any session-scoped command meant to act on *this* session — `overlay open`, `scratch`,
`type`, `text`, `background`, `status`, `copy`, … — pass `--target "$AGTERM_SESSION_ID"`. Omit it and
you open overlays / type into whatever the user has selected, not your own session.

## Command summary (60 commands)

Run `agtermctl <area> <cmd> --help` for exact flags. Full detail in **reference.md**; recipes in
**examples.md**.

**tree** — print the workspace/session tree (`--json` for structured). Each session node carries
`foreground`/`splitForeground` (the live argv of each pane's foreground process, omitted when the pane
is at its shell prompt) — i.e. what each pane is currently running — `status` (the agent-status set
via `session status`: `active`|`completed`|`blocked`, omitted when idle), `statusPane` (which pane set
that status: `left` (main) | `right` (split) | `scratch`, from `session status --pane`, omitted when
unset or idle), `statusBlink`/`statusColor` (the status glyph's `--blink` flag and `--color` `#rrggbb`
override from `session status`, omitted when idle / not blinking / default color), `background` (the background
spec — image/text watermark or solid color — set via `session background`, omitted when none — the read side of set/clear),
`unseen` (the unseen-notification badge count — raised by `notify`/OSC 9/777, cleared by `session
seen` — omitted when zero), `overlaySizePercent` (an open overlay's floating-panel percent 1–100,
omitted for a full-pane overlay or no overlay so gate on `overlay` first; the read side of `overlay
resize` for a record-then-restore zoom), `splitRatio` (the left-pane divider fraction 0.05–0.95 of a
session that has a split — shown or hidden; omitted when there's no split or the ratio was never set (at
the default 0.5) —
the read side of `session resize`, record it to restore the exact divider), `splitFocused`
(which pane holds focus in a session that has a split — `true` = split/right, `false` = main/left; omitted
when there's no split; the read side of `session focus`, record it to restore focus), and `surfaces`
(`id`, `kind`, `active`, `visible`) for `surface zoom`. The tree top level carries `zoomedSurface`
(the control id of the currently zoomed surface, omitted when nothing is zoomed — the read side of
`surface zoom`, so a script can check the zoom state and record-then-restore). It also carries the read
side of the `dashboard` command (all omitted when no dashboard is open): `dashboardMembers` (the pane refs
the open dashboard shows, in grid order — `<session-id>:left` for a primary pane, `<session-id>:right` for
a split pane, so a split session appears as both), `dashboardHighlighted` (the highlighted cell's pane ref —
the one Enter jumps into, focusing that exact pane), `dashboardFontSize` (the absolute font size in points
applied to the cells, omitted when untouched), and `dashboardFontMode` (`auto`|`fixed`|`untouched`).

**workspace** — `new [name]` · `rename <name>` · `delete` · `select` · `move --to up|down|top|bottom` ·
`focus [on|off|toggle]` (collapse the sidebar tree to a single workspace; read back which workspace is
focused from the tree workspace node's `focused` flag).

**session**
- `new [--cwd DIR] [--workspace W] [--workspace-name NAME] [--create-workspace] [--command CMD] [--name NAME] [--after SID | --before SID]` —
  create (and focus) a session. Target the workspace by id/prefix (`--workspace`) OR by name
  (`--workspace-name`, mutually exclusive); add `--create-workspace` to reuse-or-create the named
  workspace when absent. `--command` runs that program as the session process instead of a login shell
  (argv-only, and with the app's GUI `PATH` — a Homebrew/non-default binary needs an absolute path or a
  `zsh -lc '…'` wrapper, else exit 127; same caveat for `scratch --command` and `overlay open` below);
  `--name` seeds the sidebar label (default: the auto basename). `--after`/`--before` place it directly
  after/before an anchor session (id/prefix/`active`) instead of appending — the anchor carries its own
  workspace, so it's mutually exclusive with `--workspace`/`--workspace-name`. `new --after active` =
  create right after the current session.
- `close [--target T ...]` — close one session, or repeat `--target` to close a batch with one
  grace-period undo.
- `select` · `rename <name>` · `reveal` (select the focused pane's cwd in Finder).
- `go --to next|prev|first|last|next-attention|prev-attention` — move the selection between sessions.
- `move <workspace>` (relocate) or `move --to up|down|top|bottom` (reorder within the workspace) or
  `move --after SID | --before SID` (place after/before an anchor session; the anchor carries its own
  workspace, so this relocates + positions in one shot, even cross-workspace). For workspace and
  after/before placement, repeat `--target` to move several sessions as one ordered block. Do not repeat
  `--target` with `--to up|down|top|bottom`.
- `type <text> [--stdin] [--select] [--pane left|right|scratch]` — inject keystrokes (real typing, Enter
  included) into the main pane, the split pane with `--pane right`, or the scratch terminal (even hidden)
  with `--pane scratch`. Pass `--target "$AGTERM_SESSION_ID"` to type into YOUR session, not the user's
  active one (see Addressing).
- `copy` — print the session's selected text (does NOT touch the system clipboard).
- `paste` — paste the system clipboard into the session (the socket analogue of ⌘V; read it back with
  `session text`).
- `select-all` — select the session's entire terminal buffer (the socket analogue of ⌘A; read the
  selection back with `session copy`).
- `text [--all] [--lines N] [--pane left|right|scratch]` — print the session buffer as plain text. Default
  is the visible screen of the focused pane; `--pane scratch` reads the scratch terminal even while hidden;
  `--all` adds scrollback; `--lines N` keeps the last N lines.
- `search [needle] [--next|--prev|--close]` — search the terminal scrollback; prints the "N of M" counter.
- `split [on|off|toggle]` — side-by-side second shell (hide keeps it alive).
- `scratch [on|off|toggle] [--command CMD]` — full-coverage third shell (hide keeps it alive; `exit`
  recreates). `--command` (when showing) runs a program instead of a shell, run-once like `session new
  --command` (respawns the scratch if one is open). Target your own session with
  `--target "$AGTERM_SESSION_ID"` (see Addressing).
- `focus [left|right|other]` — move focus between split panes.
- `resize --split-ratio R | --grow-left D | --grow-right D` — move the split divider (no GUI/keymap
  equivalent — bind it via a `command "agtermctl session resize …"` custom action). `--split-ratio` sets
  the absolute left-pane fraction (0..1, clamped to 0.05..0.95); `--grow-left`/`--grow-right` nudge it by
  a fraction. Prints the applied (clamped) fraction.
- `status <idle|active|completed|blocked> [--blink] [--auto-reset] [--sound NAME] [--color #rrggbb] [--pane left|right|scratch]` — set the sidebar agent glyph (`--sound default` or a system sound name plays a one-shot sound; `--color` tints the glyph for this call only, reverting on the next status set without it; `--pane` records which pane set it — `left`=main, `right`=split, `scratch` — so foreground typing in another pane won't clear it and any user-initiated GUI selection (auto-follow, attention-nav ⌃⌥↑/↓, plain session nav, the command palettes, a sidebar row click) reveals the blocking pane, read back as the tree `statusPane` field; the socket `session go next-attention` only steps the selection, it does not itself reveal the pane).
- `flag [on|off|toggle|clear]` — flag a session for the flagged working-set view (`clear` unflags all).
- `seen [--target] [--window W]` — clear the session's unseen-notification badge WITHOUT changing the
  selection or focus (the focus-free counterpart to `notify`, which raises the badge). Idempotent — a
  no-op when already zero. Read the current count from the tree node's `unseen` field. Use it so an
  orchestrator can acknowledge a driven session's notifications without pulling focus to it.
- `background image <path> [--opacity F] [--fit contain|cover|stretch|none] [--position P] [--repeat]` ·
  `background text <text> [--color #rrggbb] [--opacity F] [--fit ...] [--position ...]` ·
  `background color <#rrggbb>` · `background clear` — composite an image (PNG/JPEG) or rasterized text
  behind the terminal as a watermark (auto-fitting the window, re-fits on resize), or set a solid
  terminal background color. Per session; survives restart. `--opacity` 0.0–1.0. (An image/text watermark
  renders the pane opaque, overriding window translucency, so it shows; a `color` takes no opacity and
  honors the Settings window translucency instead.)
- `overlay open <command> [--cwd DIR] [--wait] [--block] [--size-percent N] [--background-color #rrggbb] [--follow]` ·
  `overlay resize (--size-percent N | --full)` ·
  `overlay close` ·
  `overlay result` — run a program on top of a session; `--block` waits and exits with its status.
  `overlay resize` changes an ALREADY-OPEN overlay: `--size-percent N` (1-100) makes it a floating panel,
  `--full` switches it back to the full-pane overlay; the program keeps running (no re-spawn).
  Target with `--target "$AGTERM_SESSION_ID"` for YOUR session (default `active` is the user's selection).
  **By default `overlay open` does NOT switch the user** — full and floating (`--size-percent`) both open
  on `--target` and run their program in the background; the panel appears when the user visits that
  session. **Pass `--follow` to select the target after opening** (a no-op if it is already active): use
  `--follow` when you want the user pulled to the overlay, omit it to open quietly on your own or another
  session.
  `--background-color` gives the overlay pane its own solid color, independent of the session's. An
  overlay is a real terminal (pty), which is also how you **display an image inline** — via the bundled
  `scripts/show-image.sh` (see below).

**window** — `new [name]` · `list` · `select <id>` · `close <id>` · `rename <id> <name>` ·
`delete <id>` · `resize <id> --width W --height H` · `move <id> --x X --y Y [--display N]` ·
`zoom <id>` (maximize-to-screen toggle, the double-click-header gesture; a plain green-button click does full screen) ·
`fullscreen <id>` (toggle native macOS full screen, the green-button / ⌃⌘F action).

**surface** — `zoom [show|hide|toggle] [--target surface:<session-id>:left|right|scratch|overlay|quick] [--window W]`
— zoom a terminal surface to fill the window (sidebar hidden; a slim title-bar strip with an exit
button remains). Omit `--target` to use the active surface;
copy an explicit surface id from `tree --json` to address a hidden split/scratch or a background
session (`quick` is the id returned for a quick-terminal zoom). `hide` exits zoom; `toggle`
enters/exits only this zoom mode, not macOS window zoom.

**dashboard** — `dashboard <ids…> [--font-size N | --auto-size] [--window W]` opens a view-only grid
showing the named sessions' live panes; `dashboard --mru [--font-size N | --auto-size] [--window W]`
opens the window's most-recently-used sessions instead of naming ids; `dashboard --close [--window W]`
closes it. The cell unit is a session+pane: a non-split session is one cell, and a SPLIT session shows as
TWO cells (its left/primary pane and its right/split pane). View-only: no cell takes input — the keyboard
drives it (arrows move the highlight, Enter jumps into the highlighted session AND focuses that exact pane
then closes, Esc closes). `--font-size N` sets an absolute cell font in points; `--auto-size` sizes cells
relative to the Settings default font, shrinking as the grid grows (the two are mutually exclusive; a
non-positive size is rejected). The 9-cell cap counts PANES (laid out `ceil(sqrt(n))`), so a set whose
panes exceed 9 is capped to the first 9 panes and the dropped-pane count is reported; ids are deduped and
honor `--window` (default frontmost). `--mru` is mutually exclusive with explicit ids and `--close`, and
composes with the font flags. Read the state back from the tree's top-level `dashboardMembers`
(pane refs `<id>:left`/`<id>:right`, in grid order) / `dashboardHighlighted` (a pane ref) /
`dashboardFontSize`/`dashboardFontMode`. Zoom and the dashboard are mutually exclusive: opening one CLOSES
the other. Opening/closing resizes each pane's pty to its cell, so programs may redraw — view-only
means no input, not no process effect. The most-recently-used grid also has a GUI opener: **⌘⇧D** (the
`dashboard` built-in action), **Navigate ▸ Dashboard**, and the command palette's **Dashboard** entry
TOGGLE the frontmost window's MRU dashboard auto-sized (identical to `dashboard --mru --auto-size`); no new
control command, the socket `dashboard` command is unchanged.

**quick** — `[show|hide|toggle]` (visibility; read back from the tree's `quickVisible`) ·
`type TEXT` (or `--stdin`) inject keystrokes into the frontmost window's quick terminal ·
`text [--all] [--lines N]` read its screen back — the twins of `session type`/`session text`,
frontmost-window-only (no `--target`/`--window`/`--pane`).

**sidebar** — `[show|hide|toggle]` (visibility; read back from the tree's `sidebarVisible`) ·
`mode [tree|flagged|toggle]` (flip between the workspace tree and the flat flagged working-set list; read
back from the tree's top-level `sidebarMode`) · `expand [--window W]` (expand every workspace) ·
`collapse [--window W]` (collapse all workspaces except the active one, which stays expanded).
Visibility/mode act on the frontmost window; `expand`/`collapse` default to the frontmost but take a
`--window` selector to target any open window.

**notify** — `notify <body> [--title T]` — post a desktop notification attributed to a session. To signal that you need the user, prefer `session status` (`blocked`/`completed`), a persistent typed attention state rather than a one-shot banner; keep `notify` for a one-off nudge.

**font** — `font inc|dec|reset [--pane left|right|scratch]` — change a session pane's font size (omitted/`left` = main pane, `right` = the split pane, `scratch` = the scratch terminal). Read the resulting size back from `tree` (`fontSize`/`splitFontSize`/`scratchFontSize` per pane).

**keymap** — `keymap reload` — re-read `keymap.conf` (prints the parse-diagnostic count).

**config** - `config reload` - re-read the agterm-scoped `ghostty.conf` (prints the diagnostic count).

**theme** — `theme list` (bundled themes, current marked `*`) · `theme set [name]` — set + persist the
terminal theme app-wide, per slot: a NAME sets the light/single theme (a dark theme, if set, is kept);
`theme set --dark <name>` sets the dark theme, which makes the terminal track the macOS Light/Dark
appearance automatically; `theme set --dark none` stops tracking. The app default is the bundled
**agterm** theme; omit the name for ghostty's built-in default ("default ghostty"); an unknown name errors.

**restore** — `restore clear` — clear every session's saved foreground command (the
restore-running-command capture) so the next restart restores plain shells.

## Displaying an image inline

This skill bundles `scripts/show-image.sh`. It opens an overlay (a real terminal) and renders the
image there via the kitty graphics protocol, which ghostty draws natively — no kitty binary and no
external image tool, just `base64` + `printf`. Run it with the image path (optional size percent,
default 60):

```bash
bash ~/.claude/skills/agterm/scripts/show-image.sh <image> [size-percent]   # Claude Code
bash ~/.codex/skills/agterm/scripts/show-image.sh <image> [size-percent]    # Codex
```

Do NOT print graphics escapes to your own tool stdout (the agent harness escapes the control bytes)
and do NOT run an image viewer in your tool shell (no controlling terminal). The overlay is what makes
it render. Outside agterm (`AGTERM_ENABLED` unset) there is no overlay — fall back to `open <image>`.

## Troubleshooting and reporting

When the user hits a problem (a keymap editor that will not open, a custom action that does nothing,
notifications missing), diagnose it from inside the session first: inspect `agtermctl tree --json`,
run `agtermctl keymap reload` for the parse-diagnostic count, and read the unified logs under
subsystem `com.umputun.agterm`. If it turns out to be a bug, offer to help file it.

**Filing is opt-in and draft-first.** Never run a `gh` command without the user's explicit approval.
Decide first whether it is a bug (a supported feature misbehaving → a GitHub **issue**) or something
not supported / a question / an idea (→ a GitHub **Discussion**, category `Ideas` or `Q&A`). Draft the
title and body, show it to the user, scrub anything private (tokens, hostnames, usernames in paths,
selection/clipboard text), and only post after an explicit go-ahead. If `gh` is missing or not
authenticated, hand the user the prefilled text plus the new-issue / new-discussion URL instead.

Full detail, templates, and the exact `gh` commands are in **troubleshooting.md**.

## Reference files

- **reference.md** — full per-command detail: every flag, the JSON return shapes
  (`result.id`/`text`/`exitCode`/`count`/`affected`/`tree`/`windows`), error strings, the scratch/overlay/split
  lifecycle, and the keymap.conf format (`map` / `command`, chords, leaders, `{AGT_X}` tokens).
- **examples.md** — copy-paste agtermctl recipes for common tasks (build a layout, run a program in a
  blocking overlay and read its status, type into a fresh session, notify, inspect the tree).
- **troubleshooting.md** — diagnosing common problems (keymap editor, custom actions, logs) and the
  bug-issue / feature-Discussion reporting workflow (draft-first, scrub, never post without approval).
- **scripts/show-image.sh** — bundled helper that displays an image inline in an overlay (see above).

Read those files when you need exact flags, return shapes, or worked examples.
