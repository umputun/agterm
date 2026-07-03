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
- `--window <id|prefix|active>` (on session/workspace/tree/font/notify commands) picks which window's
  tree to act on; default is the frontmost. With `--window` set, that window must be open. Without it,
  an id/prefix session target is matched across all open windows.
- `window.*` commands take the window selector as a positional argument, default `active` (frontmost).
- A window need not be open to be a `window.*` target (e.g. `window select` opens a closed one).

## tree

`agtermctl tree [--json] [--window W]` — the workspace/session tree. Each session node:
`id`, `name`, `cwd`, `title` (the raw OSC terminal title — e.g. a remote host over SSH — omitted
when none reported; distinct from `name`, the derived sidebar label), `active` (selected),
`split` (split shown), `overlay` (overlay shown), `scratch` (scratch shown), `flagged` (in the
flagged working-set), `status` (the agent-status — `active`|`completed`|`blocked` — omitted when
idle), `foreground`/`splitForeground` (the live argv of each pane's foreground
process — what it is running — omitted when the pane sits at its shell prompt), and `background` (the
background spec set via `session background` — a `{kind, text?, imagePath?, colorHex?, opacity?, fit?,
position?, repeats?}` object; `kind` is `image`/`text`/`color` — omitted when none is set). Workspace nodes carry
`id`, `name`, `active`, `sessions`.

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

- `session new [--cwd DIR] [--workspace W] [--workspace-name NAME] [--create-workspace] [--command CMD] [--name NAME] [--window W]`
  — create a session and focus it; returns the new id. `--cwd` sets the start directory (default
  `$HOME`). The destination workspace is addressed one of two mutually-exclusive ways: `--workspace`
  (id / unique prefix / `active`, the default) or `--workspace-name` (the sidebar label) — the latter
  errors if no workspace has that name unless `--create-workspace` is also passed, which reuses an
  existing one or creates it when absent (idempotent). `--command` runs that command as the session's
  process instead of the login shell (no echoed command line; the session closes when the command
  exits). It runs argv-style (tokenized, quotes respected, but NO shell), so shell operators (`;`,
  `&&`, `$VAR`, redirects, globs) are not interpreted — wrap them yourself: `--command "sh -c '…'"`.
  The command is persisted (`SessionSnapshot.initialCommand`) and re-runs on restore when **Restore
  running commands on restart** is on (default off → a restored session is a plain shell); a live
  captured foreground takes precedence over it. `--name`
  seeds the session's custom name (the sidebar label; blank/omitted leaves the auto basename),
  equivalent to a `session rename` right after create.
- `session close [--target] [--window W]`.
- `session select [--target] [--window W]`.
- `session rename <name> [--target] [--window W]`.
- `session go --to next|prev|first|last|next-attention|prev-attention [--window W]` — move the
  selection relative to the CURRENT one (no `--target`). Operates over the VISIBLE/FILTERED set: the
  flagged sessions in flagged mode, the focused workspace's sessions when a workspace is focused, else
  all sessions (clearing the flag/focus restores the full set). next/prev stop at the ends (no wrap);
  first/last jump to the ends of that set; next-attention/prev-attention step only through the filtered
  sessions needing attention (status blocked/completed), wrapping. Returns the newly selected id.
- `session move <workspace> [--target] [--window W]` — relocate the session to another workspace
  (appends). OR `session move --to up|down|top|bottom [--target]` — reorder within its workspace.
  Exactly one of the positional workspace or `--to` is required.
- `session type <text> [--stdin] [--select] [--target] [--window W]` — inject text as real keystrokes
  (printable runs plus Return for each newline; no bracketed-paste markers). `--stdin` reads the text
  from stdin instead of the argument. `--select` selects (and realizes) a never-shown session before
  injecting. Any realized session is normally typable without `--select`.
- `session copy [--target] [--window W]` — returns `result.text` with the session's current selection.
  Does NOT touch the system clipboard (pipe the returned text into another `session type`). No/empty
  selection → `no selection` error. Selection is readable on any realized session regardless of focus.
- `session text [--all] [--lines N] [--pane left|right] [--target] [--window W]` — returns `result.text`
  with the session's terminal buffer as PLAIN TEXT (no ANSI/color). By default it reads the VISIBLE
  SCREEN of the on-screen pane. `--all` reads the whole buffer including scrollback; `--lines N` reads the
  full buffer and keeps only the last N CONTENT lines (trailing blank rows trimmed; `--all` and `--lines`
  are mutually exclusive and `--lines` must be > 0 — enforced server-side too). `--pane left` reads the
  main pane, `--pane right` the split pane (errors if the session has no split); omit `--pane` for the
  visible pane (the scratch terminal when it covers the session, else the focused pane). NOTE: unlike
  `session focus`, `--pane` here has NO `other` value — only `left`/`right`. A genuinely BLANK screen is
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
  scratch's process instead of a login shell — argv-style (no shell; wrap operators yourself as
  `"sh -c '…'"`) and RUN-ONCE like `session new --command` (after it exits, the next `on` is a plain
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
- `session status <idle|active|completed|blocked> [--blink] [--auto-reset] [--sound NAME] [--target] [--window W]` —
  set the sidebar agent-status glyph. `--blink` pulses it (for attention). `--auto-reset` clears it
  back to idle once the session is visited (use for a one-shot completion flash). `--sound` plays a
  one-shot sound when the status is set: `default` (the system alert sound) or a system sound name
  (`Basso`, `Blow`, `Bottle`, `Frog`, `Funk`, `Glass`, `Hero`, `Morse`, `Ping`, `Pop`, `Purr`,
  `Sosumi`, `Submarine`, `Tink`; also any custom sound in `~/Library/Sounds`) — an unknown name errors.
  Without `--sound`, a `blocked` status plays the user's Settings "Blocked sound" if they configured one
  (Appearance ▸ Agent Status; off by default); an explicit `--sound` always overrides it.
  An unknown state errors. Setting non-idle is for agents/hooks; `idle` clears it (also available in the GUI).
- `session flag [on|off|toggle|clear] [--target] [--window W]` — flag/unflag a session for the flagged
  working-set view (a durable, persisted membership). `on`/`off`/`toggle` act on `--target` (default
  `active`) and are idempotent; `clear` ignores the target and unflags every session in the window.
  Pair with `sidebar mode flagged` to see just the flagged sessions as a flat `session : workspace`
  list. Unknown mode errors. The tree's `flagged` flag tracks membership.
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
- `session overlay open <command> [--cwd DIR] [--wait] [--block] [--size-percent N] [--background-color #rrggbb] [--target] [--window W]`
  — run `command` in an ephemeral terminal on top of the session; it closes when the command exits.
  Full-size by default (hides the session); `--size-percent N` (1–100) makes it a floating framed panel
  with the session visible behind. `--background-color #rrggbb` gives the overlay pane its own solid
  background color, independent of the session's own `session background color` (nil = the default theme
  background); it honors the Settings window translucency, captured when the overlay opens. `--wait` keeps the overlay open after the command exits (press a key
  to close). `--block` waits for the command to exit and makes agtermctl exit with the command's status
  (cannot combine with `--wait`); the program renders normally — capture its OUTPUT via the program's
  own output file, not the control channel. Returns the overlay's session id. `--target` defaults to
  `active`, so an automated caller should pass `--target "$AGTERM_SESSION_ID"` — otherwise a (usually
  blocking, full-pane) overlay lands on whatever session is currently active, not the calling one.
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
- `window list` — `result.windows`, each with `id`, `name`, `open`, `active`.
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
  The window must be open. This is the control half of the double-click-on-header gesture (and the green
  zoom button); `resize`/`move` are control-native, but `zoom` mirrors a GUI action.

`window resize`/`move` are control-native (no GUI equivalent — the title bar already drags-to-resize).

## quick

`agtermctl quick [show|hide|toggle]` — the frontmost window's quick terminal (a single scratch
terminal at 90% of the window, not in the tree; its shell stays alive across hides). Errors with
`no open window` when none is open.

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
base key is a single character or `tab`/`space`/`return`/`delete`. Arrows, `+`, and `>` are not
expressible as a parsed chord. Some chords are reserved (the Ctrl-Tab switcher, Ctrl-1/2 pane focus)
and cannot be bound.

Custom-command tokens (expanded into the `/bin/sh -c` line, raw — prefer the quoted `$AGT_*` env form
for untrusted content). A remote host can set the session title (OSC) and working directory (OSC 7),
so `{AGT_SESSION_NAME}` and `{AGT_SESSION_PWD}` are as untrusted as `{AGT_SELECTION}`; use the quoted
`$AGT_*` form for any of them:

- `{AGT_SESSION_NAME}` / `$AGT_SESSION_NAME` — the session's display name (the focused pane's terminal title, remote-settable via OSC).
- `{AGT_SESSION_PWD}` / `$AGT_SESSION_PWD` — the focused pane's working directory.
- `{AGT_SELECTION}` / `$AGT_SELECTION` — the current selection.
- Plus the other `$AGT_*` context vars the runner exports.

Built-in action names for `map` include: `new_window`, `new_workspace`, `new_session`,
`open_directory`, `rename_session`, `close_session`, `clear_status`, `increase_font_size`,
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

`agtermctl theme list` — list the bundled theme names; returns `result.themes` (the names) and
`result.theme` (the current one, absent = ghostty's built-in / "default ghostty"). Human output prints
one name per line with a leading "default ghostty" row, the current one marked `* `.

`agtermctl theme set [name]` — set and persist the terminal theme app-wide (the same change as Settings
▸ Appearance ▸ Theme). Pass a bundled name (e.g. `agterm`); omit the name for ghostty's built-in
default ("default ghostty"). An unknown name returns `unknown theme: <name>`. Returns `result.theme`
= the applied name (absent = ghostty built-in); human output prints `ok`. App-global (no `--window`).
The GUI's live-preview picker (View ▸ Select Theme…) is keyboard-only; over the socket `theme set` is
the commit, with no preview.

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
`no open window` (quick/sidebar), `window not open`
(resize/move/`--window`), `unknown theme: <name>` (theme set), `unknown sound: <name>` (session status --sound). Unknown commands fail to decode and return a structured error, never a crash.
