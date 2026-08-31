---
name: agterm
description: >
  Drive agterm, a native macOS terminal app, programmatically via its agtermctl CLI and a local
  control socket. Use when running inside an agterm session and asked to control the terminal:
  create, rename, close, select, or reorder sessions and workspaces; split panes; toggle the
  per-session scratch terminal; open or close overlay terminals and read their exit status; post a
  passive HUD message panel over a session while the user keeps typing;
  display the native fuzzy picker with caller-supplied choices and poll or cancel it; display
  an image inline via a bundled helper script; type
  into a session, copy its selection, or search its scrollback; post desktop notifications; manage windows (new, list,
  select, close, resize, move); change font size; or reload and edit the keymap and the agterm-scoped
  ghostty config. Also covers the
  window/workspace/session addressing model and the AGTERM_* environment a spawned shell sees, plus
  subscribe to status, notification, session lifecycle, and tree-change events; diagnose problems
  (keymap editor, custom actions, logs); and file a bug as a GitHub issue or a
  feature request / question as a GitHub Discussion. Also list, fetch and install the repository's
  cookbook recipes, and read one as reference for a tricky workflow; and report the version of the app
  serving the socket.
when_to_use: >
  Trigger on: agterm, agtermctl, agterm control socket, session.new, session.close, session.type,
  session.split, session.split.close, session.swap, session.scratch, session.focus, session.resize, surface.zoom, surface.cursor, cursor column, dashboard, pick, pick.open, pick.result, pick.cancel, native picker, session.go, session.copy, session.paste, session.selectall, session.text, pane-id, session.search, session.status,
  session.flag, session.context, what this session is about, session.seen, session.reveal, session.duplicate, session.background, session.overlay,
  session.hud, hud panel, show a message over a session, workspace.new, workspace.select, workspace.go, workspace.move, workspace.focus, workspace.filter, window.new, window.list,
  window.select, window.resize, window.move, window.zoom, window.fullscreen, window.minimize, quick terminal, sidebar, sidebar.mode, sidebar.expand, sidebar.collapse, sidebar.width, flagged, notify, font.inc, keymap.reload, keymap.list, config.reload,
  theme.set, theme.list, events, events.read, event subscription, select theme, edit keymap, show an image, display an image inline, show-image,
  AGTERM_SESSION_ID, AGTERM_SOCKET, and asks to drive or script agterm. Also: agterm cookbook,
  cookbook recipe, list recipes, install a recipe, agterm recipe for X, what recipes are there, and
  agterm version, which agterm is running, agterm version check. Also troubleshoot agterm,
  keymap editor won't open, custom action / custom command not working, agterm logs, file an agterm
  bug, report an agterm issue, open an agterm discussion / feature request.
allowed-tools: Bash(agtermctl *)
---

<!-- agterm-skill -->

# Driving agterm

agterm is a native macOS terminal. It exposes a programmatic control channel over a local unix
socket, driven by the companion CLI `agtermctl`. Use it to build and steer terminal layouts, run
programs in overlays, type into sessions, notify the user in the exact session you are working in,
and subscribe to control events. Events cover status, notifications, session lifecycle, and
structural tree changes. They do not stream terminal output; use `session text` to read a buffer.

## Am I inside agterm?

Each shell agterm spawns gets these environment variables. Check `AGTERM_ENABLED` before assuming
the control channel is available:

- `AGTERM_ENABLED=1` — this shell runs inside agterm.
- `AGTERM_SESSION_ID` — the current session's UUID (the session this shell belongs to).
- `AGTERM_WINDOW_ID` / `AGTERM_WORKSPACE_ID` — the owning window / workspace UUIDs.
- `AGTERM_SOCKET` — the absolute path to the control socket this app bound.
- `AGTERM_PANE` / `AGTERM_PANE_ID`: the surface's spawn role (`left`|`right`|`scratch`) and stable
  per-surface token. The role is not rewritten after promotion or swap; the token resolves the LIVE slot.
  Prefer `--pane-id "$AGTERM_PANE_ID"` where supported, including `session status`, `session restore` and
  `session text`. The agent-status hook forwards both values for compatibility.

The quick terminal is scratch (not in the tree) and belongs to no window, so it only gets
`AGTERM_ENABLED` and `AGTERM_SOCKET` (no session/workspace/window ids). An untargeted `agtermctl` run
from it therefore resolves the active window like any other caller.

These variables are inherited by every process the session's shell spawns — including long-lived
daemons that outlive the shell. A tmux/screen server, a session manager (agent-deck and the like), or
any background service started from inside a session captures the spawning session's `AGTERM_*` and
passes it to every child it ever creates, so status hooks running in those children resolve
`$AGTERM_SESSION_ID` to the session that happened to start the daemon and report to the WRONG session.
Before starting such a process from inside agterm, scrub the variables
(`env -u AGTERM_ENABLED -u AGTERM_PANE -u AGTERM_PANE_ID -u AGTERM_SESSION_ID -u AGTERM_SOCKET -u AGTERM_WINDOW_ID -u AGTERM_WORKSPACE_ID <cmd>`);
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
- Commands other than `events` make one request per invocation. `events` polls with a fresh connection
  for each request. Mutating commands return the affected/new id; batch session mutations return the
  number actually changed. Create commands (`session new`, `session duplicate`, `workspace new`,
  `window new`) print the new id.

## The model

A **window** is the top level: a named bundle rendered in its own on-screen macOS window. Each window
holds a tree of **workspaces**, each holding **sessions**. A session has a primary shell and can also
have: a **split** pane (a second shell side by side), a **scratch** terminal (a third full-coverage
shell, toggled like the split), and an ephemeral **overlay** (runs one program on top, then vanishes).
An overlay covers the whole session, or with `--pane left|right` exactly one split pane, leaving the
sibling pane visible and usable. The same session-wide slot also holds a **HUD** (`session hud`), a small
passive panel carrying a message instead of a program: the session keeps focus and stays typable under it.
One slot, so a session shows either a HUD or a program overlay, never both. Separately, the app has one
**quick terminal** (a scratch shell in a floating panel at 90% of the focused screen capped at 1100x700,
or whatever share Settings sets instead; not part of the tree and not owned by a window).

Inspect the live tree any time with `agtermctl tree --json` (workspaces → sessions, each with
`id`, `name`, `cwd`, `title`, `active`, `split`, `overlay`, `hud`, `scratch`, `status`, `background`, `surfaces`). `title` is the raw OSC
terminal title (e.g. a remote host over SSH), omitted when none was reported — read it when a
session's local `cwd` is stale because it's connected to a remote. `surfaces[].id` is the
control address for `surface zoom` and `surface cursor` (`left`, `right`, `scratch`, `overlay`,
`overlay-left`, or `overlay-right`), including hidden-but-alive split/scratch surfaces. The tree object also carries
read-only top-level fields — `idleMs` (ms since the last user input in the window), `autoFollowMs`
(the Auto-follow timeout in ms, omitted when Disabled), `sidebarVisible` (whether the window's
sidebar is currently shown — the read side of the write-only `sidebar` command), `sidebarMode`
(`tree` or `flagged` — the read side of `sidebar mode`), `sidebarWidth` (the sidebar divider position in
points — the read side of `sidebar width`, on `tree` only), `workspaceFilter`, `quickVisible` (whether the
quick terminal is shown — the read side of the write-only `quick` command; app-level, so every window
reports the same value), `zoomedSurface`, the four `dashboard*` fields, `pickPending`, and `app` (the
serving app's `version`, plus `commit` when the build recorded one — the same value `agtermctl version`
returns). reference.md lists every one with its exact shape. List windows with
`agtermctl window list --json`; each window also reports `autoFollowMs`, `sidebarVisible`, `geometry`
(the live frame `{x, y, width, height, display}` in the units `window move`/`window resize` take — the
read side, so record it then restore the exact frame), and `fullscreen`/`zoomed`/`minimized` (the read side
of `window fullscreen`/`window zoom`/`window minimize`, so a script can act idempotently) — all omitted for
a closed window, but not the live `idleMs`, which is `tree`-only. A MINIMIZED window still reports its
`geometry` (the frame it comes back to), so a re-align script can include it.

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
you work. For any session-scoped command meant to act on *this* session — `session overlay open`,
`session scratch`, `session type`, `session text`, `session background`, `session status`, `session copy`,
… — pass `--target "$AGTERM_SESSION_ID"`. Omit it and
you open overlays / type into whatever the user has selected, not your own session.

## Restore modes

**Settings ▸ General ▸ Restore sessions** is global and takes effect after restarting agterm:

- **Fresh shells** restores the saved windows, workspaces, sessions, directories, and split layout with new shells.
- **Re-run commands** starts each captured foreground command again. It does not reconnect to the old process.
- **Live sessions** runs every primary and split pane through zmx and reattaches to the same process. It requires
  zsh as the macOS login shell. Scratch, overlay, and quick terminals stay temporary.

On a clean quit, agterm leaves live daemons running and captures each open pane's foreground command as a
fallback. A surviving daemon ignores that payload on the next launch. If an orderly machine restart removed
the daemon, zmx creates it with the captured command and the pane remains live. A pane starts a fresh shell
instead when its window was closed before quit, a hard power loss or force quit skipped capture, or the
command is denylisted or carries a control character. SIGTERM leaves live daemons running but skips capture.
`tree --json` is the only backing indicator: primary and split entries report `surfaces[].backedByZmx`, and
the session-level `backedByZmx` is true only when every existing primary or split is backed. The sidebar has
no zmx glyph.
Switching to Fresh shells or Re-run commands and restarting ends every detached live process in the state
directory. A launch that still requests Live sessions but cannot use it preserves those processes.

Reattach keeps usable text, TUI state, and normal colors. It does not retain inline images, earlier OSC 133
prompt markers, program-changed palette entries, or hyperlink metadata already attached to cells. New output
after reattach behaves normally.

## Launching a program in a session

**Bind it at creation.** `session new --command` (and `scratch --command`) makes the program the session
process, so no shell line is involved:

```bash
agtermctl session new --cwd ~/proj --name worker \
  --command "zsh -lc 'claude \"\$(cat ~/brief.md)\"'"   # GUI PATH: wrap a non-default binary
```

In Fresh shells and Re-run commands modes, the session closes when this command exits unless `--wait` holds
the final output. In Live sessions mode the command is typed into the persistent shell only on first creation;
the shell stays open after it exits and `--wait` adds no hold prompt. After a clean quit, a missing daemon
replays the captured running command inside a new persistent shell. The exclusions above start a fresh shell.

`session type` drives an ALREADY-RUNNING program — it is not a launcher. Its keystrokes land in a line
buffer you do not own: a newline submits (a multi-line brief becomes N premature Enters), and the user
or a concurrent agent writes to that same buffer. An untargeted `session type` from another agent hits
whatever is `active`, and `session new` focuses — so a just-created session is briefly `active`, a stray
prompt concatenates with yours, and the program starts on the merged line. (`--no-select` skips the
focus, but the newline and shared-buffer hazards of `type`-as-launcher remain — `--command` is still the
rule.) After `--command`, confirm in `tree --json` that the new node's `foreground` shows your program running, not a bare shell prompt.

## Command summary

Run `agtermctl <area> <cmd> --help` for exact flags. Full detail in **reference.md**; worked
examples in **examples.md**; installable community workflows in **cookbook.md**.

**tree** — print the workspace/session tree (`--json` for structured). Each session node carries
`foreground`/`splitForeground` (the live argv of each pane's foreground process, omitted when the pane
is at its shell prompt, or running a setuid/setgid program like `top` or `sudo` whose argv macOS won't
expose) — i.e. what each pane is currently running — `restoreCommand`/`splitRestoreCommand` (each pane's
persisted restore-command override set via `session restore` — the read side: omitted = auto-capture, `""`
= pinned to nothing (a plain shell), a command = the shell line that runs on the next launch), `status` (the agent-status set
via `session status`: `active`|`completed`|`blocked`, omitted when idle), `statusPane` (which pane set
that status: `left` (main) | `right` (split) | `scratch`, from `session status --pane`, omitted when
unset or idle), `statusBlink`/`statusColor`/`statusShape` (the status glyph's `--blink` flag, its `--color`
`#rrggbb` tint and its `--shape` silhouette from `session status`, omitted when idle / not blinking / using
the configured color or shape — the tint and the silhouette report the per-call override only),
`statusChangedAt` (when that status was last set, in epoch seconds — the same clock as an event's `ts`;
omitted when idle, and refreshed by a re-push of the SAME status, so `now - statusChangedAt` is how long
ago the status was last written — normally the agent's own push, though a pane promotion re-tags the
indicator and counts too; ephemeral, so it does not survive a restart), `background` (the background
spec — image/text watermark or solid color — set via `session background`, omitted when none — the read side of set/clear),
`unseen` (the unseen-notification badge count — raised by `notify`/OSC 9/777, cleared by `session
seen`; omitted when zero), `commandWait`/`splitCommandWait` (whether either pane's `--command` was
created with `--wait` to hold open after exit, the read side of `session new --wait`; each omitted for a
plain or non-holding pane), `overlaySizePercent` (an open overlay's floating-panel percent 1-100,
omitted for a full-pane overlay or no overlay so gate on `overlay` first; the read side of `session
overlay resize` for a record-then-restore zoom), `paneOverlays` (the panes covered by their own overlay —
`["left"]`, `["right"]` or `["left","right"]`, omitted when neither is; the read side of `session overlay
open --pane`, independent of the session-wide `overlay` flag),
`hud` (the message panel occupying the session-wide slot — `{message, detail?, spinner, backgroundColor?,
textColor?, sizePercent?, heightPercent?, position}`, the two percents being the panel's width and height
shares — omitted when none is up; the read side of `session hud`. `position` and `spinner`
always report the EFFECTIVE value, `center` and a static panel's `none` included, so a caller who omitted
them never has to know the defaults; `spinner` names the STYLE, so `none` is what a caller echoes back to
turn one off. While a HUD is up the node's `overlay` reads `false` and `overlaySizePercent` is omitted, so a
poll for "is a program covering this session" cannot mistake a message for one; HUD state is poll-only,
no event announces it),
`realized` (whether the session's MAIN pane has a live terminal; `false` means no shell was spawned and
`session type`/`session text` will answer `session not realized`. `session new` returns `ok` for a model
entry, which is weaker — libghostty will not create a surface while the display is asleep, so a session
created by a scheduled job overnight stays unrealized until the displays wake and then recovers itself.
Poll this after an unattended create),
`backedByZmx` (true only when every existing primary/split pane is currently zmx-backed; primary/split
entries in `surfaces` report their own Boolean, while scratch and overlays omit it),
`hasSplit` (whether a second pane exists at all, shown or hidden; omitted when there is none — read this
rather than `split`, which is false for a split hidden with ⌘D even though its pane is still alive),
`splitAxis` (`vertical` for left/right or `horizontal` for top/bottom; omitted without a split),
`splitRatio` (the primary-pane divider fraction 0.05-0.95 of a
session that has a split — shown or hidden; omitted when there's no split or the ratio was never set (at
the default 0.5) —
the read side of `session resize`, record it to restore the exact divider), `splitFocused`
(which pane holds focus in a session that has a split: `true` = split/right/bottom, `false` = primary/left/top; omitted
when there's no split; the read side of `session focus`, record it to restore focus), and `surfaces`
(`id`, `kind`, `active`, `visible`, and `backedByZmx` on primary/split entries) for `surface zoom` and
`surface cursor`. The tree top level carries `zoomedSurface`
(the control id of the currently zoomed surface, omitted when nothing is zoomed — the read side of
`surface zoom`, so a script can check the zoom state and record-then-restore). It also carries the read
side of the `dashboard` command (all omitted when no dashboard is open): `dashboardMembers` (the pane refs
the open dashboard shows, in grid order — `<session-id>:left` for a primary pane, `<session-id>:right` for
a split pane, so a split session appears as both), `dashboardHighlighted` (the highlighted cell's pane ref —
the one Enter jumps into, focusing that exact pane), `dashboardFontSize` (the absolute font size in points
applied to the cells, omitted when untouched), and `dashboardFontMode` (`auto`|`fixed`|`untouched`).
The top level also carries `pickPending`, the id of the native picker currently awaiting an answer in
that window, omitted when no pick is pending.

**events**: continuously print control events, subscribing from the current tail when no cursor is
given. Use `--json` for one bare event object per line; filter with repeatable or comma-separated
`--kind status|notify|session.created|session.closed|tree.changed`; resume with paired
`--run RUN --after SEQ`; and set page size with `--limit 1...1000`. The app retains 4,096 events for
one process run. Cursor run changes, expiry, and ahead-of-tail errors are fatal and are never silently
rebaselined. There is no terminal-output event stream.

**workspace** — `workspace new [name] [--collapsed]` (`--collapsed` creates it closed in the sidebar so you can fill
it with `session new --no-select` without it opening, and keeps it out of the focus set; a plain create
joins the marked set while the filter is applied, so it is visible) · `workspace rename <name>` ·
`workspace delete` · `workspace select` ·
`workspace go --to next|prev` (step the CURRENT workspace one place through the sidebar's visible order, wrapping,
and select the first session of the one it lands on — relative, so no `--target`, and unaffected by
whether a workspace is collapsed; `workspace move` REORDERS instead) ·
`workspace move --to up|down|top|bottom` ·
`workspace focus [on|off|toggle|add]` (mark ONE workspace in the sidebar's focus set — `on` marks it alone and
applies the filter, `off` unmarks it, `toggle` (default) replace-toggles, and `add` marks it alongside
the others WITHOUT switching the filter on; read membership back from the tree workspace node's
`focused` flag) ·
`workspace filter [on|off|toggle]` (apply or suspend that filter for the whole window WITHOUT losing the marked
set — no `--target`; read it back from the tree top-level `workspaceFilter`. Build a working set with
repeated `workspace focus add`, then apply it once with `workspace filter on`; a workspace row renders iff
`sidebarVisible && sidebarMode == "tree" && (!workspaceFilter || focused)` — no workspace row renders at
all with the sidebar hidden or in `flagged` mode, the whole tree renders while the filter is off, and
only while it is on does visibility narrow to the members — and `workspace filter on` with nothing marked is
refused so the pair can never lie) ·
`workspace collapse [--target W] [--window W]` · `workspace expand [--target W] [--window W]` (collapse/expand ONE workspace
in the sidebar tree — the per-workspace pair, distinct from the all-workspace `sidebar expand`/`collapse`;
read the open/closed state back from the tree workspace node's `collapsed` flag, `true` when collapsed and
omitted when expanded).

**session**
- `session new [--cwd DIR] [--workspace W] [--workspace-name NAME] [--create-workspace] [--command CMD] [--wait] [--name NAME] [--after SID | --before SID] [--no-select]` —
  create (and focus) a session. Target the workspace by id/prefix (`--workspace`) OR by name
  (`--workspace-name`, mutually exclusive); add `--create-workspace` to reuse-or-create the named
  workspace when absent. `--command` runs that program as the session process instead of a login shell
  (argv-only, and with the app's GUI `PATH` — a Homebrew/non-default binary needs an absolute path or a
  `zsh -lc '…'` wrapper, else exit 127; same caveat for `session scratch --command` and `session overlay
  open` below);
  `--wait` (with `--command`, else an error) HOLDS the session open after the command exits, showing the
  press-any-key prompt with the final output intact instead of closing (persists across restart, unlike an
  overlay's live-only wait; read back on `tree`'s `commandWait`);
  `--name` seeds the sidebar label (default: the auto basename). `--after`/`--before` place it directly
  after/before an anchor session (id/prefix/`active`) instead of appending — the anchor carries its own
  workspace, so it's mutually exclusive with `--workspace`/`--workspace-name`. `new --after active` =
  create right after the current session. `--no-select` creates the session in the BACKGROUND — it is
  added to the sidebar but NOT selected or focused, leaving the current selection untouched (the new node
  is not `active` in `tree`); omit it for the default select-and-focus behavior.
- `session duplicate [--target]` — create a fresh session (a plain login shell) in the target's workspace, right
  after it, rooted at the target's focused-pane cwd; selects + focuses it and returns the new id. ONLY the
  directory carries over — no custom name, command, split, scratch, status, flag, font size, or background.
  Equivalent to `session new --cwd <source cwd> --after <source>` in one round-trip. Read it back from
  `tree`: the new node sits directly after its source carrying the source's focused-pane cwd (equal to the
  source node's `tree.cwd` unless the source is a split focused off its primary pane, where `tree.cwd`
  reports the primary).
- `session close [--target T ...]` — close one session, or repeat `--target` to close a batch with one
  grace-period undo.
- `session select` · `session rename <name>` · `session reveal` (select the focused pane's cwd in Finder).
- `session go --to next|prev|first|last|next-attention|prev-attention` — move the selection between sessions.
- `session move <workspace>` (relocate) or `session move --to up|down|top|bottom` (reorder within the
  workspace) or `session move --after SID | --before SID` (place after/before an anchor session; the anchor carries its own
  workspace, so this relocates + positions in one shot, even cross-workspace). For workspace and
  after/before placement, repeat `--target` to move several sessions as one ordered block. Do not repeat
  `--target` with `--to up|down|top|bottom`.
- Shared pane selectors accept `primary`/`left`/`top` for the primary pane and
  `split`/`right`/`bottom` for the split pane. Commands supporting scratch also accept `scratch`.
  Syntax and read-back use canonical `left`/`right`/`scratch`; the invalid-value error keeps those names.
- `session type <text> [--stdin] [--select] [--pane left|right|scratch]` — inject keystrokes (real typing, Enter
  included) into the main pane, the split pane with `--pane right`, or the scratch terminal (even hidden)
  with `--pane scratch`. Pass `--target "$AGTERM_SESSION_ID"` to type into YOUR session, not the user's
  active one (see Addressing). Like `session text`, every `--pane` addresses the surface UNDER a covering
  overlay — by design, so a pane stays drivable whatever is drawn over it — meaning text typed while one is
  open runs in the hidden shell and is invisible until it closes. There is no write twin of
  `session overlay text`: an overlay runs the caller's own program, so nothing types into one.
- `session copy` — print the session's selected text (does NOT touch the system clipboard).
- `session paste` — paste the system clipboard into the session (the socket analogue of ⌘V; read it back with
  `session text`).
- `session select-all` — select the session's entire terminal buffer (the socket analogue of ⌘A; read the
  selection back with `session copy`).
- `session text [--all] [--lines N] [--pane left|right|scratch] [--pane-id TOKEN]`: print the session buffer
  as plain text. Default is the visible screen of the focused pane; `--pane scratch` reads the scratch
  terminal even while hidden; `--pane-id "$AGTERM_PANE_ID"` follows the same terminal after a role change
  and overrides `--pane` when it resolves; `--all` adds scrollback; `--lines N` keeps the last N lines.
- `session search [needle] [--next|--prev|--close]` — search the terminal scrollback; prints the "N of M" counter.
- `session split [on|off|toggle] [--axis vertical|horizontal]` · `session split close` - second shell, left/right by
  default or top/bottom with `--axis horizontal`. Omitting `--axis` preserves the current axis and the
  legacy left/right behavior. The GUI actions are ⌘D for vertical and ⌘⇧D for horizontal; either
  transposes a shown split of the other orientation. Hide keeps it alive; `close` destroys the pane and
  whatever runs in it.
- `session swap`: exchange the two terminals' physical positions and primary/split roles without restarting
  them. Focus follows the terminal; axis and divider ratio stay fixed. Works on shown or hidden splits and
  under zoom/dashboard; errors when there is no split or either surface is not ready. Read the new primary
  from `tree`'s `cwd`/`title`/`foreground` and the other side from `splitForeground`.
- `session scratch [on|off|toggle] [--command CMD]` — full-coverage third shell (hide keeps it alive; `exit`
  recreates). `--command` (when showing) runs a program instead of a shell, run-once like `session new
  --command` (respawns the scratch if one is open). Target your own session with
  `--target "$AGTERM_SESSION_ID"` (see Addressing).
- `session focus [primary|split|left|right|top|bottom|other]` - move focus between split panes. Role and position
  aliases select the same two live terminals; readback remains `left`/`right`.
- `session resize --split-ratio R | --grow-left D | --grow-right D | --grow-primary D | --grow-split D | --grow-top D | --grow-bottom D` - move the split divider (the GUI only drags
  it, or double-clicks it for an even split; bind any other fraction via a
  `command "agtermctl session resize …"` custom action). `--split-ratio` sets
  the absolute primary-pane fraction (left or top; 0..1, clamped to 0.05..0.95). The grow options are
  aliases for growing the primary or split pane. Prints the applied fraction.
- `session status <idle|active|completed|blocked> [--blink] [--auto-reset] [--sound NAME] [--color #rrggbb] [--shape SHAPE] [--pane left|right|scratch] [--pane-id TOKEN]` — set the sidebar agent glyph (`--sound default` or a system sound name plays a one-shot sound; `--color` tints the glyph for this call only, reverting on the next status set without it; `--shape` (`circle`, `square`, `triangle`, `diamond`, `capsule`, `star`) picks its silhouette for this call only and reverts the same way, read back as the tree `statusShape` field; `--pane` records which pane set it — `left`=main, `right`=split, `scratch` — so foreground typing in another pane won't clear it and any user-initiated GUI selection (auto-follow, attention-nav ⌃⌥↑/↓, plain session nav, the command palettes, a Dock-menu session, a sidebar row click) reveals that pane when the status needs attention (`blocked`/`completed`); `active` preserves the existing pane selection; the pane reads back as the tree `statusPane` field; the socket `session go next-attention` only steps the selection, it does not itself reveal the pane; `--pane-id` is the hook-forwarded stable surface token (`$AGTERM_PANE_ID`) that resolves the pane's live slot and overrides a stale `--pane` after a promote + re-split — scripts set `--pane` directly and leave `--pane-id` to the hook).
- `session flag [on|off|toggle|clear]` — flag a session for the flagged working-set view (`clear` unflags all).
- `session context <TEXT|--clear> [--target] [--window W]` — set what the session is ABOUT, shown in the
  title bar where the sidebar row has no room: a PR number, an issue, the task in hand. Use it when you
  start work a session's name cannot describe. Exactly one of TEXT or `--clear`; a blank TEXT is an error,
  not a second way to clear. Trimmed; max 256 UTF-8 bytes; no control characters (tabs included) or line
  breaks. Persists
  across a relaunch until cleared. Read it back from the tree node's `context` field.
- `session seen [--target] [--window W]` — clear the session's unseen-notification badge WITHOUT changing the
  selection or focus (the focus-free counterpart to `notify`, which raises the badge). Idempotent — a
  no-op when already zero. Read the current count from the tree node's `unseen` field. Use it so an
  orchestrator can acknowledge a driven session's notifications without pulling focus to it.
- `session restore ("cmd" | --none | --clear) [--pane left|right] [--pane-id TOKEN]` — pin what a pane re-runs on
  the NEXT launch, overriding the captured foreground command. A `"cmd"` shell line pins it, `--none` pins
  nothing (a plain shell), `--clear` drops the override back to auto-capture. Written now, consumed on the
  next launch (it never touches the running session), and STICKY — fires again on every restart until
  cleared. It runs in `rerun` mode. In fresh-shell or live mode, a command or `--none` still saves policy
  for a future rerun launch and returns a note naming the active mode; `--clear` works in every mode. A pin
  never opts one session out of live mode. Deliberate pins bypass `restore-denylist.conf`. Read back as the tree node's
  `restoreCommand`/`splitRestoreCommand`. `--pane right` needs a split; `scratch` is rejected. `--pane-id`
  (the shell's `$AGTERM_PANE_ID`) resolves the pane's live slot — unlike `session status`, a token that
  does not resolve errors unless `--pane` is also given. For a non-idempotent command like
  `claude --resume … --fork-session` (which mints a new session on every restart), a Claude Code
  `SessionStart` hook rewrites the override to the live id on every start so the next restart reattaches
  instead of forking. The pinned value is shell code stored in the state file and readable via `tree`, so
  it must not carry secrets. See examples.md.
- `session background image <path> [--opacity F] [--fit contain|cover|stretch|none] [--position P] [--repeat]` ·
  `session background text <text> [--color #rrggbb] [--opacity F] [--fit ...] [--position ...]` ·
  `session background color <#rrggbb>` · `session background clear` — composite an image (PNG/JPEG) or rasterized text
  behind the terminal as a watermark (auto-fitting the window, re-fits on resize), or set a solid
  terminal background color. Per session; survives restart. `--opacity` 0.0–1.0. (An image/text watermark
  renders the pane opaque, overriding window translucency, so it shows; a `color` takes no opacity and
  honors the Settings window translucency instead.)
- `session overlay open <command> [--cwd DIR] [--wait] [--block] [--size-percent N] [--background-color #rrggbb] [--follow] [--pane left|right]` ·
  `session overlay resize (--size-percent N | --full)` ·
  `session overlay close [--pane left|right]` ·
  `session overlay result [--pane left|right]` ·
  `session overlay copy [--pane left|right]` ·
  `session overlay text [--all] [--lines N] [--pane left|right]` — run a program on top of a session; `--block`
  waits and exits with its status.
  `session overlay copy` returns the selection made INSIDE the overlay and `session overlay text` its terminal buffer:
  `session copy` and `session text` both address the pane the overlay COVERS, so a selection made in the
  overlay reads there as `no selection` and `session text --pane right` returns the shell underneath.
  Reach for them when the read is NOT chord-driven — polling from outside, or reading some time after the
  fact. A chord already gets the firing surface's selection synchronously in `$AGT_SELECTION`, the
  overlay's included, so a custom command should use that rather than a later socket read.
  `session overlay text` returns a TUI's drawn screen wrapped as rendered — for a program's OUTPUT, still prefer
  its own output file.
  `session overlay resize` changes an ALREADY-OPEN overlay: `--size-percent N` (1-100) makes it a floating panel,
  `--full` switches it back to the full-pane overlay; the program keeps running (no re-spawn).
  `--pane left|right` scopes the overlay to ONE split pane instead of the whole session, leaving the
  sibling pane live and interactive; left and right are independent and may both be open at once. A pane
  overlay is ALWAYS full-pane, so `--pane` cannot combine with `--size-percent` and `session overlay resize`
  takes no `--pane`. Everything else is identical to the session-wide overlay. A non-split session
  accepts `--pane left`. `AGTERM_PANE` is only the shell's spawn role and may be stale after promotion or
  `session swap`, so a long-running shell must not assume `--pane "$AGTERM_PANE"` still names its slot.
  A pane that is not currently rendered is refused with `pane not visible`. A SHOWN
  split renders both panes, a HIDDEN one renders only the FOCUSED pane, so the refused one is the pane
  that does not have focus.
  Target with `--target "$AGTERM_SESSION_ID"` for YOUR session (default `active` is the user's selection).
  **By default `session overlay open` does NOT switch the user** — full and floating (`--size-percent N`, 1-100)
  both open on `--target` and run their program in the background; the panel appears when the user visits
  that session. **Pass `--follow` to select the target after opening** (a no-op if it is already active):
  use `--follow` when you want the user pulled to the overlay, omit it to open quietly on your own or
  another session.
  `--background-color` gives the overlay pane its own solid color, independent of the session's. An
  overlay is a real terminal (pty), which is also how you **display an image inline** — via the bundled
  `scripts/show-image.sh` (see below).
- `session hud [open] <message> [--detail T] [--spinner] [--spinner-style S] [--position P] [--background-color #rrggbb] [--text-color #rrggbb] [--size-percent N]` ·
  `session hud update <message> [--detail T] [--spinner] [--spinner-style S] [--position P] [--text-color #rrggbb] [--size-percent N]` ·
  `session hud close` — post a small **passive** panel over the session saying what you are doing
  ("gathering options…"). Unlike an overlay it takes no input and steals nothing: the session keeps first
  responder, the user keeps typing, and the terminal behind it is neither dimmed nor click-blocked. Use it
  for the seconds an agent needs before it can show something (computing picker items, waiting on a slow
  command), then take it down. `open` is the default subcommand, so `session hud "…"` posts; a message that is
  literally `update` or `close` needs the explicit `session hud open` verb. `--detail` adds a dim second line,
  `--spinner` animates a glyph in the default `bar` style and `--spinner-style bar|braille|circle|blocks|dot`
  picks another, turning the spinner on by itself (`dot` blinks instead of animating, for a panel up for
  minutes; an update may switch style in place). `--spinner-style none` is accepted and leaves the panel
  static, so the `none` a read-back reports round-trips. `--position` anchors it to any of the nine
  `top-left|top-center|top-right|center-left|center|center-right|bottom-left|bottom-center|bottom-right`
  (default `center`), the same set `session background` takes; every anchor off center holds a fixed margin
  off that pane edge automatically, so a corner keeps the panel out of the text the user is reading. The
  bare `top`/`bottom` are still accepted for `top-center`/`bottom-center`, and the read-back reports the
  canonical anchor. The panel is sized from the message on both axes —
  width from the longest line, height from the number of them — so a title and a subtitle give a wide, short
  panel, not a square one. `--size-percent N` (1-100) overrides the WIDTH only, bounded to 10-80% of the
  pane, since a message must never cover the session it is about, so a requested 100 reads back as 80. The
  height always follows the message. `--text-color` colors the panel's TEXT and `--background-color` its
  backing, independently. `session hud update` repaints in place with no re-spawn and no blink,
  and REPLACES the whole spec — repeat `--detail`/`--spinner`/`--text-color` to keep them, since an omitted
  one drops. It takes no `--background-color`: the surface reads that once at creation, so only a fresh
  `session hud` changes it and `tree` keeps reporting the creation color across updates, while the text color rides
  the panel's body file and an update recolors it in place. Message and detail are capped at 256 characters and reject control characters, newline included.
  It occupies the SAME slot as `session overlay open`, so: a second `session hud` replaces the first,
  `session overlay open` replaces a HUD (a running program is never replaced), `session overlay close`
  and ⌘W take a HUD down, `session overlay result` refuses with
  `no overlay result: the slot holds a hud`, `session overlay resize --size-percent`
  works on it while `--full` is refused (`a hud is always floating: pass --size-percent, not --full`),
  and `surface zoom` will not address it. `session hud update`/`session hud close` with none up answer `no hud`. Read it
  back from the tree node's `hud` object; nothing announces it as an event, so poll `tree`.

**window** — `window new [name] [--minimized]` · `window list` · `window select <id>` · `window close <id>` ·
`window rename <id> <name>` ·
`window delete <id>` · `window resize <id> --width W --height H` · `window move <id> --x X --y Y [--display N]` ·
`window zoom <id>` (maximize-to-screen toggle, the double-click-header gesture; a plain green-button click does full screen) ·
`window fullscreen <id>` (toggle native macOS full screen, the green-button / ⌃⌘F action) ·
`window minimize <id> [on|off|toggle]` (minimize to the Dock or restore, the ⌘M / yellow-button action; default
`toggle`, the id may be omitted so `window minimize on` targets the active window; errors on a full-screen
window; read back as `minimized` on `window list`).

**surface** — `surface zoom [show|hide|toggle] [--target surface:<session-id>:left|right|scratch|overlay|overlay-left|overlay-right|quick] [--window W]`
— zoom a terminal surface to fill the window (sidebar hidden; a slim title-bar strip with an exit
button remains). Omit `--target` to use the active surface;
copy an explicit surface id from `tree --json` to address a hidden split/scratch or a background
session. `quick` is the one target that is not a window surface: it grows the quick-terminal panel to
fill its screen, takes no `--window`, is refused while the panel is hidden, and is never what an omitted
`--target` resolves to. `hide` exits zoom; `toggle`
enters/exits only this zoom mode, not macOS window zoom.

**dashboard** — `dashboard <ids…> [--font-size N | --auto-size] [--window W]` opens a view-only grid
showing the named sessions' live panes; `dashboard --mru [--font-size N | --auto-size] [--window W]`
opens the window's most-recently-used sessions instead of naming ids; `dashboard --close [--window W]`
closes it. The cell unit is a session+pane: a non-split session is one cell, and a SPLIT session shows as
TWO cells (its left/primary pane and its right/split pane) — unless the id carries a `:left`/`:right` pane
suffix (`dashboard <a>:left <b>:right`), which places THAT PANE ALONE; the suffix is the same form
`dashboardMembers` reports, composes with `active` and prefixes, and accepts only `left`/`right` (any other
suffix fails the command, while `:right` on a session with no split parses but names no pane, so it joins
the `unresolved` note — and errors `no dashboard sessions resolved` if nothing else resolved, leaving any
open grid untouched). Cells are deduped by session+pane. View-only: no cell takes input — the keyboard
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
means no input, not no process effect. The most-recently-used grid also has a GUI opener: **⌘⇧G** (the
`dashboard` built-in action), **Navigate ▸ Dashboard**, and the command palette's **Dashboard** entry
TOGGLE the frontmost window's MRU dashboard auto-sized (identical to `dashboard --mru --auto-size`); no new
control command, the socket `dashboard` command is unchanged.

**pick**: `pick [--prompt TEXT] [--query TEXT] [--allow-custom] [--follow] [--window W] [--no-block]` reads
choices from stdin and opens the target window's native fuzzy picker. Supply nonblank lines (each line is
both the id and label) or a JSON array of `{id,label,subtitle?}` items; typing matches labels only, and an
empty query keeps the supplied order, so the caller's first item is the one Return runs. `--query` prefills
the field and filters on open, which re-ranks and drops that order. An empty item list is accepted only with
`--allow-custom`, giving a plain text prompt; stdin is read either way, so an itemless call needs
`< /dev/null` or it blocks. The default blocks until the user chooses or cancels and prints the bare JSON
result. `--no-block` prints the picker id instead;
`pick result ID [--window W]` reads it later, and `pick cancel ID [--window W]` cancels it.
Only one picker may be pending per window. It opens without raising a background target unless
`--follow` is set. Read the live picker id from the tree's top-level `pickPending` field.

**quick** — `quick [show|hide|toggle]` (visibility; read back from the tree's `quickVisible`; a panel YOU open
with `quick show` stays up when agterm loses focus, unlike one the user summoned by hotkey, so a following
`quick type` / `quick text` / `surface zoom --target quick` still finds it) ·
`quick type TEXT` (or `--stdin`) inject keystrokes into the quick terminal ·
`quick text [--all] [--lines N]` read its screen back — the twins of `session type`/`session text`. There is one
per app, so none of them take `--target`/`--window`/`--pane`; all three still need an open window.

**sidebar** — `sidebar [show|hide|toggle]` (visibility; read back from the tree's `sidebarVisible`) ·
`sidebar mode [tree|flagged|toggle]` (flip between the workspace tree and the flat flagged working-set list; read
back from the tree's top-level `sidebarMode`) · `sidebar expand [--window W]` (expand every workspace) ·
`sidebar collapse [--window W]` (collapse all workspaces except the active one, which stays expanded) ·
`sidebar width <points> [--window W]` (move the divider, clamped to 160...560pt; prints the stored width
and reads back from the tree's top-level `sidebarWidth`).
Visibility/mode act on the frontmost window; `sidebar expand`/`collapse`/`width` default to the frontmost but take a
`--window` selector to target any open window.

**notify** — `notify <body> [--title T]` — post a desktop notification attributed to a session. To signal that you need the user, prefer `session status` (`blocked`/`completed`), a persistent typed attention state rather than a one-shot banner; keep `notify` for a one-off nudge.

**font** — `font inc|dec|reset [--pane left|right|scratch]` — change a session pane's font size (omitted/`left` = main pane, `right` = the split pane, `scratch` = the scratch terminal). Read the resulting size back from `tree` (`fontSize`/`splitFontSize`/`scratchFontSize` per pane).

**keymap** — `keymap reload` — re-read `keymap.conf` (prints the parse-diagnostic count). `keymap list` — show the resolved keymap AND the live menu key equivalents: every built-in with its current binds (the menu chord first, then any `|`-separated alternatives a key monitor delivers), the custom commands, the parse diagnostics, and what the menu bar is actually dispatching. Use it to check a rebind took effect, to find a free chord, or to spot a chord the keymap resolved but the menu is not carrying.

**config** - `config reload` - re-read the agterm-scoped `ghostty.conf` (prints the diagnostic count).

**theme** — `theme list` (bundled themes, current marked `*`) · `theme set [name]` — set + persist the
terminal theme app-wide, per slot: a NAME sets the light/single theme (a dark theme, if set, is kept);
`theme set --dark <name>` sets the dark theme, which makes the terminal track the macOS Light/Dark
appearance automatically; `theme set --dark none` stops tracking. The app default is the bundled
**agterm** theme; omit the name for ghostty's built-in default ("default ghostty"); an unknown name errors.

**restore** - `restore capture` - capture every pane's running command now, into the slot the quit-time
capture fills, so an exit that never reaches a clean quit (a force quit, a crash, a hard reset) still
restores; prints how many panes were captured and runs only in `rerun` mode, otherwise refusing and naming
the active mode · `restore clear` - clear every session's saved foreground command in any mode so the next
restart restores plain shells in rerun mode · `restore mode [none|rerun|live]` - read the policy (what
settings hold, what this launch requested, what it got, whether a restart is needed) or write it for the
NEXT launch; setting it changes nothing in the running app, because a pane is wrapped in a daemon or not
at the moment it is created.

**zmx** - `zmx list` - every daemon behind a live session joined against the pane that claims it, under the
restore status as a header; a CLOSED window's panes are claimed with zero clients, which is a resting
state rather than a leak · `zmx prune` - kill the daemons no pane claims and nothing is attached to,
refusing outright on an incomplete or conflicted inventory, and reporting each daemon separately since a
stale-socket cleanup is not a kill · `zmx kill --target ID --pane left|right --force` - destroy one pane's
daemon and the process in it; all three are required because this kills a backend process that reaches a
pane no window is showing and every client attached to it, and none of its outcomes gets the undo grace.
Every zmx command needs a running agterm.

**version** — `agtermctl version` — which agterm is serving this socket, as `result.app` (`version`, plus
`commit` when the build recorded one). App-global: no target, no `--window`, no window need be open, so it
works as a preflight from a keymap-launched script, which has no `$TERM_PROGRAM_VERSION`. Address the
socket explicitly (`--socket "$AGTERM_SOCKET"`, or `"$AGT_SOCKET"` in a keymap child): a bare call
resolves the DEFAULT socket, which may be another app. The same identity is on the tree top level as
`app`.

## Displaying an image inline

This skill bundles `scripts/show-image.sh`. It opens an overlay (a real terminal) and renders the
image there via the kitty graphics protocol, which ghostty draws natively — no kitty binary and no
external image tool, just `base64` + `printf`. Run it with the image path (optional size percent,
default 60):

The script sits next to this file, so resolve `scripts/show-image.sh` against the directory this
`SKILL.md` was loaded from — not against your working directory. That one form is correct wherever
the skill came from: a plugin install (`~/.claude/plugins/cache/…`, `~/.codex/plugins/cache/…`) or the
app's own **Help ▸ Install Agent Skill…** copy (`~/.claude/skills/agterm/`, `~/.codex/skills/agterm/`).

```bash
bash <this-skill-directory>/scripts/show-image.sh <image> [size-percent]
```

The size percent sizes the overlay PANEL; the image itself is scaled to fit that panel and centered
in it, so a large screenshot needs no resizing beforehand.

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
  (`result.id`/`text`/`exitCode`/`count`/`affected`/`tree`/`windows`/`app`/`restore`/`zmx`), error strings, the scratch/overlay/split
  lifecycle, and the keymap.conf format (`map` / `command`, chords, leaders, `|` alternatives,
  `{AGT_X}` tokens).
- **examples.md** — copy-paste agtermctl examples for common tasks (build a layout, run a program in a
  blocking overlay and read its status, type into a fresh session, notify, inspect the tree).
- **cookbook.md** — how to list, acquire and install the repository's cookbook recipes, and how to read
  one as reference for a tricky workflow. The recipe list lives in the repo, not here; fetch it.
- **troubleshooting.md** — diagnosing common problems (keymap editor, custom actions, logs) and the
  bug-issue / feature-Discussion reporting workflow (draft-first, scrub, never post without approval).
- **scripts/show-image.sh** — bundled helper that displays an image inline in an overlay (see above).

Read those files when you need exact flags, return shapes, or worked examples.
