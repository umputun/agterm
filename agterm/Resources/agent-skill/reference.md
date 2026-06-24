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
  `result` carries one of: `id` (affected/new session/workspace/window), `text` (session copy),
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
`id`, `name`, `cwd`, `active` (selected), `split` (split shown), `overlay` (overlay shown),
`scratch` (scratch shown). Workspace nodes carry `id`, `name`, `active`, `sessions`.

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

## session

- `session new [--cwd DIR] [--workspace W] [--command CMD] [--window W]` — create a session and focus
  it; returns the new id. `--cwd` sets the start directory (default `$HOME`). `--command` runs that
  command as the session's process instead of the login shell (no echoed command line; the session
  closes when the command exits). The command is run-once and not persisted (a restored session is a
  plain shell).
- `session close [--target] [--window W]`.
- `session select [--target] [--window W]`.
- `session rename <name> [--target] [--window W]`.
- `session go --to next|prev|first|last|next-attention|prev-attention [--window W]` — move the
  selection relative to the CURRENT one (no `--target`). next/prev stop at the ends (no wrap); first/
  last jump to the ends; next-attention/prev-attention step only through sessions needing attention
  (status blocked/completed), wrapping. Returns the newly selected id.
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
- `session scratch [on|off|toggle] [--target] [--window W]` — a third, full-coverage shell that
  renders like a full overlay but behaves like the split. `off` hides it keep-alive; typing `exit` in
  it closes it and the next `on` spawns a fresh shell. `on` selects the target first (the scratch is
  full-coverage and owns focus). Not persisted. Unknown mode errors. The tree's `scratch` flag tracks
  visibility.
- `session focus [left|right|other] [--target] [--window W]` — move keyboard focus between the two
  split panes (`other` toggles, the default). Errors when the session is not split.
- `session status <idle|active|completed|blocked> [--blink] [--auto-reset] [--target] [--window W]` —
  set the sidebar agent-status glyph. `--blink` pulses it (for attention). `--auto-reset` clears it
  back to idle once the session is visited (use for a one-shot completion flash). An unknown state
  errors. Setting non-idle is for agents/hooks; `idle` clears it (also available in the GUI).
- `session overlay open <command> [--cwd DIR] [--wait] [--block] [--size-percent N] [--target] [--window W]`
  — run `command` in an ephemeral terminal on top of the session; it closes when the command exits.
  Full-size by default (hides the session); `--size-percent N` (1–100) makes it a floating framed panel
  with the session visible behind. `--wait` keeps the overlay open after the command exits (press a key
  to close). `--block` waits for the command to exit and makes agtermctl exit with the command's status
  (cannot combine with `--wait`); the program renders normally — capture its OUTPUT via the program's
  own output file, not the control channel. Returns the overlay's session id.
- `session overlay close [--target] [--window W]` — close (destroy) the overlay.
- `session overlay result [--target] [--window W]` — returns `result.exitCode` once the overlay has
  closed. Errors `still running` while up, `no result` if none ran.

## window

- `window new [name]` — create and open a window; returns its id.
- `window list` — `result.windows`, each with `id`, `name`, `open`, `active`.
- `window select <id>` — raise it if open, else open it.
- `window close <id>` — close the on-screen window (the bundle is kept; reopen with select).
- `window rename <id> <name>`.
- `window delete <id>` — keep-at-least-one; deleting the last errors.
- `window resize <id> --width W --height H` — frame size in points. The window must be open.
- `window move <id> --x X --y Y [--display N]` — top-left position in points, relative to display `N`
  (default the window's current display; y measured from the display top). The window must be open.

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

## notify

`agtermctl notify <body> [--title T] [--target] [--window W]` — post a macOS desktop notification
attributed to a session (default: the active session of the frontmost window). `--title` defaults to
the session name. Clicking the banner reveals that session. This is the only app-level way to post a
banner (the terminal's own OSC 9/777 is the other source). Control-native (no GUI/menu equivalent).

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
for untrusted content):

- `{AGT_SESSION_PWD}` / `$AGT_SESSION_PWD` — the focused pane's working directory.
- `{AGT_SELECTION}` / `$AGT_SELECTION` — the current selection.
- Plus the other `$AGT_*` context vars the runner exports.

Built-in action names for `map` include: `new_window`, `new_workspace`, `new_session`,
`open_directory`, `rename_session`, `close_session`, `clear_status`, `increase_font_size`,
`decrease_font_size`, `reset_font_size`, `toggle_split`, `toggle_scratch`, `toggle_sidebar`, `quick_terminal`,
`session_palette`, `command_palette`, and the navigation actions (`previous_session`, `next_session`,
`first_session`, `last_session`, `previous_attention_session`, `next_attention_session`,
`focus_left_pane`, `focus_right_pane`). Editing the keymap from a terminal: open `keymap.conf` in
`$EDITOR`, then `agtermctl keymap reload`.

## Errors you may see

`notFound` / `ambiguous` (target resolution), `no such session`, `invalid split mode` /
`invalid scratch mode`, `not split` (focus), `no selection` (copy), `overlay already open` /
`no overlay` / `still running` / `no result` (overlay), `invalid sidebar mode` (sidebar), `no open window` (quick/sidebar), `window not open`
(resize/move/`--window`). Unknown commands fail to decode and return a structured error, never a crash.
