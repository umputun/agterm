# agterm control reference

Full detail for every `agtermctl` command. See `SKILL.md` for the model and addressing overview, and
`examples.md` for recipes.

## Connection and output

- **Socket resolution** (when `--socket` is omitted): `AGTERM_SOCKET` is the path the running app
  bound; agtermctl resolves the same rendezvous: `<AGTERM_STATE_DIR>/agterm.sock`, else
  `<$HOME>/Library/Application Support/agterm/agterm.sock`. Passing `--socket "$AGTERM_SOCKET"` is the
  safe explicit form.
- **`--json`**: prints the raw response object. Without it, mutations print `ok` and `tree`/`window
  list` print a human listing. Use `--json` when you need to read ids or values back.
- **Response shape**: `{"ok": true, "result": {…}}` or `{"ok": false, "error": "<message>"}`.
  `result` carries one of: `id` (affected/new session/workspace/window), `text` (session copy/text),
  `exitCode` (overlay result), `count` (keymap diagnostics), `tree` (the tree), `windows` (window
  list). The process exit code is non-zero when `ok` is false.
- **Options go after the subcommand**: `agtermctl session type "ls" --target active`, never before it.

## Addressing

- `--target` defaults to `active` (the selected session / current workspace). Accepts a full UUID
  (case-insensitive) or a unique prefix. Zero matches → `notFound`; ambiguous prefix → `ambiguous`
  (the error lists candidates).
- **For an agent, `active` is the USER's GUI-selected session, not yours.** Your shell is
  `$AGTERM_SESSION_ID`; the user is usually on a different session while you work. Pass
  `--target "$AGTERM_SESSION_ID"` on any session-scoped command (`overlay open`, `scratch`, `type`,
  `text`, `background`, `status`, `copy`, …) that must act on the session you run in — otherwise it hits
  whatever the user has selected. `overlay open` opens in the background without switching the user
  (both full and floating); pass `--follow` to additionally SELECT the target, switching the user to it.
- `--window <id|prefix|active>` (on session/workspace/tree/font/notify commands) picks which window's
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
to restore focus via `session focus --pane left|right`), `overlay` (overlay shown),
`overlaySizePercent` (an open overlay's size — the
floating panel's percent of the pane, 1–100; omitted = a full-pane overlay or no overlay, so gate on
`overlay` first; the read side of `session overlay resize`, e.g. record it before switching to `--full`
to restore the exact size), `scratch` (scratch shown), `flagged` (in the
flagged working-set), `status` (the agent-status — `active`|`completed`|`blocked` — omitted when
idle), `statusPane` (which pane set that status — `left` (main) | `right` (split) | `scratch` — the
`--pane` value from `session status`, omitted when unset or idle; gated on the same non-idle condition
as `status`, so it is never reported without a `status`), `statusBlink` (`true` when the status glyph is
set to blink — the `--blink` value; omitted when idle or not blinking) and `statusColor` (the `#rrggbb`
glyph-tint override — the `--color` value; omitted when idle or using the default color),
`foreground`/`splitForeground` (the live argv of each pane's foreground
process — what it is running — omitted when the pane sits at its shell prompt), and `background` (the
background spec set via `session background` — a `{kind, text?, imagePath?, colorHex?, opacity?, fit?,
position?, repeats?}` object; `kind` is `image`/`text`/`color` — omitted when none is set), and `unseen`
(the unseen-notification badge count — raised by `notify`/OSC 9/777, cleared by `session seen` — omitted
when zero). Workspace nodes carry `id`, `name`, `active`, `sessions`, and `focused` (whether the sidebar
tree is collapsed to this workspace — the read side of `workspace focus`, distinct from `active` the
SELECTED workspace; omitted unless this is the focused one, and absent entirely when nothing is focused).

The tree object itself carries five top-level read-only fields: `idleMs` (milliseconds since the last
user input in the window, omitted before any activity), `autoFollowMs` (the window's Auto-follow
timeout in milliseconds, omitted when the setting is Disabled), `sidebarVisible` (whether the
window's sidebar is currently shown — the read side of the write-only `sidebar` command, so a script
can restore it, e.g. a tmux-style zoom that hides the sidebar and must re-show it only when it was
visible before), `sidebarMode` (`tree` or `flagged` — the sidebar view mode, the read side of
`sidebar mode`), and `quickVisible` (whether the window's quick terminal is currently shown — the read
side of the write-only `quick` command, so a script can make the toggle idempotent). `idleMs` is live
and grows while the window is idle, so it is on `tree` only, never `window.list`; `sidebarVisible` is on
both; `sidebarMode` and `quickVisible` are `tree`-only (a GUI toggle would leave a cached copy stale).
All five are read-only projections of GUI state.

## workspace

- `workspace new [name] [--window W]` — create a workspace; returns its id. Name defaults to an
  auto-generated one.
- `workspace rename <name> [--target] [--window W]`.
- `workspace delete [--target] [--window W]` — keep-at-least-one; deleting the last workspace errors.
- `workspace select [--target] [--window W]`.
- `workspace move --to up|down|top|bottom [--target] [--window W]` — reorder among siblings. Missing
  or invalid `--to` errors. Note: `--target active` resolves to the current workspace, which with no
  selected session falls back to the last workspace; address a specific workspace by id to step the
  same one.
- `workspace focus [on|off|toggle] [--target] [--window W]` — collapse the sidebar tree to a single
  workspace's subtree (hiding the others), or restore the full tree; returns the workspace id. `on`
  focuses the target, `off` unfocuses it only when it is the currently focused one, `toggle` (default)
  flips. Per-window and persisted; orthogonal to `sidebar mode` (the flagged flat list ignores focus).
  While a workspace is focused, `session go` navigation is scoped to that workspace's sessions (and to
  the flagged set in flagged mode); an explicit `session select` of a session outside the focused
  workspace still auto-unfocuses to reveal it. An unknown mode errors.

## session

- `session new [--cwd DIR] [--workspace W] [--workspace-name NAME] [--create-workspace] [--command CMD] [--name NAME] [--after SID | --before SID] [--window W]`
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
  right after the current session in one round-trip.
- `session close [--target] [--window W]`.
- `session select [--target] [--window W]`.
- `session rename <name> [--target] [--window W]`.
- `session go --to next|prev|first|last|next-attention|prev-attention [--window W]` — move the
  selection relative to the CURRENT one (no `--target`). Operates over the VISIBLE/FILTERED set: the
  flagged sessions in flagged mode, the focused workspace's sessions when a workspace is focused, else
  all sessions (clearing the flag/focus restores the full set). next/prev wrap around at the ends (last→first,
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
- `session type <text> [--stdin] [--select] [--pane left|right|scratch] [--target] [--window W]` — inject text
  as real keystrokes (printable runs plus Return for each newline; no bracketed-paste markers).
  `--stdin` reads the text from stdin instead of the argument. `--select` selects (and realizes) a
  never-shown session before injecting. Any realized session is normally typable without `--select`.
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
  split DIVIDER (the divider is otherwise mouse-drag only; there is no GUI/menu/keymap action, so bind a
  key by mapping a `command "agtermctl session resize …"` custom action). Provide exactly one form:
  `--split-ratio` sets the absolute left-pane fraction (`0..1`); `--grow-left D` / `--grow-right D` nudge
  it by the fraction `D` (grow-left shrinks the right pane and vice-versa). The result is clamped to
  `0.05..0.95` and persisted, and the applied (clamped) fraction is printed (and returned as `result.ratio`
  under `--json`). Errors when the session has no split. Resizing a hidden split updates the stored
  fraction; it takes effect when the split is next shown.
- `session status <idle|active|completed|blocked> [--blink] [--auto-reset] [--sound NAME] [--color #rrggbb] [--pane left|right|scratch] [--target] [--window W]` —
  set the sidebar agent-status glyph. `--blink` pulses it (for attention). `--auto-reset` clears it
  back to idle once the session is visited (use for a one-shot completion flash). `--sound` plays a
  one-shot sound when the status is set: `default` (the system alert sound) or a system sound name
  (`Basso`, `Blow`, `Bottle`, `Frog`, `Funk`, `Glass`, `Hero`, `Morse`, `Ping`, `Pop`, `Purr`,
  `Sosumi`, `Submarine`, `Tink`; also any custom sound in `~/Library/Sounds`) — an unknown name errors.
  Without `--sound`, a `blocked` status plays the user's Settings "Blocked sound" if they configured one
  (Appearance ▸ Agent Status; off by default); an explicit `--sound` always overrides it.
  `--color` (`#rrggbb`) overrides the glyph tint for THIS call only — it rides the status, so the next
  `session status` without `--color` reverts to the Settings-configured color (a malformed hex errors).
  Use it to distinguish states beyond the fixed palette (e.g. a caller-specific blocked color).
  `--pane` (`left`|`right`|`scratch`, `left`=main, `right`=split; defaults to `left` when omitted) records
  which pane set the status. It has two effects: (1) keystroke-clear becomes pane-scoped — a status set
  from a background pane survives typing in a DIFFERENT pane (so a `right`- or `scratch`-tagged block is
  no longer wiped by foreground typing in the main pane, and only a keystroke in the OWNING pane clears
  it), and (2) any user-initiated GUI selection of the session lands on the tagged pane — auto-follow,
  the attention-nav (⌃⌥↑/⌃⌥↓, the Navigate menu), plain session nav (⌥⌘↑/↓/first/last),
  the command palettes, and a sidebar row click all reveal and focus it, flipping to the split or
  showing a hidden scratch instead of the main pane. (The socket `session go next-attention|prev-attention`
  only STEPS the selection to attention sessions; it does not itself move focus into the tagged pane — the
  reveal is a GUI/auto-follow concern.) An agent that runs in a split or scratch should set its own pane so
  the user lands on it. The value is read back on `tree` as the session node's `statusPane`. An invalid
  value errors (`--pane must be left, right, or scratch`).
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
  opacity/blur instead of forcing the pane opaque like the image/text watermark. Errors on a malformed
  color (must be a `#rrggbb` hex value).
- `session background clear [--target] [--window W]` — remove the session's background.
  Per session (applies to the session's pane(s)); persisted, so it survives a relaunch. An image/text
  watermark makes the pane render OPAQUE, overriding window translucency (an image is invisible at 0
  background-opacity); a `color` instead honors the Settings window translucency. Read the current
  background back from a session's `background` field in `tree --json` (a `{kind, colorHex, …}` object,
  omitted when none).
- `session overlay open <command> [--cwd DIR] [--wait] [--block] [--size-percent N] [--background-color #rrggbb] [--follow] [--target] [--window W]`
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
- `session overlay resize (--size-percent N | --full) [--target] [--window W]` — resize an ALREADY-OPEN
  overlay in place. Exactly one of `--size-percent N` (1–100, makes it a floating framed panel) or
  `--full` (switches it back to the full-pane overlay that hides the session) is required; passing both
  or neither, or a percent outside 1–100, is an error. The overlay program keeps running across the
  resize — it is a layout re-flow, never a re-spawn. Errors `no overlay` when none is open. Returns the
  session id.
- `session overlay close [--target] [--window W]` — close (destroy) the overlay.
- `session overlay result [--target] [--window W]` — returns `result.exitCode` once the overlay has
  closed. Errors `still running` while up, `no result` if none ran.

**Displaying an image inline.** This skill bundles `scripts/show-image.sh`. It opens an overlay (a
real terminal surface) and renders the image there via the kitty graphics protocol, which ghostty —
agterm's engine — draws natively. No kitty binary and no external image viewer are used; the encoder
is plain `base64` + `printf`. Run it as `bash <skill-dir>/scripts/show-image.sh <image> [size-percent]`
(the skill installs to `~/.claude/skills/agterm/` and `~/.codex/skills/agterm/`, so the path is
`~/.claude/skills/agterm/scripts/show-image.sh` or `~/.codex/skills/agterm/scripts/show-image.sh`).
Two simpler routes fail and are why the overlay is needed: emitting graphics escapes to the agent's own
tool stdout (the harness escapes the control bytes) and running an image viewer in the agent's tool
shell (no controlling terminal — `/dev/tty` errors). See examples.md for usage.

## window

- `window new [name]` — create and open a window; returns its id.
- `window list` — `result.windows`, each with `id`, `name`, `open`, `active`, `autoFollowMs` (the
  window's Auto-follow timeout in milliseconds, omitted when the setting is Disabled), and
  `sidebarVisible` (whether that window's sidebar is shown, read from the open window's store — omitted
  for a closed window with no live store), and `geometry` (the open window's live frame `{x, y, width,
  height, display}` in the SAME units `window move`/`window resize` take — `x`/`y` top-left relative to
  `display`, y down — omitted for a closed window; the read side of `window move`/`window resize`, so
  record it, move/resize, then restore the exact frame), plus `fullscreen` and `zoomed` (whether the
  window is in native full screen / zoomed-to-screen — the read side of `window fullscreen` / `window
  zoom`, so a script can make those toggles idempotent; both omitted for a closed window). The
  `geometry`/`fullscreen`/`zoomed` fields stay current — the cache is refreshed when a window
  moves/resizes/zooms/enters or exits full screen, so a hand-drag or GUI toggle is reflected without needing
  another command. (`autoFollowMs` still reflects the last cache refresh, since a settings change is rare;
  and unlike `tree`, `window.list` does NOT carry `idleMs` — the live idle metric would freeze in the cache.)
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

`window resize`/`move` are control-native (no GUI equivalent — the title bar already drags-to-resize).

## quick

`agtermctl quick [show|hide|toggle]` — the frontmost window's quick terminal (a single scratch
terminal at 90% of the window, not in the tree; its shell stays alive across hides). Errors with
`no open window` when none is open. Read its visibility back from the tree's top-level `quickVisible`.

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
to the flagged sessions only; back in `tree` it spans the focused workspace's sessions (when focused)
or all sessions. The GUI half is the bottom-bar flag button, View ▸ Show Flagged / Show All, and the
⌃⇧P palette. Use with `session flag` to build and view a cross-workspace working set.

`agtermctl sidebar expand [--window W]` — expand every workspace row in a window's sidebar tree.
Defaults to the frontmost window; `--window` (id / prefix / `active`) targets any OPEN window, so a
script can expand a background window's tree. Idempotent (a clean no-op when all are already expanded);
a graceful no-op in `flagged` mode (no workspace rows); a named-but-closed window errors, and `no open
window` when none is open. The GUI half (frontmost only) is View ▸ Expand Workspaces and the ⌃⇧P palette
"Expand Workspaces".

`agtermctl sidebar collapse [--window W]` — collapse every workspace EXCEPT the active one (the
workspace of the active session), which stays expanded and is scrolled into view. Same `--window`
selector and defaults as `expand`. Idempotent; a graceful no-op in `flagged` mode; a named-but-closed
window errors, and `no open window` when none is open. The GUI half (frontmost only) is View ▸ Collapse
Workspaces and the ⌃⇧P palette "Collapse Workspaces".

## notify

`agtermctl notify <body> [--title T] [--target] [--window W]` — post a macOS desktop notification
attributed to a session (default: the active session of the frontmost window). `--title` defaults to
the session name. Clicking the banner reveals that session. This is the only app-level way to post a
banner (the terminal's own OSC 9/777 is the other source). Control-native (no GUI/menu equivalent).

For agentic attention (waiting on input, or a finished result), prefer `session status` over `notify`
and OSC 9/777. The two overlap, either can raise an "I need you" signal, but a notification is a
one-shot banner and badge with no lasting state, while `session status` is a typed, persistent state
(`active`/`blocked`/`completed`) that stays on the row until acted on, is more precise, and drives the
attention list, the title-bar bell, and attention navigation (`session go --to next-attention`). Keep
`notify` for a one-off nudge that needs no follow-up.

## font

`agtermctl font inc|dec|reset [--target] [--window W]` — increase / decrease / reset the font size on
the focused surface.

## keymap

`agtermctl keymap reload` — re-read and apply `keymap.conf`; returns `result.count` = the number of
parse diagnostics (0 = clean). App-global (no `--window`).

### keymap.conf format

The file lives at `<config dir>/keymap.conf` (default `~/.config/agterm`; the dir is set in Settings ▸
Key Mapping). Two verbs, line-based; blank lines and `#` comments ignored:

- `map <chord> <action>` — rebind a built-in menu action to a single chord (no leaders for built-ins).
- `command "<name>" [chord] <shell...>` — define a custom shell command, listed in the action palette
  marked `custom`. The quoted name may contain spaces. The post-name token is the chord only if it
  parses AND carries a modifier (a bare modifier-less key is rejected). A custom chord may be a leader
  sequence (chords joined by `>`, e.g. `ctrl+a>g`). No chord → palette-only.

A **chord** is modifier words joined by `+` then a base key: modifiers `ctrl`, `cmd`, `opt`, `shift`;
base key is a single character or `tab`/`space`/`return`/`delete`. A key typed with Shift is written
`shift+<base>` (`shift+/` = `?`, `shift+=` = `+`, `shift+5` = `%`) — the base key, not the shifted glyph.
Arrows aren't expressible, and `+`/`>` can't be a bare key token (they are the separators), though those
keys are bindable via `shift+=`/`shift+.`. Some chords are reserved (the Ctrl-Tab switcher, Ctrl-1/2 pane
focus) and cannot be bound.

Custom-command tokens (expanded into the `/bin/sh -c` line, raw — prefer the quoted `$AGT_*` env form
for untrusted content). A remote host can set the session title (OSC) and working directory (OSC 7),
so `{AGT_SESSION_NAME}` and `{AGT_SESSION_PWD}` are as untrusted as `{AGT_SELECTION}`; use the quoted
`$AGT_*` form for any of them:

- `{AGT_SESSION_NAME}` / `$AGT_SESSION_NAME` — the session's display name (the focused pane's terminal title, remote-settable via OSC).
- `{AGT_SESSION_PWD}` / `$AGT_SESSION_PWD` — the focused pane's working directory.
- `{AGT_SELECTION}` / `$AGT_SELECTION` — the current selection.
- `{AGT_PANE}` / `$AGT_PANE` — the pane the command fired from: `left` (main) or `right` (split). Feed
  it back as `session type --pane "$AGT_PANE"` to type into the very pane the shortcut was pressed in.
- Plus the other `$AGT_*` context vars the runner exports.

Built-in action names for `map` include: `new_window`, `new_workspace`, `new_session`,
`open_directory`, `rename_session`, `close_session`, `reopen_recent`, `undo_close`, `clear_status`, `increase_font_size`,
`decrease_font_size`, `reset_font_size`, `toggle_split`, `toggle_scratch`, `toggle_sidebar`, `quick_terminal`,
`session_palette`, `command_palette`, `custom_command_palette`, and the navigation actions (`previous_session`, `next_session`,
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

## Errors you may see

`notFound` / `ambiguous` (target resolution), `no such session`, `invalid split mode` /
`invalid scratch mode`, `session has no split` (focus), `no selection` (copy), `overlay already open` /
`no overlay` / `still running` / `no result` (overlay), `invalid flag mode` (session flag),
`invalid fit` / `invalid position` / `invalid opacity` / `invalid color` / `text too long` /
`unsupported image (PNG or JPEG only)` / `no such image file` / `image path must not contain control characters` / `invalid background mode` (session background),
`invalid sidebar mode` (sidebar), `invalid focus mode` (workspace focus),
`no open window` (quick/sidebar), `quick terminal not open` / `quick terminal not realized` (quick type) /
`failed to read surface buffer` (quick text / session text), `window not open`
(resize/move/`--window`), `unknown theme: <name>` (theme set), `unknown sound: <name>` (session status --sound),
`invalid color (expected #rrggbb)` (session status --color),
`--pane must be left, right, or scratch` (the `--pane` value check — the `agtermctl` CLI rejects a bad pane
with this for session status/type/text, and over the raw socket `session.status` returns this same string;
`session.type`/`session.text` over the raw socket instead return `invalid pane: <value>`). Unknown commands fail to decode and return a structured error, never a crash.
