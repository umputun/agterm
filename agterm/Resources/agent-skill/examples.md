# agterm control recipes

Worked `agtermctl` examples. See `reference.md` for exact flags and return shapes. All assume
`agtermctl` is on PATH and you are inside an agterm session (`AGTERM_ENABLED=1`).

## Inspect the current state

```bash
agtermctl tree --json        # workspaces -> sessions, active/split/overlay/scratch/flagged flags, surface ids
agtermctl window list --json # windows, with open/active flags

# what is each pane RUNNING right now (foreground argv; absent at the shell prompt or for a setuid program like top/sudo)
agtermctl tree --json | jq -r '.result.tree.workspaces[].sessions[] | "\(.name): \(.foreground // "shell")"'
```

## Reset the restore-on-restart commands

The opt-in "Restore running commands on restart" setting saves each pane's foreground command at quit.
Clear those saved commands so the next launch restores plain shells:

```bash
agtermctl restore clear
```

## Create a session and type into it

`session new` returns the new id and focuses the session. Capture the id, then type. The session is
realized eagerly, so no `--select` is needed.

```bash
sid=$(agtermctl session new --cwd "$HOME/project" --json | jq -r '.result.id')
agtermctl session type "git status" --target "$sid"
agtermctl session type $'\n' --target "$sid"     # send Return (or include it in the text)
agtermctl session split on --target "$sid"                    # open a split first
agtermctl session type $'ls\n' --target "$sid" --pane right   # then type into the split pane
```

Typing goes to the session's main (left) pane by default; `--pane right` targets the split pane and
errors with `session has no split pane` when there is none. In a custom keymap command, `$AGT_PANE`
holds the pane the shortcut fired from, so `session type --pane "$AGT_PANE"` types back into it.

Run a command AS the session's process (closes when it exits, no echoed command line):

```bash
agtermctl session new --command "ssh host -p 22"     # a default-PATH binary: argv-split (quotes respected), no shell, no echo
agtermctl session new --command "zsh -lc 'htop'"     # Homebrew/non-default binary: --command has the app's GUI PATH, so wrap in a login shell (or use an absolute path); bare "htop" exits 127
```

Create a session pre-named (label set at creation, no follow-up rename):

```bash
agtermctl session new --name "myhost" --command "ssh user@host"
```

Open a session in a named workspace, creating the workspace once and reusing it after (idempotent — no
duplicate "servers" workspace on repeated calls):

```bash
agtermctl session new --workspace-name servers --create-workspace --name "myhost" --command "ssh user@host"
```

## Build a small layout

```bash
ws=$(agtermctl workspace new "build" --json | jq -r '.result.id')
a=$(agtermctl session new --workspace "$ws" --cwd "$HOME/proj" --json | jq -r '.result.id')
agtermctl session rename "server" --target "$a"
agtermctl session split on --target "$a"          # second shell side by side
agtermctl session resize --split-ratio 0.7 --target "$a"   # left pane gets 70% (prints 0.700)
b=$(agtermctl session new --workspace "$ws" --json | jq -r '.result.id')
agtermctl session rename "logs" --target "$b"
```

## Place a session next to another instead of appending

`session new` appends at the end of the workspace by default. `--after`/`--before` place it directly
after/before an anchor session in one round-trip — no `move --to up` walk. The anchor is a session
address (id / unique prefix / `active`) and carries its own workspace, so it names the destination
itself (mutually exclusive with `--workspace`/`--workspace-name`).

```bash
# the headline case: create right after the current session
agtermctl session new --after active

# create right before a specific session (by unique prefix)
agtermctl session new --before 3f2a --name "notes"
```

`session move` gains the same placement mode. Relocate a session and slot it after/before an anchor —
wherever the anchor lives, even in another workspace — in one shot, with no visible row-by-row shuffle:

```bash
# move the current session to sit right after another (cross-workspace if the anchor is elsewhere)
agtermctl session move --after 3f2a --target active
agtermctl session move --before "$logs" --target "$server"

# move several sessions together as one ordered block
agtermctl session move "$ws" --target "$server" --target "$logs"
agtermctl session move --after "$anchor" --target "$server" --target "$logs"

# close several sessions with one grace-period undo
agtermctl session close --target "$server" --target "$logs"
```

`--after`/`--before` are mutually exclusive with each other, with `--to`, and with a destination
workspace — the anchor already picks the workspace. Repeated `--target` is only for workspace and
after/before placement, not `--to up|down|top|bottom`.

## Resize the split divider from a keybinding

The divider is otherwise mouse-drag only — there is no built-in resize action, so bind keys to the CLI
with `command "<name>" <chord> <shell…>` custom actions in `keymap.conf` (then `agtermctl keymap reload`):

```conf
# grow/shrink the left pane by 5% per press; cmd+ctrl+0 resets to an even split
command "grow left pane"  cmd+ctrl+l agtermctl session resize --grow-left 0.05
command "grow right pane" cmd+ctrl+h agtermctl session resize --grow-right 0.05
command "even split"      cmd+ctrl+0 agtermctl session resize --split-ratio 0.5
```

`--split-ratio` is absolute (0..1); `--grow-left`/`--grow-right` are relative nudges. All clamp to
0.05..0.95 and print the applied fraction.

## Run a program in a blocking overlay and read its status

`--block` waits for the program to exit and makes agtermctl exit with the program's status. The
program renders normally in the overlay; read its OUTPUT from the program's own output file.

Pass `--target "$AGTERM_SESSION_ID"` so the overlay attaches to YOUR (the calling) session. Without
`--target` it opens on whatever session is currently active — so if the user has moved to another
session or workspace, an agent (e.g. running revdiff) pops a blocking full-pane overlay on the WRONG
session. Always target your own session for these recipes.

```bash
agtermctl session overlay open "revdiff HEAD~3 --output /tmp/notes.md" --target "$AGTERM_SESSION_ID" --block   # this session
echo "exit status: $?"
cat /tmp/notes.md
```

Floating panel variant (session stays visible behind it). Like a full overlay it opens in the background
without switching the user; add `--follow` when you want the user pulled to the overlay:

```bash
agtermctl session overlay open "zsh -lc 'htop'" --target "$AGTERM_SESSION_ID" --size-percent 70   # login shell so Homebrew's htop is on PATH; bare "htop" flashes open then vanishes (exit 127)
# tint the overlay pane so it stands out from the session behind it:
agtermctl session overlay open "revdiff HEAD~3" --target "$AGTERM_SESSION_ID" --size-percent 80 --background-color "#2a1a3a"
# switch the user to the target as it opens:
agtermctl session overlay open "revdiff HEAD~3" --target "$AGTERM_SESSION_ID" --size-percent 80 --follow
# resize the open overlay in place (the program keeps running): shrink to a floating panel, then back to full
agtermctl session overlay resize --size-percent 60 --target "$AGTERM_SESSION_ID"
agtermctl session overlay resize --full --target "$AGTERM_SESSION_ID"
# ... later
agtermctl session overlay close
```

Manual open + poll for status instead of `--block`:

```bash
agtermctl session overlay open "make test" --target "$AGTERM_SESSION_ID"   # this session
agtermctl session overlay result --json   # errors "still running" until it exits, then result.exitCode
```

## Show an image inline

To show the user an image (a generated favicon, a chart, a preview), run the bundled
`scripts/show-image.sh` with the image path. It opens an overlay (a real terminal) and renders the
image there via the kitty graphics protocol, which ghostty draws natively — no kitty binary and no
external image tool, just `base64` + `printf`. An optional second argument sets the panel size percent
(default 60):

```bash
bash ~/.claude/skills/agterm/scripts/show-image.sh /abs/path/to/img.png 60   # Claude Code
bash ~/.codex/skills/agterm/scripts/show-image.sh /abs/path/to/img.png 60    # Codex
```

The image shows in a floating overlay over the active session; dismiss it with Enter in the panel or
`agtermctl session overlay close`. Do NOT emit graphics escapes to your own tool stdout (the harness
escapes the control bytes) and do NOT run an image viewer in your tool shell (no controlling
terminal) — the overlay's real terminal is what renders.

Tiny images (a favicon) enlarge with nearest-neighbor first, so the pixels stay crisp:

```bash
magick favicon.png -filter point -resize 256x256 /tmp/big.png
```

Outside agterm (`AGTERM_ENABLED` unset) there is no overlay — fall back to `open img.png` (Preview).

## Set a background watermark or color

A persistent backdrop behind the terminal grid (distinct from `show-image.sh`, which is a transient
overlay). An image or rasterized-text watermark (auto-fitting the window, re-fitting on resize), or a
solid terminal background color — per session, surviving a relaunch.

```bash
# rasterized text watermark on this session, faint
agtermctl session background text "STAGING" --color '#ff5500' --opacity 0.15 --target "$AGTERM_SESSION_ID"

# an image (PNG/JPEG), scaled to cover the window
agtermctl session background image /abs/logo.png --fit cover --opacity 0.2 --target "$AGTERM_SESSION_ID"

# a solid background color — e.g. mark a PROD session so it can't be mistaken for a scratch one
agtermctl session background color '#3a0d0d' --target "$AGTERM_SESSION_ID"

# remove it
agtermctl session background clear --target "$AGTERM_SESSION_ID"
```

`--opacity` is 0.0–1.0; `--fit` is `contain` (default) / `cover` / `stretch` / `none`; `--position` is
`center` (default) or an edge/corner anchor. An image/text watermark renders the pane opaque (overriding
window translucency), so it is always visible; a `color` takes no opacity and honors the Settings window
translucency (solid when off, blurred/translucent when on).

## Toggle the scratch terminal

A third per-session full-coverage shell. Hide keeps it alive; `exit` in it recreates on next show.

```bash
agtermctl session scratch on        # show (selects the target)
agtermctl session scratch off       # hide, shell stays alive
agtermctl session scratch toggle
agtermctl session scratch on --command "zsh -lc 'lazygit'"   # run a program instead of a shell (run-once); login-shell wrap so Homebrew's PATH is found (bare "lazygit" exits 127)
```

## Drive the quick terminal

The quick terminal is the window's throwaway overlay (not in the session tree). Show it, type into it,
and read it back — the twins of `session type`/`session text`, but always the frontmost window's quick
terminal (no `--target`/`--pane`).

```bash
agtermctl quick show                                 # drop the overlay over whatever is active
agtermctl quick type 'ls -la'$'\n'                   # inject keystrokes (\n runs it)
echo "some payload" | agtermctl quick type --stdin   # pipe stdin in (e.g. a paste helper)
agtermctl quick text --all                           # read its screen + scrollback back
agtermctl tree | jq .quickVisible                    # is it open right now?
```

## Flag a working set and view just the flagged sessions

Flag a few sessions across workspaces, then flip the sidebar to the flat flagged list (each row labeled
`session : workspace`). The flag is durable (persisted per session); `sidebar mode` is per-window.

```bash
agtermctl session flag on --target "$AGTERM_SESSION_ID"   # flag this session
agtermctl session flag on --target a1b2                   # flag another (any workspace)
agtermctl sidebar mode flagged                            # show only the flagged sessions
agtermctl session go --to next                            # in flagged mode, nav steps the flagged set only
agtermctl sidebar mode tree                               # back to the full tree
agtermctl session flag clear                              # unflag everything in the window
```

## Acknowledge a driven session's notifications without stealing focus

An orchestrator relaying a session's output elsewhere (Telegram, another agent) fires `notify` to signal
"your turn", which raises the session's red unseen badge. Nothing normally clears that badge except
visiting the session — which pulls the selection to it. `session seen` clears it in place, so the badge
stays a real attention signal on the sessions a human tends while the driven ones stay clean.

```bash
agtermctl notify "your turn" --target "$SID"             # raises the unseen badge (body is positional)
agtermctl tree --json | jq '.result.tree.workspaces[].sessions[] | {id, unseen}'  # read the counts
agtermctl session seen --target "$SID"                   # clear it, selection/focus unchanged
```

## Focus a single workspace

Collapse the sidebar tree to one workspace's sessions (hiding the others), with the full tree one
command away. Per-window and persisted; orthogonal to `sidebar mode`. While focused, `session go`
navigation is scoped to that workspace's sessions; unfocusing restores stepping over all sessions.

```bash
agtermctl workspace focus on --target "$AGTERM_WORKSPACE_ID"  # zoom to this workspace
agtermctl workspace focus toggle --target a1b2                # flip focus on another workspace
agtermctl workspace focus off                                 # restore the full tree
```

## Expand or collapse the sidebar tree

Open every workspace at once, or collapse all but the active one (the workspace of the active session,
which stays expanded and scrolled into view) to cut clutter. Defaults to the frontmost window; pass
`--window` to target any open window. A no-op in flagged mode.

```bash
agtermctl sidebar expand                                 # expand every workspace (frontmost window)
agtermctl sidebar collapse                               # collapse all but the active workspace
agtermctl sidebar collapse --window "$AGTERM_WINDOW_ID"  # collapse a specific window's sidebar
```

## Copy a selection and reuse it

`session copy` returns the selection as text (it does not use the system clipboard). Pipe it onward.

```bash
sel=$(agtermctl session copy --json | jq -r '.result.text')
agtermctl session type "$sel" --target "$other"
```

`session select-all` selects the whole buffer, then `session copy` reads it back (or use `session text --all`):

```bash
agtermctl session select-all --target "$other"
buf=$(agtermctl session copy --target "$other" --json | jq -r '.result.text')
```

`session paste` pastes the system clipboard into a session — the socket analogue of ⌘V:

```bash
printf 'deploy staging' | pbcopy
agtermctl session paste --target "$other"   # lands at the prompt, not submitted
```

## Read a session's buffer as text

`session text` returns the terminal buffer as plain text in `result.text` — the visible screen by
default, the whole scrollback with `--all`, or the last N lines with `--lines N`. Pipe it into
`grep`/`fzf` to extract URLs, paths, etc.

```bash
agtermctl session text                         # the visible screen of the focused pane
agtermctl session text --lines 50              # the last 50 lines of the buffer
agtermctl session text --pane right            # the split pane (errors if there is no split)
agtermctl session text --pane scratch --all    # the scratch terminal's full buffer, even while it's hidden
# extract every URL from the full scrollback:
agtermctl session text --all --json | jq -r '.result.text' | grep -oE 'https?://[^ ]+'
```

`--pane scratch` reads (and `session type --pane scratch` writes) the session's scratch terminal whether
or not it is on screen, since its shell is kept alive when hidden. Handy for "I ran a deploy in the
scratch, read its output and tell me what broke" without leaving the scratch open:

```bash
agtermctl session scratch on                             # open the scratch once so it exists
agtermctl session type $'./deploy.sh\n' --pane scratch   # run it in the scratch (even after you hide it)
agtermctl session text --pane scratch --all              # read the result back
```

## Search the terminal scrollback

`session search` opens a search bar over the focused terminal and highlights matches in the live
output. It returns the "N of M" counter; step matches with `--next`/`--prev`, close with `--close`.

```bash
agtermctl session search "error"          # highlight matches, print the counter (e.g. "1 of 7")
agtermctl session search --next           # step to the next match
agtermctl session search --prev           # step back
n=$(agtermctl session search "warn" --json | jq -r '.result.count')   # how many matches
agtermctl session search --close          # close the search bar
```

## Notify the user in a specific session

```bash
agtermctl notify "build finished" --title "CI"                 # active session
agtermctl notify "tests failed" --target "$sid"               # a specific session
```

## Agent status glyph

```bash
agtermctl session status active --blink --target "$AGTERM_SESSION_ID"   # working
agtermctl session status completed --auto-reset --target "$AGTERM_SESSION_ID"  # one-shot done flash
agtermctl session status blocked --sound default --target "$AGTERM_SESSION_ID" # needs input, with a beep
agtermctl session status completed --sound Glass --target "$AGTERM_SESSION_ID" # done, with a named sound
agtermctl session status blocked --color '#ff0000' --target "$AGTERM_SESSION_ID" # per-call red tint (reverts on next status)
agtermctl session status blocked --pane right --target "$AGTERM_SESSION_ID"     # a split-pane agent tags its pane (see below)
agtermctl session status idle --target "$AGTERM_SESSION_ID"             # clear
```

## Tag the blocking pane so navigation lands on it

An agent running in a split or scratch pane sets `--pane` so its block survives foreground typing in
another pane and the user's attention navigation lands on the RIGHT pane — the split, or a hidden scratch,
not the main pane. Auto-follow and any GUI selection — the attention-nav (⌃⌥↑/⌃⌥↓), plain session nav,
the command palettes, and a sidebar row click — reveal and focus the tagged pane; the socket
`session go --to next-attention` only steps the selection, it does not move focus into the pane.
Without `--pane` the status is treated as coming from the main (`left`) pane, so a block set from the split
can be wiped by typing in the main pane and the reveal lands on the wrong surface.

```bash
# an agent working in the split pane; $AGT_PANE is set in a custom keymap command, else name it
agtermctl session status active --pane right --target "$AGTERM_SESSION_ID"   # working, in the split
agtermctl session status blocked --pane right --target "$AGTERM_SESSION_ID"  # needs input; the user's attention nav focuses the split

# an agent working in the scratch terminal (even while it is hidden)
agtermctl session status blocked --pane scratch --target "$AGTERM_SESSION_ID" # the user's attention nav SHOWS + focuses the scratch

# read back which pane blocked
agtermctl tree --json | jq -r '.result.tree.workspaces[].sessions[] | select(.status) | "\(.name): \(.status) in \(.statusPane // "left")"'
```

`--pane left` (or omitting it) is the main pane. Feed a keymap command's `$AGT_PANE` straight through
(`session status blocked --pane "$AGT_PANE"`) to tag the exact pane a shortcut fired from.

The installed agent-status hook also forwards each surface's `$AGTERM_PANE_ID` as `session status --pane-id`,
a stable per-surface token that resolves to the pane's LIVE slot and overrides a stale `--pane` after a split
survivor is promoted into the main pane and then re-split; scripts driving `--pane` directly need not set it.

## Zoom a terminal surface by control id

```bash
# Fill the window with the active terminal surface; call again to leave zoom.
agtermctl surface zoom

# Zoom the active session's right split pane by id, even if the split is hidden.
sid=${AGTERM_SESSION_ID:?}
surface=$(agtermctl tree --json |
  jq -r --arg sid "$sid" '.result.tree.workspaces[].sessions[]
    | select(.id == $sid)
    | .surfaces[]
    | select(.kind == "right")
    | .id')
agtermctl surface zoom show --target "$surface"
agtermctl surface zoom hide --target "$surface"

# Read the current zoom back (the zoomed surface's control id; null when nothing is zoomed).
agtermctl tree --json | jq -r '.result.tree.zoomedSurface'
```

`surface zoom` is not `window zoom`: it does not move/resize the macOS window and must not change split
ratios, sidebar state, focus, or split/scratch visibility. Surface ids come from `tree --json`.

## Watch several sessions at once in a dashboard grid

The dashboard shows several sessions' live output in one view-only grid — for watching several agents or
builds at once. The cell unit is a session+pane: a non-split session is one cell, and a SPLIT session
shows as TWO cells (its left/primary and right/split panes), capped at 9 cells total. No cell takes input:
the keyboard navigates a highlight (arrows), Enter jumps into the highlighted session AND focuses that
exact pane then closes, Esc closes. Open it over the socket with explicit session ids, or with `--mru` to
pull the window's most-recently-used sessions automatically. The most-recently-used grid also has a built-in
opener — **⌘⇧D** (the `dashboard` action), **Navigate ▸ Dashboard**, or the command palette's **Dashboard**
toggle it auto-sized (the `dashboard --mru --auto-size` equivalent), so the recent-sessions view needs no
script for the common case.

```bash
# grid of three sessions, cells auto-sized to the grid (shrinking as it grows)
agtermctl dashboard "$a" "$b" "$c" --auto-size

# no ids: fill the grid from the window's most-recently-used sessions (up to 9, fewer if fewer)
agtermctl dashboard --mru --auto-size

# an absolute cell font in points instead of --auto-size (the two are mutually exclusive)
agtermctl dashboard "$a" "$b" --font-size 12

# open in a specific window (default is the frontmost)
agtermctl dashboard "$a" "$b" --window "$AGTERM_WINDOW_ID"

# read back what the open dashboard is showing (all null when none is open); members are pane refs
# (`<id>:left`/`<id>:right`), so a split session shows both its :left and :right cells
agtermctl tree --json | jq '.result.tree | {dashboardMembers, dashboardHighlighted, dashboardFontSize, dashboardFontMode}'

# close it (or press Enter/Esc in the grid)
agtermctl dashboard --close
```

The MRU grid is already on **⌘⇧D** (the built-in `dashboard` action) — rebind that chord in `keymap.conf`
with `map <chord> dashboard`. To dashboard a FIXED set of explicit ids instead, bind a `keymap.conf` custom
action (then `agtermctl keymap reload`):

```conf
command "Dashboard build hosts" ctrl+a>d /usr/local/bin/agtermctl dashboard "$WEB" "$API" --auto-size
```

`--mru` is mutually exclusive with explicit ids and `--close`, and errors with `no recent sessions` when
the window has none. The 9-cell cap counts PANES (a split session is two cells), so a set whose panes
exceed 9 keeps the first 9 panes and the response reports the dropped-pane count; ids are deduped. The
dashboard and terminal zoom are mutually exclusive (opening one closes the other). Opening/closing resizes
each pane's pty to/from its cell, so a running program may redraw — view-only means no input, not no
process effect.

## Navigate and manage windows

```bash
agtermctl session go --to next            # step selection to the next session
agtermctl session go --to next-attention  # jump to the next blocked/completed session
w=$(agtermctl window new "scratch" --json | jq -r '.result.id')
agtermctl window resize "$w" --width 1200 --height 800
agtermctl window move "$w" --x 100 --y 100 --display 0
agtermctl window zoom "$w"                 # maximize-to-screen toggle (call again to restore)
agtermctl window fullscreen "$w"           # native macOS full screen toggle (⌃⌘F / green button)
agtermctl window select "$w"
```

## Reload the keymap after editing it

```bash
$EDITOR ~/.config/agterm/keymap.conf
agtermctl keymap reload          # prints the parse-diagnostic count (0 = clean)
```

## Change a ghostty setting agterm does not expose

```bash
$EDITOR ~/.config/agterm/ghostty.conf   # e.g. add: macos-option-as-alt = true
agtermctl config reload                 # apply it; prints the diagnostic count (0 = clean)
```

`ghostty.conf` is scoped to agterm and overrides the bundled defaults and your global
`~/.config/ghostty/config`; agterm's own Settings (font, theme, opacity, scroll) still win. Full key
reference: https://ghostty.org/docs/config

## Set the terminal theme

The app default is the bundled `agterm` theme; the "default ghostty" option (no theme) is ghostty's
own built-in colors.

```bash
agtermctl theme list                         # bundled themes, the current one marked *
agtermctl theme list --json | jq -r '.result.themes[]'   # just the names
agtermctl theme set "Dracula"                # set + persist it app-wide (unknown name errors)
agtermctl theme set "agterm"                 # back to the app default theme
agtermctl theme set                          # ghostty's built-in default (no theme)

# follow the macOS Light/Dark appearance automatically — setting a dark theme starts tracking:
agtermctl theme set --dark "agterm"          # light side seeds from the current theme
agtermctl theme set "Builtin Light"          # while tracking, a name replaces the LIGHT side (pair kept)
agtermctl theme list --json | jq '.result | {sync, light, dark}'   # inspect the sync state
agtermctl theme set --dark none              # stop tracking; the light theme stays as the single theme
```

## Targeting another window's tree

```bash
agtermctl tree --json --window work          # the "work" window's tree (prefix match)
agtermctl session new --window work --cwd "$HOME"
```
