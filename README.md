# agterm - modern terminal for agentic flow [![Build Status](https://github.com/umputun/agterm/workflows/build/badge.svg)](https://github.com/umputun/agterm/actions)

`agterm` is a native macOS terminal for working with AI coding agents across many sessions at once. It is intentionally opinionated: rather than scattering shells across tabs, it organizes them into named workspaces, each holding the sessions for one project or context, so several agent-driven sessions can run side by side and you can move between them without losing track of which is which. The motivation is specific: running several coding agents at once means many long-lived sessions, each progressing on its own, and a tabbed terminal loses track of them quickly. agterm keeps them organized and makes it obvious which session needs you. None of this is limited to agents. It also works as a capable general-purpose terminal for everyday multi-project work.

The design is deliberately minimal: it covers the use cases above and stops there. Features come in two kinds. One is just enough to get the work done. The other is the small set of things other terminals get wrong, done the way they should have been. There is no deep agent integration and no attempt to invent a new way of working with agents. You get a sensible minimum out of the box, plus a complete control API and CLI on top. Almost everything is scriptable, so anything past the defaults you build yourself instead of waiting for it to ship.

What sets it apart:

- **Workspace organization.** A vertical, two-level sidebar groups sessions under named workspaces such as "work" and "personal". Sessions split into two shells, open a scratch terminal on demand, drag between workspaces, and are reached by name, recency, or keyboard, so a screen full of concurrent sessions stays legible.
- **Programmatic control.** A bundled command-line tool, `agtermctl`, drives almost everything over a local socket: create sessions, type into them, run a program in an overlay and read its exit status, move and resize windows, or post a desktop notification tied to a specific session. An external script or an AI agent can build and steer its own terminal layout, and notify you in the exact session it was working in, rather than being stuck inside a single shell.
- **A working surface built for flow.** Split a session into two shells, drop a quick scratch terminal over the active one, or run a program in a full or floating overlay without disturbing the session beneath it. Navigation stays on the keyboard: jump to a session by name with a fuzzy palette, flip through a most-recently-used list with Ctrl-Tab for a quick jump back, and step between sessions, panes, and windows with shortcuts. Windows that are open at quit reopen on the next launch.
- **Built to be driven by agents.** agterm ships with an agent skill (Help ▸ Install Agent Skill…) that teaches Claude Code or Codex the control model and the full `agtermctl` command set. An agent running inside agterm can then build its own layout, run overlays, manage windows, and display images inline, without you explaining the API first.
- **Agent status at a glance.** A coding agent reports its state onto its session's sidebar row as a tinted glyph (active, blocked, or completed), so a screen of concurrent agents shows which one needs you. An optional title-bar bell and an attention list (⌃⇧I) surface the same signal when the sidebar is hidden. Wiring it up is automatic: the app installs status hooks for Claude Code and notify and shell scripts for Codex and other agents (Help ▸ Install Agent Status Hooks…).

For the real terminal work, rendering, VT parsing, and shell I/O, `agterm` embeds [Ghostty](https://ghostty.org)'s engine (libghostty); everything above is `agterm`'s own.

![agterm](docs/screenshots/main.png)

<details>
<summary>More screenshots</summary>

An agent's interactive prompt mid-session, with attention glyphs on the sessions that need you:

![Agent prompt](docs/screenshots/agent-prompt.png)

A split session (agent and shell side by side) with the action palette open:

![Action palette](docs/screenshots/action-palette.png)

A full-screen diff TUI running inside a session:

![Diff TUI](docs/screenshots/diff-tui.png)

A file manager in a floating overlay over the active session:

![Floating overlay](docs/screenshots/floating-overlay.png)

The fuzzy session palette for jumping to any session by name:

![Session palette](docs/screenshots/session-palette.png)

A session's right-click context menu:

![Context menu](docs/screenshots/context-menu.png)

The keymap editor:

![Keymap editor](docs/screenshots/keymap-editor.png)

A file open in the quick terminal, the window's shared scratch overlay:

![Quick terminal](docs/screenshots/quick-terminal.png)

</details>

## Install

Pre-built releases are for **Apple Silicon (arm64) Macs running macOS 14 or later**.

These interim builds are ad-hoc signed but **not yet Apple-notarized** (Developer ID enrollment is in progress), so macOS Gatekeeper blocks them until the quarantine flag is removed. This is temporary — once notarized builds ship, they install with no extra step.

Homebrew:

```sh
brew install --cask umputun/apps/agterm
```

The cask strips the quarantine flag on install, so the app opens with no prompt. It also installs the `agtermctl` command-line tool, so cask users should not run the in-app installer as well.

Direct download:

Download the latest `.dmg` from the [releases page](https://github.com/umputun/agterm/releases), open it, and drag `agterm.app` into `/Applications`. Because the build isn't notarized yet, run this once so Gatekeeper lets it launch:

```sh
xattr -cr /Applications/agterm.app
```

(Or try to open it, then click **Open Anyway** in **System Settings → Privacy & Security**. Right-click → Open no longer bypasses Gatekeeper on current macOS.) To put the `agtermctl` CLI on your `PATH`, use **Help ▸ Install Command Line Tool…** from the app.

## Build from source

<details>
<summary>Build steps</summary>

Requirements:

- macOS 14 or later.
- Xcode 26 with `xcodegen` on `PATH`, plus its Metal Toolchain (auto-downloaded on first setup).
- Homebrew, for the `zig@0.15` formula `scripts/setup.sh` builds libghostty with.

```sh
scripts/setup.sh   # build libghostty from ghostty source + stage resources (idempotent; first run takes a few min)
scripts/run.sh     # setup, generate the Xcode project, build Debug, launch
```

A `Makefile` wraps these as a convenience front door: `make run` (build Debug + launch), `make build` (Debug, no launch), `make release` (Release build), `make deploy` (Release build + copy to `~/Applications`), `make test`, and `make dist VERSION=x.y.z` (release DMG — signed + notarized when a Developer ID cert is present, otherwise ad-hoc). Run `make` with no target to list them.

`scripts/build.sh` produces a Release build without launching. The unit tests run independently of Xcode and libghostty:

```sh
cd agtermCore && swift test
```

`scripts/test.sh` is a wrapper for the same command. UI behavior (rename, close, move, drag, add-session) is covered by XCUITests in `agtermUITests/` that drive the running app through the accessibility API:

```sh
xcodebuild test -project agterm.xcodeproj -scheme agterm -destination 'platform=macOS'
```

</details>

## Features

### Workspaces and sessions

- Two-level sidebar tree: workspaces, each containing sessions. Each row carries a leading kind icon: a filled folder for a workspace, an outlined terminal for a session.
- Default session name is the basename of the session's working directory. Renaming a session pins a custom name; clearing it reverts to the basename.
- Add workspaces and sessions from a two-icon bar at the bottom of the sidebar: a workspace button, and a session menu offering **New Session** (a shell in the home directory) and **Open Directory…** (a folder picker that roots the session there). The two session actions are also on each workspace row's right-click menu, so a specific or empty workspace can be targeted.
- Rename inline (double-click a row or use its `Rename` context-menu item). Close a session from its context menu, or it closes itself when the shell exits. Delete a whole workspace from its right-click menu (also in the menu bar and the action palette); a non-empty workspace asks to confirm first, and the last remaining workspace can't be deleted.
- Move a session between workspaces by dragging it onto another workspace, or via the row's `Move to` menu. The session keeps running across the move, with its shell and scrollback intact. Reorder a session within its workspace by dragging it up or down, and reorder workspaces by dragging them. Dropping between two rows places the dragged row at that exact position rather than just appending it.
- Narrow a crowded sidebar two ways. **Flag** a few sessions from across different workspaces (right-click a session → Flag, or the bottom-bar flag button), then flip the sidebar to a flat **flagged working-set** view that shows only them, each labeled `session : workspace` — useful when you work with a handful of sessions spread over many workspaces. The flag is durable (it persists and survives a workspace move). Separately, **focus** a single workspace (its right-click menu) to collapse the tree to just that workspace's sessions and hide the others; a pill showing the focused workspace's name with a ✕ to clear it is the always-visible escape hatch. Focus is independent of the flagged view, and selecting a session outside the focused workspace lifts the focus automatically so it stays visible.

### Terminals: split, scratch, quick, and search

- A quick terminal: a single scratch terminal overlaid at 90% of the window (toolbar button next to the split toggle), opening in the active session's directory. Click the button again or the surrounding margin to dismiss; hiding keeps its shell alive. It is not persisted across launches.
- A per-session scratch terminal (⌘J, the toolbar button next to the split toggle, View ▸ Show/Hide Scratch, or the action palette): a third shell for the session that covers it full-screen like an overlay but, like the split, is always available and just hidden — toggling it back keeps the same shell alive. It opens in the session's directory; typing `exit` closes it, and the next toggle starts a fresh shell. In-terminal search (⌘F) works inside it. Each session has its own; it is not persisted across launches.
- In-terminal text search (⌘F, View ▸ Find…, or the action palette): a small search bar opens at the top of the focused terminal — a main pane, a split pane, or the scratch terminal when it is shown. Typing a query highlights matches in the live scrollback and shows an "N of M" counter; Enter steps to the next match, Shift-Enter to the previous (or click the up/down buttons), and Esc (or ⌘F again) closes and returns focus to the terminal.

### Navigation

- A standard macOS menu bar mirrors the in-app actions with keyboard shortcuts: **File** — New Session (⌘N), New Workspace (⇧⌘N), Open Directory… (⌘O), Rename Session/Workspace, Delete Workspace, Close Session (⌘W, terminal-style: dismisses an open cover — quick terminal, overlay, or scratch — else closes the active session); **View** — Show/Hide Sidebar (⌃⌘S), Expand/Collapse Workspaces, Show Flagged/All, Flag Session (⌘⇧F), Focus Workspace, Split (⌘D), Scratch (⌘J), Find… (⌘F), Quick Terminal (⌃`), Increase/Decrease/Actual font size (⌘+/⌘−/⌘0), Select Theme… (the live-preview theme picker); **Navigate** — the command palettes, Previous/Next Session (⌥⌘↑/⌥⌘↓), Previous/Next Attention Session (⌃⌥↑/⌃⌥↓, jump between sessions with a blocked/completed status glyph), Go to Attention… (⌃⇧I, open a list of every session that needs attention), First/Last Session (menu and palette only, no hotkey), Focus Left/Right Pane (⌘⌥←/⌘⌥→).
- Three fuzzy-search command palettes (type to filter, ↑/↓ to move, Enter to run, Esc to dismiss): the **session switcher** (⌃P) jumps between open sessions by name or working directory, the **action palette** (⌃⇧P) runs any command (new/rename/close, delete workspace, split, scratch, toggle sidebar, quick terminal, font size, move session to a workspace, …), and the **custom-commands palette** (⌃⇧O) lists only your `keymap.conf` custom commands (no `custom` badge — every entry is custom). Results sort by match quality then alphabetically. All three are also in the Navigate menu.
- A Ctrl-Tab session switcher (macOS app-switcher style): hold Ctrl and tap Tab to walk a most-recently-used list of sessions across all workspaces (the previous session pre-selected on top, Ctrl+Shift+Tab reverses), then release Ctrl to switch. A quick tap of Ctrl+Tab flips straight to the previously visited session.

### Windows

- Named windows: a window is a top-level bundle of workspaces and sessions, each in its own on-screen macOS window. Keep a library of windows (for example "work" and "personal"), open one per on-screen window, and create, rename, or delete them from the **File** menu (New Window ⌥⌘N, Open Window ▸, Rename Window…, Delete Window) or the action palette. Each bundle shows in exactly one window. The set of windows open at quit reopens on the next launch, with their frames restored. Quitting (menu or ⌘Q) asks to confirm first, reporting how many windows and sessions it will close.

### Notifications

- Terminal desktop notifications: a program's OSC 9 / 777 notification from any session or pane surfaces as a macOS banner and an unseen-count badge on the sidebar row (rolled up onto a collapsed workspace row). Clicking the banner brings agterm forward and focuses the exact pane; focusing a session clears its badge and dismisses its delivered banners. A notification from the pane you're already focused on is suppressed. Banners can be turned off with the **Show notification banners** toggle in General settings; the red count badges can be hidden separately with **Show notification badges** — the count keeps tracking either way (it reappears with the current count when re-enabled), and the agent-status indicator is unaffected.

### Customization and settings

- A live-preview theme picker (View ▸ Select Theme…, the action palette's "Select Theme…", or the `select_theme` keymap action): a fuzzy-search palette of the bundled themes that applies each one to the open terminals **as you navigate or filter** — Enter commits it (and syncs Settings), Esc reverts to the theme you started on. The full theme catalog stays out of the action palette; only the single "Select Theme…" launcher appears there. The app's default theme (a fresh install) is the bundled **agterm** theme; a "default ghostty" entry selects ghostty's own built-in colors.
- A Settings window (Cmd+,) with **General**, **Appearance**, and **Key Mapping** tabs. **General** toggles macOS notification banners and the sidebar notification count badges, sets the mouse-wheel/trackpad scroll speed (a multiplier, default 3), sets how strongly the inactive split pane is muted (a 0–10 slider, default 5; 0 turns it off) — the inactive pane's text dims toward the background while the background stays unchanged — and has an opt-in **Restore running commands on restart** toggle (off by default; re-runs each pane's foreground command on relaunch, skipping the programs in `restore-denylist.conf`). **Appearance → Terminal** sets the terminal font family, default font size, and ghostty theme (any of the 512 bundled themes); **Appearance → Window** sets background opacity and blur (a translucent, optionally blurred window — the sidebar's Liquid Glass tints to match on macOS 26). A **Sidebar Tint** slider (0–10, default 5 = neutral) makes the sidebar background a touch lighter or darker than the terminal, staying translucent when the window is. **Key Mapping** points at the config directory holding `keymap.conf` (see Customizing keys), lists any parse diagnostics, and has a Reload button. Changes persist and apply live to open terminals. Applying a font/theme change resets per-session cmd-+/- zoom to the default.
- Keyboard-driven and customizable: every action is reachable by a keyboard shortcut, not only from the menus, toolbar icons, and palettes, and every built-in shortcut can be rebound in a `keymap.conf` file (see Customizing keys).
- Custom commands: bind any shell command to a key or list it in the action palette (and the dedicated custom-commands palette, ⌃⇧O) through `keymap.conf`. The focused session's directory and selection pass to the command as tokens, so you can drive your own user-defined workflows (open an editor, deploy, run a script) without changing the app.

### Persistence

- Auto-persist on every change and on quit; restore the tree, names, selection, each session's working directory and font size, the split state and each split's divider ratio, and each window's sidebar width and visibility on the next launch.

## Scripting agterm

`agterm` can be driven from a script over a local unix-domain socket through a companion CLI, `agtermctl`. This is for personal scripting — fire-and-forget commands that manage workspaces and sessions, inject text, and invoke control actions. There is no terminal-output streaming and no event subscription.

The app bundles `agtermctl` inside `agterm.app`. The easiest way to put it on your PATH is **Help ▸ Install Command Line Tool…**, which symlinks the bundled binary into `/usr/local/bin` (the first entry in macOS's default PATH). When that directory is user-writable it installs silently; otherwise it asks once for an administrator password.

To let a coding agent drive agterm without you explaining the API, install the bundled agent skill with **Help ▸ Install Agent Skill…**. Claude Code and Codex share the same skill format, so it installs to whichever you have, `~/.claude/skills/agterm/` and/or `~/.codex/skills/agterm/`. The skill teaches the agent the control model and the full `agtermctl` command set, so an agent running inside agterm can create sessions, run overlays, manage windows, and reload the keymap on its own. It drives the app through `agtermctl`, so install the CLI too.

`agtermctl` also lives in the `agtermCore` Swift package and builds standalone without Xcode or libghostty:

```sh
cd agtermCore && swift build -c release
# the binary is at agtermCore/.build/release/agtermctl
```

Each command targets a session or workspace by its UUID, a unique prefix of that UUID (git-style), or the keyword `active` (the selected session / current workspace). `--target` defaults to `active`, so the current one rarely needs to be named. Mutating commands print the affected id; `tree` prints the workspace and session tree. Add `--json` for the raw response, or `--socket PATH` to override the socket path. The exit code is zero on success, non-zero on error.

`--workspace`/`--target` take an id, a unique id prefix, or `active` — never a name. (`session new` also accepts `--workspace-name <name>` to target a workspace by its sidebar label, plus `--create-workspace` to make it when none matches — the two are mutually exclusive with `--workspace`.) To create a workspace and then open a session in it, capture the printed id:

```sh
agtermctl tree                                   # print the workspace/session tree with ids
ws=$(agtermctl workspace new work)               # create a workspace, capture its id
agtermctl session new --workspace "$ws" --cwd ~/src/agterm  # open a session in it, print its id
agtermctl session new --command "ssh user@host"  # run a command as the session's process (like kitty launch; no typed command, closes on exit)
agtermctl session new --command "sh -c 'clear; ssh user@host'"  # --command is argv-style (no shell); wrap in sh -c for ;, $VAR, redirects
agtermctl session new --name "myhost" --command "ssh user@host"  # pre-name the session (sidebar label set at creation)
agtermctl session new --workspace-name servers --create-workspace --name "myhost"  # open in the "servers" workspace, creating it if absent (idempotent)
agtermctl session type --target 9f3c $'make test\n'      # inject text into a session by id prefix
echo 'make test' | agtermctl session type --target active --stdin
agtermctl session go --to next                   # step to the next session (next|prev|first|last; stops at ends)
agtermctl session move --to up                   # reorder the active session within its workspace (up|down|top|bottom)
agtermctl session move "$ws"                      # relocate the active session to another workspace (appends)
agtermctl workspace move --to top                # reorder a workspace among its siblings (up|down|top|bottom)
agtermctl session split toggle                   # split the active session
agtermctl session scratch toggle                 # show/hide the active session's scratch terminal (on|off|toggle)
agtermctl session flag on                        # flag the active session for the flagged working-set view (on|off|toggle|clear)
agtermctl sidebar mode flagged                   # show only the flagged sessions as a flat list (tree|flagged|toggle)
agtermctl workspace focus on                     # collapse the sidebar tree to the active workspace (on|off|toggle)
agtermctl session search "error"                 # open the search bar and highlight matches; prints the "N of M" counter
agtermctl session search --next                  # step to the next match (--prev steps back, --close hides the bar)
agtermctl quick toggle                           # toggle the quick terminal
agtermctl font inc                               # increase the active surface's font size
```

`session type` types the text as real keystrokes, and every newline is a real Return press — so a trailing newline submits the command, and a multi-line payload runs line by line (a multi-line shell construct like a `for` loop is entered across the shell's continuation prompts and runs as one command). Note the `$'…\n'` quoting: a literal `\n` inside plain single quotes reaches the CLI as two characters, not a newline; use `$'…\n'` or pipe a real newline via `--stdin`.

`session copy` returns the target session's selected text in the response (it does not touch the system clipboard), so a script can move a selection from one session to another:

```sh
sel=$(agtermctl session copy --target 9f3c)      # the selected text in session 9f3c
agtermctl session type --target work --select "$sel"  # paste it into another session
```

With no selection it exits non-zero with `no selection`. The selection must be made in the terminal (drag/Shift-click); `session copy` only reads it.

`session overlay open` runs a program in an ephemeral terminal on top of a session (full size, hiding the single/split content underneath). It is meant for launching an interactive program over a session — the overlay grabs focus, and when the program exits the overlay vanishes and the session reappears unchanged:

```sh
agtermctl session overlay open "revdiff HEAD~3" --target 9f3c  # review the last 3 commits over session 9f3c
agtermctl session overlay open "htop"                          # on the active session
agtermctl session overlay open "htop" --size-percent 70        # a floating, framed panel at 70% of the pane
agtermctl session overlay open "make test" --wait              # keep the overlay open after exit (press a key to close)
agtermctl session overlay open "make test" --block             # block until it exits; exit with its status
agtermctl session overlay close --target 9f3c                  # close it from a script
```

The overlay renders only for the active session, so select it first (or target `active`) — a floating `--size-percent` overlay auto-selects its target (see below), so this caveat is really about the full overlay. By default it closes the instant the program exits; `--wait` keeps it on a "press any key to close" prompt so you can read the program's final output. A `*` `(overlay)` tag in `agtermctl tree` marks a session whose overlay is open.

`--block` runs the program in the overlay (rendering normally) and blocks until it exits, then exits with the program's status — useful in a script that needs the outcome of an interactive run. The program's output stays its own concern: a TUI writes its result to its own file (for example `revdiff --output=…`) which the script reads, while `--block` reports only the exit status (the overlay never captures stdout). `--block` can't be combined with `--wait`; `session overlay result` reports the last overlay's exit status on demand for a manual open → poll flow.

By default the overlay fills the pane, drawn translucent, hiding the session beneath it. Pass `--size-percent N` (1–100) for a *floating* variant instead: an opaque, framed panel sized to N% of the pane in both dimensions and centered in it, with the session still visible around it. Useful for a small auxiliary program (a picker, a monitor) that you want floating over — not replacing — the terminal you're working in. It composes with `--block` (a blocking floating overlay). Opening a floating overlay selects its target session (the floating panel only renders for the active session), so it always starts even when the target was not active.

A session's terminal surface is created lazily — it does not exist until the session has been shown at least once. Injecting text into a never-shown session therefore fails with `session not realized` unless you pass `--select`, which selects the session (realizing its surface) before injecting:

```sh
id=$(agtermctl session new --cwd ~/src/agterm)
agtermctl session type --target "$id" --select $'echo hello\n'
```

`agtermctl window` drives the named windows. `window list` prints `id  name  [open]  [active]` (raw with `--json`); the other subcommands take a window id, a unique prefix, or `active` (the frontmost):

```sh
agtermctl window list                            # id  name  [open]  [active]
w=$(agtermctl window new work)                   # create and open a window, capture its id
agtermctl window select "$w"                     # raise it (opening it first if it was closed)
agtermctl window rename "$w" personal            # rename it
agtermctl window close "$w"                      # close its on-screen window (the bundle is kept)
agtermctl window delete "$w"                     # delete it (the last window can't be deleted)
```

A global `--window <id>` option on the session, workspace, `tree`, and `font` commands targets a *specific* window's tree instead of the frontmost one (the window must be open). Without it, those commands act on the frontmost window:

```sh
agtermctl tree --window "$w"                              # the tree of window $w
agtermctl session new --window "$w" --cwd ~/src/agterm       # open a session in window $w
```

Inside a session's shell, `agterm` injects environment variables a script can read: `AGTERM_ENABLED=1`, `AGTERM_WINDOW_ID`, `AGTERM_WORKSPACE_ID`, `AGTERM_SESSION_ID`, and `AGTERM_SOCKET` (the live control-socket path). So a script running in a session can drive its own window without hard-coding ids:

```sh
agtermctl session new --window "$AGTERM_WINDOW_ID" --cwd .   # open a sibling session in this window
agtermctl session type --target "$AGTERM_SESSION_ID" $'\n'   # type into this very session
agtermctl tree --socket "$AGTERM_SOCKET"                     # reach the same agterm this shell runs in
```

## Customizing keys

`agterm` reads a user-editable, kitty-flavored keymap file at `~/.config/agterm/keymap.conf`. It does two things: rebind the built-in menu shortcuts, and define custom shell commands bound to keys (and listed in the action palette). The file is optional — the app ships with working defaults, and a commented starter `keymap.conf` is written on first launch. The directory holding it can be changed in **Settings ▸ Key Mapping** (the field shows the active path, with a "Choose…" picker and "Use Default").

The format is line-based with two verbs. Blank lines and lines starting with `#` are ignored:

```
# rebind a built-in to a single chord (mods joined by +; no leader sequences for built-ins)
map cmd+shift+d   toggle_split
map ctrl+shift+k  command_palette

# define custom commands ("name" shows in the palette; chord is optional)
command "Open in Zed"  cmd+shift+e  open -a Zed {AGT_SESSION_PWD}
command "Lazygit"      ctrl+a>g     agtermctl session overlay open lazygit --socket {AGT_SOCKET}
command "Deploy"                    ./deploy.sh
```

A chord is modifier words joined by `+` and a base key, e.g. `cmd+shift+e` or `ctrl+\``. The modifiers are `ctrl`, `cmd`, `opt`, and `shift`. The base key is a single character or one of `tab`, `space`, `return`, `delete`. A custom command's chord may also be a leader sequence — chords separated by `>`, e.g. `ctrl+a>g` (press `ctrl+a`, then `g`). A `command` with no chord is palette-only. A custom command's chord must include a modifier: a bare key like `a` is rejected with a diagnostic and the line is treated as palette-only, so a binding can't silently shadow a plain terminal key (and a palette-only shell line that happens to start with a single-character token isn't swallowed as a binding).

The bindable built-in action names are:

```
new_window         rename_window      delete_window
new_workspace      rename_workspace   delete_workspace
new_session        open_directory     rename_session
close_session      clear_status
increase_font_size decrease_font_size reset_font_size
toggle_split       toggle_scratch     toggle_search
toggle_sidebar     toggle_flag        toggle_flagged_view
focus_left_pane    focus_right_pane   focus_workspace
previous_session   next_session       first_session      last_session
previous_attention_session            next_attention_session
quick_terminal     session_palette    command_palette
custom_command_palette                show_attention
select_theme
```

The shell line of a `command` may use these `{AGT_X}` tokens, expanded at fire time (the same values are also exported as `$AGT_X` environment variables on the spawned process):

```
{AGT_SESSION_ID}   {AGT_SESSION_NAME}   {AGT_SESSION_PWD}
{AGT_WORKSPACE_ID} {AGT_WORKSPACE_NAME}
{AGT_WINDOW_ID}    {AGT_WINDOW_NAME}
{AGT_SELECTION}    {AGT_SOCKET}
```

The context is resolved from the focused pane's session, so a custom command runs in that session's working directory and can read its current selection. A custom command runs as a detached `/bin/sh -c`; a non-zero exit (or a spawn failure) posts a notification banner.

Because it runs detached with no controlling terminal, a custom command suits fire-and-forget launches — GUI apps (`open -a …`), scripts, one-off shell lines — not interactive or full-screen programs: a TUI like `lazygit` run bare has no TTY to draw into and exits immediately. The `Lazygit` example above launches it the right way, in an overlay terminal that *does* have a TTY (`agtermctl session overlay open`, passing `{AGT_SOCKET}` so the CLI reaches this very app; add `--size-percent 80` for a floating panel instead of full-size). A per-session scratch terminal (`agtermctl session scratch on --command lazygit`) works too.

A `{AGT_X}` token is substituted **raw** into the shell line — convenient, but unsafe for content you don't control. `{AGT_SELECTION}` is the obvious case, but a remote host can also set the session title (OSC) and report the working directory (OSC 7), so `{AGT_SESSION_NAME}` and `{AGT_SESSION_PWD}` are equally unsafe to interpolate raw. For any such content prefer the matching `$AGT_X` environment variable, quoted, e.g. `"$AGT_SELECTION"` — the shell quotes it for you so it can't inject syntax.

Open the file in your editor with **File ▸ Edit Keymap…** or the ⌃⇧P palette ("Edit Keymap"): it opens in a 95% overlay running `$VISUAL`/`$EDITOR` (falling back to `vi`), and reloads automatically when you save and quit. The editor is resolved through your interactive login shell, so an `$EDITOR`/`$VISUAL` set anywhere your normal terminal picks it up (including `~/.zshrc`) is honored.

After editing the file, apply it with **File ▸ Reload Keymap**, the action palette (⌃⇧P → "Reload Keymap"), or `agtermctl keymap reload`. A malformed line never discards the rest of the file — it surfaces in the diagnostics list in Settings ▸ Key Mapping (and `keymap.reload` returns the diagnostic count) while the good lines still apply.

v1 limitations:

- Built-in rebinds are single-chord only; leader sequences (`ctrl+a>g`) work only for custom commands.
- A few keys are not expressible in the file because they clash with the grammar's separators: the arrow keys, `+` (the chord-joiner, so `increase_font_size`'s default ⌘+ can't be written), and `>` (the leader separator). The arrow-bound actions (`focus_left_pane`, `focus_right_pane`, `previous_session`, `next_session`, `previous_attention_session`, `next_attention_session`) and `increase_font_size` keep their default shortcuts unless you `map` them to a parseable chord.
- The Ctrl-Tab MRU session switcher and Ctrl-1/Ctrl-2 pane focus are not rebindable yet; they keep their current keys.
- The action palette shows chords as live kitty syntax (e.g. `cmd+shift+e`) for both custom commands and built-in shortcuts; only chords that can't be expressed in the file fall back to a glyph (the arrow-bound actions and `increase_font_size`'s ⌘+).

## Ghostty config

`agterm` builds its terminal config from these sources, each overriding the one before it:

```
ghostty's bundled defaults  →  ~/.config/ghostty/config  →  <config dir>/ghostty.conf  →  agterm Settings
       (lowest)                  (your global config,           (agterm-scoped,             (UI wins)
                                   OFF by default)                always loaded)
```

agterm is self-contained: **by default it does not read your global `~/.config/ghostty/config`**, so a config written for the standalone Ghostty.app never silently changes agterm. Turn on **Settings ▸ General ▸ Use my global Ghostty config** to fold it into the chain.

`<config dir>/ghostty.conf` is the place to customize agterm. It sits next to `keymap.conf` (default `~/.config/agterm/ghostty.conf`; the directory is the one set in **Settings ▸ Key Mapping**), is always loaded, and is scoped to agterm so the standalone Ghostty.app never reads it. Put any ghostty config key there to override the bundled defaults for agterm only. The keys agterm manages from its Settings window (font, theme, background opacity and blur, scroll speed) still win, because the generated Settings file loads last, so set those in Settings and put everything else here. The file is optional: a commented starter is written on first launch and stays a no-op until you edit it.

A common use is making the macOS Option key send Alt:

```
macos-option-as-alt = true
```

Put that in `ghostty.conf`. It also works in your global `~/.config/ghostty/config` once you enable the toggle above. The full key reference is at <https://ghostty.org/docs/config>.

Open the file with **File ▸ Edit ghostty.conf…** or the ⌃⇧P palette ("Edit ghostty.conf"): it opens in a 95% overlay running `$VISUAL`/`$EDITOR` (falling back to `vi`), the same as Edit Keymap, and reloads when you save and quit. Apply edits made elsewhere with **File ▸ Reload Config**, the action palette ("Reload Config"), or `agtermctl config reload`. A malformed line does not break the load: the bad lines are skipped and the good ones still apply. The diagnostic count (shown in a banner and returned by `config.reload`) covers every ghostty config source, not just `ghostty.conf`, because the diagnostics do not record which file they came from. The Console log shows the offending line.

## Agent status

A coding agent running in a session can flag its status on that session's sidebar row, so you can tell at a glance which of many concurrent agents needs you. The status shows as a small tinted SF Symbol just left of the notification badge: `active` is a blue ellipsis, `blocked` an amber exclamation, `completed` a green check, and `idle` is nothing. The glyph shows on every non-idle session, the selected one included. A one-time `completed` flash auto-clears once you visit the session.

When the sidebar is hidden the per-session glyphs go with it, so the same signal is available two more ways. An optional **title-bar bell** (turn on **Show attention indicator** in Settings ▸ General ▸ Notifications; off by default) reflects the window at a glance: dimmed when nothing needs attention, plain when a session is active or completed, and a filled amber bell when any session is blocked. Clicking it — or pressing ⌃⇧I, choosing **Navigate ▸ Go to Attention…**, or the action palette's "Show Attention" — opens the **attention list**: a palette of just this window's non-idle sessions, each with its status glyph, sorted blocked → active → completed (newest change first). Enter jumps to the session. Over the control channel, `agtermctl tree --json` now reports each session's `status` (omitted when idle).

An agent sets it over the control channel:

```sh
agtermctl session status active --target "$AGTERM_SESSION_ID"      # agent started working
agtermctl session status blocked --target "$AGTERM_SESSION_ID"     # waiting on you
agtermctl session status completed --auto-reset --target "$AGTERM_SESSION_ID"  # done; clears when seen
agtermctl session status blocked --sound default --target "$AGTERM_SESSION_ID" # waiting on you, with a beep
agtermctl session status idle --target "$AGTERM_SESSION_ID"        # clear it
```

`<state>` is one of `idle | active | completed | blocked`. `--blink` pulses the icon for attention. `--auto-reset` makes the indicator clear back to idle the moment you visit (select) the session — used for a finished result you only need to notice once; without it the status is kept until something changes it. `--sound` plays a one-shot sound when the status is set — `default` for the system alert sound, or a system sound name (`Basso`, `Blow`, `Bottle`, `Frog`, `Funk`, `Glass`, `Hero`, `Morse`, `Ping`, `Pop`, `Purr`, `Sosumi`, `Submarine`, `Tink`, plus any custom sound in `~/Library/Sounds`); it is optional and entirely caller-driven, so the agent decides when a status change is worth an audible nudge. If you'd rather have a blocked prompt always make a sound without touching the hooks, set **Settings ▸ Appearance ▸ Agent Status ▸ Blocked sound** to a system sound (default None) — it plays whenever a session becomes `blocked`, and an explicit `--sound` on the call still overrides it. The target session can live in any window, frontmost or not. Typing into a session that's flagged for your attention (`blocked` or `completed`) clears its status back to idle, so answering a prompt or re-engaging with a finished session drops the glyph immediately. An `active` (working) session is left alone for ordinary typing — except Esc, which interrupts the agent and also clears the glyph, so cancelling a prompt drops it at once even if the `blocked` waiting-state hadn't appeared yet.

To wire this up automatically, **Help ▸ Install Agent Status Hooks…** installs a hooks package. It copies the scripts to `~/.config/agterm/agent-status/` (baking in the bundled `agtermctl`'s path so the hooks work even without the CLI on your PATH), adds a `source` line to `~/.zshrc`, `~/.bashrc`, and `~/.config/fish/config.fish` for the generic shell integration, and merges four Claude Code hooks into `~/.claude/settings.json` (backing up the prior file as `.bak`, or leaving it untouched and skipping the merge if it isn't valid JSON): a prompt sets `active`, each tool that runs re-asserts `active` (so the status returns to active when work resumes after you answer a permission prompt), the Stop event sets `completed --auto-reset`, and a permission prompt sets `blocked`. It is idempotent — re-running refreshes the baked path and is a clean no-op for entries already present.

For Codex, the installer prints (it does not auto-edit TOML) a line to add to `~/.codex/config.toml` yourself:

```toml
notify = ["/Users/you/.config/agterm/agent-status/codex-notify.sh"]
```

A generic bash/zsh/fish `shell/integration.sh` (or `.fish`) covers any agent launched as a shell command: it flags `active` while a command matching `AGTERM_AGENT_RE` runs and `idle` at the next prompt. The default regex matches `codex`, `gemini`, `cursor-agent`, `aider`, `opencode`, `crush`, and `goose`; Claude Code is excluded by default because its own hooks drive finer per-turn state, and Codex additionally has the richer `codex-notify.sh` chain above. Override `AGTERM_AGENT_RE` before sourcing to change the set. All hooks are no-ops outside an agterm session.

## Troubleshooting

Where the logs and config live, how to read them, and the common problems (a keymap editor that will not open, a custom action that does nothing, missing notifications) are covered in [docs/troubleshooting.md](docs/troubleshooting.md). For a bug, open an [issue](https://github.com/umputun/agterm/issues/new); for a feature request or question, start a [Discussion](https://github.com/umputun/agterm/discussions/new).

## Restore limitations

Restore reconstructs the structure, not the running processes. Three limitations follow from the design:

1. Live processes are not reattached — true process survival would require a tmux-style backend, which is out of scope. By default a restored session re-spawns a fresh login shell in its saved working directory. The optional **Restore running commands on restart** toggle (General settings, off by default) re-runs the command each pane had in the foreground at the last clean quit, so a gate `ssh`, `tail -f`, or `top` comes back — but it is a re-run, not a reattach: only a single-process command restores faithfully (pipelines and compound lines do not); a force-quit or crash captures nothing; and the programs named in `restore-denylist.conf` (in the config directory, seeded with the terminal multiplexers `tmux`/`screen`/`zellij`, one command name per line) are skipped so they start fresh rather than re-launching — everything else, including `python manage.py runserver` or `node server.js`, is restored. Edit that file to add or remove entries.
2. The saved working directory depends on the `GHOSTTY_ACTION_PWD` callback, which only fires when the shell has Ghostty shell-integration / OSC 7 active (auto-injected for zsh, bash, fish, and nu when the shell-integration resources are present). If the working directory is never reported, a session restores to the directory it was created in.
3. The live working directory is persisted on quit and on every structural change (adding, closing, moving, renaming, or selecting a session), but not on every `cd` — OSC 7 fires on each prompt redraw, so saving each one would thrash the disk. A crash or force-quit therefore loses only the working-directory changes made since the last structural change or quit.

## Attribution

agterm embeds **libghostty**, the terminal engine from [Ghostty](https://github.com/ghostty-org/ghostty) (MIT). It does all the real terminal work: rendering, VT parsing, and shell I/O. agterm builds it from upstream source at a pinned commit via `scripts/setup.sh`, with no fork and no prebuilt binary.

The way agterm drives libghostty's C API from a SwiftUI/AppKit app, under the Swift 6 strict-concurrency toolchain, was learned from [macterm](https://github.com/thdxg/macterm) (`thdxg/macterm`, MIT). The libghostty bridge files (`GhosttyApp`, `GhosttyCallbacks`, `GhosttyResources`, `GhosttySurfaceView`, `WindowAppearance`) are adapted from it and each carries an attribution comment. The model, sidebar, persistence, control channel, and multi-window code are original to agterm.

SwiftUI guidance during development came from the [SwiftUI Agent Skill](https://github.com/AvdLee/SwiftUI-Agent-Skill) by Antoine van der Lee (MIT). Special thanks to [@ksenks](https://github.com/ksenks) for recommending it.
