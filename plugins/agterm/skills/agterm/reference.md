# agterm control reference

Full detail for every `agtermctl` command. See `SKILL.md` for the model and addressing overview, and
`examples.md` for recipes.

## Connection and output

- **Socket resolution** (when `--socket` is omitted): `AGTERM_SOCKET` is the path the running app
  bound; agtermctl resolves the same rendezvous: `<AGTERM_STATE_DIR>/agterm.sock`, else
  `<$HOME>/Library/Application Support/agterm/agterm.sock`. Passing `--socket "$AGTERM_SOCKET"` is the
  safe explicit form.
- **`--json`**: prints the raw response object. Without it, ordinary mutations print `ok`, batch
  close/move prints the affected session count, and `tree`/`window list` print a human listing. Use
  `--json` when you need to read ids or values back.
- **Response shape**: `{"ok": true, "result": {…}}` or `{"ok": false, "error": "<message>"}`.
  `result` carries one of: `id` (affected/new session/workspace/window), `text` (session copy/text),
  `exitCode` (overlay result), `count` (diagnostics/search), `affected` (sessions actually changed by a
  batch close/move), `tree` (the tree), `windows` (window list). The process exit code is non-zero when
  `ok` is false.
- **Options go after the subcommand**: `agtermctl session type "ls" --target active`, never before it.

## events

`agtermctl events [--json] [--kind KIND ...] [--run UUID --after SEQ] [--limit N]` continuously
prints control events. Each poll is one ordinary socket connection and one `events.read` response.
The CLI immediately reads again after a non-empty page and waits 250 ms only after an empty page.

With no cursor, the first read subscribes from now: it returns an empty batch anchored at the current
tail, and the CLI prints only later events. The app keeps a non-destructive ring of the latest 4,096
events for its current process run. Independent readers do not consume one another's events.

The five event kinds and payloads are:

- `status`: `name`, normalized `status` (`idle`|`active`|`blocked`|`completed`), a `blink` boolean,
  and optional `pane`, `color` and `shape` (the last two being the per-call `--color`/`--shape`
  overrides). An event fires whenever the whole indicator changes, not just the state name — so a
  change to `blink`, `pane`, `color` or `shape` alone is a real event you can watch, while re-asserting
  an identical indicator emits nothing. Clearing emits `idle`.
- `notify`: `name`, effective `title`, and `body`. It is emitted after target and foreground-focus
  suppression checks, including when desktop banners are disabled.
- `session.created` / `session.closed`: session `name`, emitted when the session enters or leaves a
  visible window tree. Undo emits a new `session.created`; grace-period finalization does not emit a
  second close.
- `tree.changed`: an empty payload and the affected window id. Name, membership, and ordering changes
  are coalesced for 100 ms per window. Read `tree --json` for the current snapshot.

Every event has `seq` (app-wide sequence), `ts` (Unix timestamp), `kind`, optional
`window`/`workspace`/`session` ids, and `payload`. Human mode prints one compact line. `--json` emits
one bare `ControlEvent` JSON object per line and flushes promptly.

`--kind` may be repeated or comma-separated. Unknown kinds are errors. Filtering advances the global
cursor across nonmatching events, so changing a filter does not replay skipped history. `--limit`
defaults to 100 and accepts 1 through 1,000.

The raw `events.read` response stores the batch under `result.events`:

```json
{"ok":true,"result":{"events":{"run":"01234567-89AB-CDEF-0123-456789ABCDEF","next":42,"items":[]}}}
```

A no-cursor response supplies the `run` and `next` anchor. Resume with both values:
`agtermctl events --run RUN --after NEXT`. The options must appear together. The streaming `--json`
format contains bare events rather than this batch envelope, so a restart-safe client must retain the
cursor from raw `events.read` responses.

Cursor failures return `ok: false`, one of `event run changed`, `event cursor expired`, or
`event cursor is ahead of the current sequence`, plus the current empty anchor under
`result.events`. Treat them as data-loss boundaries. Do not silently use the supplied anchor unless
the caller explicitly accepts dropping the missing interval. `agtermctl events` exits non-zero on a
cursor, transport, or server error and does not retry forever while the app is absent. SIGINT and
SIGTERM use normal process behavior.

## Addressing

- `--target` defaults to `active` (the selected session / current workspace). Accepts a full UUID
  (case-insensitive) or a unique prefix. Zero matches → `notFound`; ambiguous prefix → `ambiguous`
  (the error lists candidates).
- For a WORKSPACE, `active` is where a new session lands: one created in the foreground (the GUI's New
  Workspace, or `workspace new` without `--collapsed`) until the selection CHANGES — to a different
  session or to none at all, as when you close the last one — or `workspace select` names another, it is
  deleted, or the workspace filter hides it. Hiding drops it for good, so turning the filter off does not
  restore it. Reselecting the already-selected session does not count: `session select`,
  `overlay open --follow` and single-session `session go` leave it in place. `workspace select` on an EMPTY
  workspace has no session to select, so it takes the target instead (and is revealed if the filter was
  hiding it). Else the selected session's workspace, else the last one. A background create (`workspace new --collapsed`,
  `session new --create-workspace --no-select`) never takes it. The tree workspace node's `active` flag
  reads the SELECTED session's workspace only, so right after a foreground create it can name a
  different workspace than `--target active` resolves to; address by id when the two must agree.
- **For an agent, `active` is the USER's GUI-selected session, not yours.** Your shell is
  `$AGTERM_SESSION_ID`; the user is usually on a different session while you work. Pass
  `--target "$AGTERM_SESSION_ID"` on any session-scoped command (`overlay open`, `scratch`, `type`,
  `text`, `background`, `status`, `copy`, …) that must act on the session you run in — otherwise it hits
  whatever the user has selected. `overlay open` opens in the background without switching the user
  (both full and floating); pass `--follow` to additionally SELECT the target, switching the user to it.
- `--window <id|prefix|active>` (on session/workspace/tree/font/notify/pick commands) picks which window's
  tree to act on; default is the frontmost. With `--window` set, that window must be open. Without it,
  an id/prefix session target is matched across all open windows.
- `window.*` commands take the window selector as a positional argument, default `active` (frontmost).
- A window need not be open to be a `window.*` target (e.g. `window select` opens a closed one).

## tree

`agtermctl tree [--json] [--window W]` — the workspace/session tree. Each session node:
`id`, `name`, `cwd`, `title` (the raw OSC terminal title — e.g. a remote host over SSH — omitted
when none reported; distinct from `name`, the derived sidebar label), `active` (selected),
`split` (split shown), `splitRatio` (the left-pane fraction 0.05–0.95 of a session that HAS a split —
shown or hidden; omitted when there's no split or the ratio was never explicitly set (divider at the
default 0.5) — the read side
of `session resize`, record it to restore the exact divider position),
`splitFocused` (which pane holds focus in a session that HAS a split — `true` = the split/right pane,
`false` = the main/left pane; omitted when there's no split; the read side of `session focus`, record it
to restore focus via `session focus --pane left|right`),
`commandWait` (whether a `--command` session was created with `--wait` to hold open after the command
exits — the read side of `session new --wait`; omitted for a plain or non-holding session),
`overlay` (overlay shown),
`overlaySizePercent` (an open overlay's size — the
floating panel's percent of the pane, 1–100; omitted = a full-pane overlay or no overlay, so gate on
`overlay` first; the read side of `session overlay resize`, e.g. record it before switching to `--full`
to restore the exact size),
`paneOverlays` (the panes covered by their own pane-scoped overlay — `["left"]`, `["right"]` or
`["left","right"]`, omitted when neither is; the read side of `session overlay open --pane`, reported
independently of the session-wide `overlay` flag, which a pane overlay never sets),
`scratch` (scratch shown), `flagged` (in the
flagged working-set), `status` (the agent-status — `active`|`completed`|`blocked` — omitted when
idle), `statusPane` (which pane set that status — `left` (main) | `right` (split) | `scratch` — the
`--pane` value from `session status`, omitted when unset or idle; gated on the same non-idle condition
as `status`, so it is never reported without a `status`), `statusBlink` (`true` when the status glyph is
set to blink — the `--blink` value; omitted when idle or not blinking), `statusColor` (the `#rrggbb`
glyph-tint override — the `--color` value; omitted when idle or using the configured color) and
`statusShape` (the glyph silhouette override — the `--shape` value, one of
`circle`|`square`|`triangle`|`diamond`|`capsule`|`star`; omitted when idle or using the configured shape.
Like `statusColor` it reports the PER-CALL override only, so a shape picked in Settings reads back as
absent),
`foreground`/`splitForeground` (the live argv of each pane's foreground
process — what it is running — omitted when the pane sits at its shell prompt, and also for a
setuid/setgid foreground process like `top` or `sudo`, whose argv macOS refuses to expose),
`restoreCommand`/`splitRestoreCommand` (each pane's persisted restore-command override — the read side of
`session restore`: omitted = no override (auto-capture), `""` = pinned to nothing (a plain shell), a
command string = the shell line that runs on the next launch; reported from persisted state, so a read
after the override already fired still reports what is pinned), `background` (the
background spec set via `session background` — a `{kind, text?, imagePath?, colorHex?, opacity?, fit?,
position?, repeats?}` object; `kind` is `image`/`text`/`color` — omitted when none is set), `unseen`
(the unseen-notification badge count — raised by `notify`/OSC 9/777, cleared by `session seen` — omitted
when zero), `fontSize`/`splitFontSize`/`scratchFontSize` (the LIVE font size in points of each pane —
the read side of `font --pane`; each omitted when that pane isn't realized. `fontSize` tracks the
default/left target (the main pane, or the promoted split survivor once the primary exits — the same pane
`font --pane left` writes); only the main pane's size survives a relaunch, so the split/scratch sizes and a
promoted survivor are live-only — read them back here rather than from the snapshot), and `surfaces` (array
of `{id, kind, active, visible}` where `kind` is
`left`|`right`|`scratch`|`overlay`|`overlay-left`|`overlay-right`).
The surface `id` is the address for `surface zoom`; hidden-but-alive split/scratch surfaces are included
so a script can zoom them without changing split/scratch visibility first. Caveat: `active`/`visible`
derive from the session's own flags, not from zoom — and `visible` reads false for a pane behind a
FLOATING overlay even though it is visually on screen; address by `id`/`kind`, and read the zoom state
from the top-level `zoomedSurface`. Workspace nodes carry
`id`, `name`, `active`, `sessions`, `focused` (whether this workspace is a MEMBER of the sidebar's focus
set — the read side of `workspace focus`, distinct from `active` the SELECTED workspace; omitted on
non-members, and absent entirely when nothing is marked. Membership is reported INDEPENDENTLY of whether
the filter is applied, so a marked-but-not-filtering set reads back too; a workspace ROW RENDERS in the
sidebar iff `sidebarVisible && sidebarMode == "tree" && (!workspaceFilter || focused)`, every term on the
same tree response — the sidebar hidden renders nothing, `flagged` mode renders a flat flagged-session
list with NO workspace rows whatever the filter says, `tree` mode with the filter OFF renders the whole
tree regardless of membership, and only `tree` mode with the filter ON narrows visibility to the
members), and `collapsed` (whether this workspace is COLLAPSED in the sidebar tree — the read side of
`workspace collapse`/`workspace expand` and `workspace new --collapsed`; `true` when collapsed, omitted
when expanded, so an all-expanded tree carries no `collapsed` keys).

The tree object itself carries twelve top-level read-only fields: `idleMs` (milliseconds since the last
user input in the window, omitted before any activity), `autoFollowMs` (the window's Auto-follow
timeout in milliseconds, omitted when the setting is Disabled), `sidebarVisible` (whether the
window's sidebar is currently shown — the read side of the write-only `sidebar` command, so a script
can restore it, e.g. a tmux-style zoom that hides the sidebar and must re-show it only when it was
visible before), `sidebarMode` (`tree` or `flagged` — the sidebar view mode, the read side of
`sidebar mode`), `workspaceFilter` (whether the window's workspace focus filter is currently APPLIED —
the flag half of the focus set, whose member half is each workspace node's `focused`; the read side of
`workspace filter`, so a script can record the filter state, restore it, or make the toggle idempotent),
`quickVisible` (whether the window's quick terminal is currently shown — the read
side of the write-only `quick` command, so a script can make the toggle idempotent), `zoomedSurface`
(the control id of the surface terminal zoom currently fills the window with —
`surface:<session-id>:<kind>` or `quick`; omitted when nothing is zoomed — the read side of the
write-only `surface zoom` command, so a script can check "is it already zoomed" and
record-then-restore), and the four read sides of the write-only `dashboard` command (all omitted when
no dashboard is open): `dashboardMembers` (the pane refs the open dashboard shows, in grid order —
`<session-id>:left` for a primary pane, `<session-id>:right` for a split pane, so a split session appears
as both), `dashboardHighlighted` (the highlighted cell's pane ref — the one Enter jumps into, focusing
that exact pane), `dashboardFontSize` (the absolute font size in points applied to the cells, omitted when
the mode is `untouched`), and `dashboardFontMode` (`auto` for `--auto-size`, `fixed` for `--font-size`, or
`untouched`), plus `pickPending` (the id of the native picker currently awaiting an answer in this
window, omitted when none is pending). `idleMs` is live
and grows while the window is idle, so it is on `tree` only, never `window.list`; `sidebarVisible` is on
both; `sidebarMode`, `workspaceFilter`, `quickVisible`, `zoomedSurface`, the four `dashboard*` fields, and
`pickPending`
are `tree`-only (a GUI/keyboard change would leave a cached copy stale).
All twelve are read-only projections of GUI state.

## workspace

- `workspace new [name] [--collapsed] [--window W]` — create a workspace; returns its id. Name defaults
  to an auto-generated one. `--collapsed` creates it CLOSED in the sidebar tree so a script can build a
  workspace and fill it with `session new --no-select` without it ever opening (a fresh workspace is
  expanded by default), and for the same reason a `--collapsed` create is kept OUT of the workspace focus
  set — it never widens a marked working set. A PLAIN `workspace new` while the filter is applied JOINS
  the marked set instead, so a foreground create is visible rather than hidden behind the filter (the
  same auto-reveal the GUI's New Workspace button has). Read the state back from the tree workspace
  node's `collapsed` flag, and the membership from its `focused` flag.
- `workspace rename <name> [--target] [--window W]`.
- `workspace delete [--target] [--window W]` — keep-at-least-one; deleting the last workspace errors.
- `workspace select [--target] [--window W]`.
- `workspace move --to up|down|top|bottom [--target] [--window W]` — reorder among siblings. Missing
  or invalid `--to` errors. Note: `--target active` resolves to the current workspace — a
  foreground-created workspace that still holds the target, else the selected session's, else
  the last one; address a specific workspace by id to step the same one.
- `workspace focus [on|off|toggle|add] [--target] [--window W]` — mark or unmark ONE workspace in the
  sidebar's focus SET; returns the workspace id. The sidebar renders the marked workspaces when the
  filter is applied, all of them when it is not. `on` sets the marked set to just this workspace and
  APPLIES the filter (the single-workspace zoom); `off` removes it, and the filter switches off once the
  set empties; `toggle` (the default) replace-toggles — it clears when the set is exactly this workspace
  and the filter is applied, else sets the set to just this workspace and applies it; `add` inserts it
  into the set leaving the filter flag EXACTLY as it was. `add` never switches the filter on: that is
  what makes a multi-workspace set buildable, since a mark that narrowed the tree would hide the rows
  still to be marked, so mark several and apply once with `workspace filter on`.
  Per-window and persisted; orthogonal to `sidebar mode` (the flagged flat list ignores the filter).
  While the filter is applied, `session go` navigation is scoped to the marked workspaces' sessions (and
  to the flagged set in flagged mode); an explicit `session select` of a session outside the set switches
  the filter OFF while KEEPING the set, so re-applying it costs one `workspace filter on`.
  That reveal is TREE-MODE ONLY: the flagged list is cross-workspace and ignores the marked set, so
  selecting an off-set session there leaves the filter applied.
  The converse also holds for the commands listed below, and it MOVES THE SELECTION: when one of them
  leaves the selected session invisible, the most recently used session still visible is selected instead
  — read back as `active` on `tree`. The transitions that do it: `workspace focus on` and a narrowing `toggle`; a
  `workspace focus off` that drops the selected session's workspace while the remaining members keep the
  filter applied; `workspace filter on`; both `sidebar mode` flips; and `session flag off` on the selected
  session while the flagged view is up and other flagged sessions remain.
  A visible set with NO sessions is the one exception — nothing to move to, so the selection stays. The
  same commands repair it, so `session flag on` into an empty flagged view and `workspace focus add` of a
  populated workspace while the marked set holds only empty ones both move the selection despite widening —
  provided something was selected at all; a window restored with no selection stays unselected.
  `session flag clear` never does (it empties the list), and neither does `session new --no-select`, so
  the view can hold a row with nothing selected until one of the listed commands runs.
  Nor does a plain `session new` or a `session select` in FLAGGED mode: both make the fresh or chosen
  session active while the flagged view renders no row for it, leaving the sidebar unselected.
  A script that changes what is visible should re-read `tree` before using the default `active` target.
  A workspace
  created while the filter is applied joins the set, so it is visible without breaking the filter — except
  a `workspace new --collapsed` (or a `session new --no-select --create-workspace`), whose whole point is a
  quiet background build.
  Read membership back from the tree workspace node's `focused` flag. An unknown mode errors.
- `workspace filter [on|off|toggle] [--window W]` — apply or suspend the whole window's workspace focus
  filter WITHOUT touching the marked set, so peeking at the full tree and coming back costs one call each
  way. Window-scoped: it takes NO `--target` (it flips the window's filter, not one workspace's
  membership), and `--window` picks the window like `sidebar expand`/`sidebar collapse`, defaulting to
  the frontmost. `toggle` is the default; idempotent (delta-computed); an unknown mode errors, and
  `no open window` when none is open. `on` with an EMPTY marked set is REFUSED — it returns ok having
  changed nothing, which is what keeps the filter term of the row-visibility contract exact:
  `workspaceFilter == true` with nothing marked cannot occur, so an applied filter always has at least one
  visible member (the full predicate, including the sidebar-mode term, is on the `focused` field above).
  Read it
  back from the tree top-level `workspaceFilter`. The GUI half is the sidebar's bottom-bar grid button
  (filled while applied, disabled with nothing marked), View ▸ Toggle Workspace Filter, the ⌃⇧P palette
  entry, and the `toggle_workspace_filter` keymap action.
- `workspace collapse [--target] [--window W]` — collapse ONE workspace's subtree in the sidebar tree
  (hide its sessions); returns the workspace id. The per-workspace counterpart of `sidebar collapse`
  (which collapses ALL but the active workspace) — this targets exactly the addressed workspace and does
  not depend on which one is active. Idempotent. Persisted. Read back from the tree workspace node's
  `collapsed` flag.
- `workspace expand [--target] [--window W]` — expand ONE workspace's subtree (show its sessions);
  returns the workspace id. The inverse of `workspace collapse`, and the per-workspace counterpart of
  `sidebar expand`. Idempotent. To TOGGLE a workspace, read its `collapsed` flag off `tree` first, then
  call `expand` or `collapse`.

## session

- `session new [--cwd DIR] [--workspace W] [--workspace-name NAME] [--create-workspace] [--command CMD] [--wait] [--name NAME] [--after SID | --before SID] [--no-select] [--window W]`
  — create a session and focus it; returns the new id. `--cwd` sets the start directory (default
  `$HOME`). The destination workspace is addressed one of two mutually-exclusive ways: `--workspace`
  (id / unique prefix / `active`, the default) or `--workspace-name` (the sidebar label) — the latter
  errors if no workspace has that name unless `--create-workspace` is also passed, which reuses an
  existing one or creates it when absent (idempotent). `--command` runs that command as the session's
  process instead of the login shell (no echoed command line; the session closes when the command
  exits). It runs argv-style (tokenized, quotes respected, but NO shell), so shell operators (`;`,
  `&&`, `$VAR`, redirects, globs) are not interpreted, and it inherits the app's GUI `PATH` (the launchd
  default — no `/opt/homebrew/bin`), so a bare Homebrew or other non-default binary fails with exit 127.
  Wrap in a login shell for both — `--command "zsh -lc 'htop'"` — or give an absolute path
  (`/opt/homebrew/bin/htop`).
  `--wait` (only with `--command`, else an error) HOLDS the session open after the command exits —
  showing libghostty's press-any-key prompt with the final output intact instead of closing immediately —
  so you can read a build/test/deploy's final output or an early failure that would otherwise flash and
  vanish. It persists across restart (unlike an overlay's live-only `--wait`), so a restored command
  session that re-runs its command holds again; read it back on `tree`'s `commandWait`.
  The command is persisted (`SessionSnapshot.initialCommand`) and re-runs on restore when **Restore
  running commands on restart** is on (default off → a restored session is a plain shell); a live
  captured foreground takes precedence over it. `--name`
  seeds the session's custom name (the sidebar label; blank/omitted leaves the auto basename),
  equivalent to a `session rename` right after create. `--after SID` / `--before SID` place the new
  session directly after / before an anchor session instead of appending at the end (the anchor is a
  session address — id / unique prefix / `active`). The anchor CARRIES ITS OWN WORKSPACE (resolved
  across all workspaces), so it names the destination workspace itself — `--after`/`--before` are
  therefore mutually exclusive with each other and with `--workspace`/`--workspace-name` (the anchor
  already picks the workspace). `agtermctl session new --after active` is the headline case: create
  right after the current session in one round-trip. `--no-select` creates the session in the BACKGROUND:
  it is added to the sidebar but NOT selected or focused, so the current selection and focus are left
  untouched (the new node is not `active` in `tree` — that flag is the read-back); omit it for the default
  select-and-focus behavior. Every other addressing/placement option composes with it, and a background
  `--create-workspace` create does not widen the workspace focus set either (the new workspace stays
  unmarked, so the filtered sidebar view is left put instead of revealing it).
- `session duplicate [--target] [--window W]` — create a fresh session in the SAME workspace as the
  target, inserted directly AFTER it, rooted at the target's focused-pane working directory (the live
  OSC 7 cwd the sidebar row shows and `session reveal` opens); selects + focuses the new session and
  returns its id. There are NO other options — the target session names both the destination workspace
  and the cwd — and `--target` defaults to `active`. It is equivalent to
  `session new --cwd <source cwd> --after <source>` in ONE atomic round-trip.
  ONLY the directory carries over: the duplicate is a plain login shell with the auto basename, and it
  does NOT inherit the source's custom name, `--command`, split, scratch, status, flag, font size, or
  background — it is "new session seeded with the source's cwd", not a clone of state. Errors: the usual
  resolver errors for an unresolvable / ambiguous target, and `could not duplicate session` when creation
  fails. READ-BACK: no new tree field — `tree` itself is the read-back, since the new session node appears
  directly after its source, carrying the source's focused-pane cwd. That equals the source node's
  `tree.cwd` for a non-split session (and a split focused on its primary pane); for a split focused off its
  primary the source node's `tree.cwd` reports the primary pane while the duplicate carries the focused
  pane's directory. It is the control half of the sidebar row's **Duplicate Session** context-menu item
  (single-selection only).
- `session close [--target T ...] [--window W]` — close one session, or repeat `--target` to close
  several sessions in the same window/store. Batch close honors the GUI grace-undo setting: one grouped
  undo/reopen record when enabled, immediate close when disabled. Returns `result.affected`.
- `session select [--target] [--window W]`.
- `session rename <name> [--target] [--window W]`.
- `session reveal [--target] [--window W]` — select the target session's focused-pane working
  directory in Finder. Errors when that directory no longer exists.
- `session go --to next|prev|first|last|next-attention|prev-attention [--window W]` — move the
  selection relative to the CURRENT one (no `--target`). Operates over the VISIBLE/FILTERED set: the
  flagged sessions in flagged mode, the marked workspaces' sessions while the focus filter is applied,
  else all sessions (clearing the flag / suspending the filter restores the full set). next/prev wrap around at the ends (last→first,
  first→last); first/last jump to the ends of that set; next-attention/prev-attention step only through the filtered
  sessions needing attention (status blocked/completed), wrapping. Returns the newly selected id.
- `session move <workspace> [--target] [--window W]` — relocate the session to another workspace
  (appends). OR `session move --to up|down|top|bottom [--target]` — reorder within its workspace. OR
  `session move --after SID | --before SID [--target]` — place the session directly after / before an
  anchor session (id / unique prefix / `active`). The anchor CARRIES ITS OWN WORKSPACE (resolved across
  all workspaces), so it relocates + positions in one shot, wherever the anchor lives — cross-workspace
  placement falls out for free. Exactly one placement intent is required among {positional workspace,
  `--to`, `--after`/`--before`}; `--after`/`--before` are mutually exclusive with each other, with `--to`,
  and with a destination workspace (the anchor already names the workspace).
  Repeat `--target` for a batch move with the workspace and after/before placement forms; the sessions
  move as one ordered block after all sources are removed. Repeated `--target` is rejected with
  `--to up|down|top|bottom` because relative reorder is per-session. Batch moves return `result.affected`,
  counting only sessions whose position/workspace changed.
- `session type <text> [--stdin] [--select] [--pane left|right|scratch] [--target] [--window W]` — inject text
  as real keystrokes (printable runs plus Return for each newline; no bracketed-paste markers).
  `--stdin` reads the text from stdin instead of the argument. Any session is typable without `--select`,
  including a background one and one created moments ago: the main pane bounded-polls (12 × 30ms) for the
  surface, so `session new --no-select` followed straight away by `session type` does not race the mount.
  `--select` selects the session first, and only when its surface is not ready — a realized session is typed
  into without moving the user's selection. A surface that never comes up → `session not realized`.
  `--pane left` types into the main pane (the default when omitted), `--pane right` into the split pane
  (errors with `session has no split pane` when the session has no split), `--pane scratch` into the
  session's scratch terminal even while it is hidden (`session has no scratch terminal` when none opened);
  like `session text`, no `other` value. `--select` realizes the MAIN pane only — a split pane must
  already exist.
- `session copy [--target] [--window W]` — returns `result.text` with the session's current selection.
  Does NOT touch the system clipboard (pipe the returned text into another `session type`). No/empty
  selection → `no selection` error. Selection is readable on any realized session regardless of focus.
- `session paste [--target] [--window W]` — paste the system clipboard (`NSPasteboard.general`) into the
  session's main pane, the socket analogue of ⌘V / Edit ▸ Paste. Runs libghostty's `paste_from_clipboard`
  (bracketed paste, no prompt), so the text lands at the prompt without auto-submitting. Read it back with
  `session text`. A never-shown session → `session not realized`.
- `session select-all [--target] [--window W]` — select the session's entire terminal buffer (main pane),
  the socket analogue of ⌘A / Edit ▸ Select All (libghostty `select_all`). Read the resulting selection
  back with `session copy`. A never-shown session → `session not realized`.
- `session text [--all] [--lines N] [--pane left|right|scratch] [--target] [--window W]` — returns `result.text`
  with the session's terminal buffer as PLAIN TEXT (no ANSI/color). By default it reads the VISIBLE
  SCREEN of the on-screen pane. `--all` reads the whole buffer including scrollback; `--lines N` reads the
  full buffer and keeps only the last N CONTENT lines (trailing blank rows trimmed; `--all` and `--lines`
  are mutually exclusive and `--lines` must be > 0 — enforced server-side too). `--pane left` reads the
  main pane, `--pane right` the split pane (errors if the session has no split), `--pane scratch` the
  session's scratch terminal even while it is hidden (its buffer is kept alive; `session has no scratch
  terminal` when none opened); omit `--pane` for the visible pane (the scratch terminal when it covers the
  session, else the focused pane). NOTE: unlike
  `session focus`, `--pane` here has NO `other` value — only `left`/`right`/`scratch`. A genuinely BLANK screen is
  NOT an error (returns `ok` with an empty string, unlike `session copy`'s `no selection`), but a failed
  read IS an error (`failed to read surface buffer`). Pipe the text into `grep`/`fzf` to extract URLs,
  paths, etc.
- `session search [needle] [--next|--prev|--close] [--target] [--window W]` — search the target
  session's live terminal scrollback. Selects the target first (so the search bar and match highlights
  render). With a `needle` it sets the query (opening the bar if needed) and highlights matches; with no
  needle and no flag it just opens the empty bar. `--next`/`--prev` step the selected match;
  `--close` closes the bar (the three flags are mutually exclusive). Returns `result.count` (total
  matches) and `result.text` (the counter string: "N of M", "M matches", or "no matches"); the count
  settles asynchronously, so the command waits briefly for it. Without `--json` it prints `result.text`
  (or `ok` on close / an empty bar).
- `session split [on|off|toggle] [--target] [--window W]` — side-by-side second shell. `off` HIDES it
  but keeps the shell alive (mirrors ⌘D); the pane's surface is torn down only when its shell exits.
  Unknown mode errors.
- `session scratch [on|off|toggle] [--command CMD] [--target] [--window W]` — a third, full-coverage
  shell that renders like a full overlay but behaves like the split. `off` hides it keep-alive; typing
  `exit` in it closes it and the next `on` spawns a fresh shell. `on` selects the target first (the
  scratch is full-coverage and owns focus). `--command` (only when showing) runs that program as the
  scratch's process instead of a login shell — argv-style (no shell, and inheriting the app's GUI
  `PATH`, so the same exit-127 caveat as `session new --command`: wrap in `"zsh -lc '…'"` or use an
  absolute path) and RUN-ONCE like `session new --command` (after it exits, the next `on` is a plain
  shell). A scratch is expendable, so passing `--command` while one is already open respawns it. Not
  persisted. Unknown mode errors. The tree's `scratch` flag tracks visibility.
- `session focus [left|right|other] [--target] [--window W]` — move keyboard focus between the two
  split panes (`other` toggles, the default). Errors when the session has no split. Works whether the
  split is shown side-by-side or hidden (maximized) — when hidden, focusing a pane swaps which one shows.
- `session resize (--split-ratio R | --grow-left D | --grow-right D) [--target] [--window W]` — move the
  split DIVIDER (the divider is otherwise mouse-only: drag it, or double-click it for an even split. No
  GUI/menu/keymap action reaches any other fraction, so bind a key by mapping a
  `command "agtermctl session resize …"` custom action). Provide exactly one form:
  `--split-ratio` sets the absolute left-pane fraction (`0..1`); `--grow-left D` / `--grow-right D` nudge
  it by the fraction `D` (grow-left shrinks the right pane and vice-versa). The result is clamped to
  `0.05..0.95` and persisted, and the applied (clamped) fraction is printed (and returned as `result.ratio`
  under `--json`). Errors when the session has no split. Resizing a hidden split updates the stored
  fraction; it takes effect when the split is next shown.
- `session status <idle|active|completed|blocked> [--blink] [--auto-reset] [--sound NAME] [--color #rrggbb] [--shape circle|square|triangle|diamond|capsule|star] [--pane left|right|scratch] [--pane-id TOKEN] [--target] [--window W]` —
  set the sidebar agent-status glyph. `--blink` requests an attention pulse; macOS Reduce Motion
  suppresses the repeating sidebar and dashboard animation while keeping the status visible, and the
  pulse resumes when Reduce Motion is disabled. `--auto-reset` clears it back to idle once the session
  is visited (use for a one-shot completion flash). `--sound` plays a
  one-shot sound when the status is set: `default` (the system alert sound) or a system sound name
  (`Basso`, `Blow`, `Bottle`, `Frog`, `Funk`, `Glass`, `Hero`, `Morse`, `Ping`, `Pop`, `Purr`,
  `Sosumi`, `Submarine`, `Tink`; also any custom sound in `~/Library/Sounds`) — an unknown name errors.
  Without `--sound`, a `blocked` status plays the user's Settings "Blocked sound" if they configured one
  (Appearance ▸ Agent Status; off by default); an explicit `--sound` always overrides it.
  `--color` (`#rrggbb`) overrides the glyph tint for THIS call only — it rides the status, so the next
  `session status` without `--color` reverts to the Settings-configured color (a malformed hex errors).
  Use it to distinguish states beyond the fixed palette (e.g. a caller-specific blocked color).
  `--shape` (`circle`, `square`, `triangle`, `diamond`, `capsule`, `star`) overrides the glyph SILHOUETTE
  the same way — it rides the status, so the next `session status` without `--shape` reverts to the
  Settings-configured shape, else the built-in plain circle (an unknown name errors, listing the six).
  Shape is a second channel alongside the tint, so a session stays distinguishable at a glance and for a
  color-blind user; use it to mark one session for the length of a run.
  The value is read back on `tree` as the session node's `statusShape` (the per-call override only, like
  `statusColor`), and rides the `status` control event's `shape` payload field so an `events` consumer can
  explain a shape-only change.
  A `--shape` on `idle` is accepted and ignored, since an idle session draws no glyph.
  `--pane` (`left`|`right`|`scratch`, `left`=main, `right`=split; defaults to `left` when omitted) records
  which pane set the status. It has two effects: (1) keystroke-clear becomes pane-scoped — a status set
  from a background pane survives typing in a DIFFERENT pane (so a `right`- or `scratch`-tagged block is
  no longer wiped by foreground typing in the main pane, and only a keystroke in the OWNING pane clears
  it), and (2) when the status needs attention (`blocked`/`completed`), any user-initiated GUI selection of
  the session lands on the tagged pane — auto-follow,
  the attention-nav (⌃⌥↑/⌃⌥↓, the Navigate menu), plain session nav (⌥⌘↑/↓/first/last),
  the command palettes, a sidebar row click, and a Dock-menu session row all reveal and focus it, flipping to the split or
  showing a hidden scratch instead of the main pane. An `active` status keeps the existing pane selection.
  (The socket `session go next-attention|prev-attention`
  only STEPS the selection to attention sessions; it does not itself move focus into the tagged pane — the
  reveal is a GUI/auto-follow concern.) An agent that runs in a split or scratch should set its own pane so
  the user lands on it. The value is read back on `tree` as the session node's `statusPane`. An invalid
  value errors (`--pane must be left, right, or scratch`).
  `--pane-id` is the surface's stable spawn token (the shell's `$AGTERM_PANE_ID`) — the agent-status hook
  forwards it automatically. When it resolves against the session's LIVE surfaces it OVERRIDES `--pane`, so
  a status from a pane whose baked role went stale (a split survivor promoted into the main pane, then a
  re-split) lands on the pane's CURRENT slot instead of the stale role; an absent/unknown token falls back
  to `--pane`. Scripts normally set `--pane` directly and leave `--pane-id` to the hook.
  An unknown state errors. Setting non-idle is for agents/hooks; `idle` clears it (also available in the GUI).
- `session flag [on|off|toggle|clear] [--target] [--window W]` — flag/unflag a session for the flagged
  working-set view (a durable, persisted membership). `on`/`off`/`toggle` act on `--target` (default
  `active`) and are idempotent; `clear` ignores the target and unflags every session in the window.
  Pair with `sidebar mode flagged` to see just the flagged sessions as a flat `session : workspace`
  list. Unknown mode errors. The tree's `flagged` flag tracks membership.
- `session seen [--target] [--window W]` — clear the session's unseen-notification badge without changing
  the selection, focus, or agent status. It is the focus-free counterpart to `notify`: `notify` (and a
  terminal's own OSC 9/777) raise the red badge, and until now the only way to clear it was visiting the
  session. Idempotent — a no-op when the badge is already zero. Read the current count from the tree node's
  `unseen` field. This lets an orchestrator acknowledge a driven session's notifications over the socket
  while keeping the badge a real attention signal on the sessions a human tends.
- `session restore (<command> | --none | --clear) [--pane left|right] [--pane-id TOKEN] [--target] [--window W]`
  — pin the command a pane re-runs on the NEXT launch, overriding the captured foreground. Provide exactly
  one of: a `<command>` shell line to pin, `--none` to pin nothing (the pane restores a plain shell,
  suppressing the captured command), or `--clear` to drop the override and fall back to auto-capture.
  Tri-state, read back on the tree node as `restoreCommand` (main pane) / `splitRestoreCommand` (split
  pane): omitted = auto-capture, `""` = pinned to nothing, a command = the pinned line.
  The override is written NOW and consumed on the next launch — it never touches the running session — and
  it is STICKY: it fires again on every restart until cleared. It wins over EVERYTHING else the pane could
  restore: the captured foreground AND the session's own `session new --command`, which a pinned line (or
  `--none`) suppresses — so a restored `--command` session runs the pinned line instead, as typed input
  rather than the exec path, and its `--wait` close-on-exit behavior no longer applies.
  It is gated on the **Restore running commands on restart** setting (a pinned command while the setting is
  off succeeds with a note in `result.text` that nothing will run; `--none`/`--clear` get no note, since
  their outcome is delivered either way), and bypasses `restore-denylist.conf`
  (it names its command deliberately, so the denylist is never the reason it does not fire). It is typed
  verbatim as a shell line, so `cd x && claude --resume y` works as written.
  A split HIDDEN at quit is not restored, so its pin is dropped on that launch rather than left to fire
  into a later manual split.
  It exists for NON-IDEMPOTENT commands — `claude --resume <id> --fork-session` mints a NEW session on every
  restart, so restoring it verbatim never reattaches the session the user was in. A Claude Code
  `SessionStart` hook that rewrites the override to the live session id on every start makes the next
  restart reattach instead of fork (see examples.md). Ownership flips to whoever sets it: write once and
  forget, and it stays pinned to a stale id — that is the deliberate hook-driven tradeoff.
  `--pane` (default `left`) picks the pane; `--pane right` errors when the session has no split, and
  `scratch` is rejected (`the scratch terminal is never restored`). `--pane-id` (the shell's
  `$AGTERM_PANE_ID`) resolves the pane's LIVE slot, so a hook in a promoted-then-re-split pane still pins
  the right one; UNLIKE `session status`, a token that does not resolve is an error unless `--pane` is also
  given as the fallback (a silent main-pane default here would overwrite the wrong pane).
  The pinned value is SHELL CODE: it persists in the window's state file (`windows/<id>.json`), is readable
  via `tree`, and may enter shell history when it runs — so it must not carry secrets, and only
  safely-interpolated values (a UUID-shaped session id) belong in it. It persists immediately, so a
  force-quit does not lose a hook's write; if that write fails the command answers with an ERROR rather
  than `ok` (the previous override is still in effect and still fires, so re-issue the same request to
  retry). Not to be confused with the app-global `restore clear`, which
  clears every session's CAPTURED foreground command; this is per-session and clears only the override.
- `session background image <path> [--opacity F] [--fit contain|cover|stretch|none] [--position P] [--repeat] [--target] [--window W]`
  — composite the image at `path` (PNG or JPEG only) behind the terminal as a watermark. libghostty
  auto-fits it to the surface and re-fits on every window resize. `--opacity` is 0.0–1.0 (default 1.0);
  `--fit` defaults to `contain`; `--position` is `center` (default) or an edge/corner anchor
  (`top-left`, `top-center`, `top-right`, `center-left`, `center-right`, `bottom-left`, `bottom-center`,
  `bottom-right`); `--repeat` tiles to fill blank space. Errors on a bad fit/position, an out-of-range
  `--opacity` (must be 0.0–1.0), an unsupported format, a missing file, or a path containing control
  characters (the path reaches a ghostty config line, so a newline could inject other keys).
- `session background text <text> [--color #rrggbb] [--opacity F] [--fit ...] [--position ...] [--target] [--window W]`
  — rasterize `text` to a watermark behind the terminal. `--color` defaults to the terminal foreground
  (must be a `#rrggbb` hex value); `--opacity`/`--fit`/`--position` as above. `text` is capped at 256
  characters (a watermark is a word or two).
- `session background color <#rrggbb> [--target] [--window W]` — set a SOLID terminal background color
  (the `background` key, not an image). Takes no opacity: the color is drawn at the Settings window
  translucency (solid when translucency is off; blurred/translucent when on), so it honors your
  opacity/blur instead of forcing the pane opaque like the image/text watermark. macOS Reduce
  Transparency temporarily presents it as opaque and unblurred without changing the saved opacity/blur;
  the requested presentation returns when Reduce Transparency is disabled. Errors on a malformed color
  (must be a `#rrggbb` hex value).
- `session background clear [--target] [--window W]` — remove the session's background.
  Per session (applies to the session's pane(s)); persisted, so it survives a relaunch. An image/text
  watermark makes the pane render OPAQUE, overriding window translucency (an image is invisible at 0
  background-opacity); a `color` instead honors the Settings window translucency. Read the current
  background back from a session's `background` field in `tree --json` (a `{kind, colorHex, …}` object,
  omitted when none).
- `session overlay open <command> [--cwd DIR] [--wait] [--block] [--size-percent N] [--background-color #rrggbb] [--follow] [--pane left|right] [--target] [--window W]`
  — run `command` in an ephemeral terminal on top of the session; it closes when the command exits.
  `command` runs through `sh -c` (so shell operators DO work here) but with the app's GUI `PATH` (no
  `/opt/homebrew/bin`), so a bare Homebrew or other non-default binary fails with exit 127 — the overlay
  flashes open then vanishes and `overlay result` reports 127; give an absolute path or wrap in
  `"zsh -lc '…'"`.
  Full-size by default (hides the session); `--size-percent N` (1–100) makes it a floating framed panel
  with the session visible behind. **By default the overlay does NOT switch the active session** — full
  and floating both open on `--target` and run their program in the background, appearing when the user
  visits that session. **Pass `--follow` to select the target after opening** (a no-op if it is already
  active); use it when you want the user pulled to the overlay, omit it to open quietly. `--background-color #rrggbb` gives the overlay pane its own solid
  background color, independent of the session's own `session background color` (nil = the default theme
  background); it honors the Settings window translucency, captured when the overlay opens. `--wait` keeps the overlay open after the command exits (press a key
  to close). `--block` waits for the command to exit and makes agtermctl exit with the command's status
  (cannot combine with `--wait`); the program renders normally — capture its OUTPUT via the program's
  own output file, not the control channel. Returns the overlay's session id. `--target` defaults to
  `active`, so an automated caller should pass `--target "$AGTERM_SESSION_ID"` — otherwise a (usually
  blocking, full-pane) overlay lands on whatever session is currently active, not the calling one.
  `--pane left|right` scopes the overlay to ONE split pane rather than the whole session: it covers
  exactly that pane and leaves the sibling pane visible and interactive. The two panes are independent
  and may both hold an overlay at once, each with its own `--background-color` and `--cwd`. A pane
  overlay is ALWAYS full-pane — there is no floating variant, so `--pane` with `--size-percent` is a
  usage error and `session overlay resize` takes no `--pane`. Everything else matches the session-wide
  overlay: it closes when the program exits, `--wait` holds it open on the press-any-key prompt,
  `--block` blocks and exits with the program's status, and `--follow` selects the target. A NON-SPLIT
  session accepts `--pane left`, because such a session reports `AGTERM_PANE=left` — so an agent can
  pass `--pane "$AGTERM_PANE"` without first checking whether the session is split. A pane that is not
  currently rendered is refused with `pane not visible`: a SHOWN split renders both panes, a HIDDEN one
  renders only the FOCUSED pane, so the refused one is the pane without focus — `--pane left` on a
  session whose hidden split holds it, `--pane right` when the main pane does; hiding the split AFTER
  opening is fine, the program keeps running and reappears when the split is shown again. Opening a
  second overlay on the same pane errors `pane overlay already open`. A full session-wide overlay and
  the scratch terminal both cover a pane overlay, and ⌘W dismisses the FOCUSED pane's overlay before it
  would close the session — an overlay on the other pane is not in front of the user, so ⌘W keeps its
  ordinary meaning there. Read the open panes back from `paneOverlays` in `tree --json`.
- `session overlay resize (--size-percent N | --full) [--target] [--window W]` — resize an ALREADY-OPEN
  overlay in place. Exactly one of `--size-percent N` (1–100, makes it a floating framed panel) or
  `--full` (switches it back to the full-pane overlay that hides the session) is required; passing both
  or neither, or a percent outside 1–100, is an error. The overlay program keeps running across the
  resize — it is a layout re-flow, never a re-spawn. Errors `no overlay` when none is open. Returns the
  session id. It has no `--pane`: pane overlays are always full-pane, and passing one errors.
- `session overlay close [--pane left|right] [--target] [--window W]` — close (destroy) the overlay.
  `--pane` closes that split pane's overlay; omit it for the session-wide one.
- `session overlay result [--pane left|right] [--target] [--window W]` — returns `result.exitCode` once
  the overlay has closed. Errors `overlay still running` while up, `no overlay result` if none ran.
  `--pane` reads that pane's overlay; omit it for the session-wide one.

**Displaying an image inline.** This skill bundles `scripts/show-image.sh`. It opens an overlay (a
real terminal surface) and renders the image there via the kitty graphics protocol, which ghostty —
agterm's engine — draws natively. No kitty binary and no external image viewer are used; the encoder
is plain `base64` + `printf`. Run it as `bash <skill-dir>/scripts/show-image.sh <image> [size-percent]`,
resolving `<skill-dir>` as the directory `SKILL.md` was loaded from rather than a fixed path — the skill
ships both as a plugin (`~/.claude/plugins/cache/…`, `~/.codex/plugins/cache/…`) and as the app's own
copy (`~/.claude/skills/agterm/`, `~/.codex/skills/agterm/`), and the script sits beside `SKILL.md` in
every one of them.
The image is scaled to fit the overlay and centered in it (uniform, aspect preserved, up or down): the
script asks the terminal for its pixel and cell geometry over `/dev/tty`, reads the image dimensions
with `sips`, and gives the graphics command an explicit cell box. If the terminal does not answer the
geometry query it falls back to drawing at native pixel size in the top-left corner.
Two simpler routes fail and are why the overlay is needed: emitting graphics escapes to the agent's own
tool stdout (the harness escapes the control bytes) and running an image viewer in the agent's tool
shell (no controlling terminal — `/dev/tty` errors). See examples.md for usage.

## window

- `window new [name] [--minimized]` — create and open a window; returns its id. It replies only once
  the on-screen window exists, so an immediate `window resize`/`move` on the returned id works.
  `--minimized` parks it in the Dock right after creating it, and leaves frontmost on a window you can
  still see — for building a set of project windows and ending up on one you are looking at. The window
  is presented briefly before it is parked, so expect it to appear and take focus on its way to the Dock.
- `window list` — `result.windows`, each with `id`, `name`, `open`, `active`, `autoFollowMs` (the
  window's Auto-follow timeout in milliseconds, omitted when the setting is Disabled), and
  `sidebarVisible` (whether that window's sidebar is shown, read from the open window's store — omitted
  for a closed window with no live store), and `geometry` (the open window's live frame `{x, y, width,
  height, display}` in the SAME units `window move`/`window resize` take — `x`/`y` top-left relative to
  `display`, y down — omitted for a closed window; the read side of `window move`/`window resize`, so
  record it, move/resize, then restore the exact frame), plus `fullscreen`, `zoomed` and `minimized`
  (whether the window is in native full screen / zoomed-to-screen / minimized to the Dock — the read side
  of `window fullscreen` / `window zoom` / `window minimize`, so a script can act idempotently; all omitted
  for a closed window). A MINIMIZED window still reports its `geometry` — the frame it comes back to — so a
  re-align script can include one. The `geometry`/`fullscreen`/`zoomed`/`minimized` fields stay current —
  the cache is refreshed when a window moves/resizes/zooms/enters or exits full screen/minimizes or
  restores, so a hand-drag or GUI toggle is reflected without needing another command. (`autoFollowMs`
  still reflects the last cache refresh, since a settings change is rare; and unlike `tree`, `window.list`
  does NOT carry `idleMs` — the live idle metric would freeze in the cache.)
- `window select <id>` — raise it if open, else open it.
- `window close <id>` — close the on-screen window (the bundle is kept; reopen with select).
- `window rename <id> <name>`.
- `window delete <id>` — keep-at-least-one; deleting the last errors.
- `window resize <id> --width W --height H` — frame size in points. The window must be open. The size is
  clamped into `[window min size, the display's visible frame]`, so an oversized or under-min request is
  bounded to fit rather than applied verbatim.
- `window move <id> --x X --y Y [--display N]` — top-left position in points, relative to display `N`
  (default the window's current display; y measured from the display top). The window must be open. The
  origin is clamped so an off-screen request keeps a grabbable strip of the window on the target display.
- `window zoom <id>` — toggle the window between its normal frame and a maximized (fill-screen, NOT
  native fullscreen) frame, via the standard `NSWindow.zoom`. A second call restores the prior frame.
  The window must be open. This is the control half of the double-click-on-header gesture (a plain green-button
  click does native full screen, not zoom — Option-click the green button to zoom); `resize`/`move` are
  control-native, but `zoom` mirrors a GUI action.
- `window fullscreen <id>` — toggle NATIVE macOS full screen (a separate Space, auto-hidden menu bar),
  via `NSWindow.toggleFullScreen`. A second call exits. The window must be open. This is the control half
  of the View ▸ Toggle Full Screen menu item (⌃⌘F, rebindable as `toggle_fullscreen`) and the green
  traffic-light button — distinct from `zoom`, which only maximizes the frame in the same Space.
- `window minimize <id> [on|off|toggle]` — minimize the window to the Dock, or restore it, via
  `NSWindow.miniaturize`/`deminiaturize`. The mode resolves against the window's current state, so `on` and
  `off` are idempotent and only `toggle` (the default) flips. Both positionals are optional and a window
  address is always a hex UUID prefix or `active`, so `window minimize on` is understood as the active
  window. The window must be open, and a window in NATIVE FULL SCREEN is rejected
  (`cannot minimize a full-screen window — window.fullscreen it first`) because AppKit no-ops miniaturize
  there. Restoring puts the window back on screen without making it key — use `window select` to restore
  and raise in one step. This
  is the control half of ⌘M, the yellow traffic-light button, and the Minimize title-bar double-click
  action. Read back as `minimized` on `window list`. The state is LIVE-ONLY: it is never persisted, so
  every window reopens un-minimized after a restart, and a Dock-icon click restores minimized windows.

`window resize`/`move` are control-native (no GUI equivalent — the title bar already drags-to-resize).

## surface

`agtermctl surface zoom [show|hide|toggle] [--target SURFACE_ID|active|quick] [--window W]` — zoom one
terminal surface to fill the window, hiding the sidebar (a slim title-bar strip with the traffic
lights and an exit button remains). `SURFACE_ID` comes from
`agtermctl tree --json` at `.result.tree.workspaces[].sessions[].surfaces[].id`, for example
`surface:<session-id>:right` for the split pane or `surface:<session-id>:overlay-right` for a pane
overlay covering it. Omit `--target` (or pass `active`) to act on the active surface in the
frontmost or `--window` window; `quick` addresses a quick-terminal zoom (the id the command itself
returns when the quick terminal is the zoom target).

`show` is idempotent; `hide` exits zoom and is idempotent too (when an explicit id is provided, it
only clears that same zoom target, and succeeds as a no-op even if that surface has since vanished);
`toggle` enters when unzoomed and exits when that surface is already zoomed. Read the current zoom
back from the tree's top-level `zoomedSurface` (the zoomed surface's control id, omitted when nothing
is zoomed). This is NOT
`window zoom`: it does not change the macOS window frame and it must not mutate split ratios, focus,
sidebar state, or split/scratch visibility. Entering zoom does close the window's transient chrome —
an open command palette, an active in-terminal search, and (for a session-surface zoom) a visible
quick terminal. While zoomed, the hidden deck keeps running: `session.split`/`session.scratch`/overlay
opens on the zoomed session still spawn their shells behind the zoom layer. A notification-banner
click exits zoom before revealing its session. Use `surface zoom` when the user/agent needs a pane
fullscreen inside agterm; use `window zoom` only to maximize the whole window on screen.

## dashboard

`agtermctl dashboard <ids…> [--font-size N | --auto-size] [--window W]` opens a per-window, view-only
grid of the named sessions' live panes; `agtermctl dashboard --mru [--font-size N | --auto-size]
[--window W]` opens the window's most-recently-used sessions instead of naming ids; `agtermctl dashboard
--close [--window W]` closes the open one. The cell unit is a session+pane: a non-split session is ONE
cell, and a SPLIT session shows as TWO cells — its left/primary pane and its right/split pane. The
positional ids are session addresses (id / unique prefix / `active`), each of which may carry a
`:left`/`:right` pane suffix to place THAT PANE ALONE — the same form `dashboardMembers` reports back, so
`dashboard <a>:left <b>:right` grids one pane per session while a bare id still takes every pane of its
session. The suffix composes with any head, so `active:left` and `<prefix>:right` both work, and it is
case-insensitive. Only `left`/`right` are accepted: any other suffix (`:scratch`, `:overlay`, `:primary`,
`:split`, a typo like `:lft`, or a pasted `surface:<id>:left` zoom address) is REJECTED and fails the whole
command. Unresolved ids are dropped — including `:right` on a session with no split, which parses fine but
names no pane — and cells are deduped by session+pane, so a bare id beside a pane ref for the same session
collapses instead of double-hosting a surface. A grid that expands to no cells at all is an error and
leaves any open dashboard untouched. The 9-cell cap counts PANES (laid out `ceil(sqrt(n))`), applied after
each session expands into its pane cells: if the panes exceed 9 the first 9 are kept and the dropped-pane
count is reported in the response text (`dropped N pane(s) beyond the 9-cell limit`, appended to any
`unresolved:` note with `; `). `--window` targets a specific window's dashboard (default: the frontmost).
`--mru` draws its members from the window's recency (most-recent first); it is mutually exclusive with
explicit ids and `--close`, composes with the font flags and `--window`, and errors with `no recent
sessions` when the window has none.

A cell placed by a `:right` ref FOLLOWS its pane through promotion: when a split session's main shell
exits, agterm promotes the survivor into the primary slot, and the grid rewrites that cell to `<id>:left`
rather than dropping it, so a dashboard built to watch an agent in the split pane keeps watching it.

The most-recently-used grid also has a GUI opener — **⌘⇧D** (the `dashboard` built-in action, rebindable
in `keymap.conf`), **Navigate ▸ Dashboard**, and the command palette's **Dashboard** entry all TOGGLE the
frontmost window's dashboard: open it over the window's most-recently-used sessions auto-sized (identical to
`dashboard --mru --auto-size`) when closed, close it when open. It is a no-op while terminal zoom is active.
There is no new control command for it — the socket `dashboard` command is unchanged.

It is **view-only**: no cell takes keyboard or mouse input — the whole grid shows live output, and once
open the keyboard drives it. Arrow keys move a highlight between cells (2-D, no wrap; clamped into a
ragged last row), Enter jumps into the highlighted session AND focuses that exact pane (selecting the
session, focusing the primary pane for a `:left` cell or the split pane for a `:right` cell, then closing
the dashboard), and Esc closes it (leaving the selection as it was). Because a cell takes no input, a
program you dashboard keeps running but you cannot type into it from the grid — jump in with Enter first.

Font size is optional and mutually exclusive: `--font-size N` sets an absolute cell font in points
(must be finite and positive), while `--auto-size` sizes the cells relative to the Settings default font
size, shrinking as the grid grows so a dense 3×3 stays readable. Omit both to leave each pane's own
font untouched. The applied size and mode read back on the tree's top-level `dashboardFontSize` /
`dashboardFontMode`; the member pane refs and the highlighted cell read back on `dashboardMembers` /
`dashboardHighlighted` (each a `<session-id>:left`/`<session-id>:right` pane ref).

The dashboard and terminal zoom are **mutually exclusive**: opening a dashboard closes any active zoom,
and a zoom becoming active while the dashboard is open closes the dashboard. Opening (and closing) the
dashboard resizes each pane's pty to (and back from) its cell, so a running program receives a resize
event and may redraw — "view-only" means no input reaches the cell, not that the pane's process is
untouched.

Invalid invocations error (rejected at the CLI and re-checked server-side): `--font-size` with
`--auto-size`, a non-positive `--font-size`, `--close` combined with ids, `--mru`, or a font option,
`--mru` combined with explicit ids, and an open with neither ids nor `--mru`.

## pick

`agtermctl pick [--prompt TEXT] [--query TEXT] [--allow-custom] [--follow] [--window W] [--no-block]`
reads choices from stdin and opens a native fuzzy picker in the target window. `pick` defaults to the open
subcommand, so `agtermctl pick open` is not required. Stdin is read unconditionally, so a call that supplies
no items needs `< /dev/null` or it blocks.

The first non-whitespace input byte selects the format. `[` starts a JSON array of objects with required
`id` and `label` strings plus an optional `subtitle`; any other input is split into lines, blank and
whitespace-only lines are dropped, and each remaining line becomes both the id and label. Item ids must
be unique, labels must not be empty, labels and subtitles may not contain control characters, and a
picker accepts at most 1,000 items. An empty list is rejected with `pick.open requires at least one item`
unless `--allow-custom` is set, which accepts it and opens a plain text prompt. Omitting `items` altogether
is rejected with `pick.open requires items`, reachable only over the raw protocol: the CLI always sends the
list it parsed, empty or not.

The query matches item labels only; a subtitle is displayed but never searched, so consequence text on one
row cannot filter out its safer neighbour. An empty query lists the items in the order the caller supplied
them, so the first item is the one Return runs on open.

`--prompt` sets the query field's placeholder text. `--query` prefills it and filters on open, which ranks
by match score and so does not preserve the supplied order; the seeded text opens selected, so the first
keystroke replaces it rather than appending. `--allow-custom` adds a row for a nonmatching
query and returns it as a custom result; with an empty item list that row is the only possible one, and it
appears as soon as the query is nonblank, prefilled or typed; whitespace and newlines are trimmed first.
A background `--window` target is not raised by default; `--follow` raises it. Only one picker can be
pending in a window, and a second open fails with `pick already pending`.

The default call polls until the user answers and prints one bare JSON result:

```json
{"result":"picked","id":"production","label":"Production","index":1}
{"result":"custom","query":"new target"}
{"result":"cancelled"}
```

Picked and custom results exit 0. Cancellation exits 2. Protocol, validation, transport, and server
failures exit 1. The blocking client polls every 100 ms for the first second, then every 500 ms.

`--no-block` returns immediately with `{"id":"<pick-id>"}`. Use
`agtermctl pick result <pick-id> [--window W]` for a one-shot read; it prints the same bare result JSON,
including `{"result":"pending"}`, and exits 1 while pending. Use
`agtermctl pick cancel <pick-id> [--window W]` to cancel it. Result and cancel require the exact picker
id. Without `--window`, the globally unique id keeps result/cancel pinned to its owning window even if
the frontmost window changes. With `--window`, a live or close-retained result must belong to that
window. A wrong id returns `unknown pick: <id>`.

Read the live picker id from the tree's top-level `pickPending` field. It is omitted after selection,
custom input, cancellation, or window closure. Closing the picker, closing its window, and ⌘W resolve it
as cancelled. App termination cancels in-memory picker state before stopping the socket, but a client
whose next poll races process shutdown may observe a transport failure instead of the final cancellation.
A terminal result stays readable by its own id after the next picker opens in that window, and after the
window closes — including permanent window deletion — so a blocking caller always reads back the answer
it waited for. Results age out oldest-first: the 8 most recent per open window, and 32 across closed ones.

## quick

`agtermctl quick [show|hide|toggle]` — the frontmost window's quick terminal (a single scratch
terminal at 90% of the window, not in the tree; its shell stays alive across hides). Errors with
`no open window` when none is open. Read its visibility back from the tree's top-level `quickVisible`.
While terminal zoom is active, `show` errors with `terminal zoom active`; `hide` always succeeds (a
zoomed quick terminal exits its zoom first), so cleanup scripts can dismiss it unconditionally.

`agtermctl quick type TEXT` (or `--stdin`) — inject `TEXT` as literal keystrokes into the frontmost
window's quick terminal, the quick-terminal twin of `session type`. There is no `--target`/`--window`
(always the frontmost window's quick terminal) and no `--pane` (a single surface). It polls briefly for
the surface to come up, so `quick show; quick type` back-to-back is reliable (the overlay mounts a beat
after `quick show` flips visibility). Errors with `quick terminal not open` when the overlay has never
been shown, `quick terminal not realized` if a shown surface never comes up in time, `no open window`
when none is open. Typing into a shown-then-hidden quick terminal still works (its shell stays alive).

`agtermctl quick text [--all] [--lines N]` — print the frontmost window's quick-terminal buffer as
plain text (the read-back for `quick type`; does not touch the system clipboard). `--all` reads the
full screen + scrollback, `--lines N` keeps only the last N (mutually exclusive). Polls for the surface
like `quick type`. Errors with `quick terminal not open` (never shown), `failed to read surface buffer`
(shown surface never realized in time), `no open window`.

## sidebar

`agtermctl sidebar [show|hide|toggle]` — show/hide the frontmost window's workspace/session sidebar
(the custom split has no system toggle). `toggle` is the default; an unknown mode is an error, and
`no open window` when none is open. The GUI half is the title-bar button, View ▸ Show/Hide Sidebar,
the ⌃⇧P palette "Toggle Sidebar", and the ⌃⌘S keymap action (`toggle_sidebar`).

`agtermctl sidebar mode [tree|flagged|toggle]` — flip the frontmost window's sidebar VIEW between the
workspace tree and the flat flagged working-set list (the durable per-session `flag`; each flagged row
is labeled `session : workspace`, even across workspaces). `toggle` is the default; idempotent
(delta-computed); an unknown mode is an error, and `no open window` when none is open. Persisted
per-window. While in `flagged` mode, `session go` navigation (and the Ctrl-Tab MRU switcher) is scoped
to the flagged sessions only; back in `tree` it spans the marked workspaces' sessions (while the focus
filter is applied) or all sessions. The GUI half is the bottom-bar flag button, View ▸ Show Flagged / Show All, and the
⌃⇧P palette. Use with `session flag` to build and view a cross-workspace working set.

`agtermctl sidebar expand [--window W]` — expand every workspace row in a window's sidebar tree.
Defaults to the frontmost window; `--window` (id / prefix / `active`) targets any OPEN window, so a
script can expand a background window's tree. Idempotent (a clean no-op when all are already expanded);
a graceful no-op in `flagged` mode (no workspace rows); a named-but-closed window errors, and `no open
window` when none is open. The GUI half (frontmost only) is View ▸ Expand Workspaces and the ⌃⇧P palette
"Expand Workspaces".

`agtermctl sidebar collapse [--window W]` — collapse every workspace EXCEPT the current one (the same
resolution as `--target active`), which stays expanded and is scrolled into view. Same `--window`
selector and defaults as `expand`. Idempotent; a graceful no-op in `flagged` mode; a named-but-closed
window errors, and `no open window` when none is open. The GUI half (frontmost only) is View ▸ Collapse
Workspaces and the ⌃⇧P palette "Collapse Workspaces".

## notify

`agtermctl notify <body> [--title T] [--target] [--window W]` — post a macOS desktop notification
attributed to a session (default: the active session of the frontmost window). `--title` defaults to
the session name. Clicking the banner reveals that session. This is the only app-level way to post a
banner (the terminal's own OSC 9/777 is the other source). Control-native (no GUI/menu equivalent).

The banner is gated by **Settings ▸ Notifications ▸ Show notification banners**; the unseen badge is
not. With banners off the command still succeeds and still raises the badge, but nothing reaches macOS
— so it answers `ok` with an advisory `result.text` (`badge updated, but "Show notification banners" is
off, so no banner was posted`) instead of a bare `ok`. Treat the presence of `result.text` as "no banner
appeared"; a delivered notification carries none. The badge itself reads back on `tree` as `unseen`.

For agentic attention (waiting on input, or a finished result), prefer `session status` over `notify`
and OSC 9/777. The two overlap, either can raise an "I need you" signal, but a notification is a
one-shot banner and badge with no lasting state, while `session status` is a typed, persistent state
(`active`/`blocked`/`completed`) that stays on the row until acted on, is more precise, and drives the
attention list, the title-bar bell, and attention navigation (`session go --to next-attention`). Keep
`notify` for a one-off nudge that needs no follow-up.

## font

`agtermctl font inc|dec|reset [--pane left|right|scratch] [--target] [--window W]` — increase / decrease /
reset the font size of a session pane. `--pane` picks which surface's font to change, like `session type`
and `session text`: omitted or `left` is the main pane, `right` the split pane (errors with `session has
no split pane` when the session has no split), `scratch` the session's scratch terminal (settable even
while hidden). No `other` value. Only the MAIN pane's size is persisted across relaunch; a split/scratch
pane's font change is live-only, matching a GUI cmd +/- on those panes. Read the resulting size back from
`tree` — `fontSize` (main), `splitFontSize`, `scratchFontSize`, each in points and omitted when that pane
isn't realized.

## keymap

`agtermctl keymap reload` — re-read and apply `keymap.conf`; returns `result.count` = the number of
parse diagnostics (0 = clean). App-global (no `--window`).

`agtermctl keymap list` — the read side of `keymap.reload`. App-global, no target and no args. Returns
`result.keymap`:

- `path` — the `keymap.conf` this came from.
- `actions[]` — every rebindable built-in: `action` (its `keymap.conf` name), `chord` (the resolved
  chord in the same kitty syntax the file uses, omitted when the action is keyless), and
  `overridden: true` when a `map` line moved it off its shipped default. Every action is listed, bound
  or not, so you can also see which chords are free.
- `commands[]` — the custom commands: `name`, and `shortcut` omitted for a palette-only one.
- `diagnostics[]` — `line` + `message` per parse problem (`keymap.reload` returns only the count).
- `menu[]` — the key equivalents the menu bar carries: `chord`, the owning `menu`, the item `title`, its
  `selector`, and `enabled: false` when the item is disabled. agterm's own items report `menuAction:`;
  anything else is an AppKit-supplied item. Nested submenus are included, attributed to their top-level
  menu. A disabled item's chord is INERT — AppKit consumes the key and fires nothing, including a
  same-chord sibling — so an entry marked `enabled: false` explains a dead binding by itself.

**`actions` and `menu` can disagree, and that is what this command is for.** SwiftUI rebuilds the menu
only on the next app activation, so right after `keymap reload` a chord can be correct in `actions` and
stale in `menu`. It also resolves a chord collision by unbinding agterm's own item, so a stock item can
end up holding a chord an action claims. If a keybinding "does not work" while `actions` looks right,
compare the two lists: find the action's `chord`, then look for that chord in `menu` and check which
item carries it.

One built-in is legitimately absent from `menu`: `undo_close` (⌘Z by default) is delivered by a key
monitor, not a menu item, so native text undo keeps working in the rename, palette and Settings fields.
Its missing menu entry is expected and not a fault.

Menu chords use the same vocabulary as the file (`cmd+opt+up`, `cmd+shift+return`), so the two lists
compare as plain strings. One exception: the globe/fn modifier prints as `fn+`, which no `keymap.conf`
line can express — such an item is AppKit's own and never matches an action.

### keymap.conf format

The file lives at `<config dir>/keymap.conf` (default `~/.config/agterm`; the dir is set in Settings ▸
Key Mapping). Two verbs, line-based; blank lines and `#` comments ignored:

- `map <chord> <action>` — rebind a built-in menu action to a single chord (no leaders for built-ins).
- `command "<name>" [chord] <shell...>` — define a custom shell command, listed in the action palette
  marked `custom`. The quoted name may contain spaces. The post-name token is the chord only if it
  parses AND carries a modifier (a bare modifier-less key is rejected). A custom chord may be a leader
  sequence (chords joined by `>`, e.g. `ctrl+a>g`). No chord → palette-only.

A **chord** is modifier words joined by `+` then a base key: modifiers `ctrl`, `cmd`, `opt`, `shift`;
base key is a single character or `tab`/`space`/`return`/`delete`/`left`/`right`/`up`/`down`. A key typed
with Shift is written `shift+<base>` (`shift+/` = `?`, `shift+=` = `+`, `shift+5` = `%`) — the base key,
not the shifted glyph. `+`/`>` can't be a bare key token (they are the separators), though those keys are
bindable via `shift+=`/`shift+.`. A `map` line may not bind a bare, modifier-less arrow (`map left …`) —
a built-in rides an always-on menu key-equivalent, so a bare arrow would swallow the key everywhere;
any modifier makes it bindable. Some chords are reserved (the Ctrl-Tab switcher, Ctrl-1/2 pane focus)
and cannot be bound.

Custom-command tokens (expanded into the `/bin/sh -c` line, raw — prefer the quoted `$AGT_*` env form
for untrusted content). A remote host can set the session title (OSC) and working directory (OSC 7),
so `{AGT_SESSION_NAME}` and `{AGT_SESSION_PWD}` are as untrusted as `{AGT_SELECTION}`; use the quoted
`$AGT_*` form for any of them:

- `{AGT_SESSION_NAME}` / `$AGT_SESSION_NAME` — the session's display name (the focused pane's terminal title, remote-settable via OSC).
- `{AGT_SESSION_PWD}` / `$AGT_SESSION_PWD` — the focused pane's working directory.
- `{AGT_SELECTION}` / `$AGT_SELECTION` — the current selection.
- `{AGT_PANE}` / `$AGT_PANE` — the pane the command fired from: `left` (main), `right` (split), or
  `scratch` (the session's scratch terminal). Feed it back as `session type --pane "$AGT_PANE"` to type
  into the very pane the shortcut was pressed in.
- Plus the other `$AGT_*` context vars the runner exports.

Built-in action names for `map` include: `new_window`, `new_workspace`, `new_session`,
`open_directory`, `rename_session`, `duplicate_session`, `close_session`, `reopen_recent`, `undo_close`, `clear_status`, `increase_font_size`,
`decrease_font_size`, `reset_font_size`, `toggle_split`, `toggle_scratch`, `toggle_sidebar`,
`focus_workspace`, `toggle_workspace_filter`, `quick_terminal`,
`session_palette`, `command_palette`, `custom_command_palette`, `dashboard`, and the navigation actions (`previous_session`, `next_session`,
`first_session`, `last_session`, `previous_attention_session`, `next_attention_session`,
`focus_left_pane`, `focus_right_pane`, `select_theme`). Editing the keymap from a terminal: open
`keymap.conf` in `$EDITOR`, then `agtermctl keymap reload`.

## config

`agtermctl config reload` - re-read and apply the ghostty config; returns `result.count` = the ghostty
config-diagnostic count (0 = clean), counted across ALL config sources, not just the agterm-scoped
`ghostty.conf` (libghostty diagnostics do not record which file they came from), so do not read a
non-zero count as proof `ghostty.conf` is the culprit. App-global (no `--window`). It runs the same path
as the GUI's File ▸ Reload Config menu/palette item, which posts a warning banner on diagnostics.

### ghostty.conf

`<config dir>/ghostty.conf` (default `~/.config/agterm`, next to `keymap.conf`) is the agterm-scoped
ghostty config and the place to put agterm overrides/customizations. It is ALWAYS loaded. The app builds
its terminal config in order, each source overriding the one before: ghostty's bundled defaults, then
your global `~/.config/ghostty/config` (OFF by default — opt in with Settings ▸ General ▸ Use my global
Ghostty config), then `<config dir>/ghostty.conf`, then agterm's own Settings (font, theme, background
opacity/blur, scroll speed), which load last and win for the keys the UI manages. The scoped file is
agterm-only; the standalone Ghostty.app never reads it. agterm is self-contained by default, so a config
written for Ghostty.app does not silently change agterm — put agterm overrides in `ghostty.conf` (e.g.
`macos-option-as-alt = true`); the full reference is at https://ghostty.org/docs/config. Editing it from
a terminal: open `ghostty.conf` in `$EDITOR`, then `agtermctl config reload`.

## theme

The app's out-of-the-box default theme is the bundled **agterm** theme (a fresh install opens on it).
A separate **default ghostty** entry means "no theme" — ghostty's own built-in colors (`theme` absent).

`agtermctl theme list` — list the bundled theme names; returns `result.themes` (the names),
`result.theme` (the current plain theme, absent = ghostty's built-in / "default ghostty"), and
`result.sync` with `result.light`/`result.dark` (the per-appearance themes). While syncing,
`result.theme` is absent — the state rides the three sync fields. Human output prints one name per
line with a leading "default ghostty" row, the active one(s) marked `* `; when syncing, a header notes
the light/dark pair and both sides are marked.

`agtermctl theme set [name]` — set and persist the terminal theme app-wide (the same change as Settings
▸ Appearance), per slot:
- `theme set <name>` sets the light/single theme; a dark theme, if set, is KEPT (syncing stays on).
  Omit the name for ghostty's built-in default ("default ghostty") — with a dark theme set, that
  clears BOTH (an unnamed side can't be part of a pair).
- `theme set --dark <name>` sets the dark theme — the terminal then tracks the macOS Light/Dark
  appearance, applying the matching side automatically as the OS switches (the light side seeds from
  the current theme, else `Builtin Light`). `--light <name>` is an alias for the positional name.
- `theme set --dark none` clears the dark theme — tracking stops, the light theme stays as the single
  theme.
The response always echoes the full state (`result.theme`/`sync`/`light`/`dark`). An unknown name
returns `unknown theme: <name>`; a positional name combined with `--light` is a usage error. Human
output prints `ok`. App-global (no `--window`). The GUI's live-preview picker (View ▸ Select Theme…)
is keyboard-only — committing it replaces the CURRENT appearance's side when syncing (the pair is
kept); over the socket `theme set` is the commit, with no preview.

## restore

`agtermctl restore clear` — clear every session's saved CAPTURED foreground command and persist, so the
next restart restores plain shells for those panes (not whatever each pane was running). It does NOT clear
a `session.new --command` session's own command (`initialCommand`, the durable creation identity), which
still re-runs on restore when the setting is on. This is the counterpart to the
opt-in **Restore running commands on restart** setting: that setting captures each pane's foreground
command at a clean quit and re-runs it on relaunch; `restore clear` wipes those saved commands now
(also closing the force-quit re-fire window). App-global (no `--window`), prints `ok`.

Which programs are NOT re-run is controlled by `restore-denylist.conf` in the config directory (one
command name per line, seeded with the terminal multiplexers `tmux`/`screen`/`zellij`). It is a plain
user-edited file read at launch — there is no control command for it.

For a PER-SESSION, per-pane override that pins (or suppresses) what a pane restores, use
`session restore` (in the session section above): it wins over the captured foreground, bypasses the
denylist, and is what a `SessionStart` hook rewrites to reattach a non-idempotent command. `restore clear`
here is app-global and touches only the captured commands, not those overrides.

## Errors you may see

`notFound` / `ambiguous` (target resolution), `no such session`, `invalid split mode` /
`invalid scratch mode`, `session has no split` (focus), `no selection` (copy), `overlay already open` /
`no overlay` / `overlay still running` / `no overlay result` / `pane overlay already open` /
`pane not visible` (overlay), `invalid flag mode` (session flag),
`invalid fit` / `invalid position` / `invalid opacity` / `invalid color` / `text too long` /
`unsupported image (PNG or JPEG only)` / `no such image file` / `image path must not contain control characters` / `invalid background mode` (session background),
`invalid sidebar mode` (sidebar),
`invalid focus mode: <value> (on|off|toggle|add)` (workspace focus over the raw socket; the `agtermctl`
CLI rejects the same value locally with `mode must be one of: on, off, toggle, add`),
`invalid workspace filter mode: <value>` (workspace filter over the raw socket; the CLI rejects it
locally with `mode must be on, off, or toggle`),
`no open window` (quick/sidebar/workspace filter), `quick terminal not open` / `quick terminal not realized` (quick type) /
`failed to read surface buffer` (quick text / session text),
`invalid restore mode` / `session.restore set requires a command` / `command must not contain control characters` /
`command too long (max 1024 bytes)` / `the scratch terminal is never restored` / `unknown pane id` /
`failed to save the restore override, the previous value is still in effect` (session
restore; a `session restore --pane right` on a session with no split also returns `session has no split`),
`window not open`
(resize/move/`--window`), `unknown theme: <name>` (theme set), `unknown sound: <name>` (session status --sound),
`invalid color (expected #rrggbb)` (session status --color),
`invalid shape: <value> (circle|square|triangle|diamond|capsule|star)` (session status --shape over the
raw socket; the `agtermctl` CLI rejects the same value locally with
`shape must be one of: circle, square, triangle, diamond, capsule, star`),
`--pane must be left, right, or scratch` (the `--pane` value check — the `agtermctl` CLI rejects a bad pane
with this for session status/type/text, and over the raw socket `session.status` returns this same string;
`session.type`/`session.text` over the raw socket instead return `invalid pane: <value>`). Unknown commands fail to decode and return a structured error, never a crash.
