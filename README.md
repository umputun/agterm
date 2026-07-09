# agterm - modern terminal for agentic flow

[![Build Status](https://github.com/umputun/agterm/workflows/build/badge.svg)](https://github.com/umputun/agterm/actions) [![Coverage Status](https://coveralls.io/repos/github/umputun/agterm/badge.svg?branch=master)](https://coveralls.io/github/umputun/agterm?branch=master)

**[agterm.com](https://agterm.com)** · [Documentation](https://agterm.com/docs) · [Command reference](https://agterm.com/commands)

`agterm` is a native macOS terminal for working with AI coding agents across many sessions at once. It is intentionally opinionated: rather than scattering shells across tabs, it organizes them into named workspaces, each holding the sessions for one project or context, so several agent-driven sessions can run side by side and you can move between them without losing track of which is which. The motivation is specific: running several coding agents at once means many long-lived sessions, each progressing on its own, and a tabbed terminal loses track of them quickly. agterm keeps them organized and makes it obvious which session needs you. None of this is limited to agents. It also works as a capable general-purpose terminal for everyday multi-project work.

The design is deliberately minimal: it covers the use cases above and stops there. Features come in two kinds. One is just enough to get the work done. The other is the small set of things other terminals get wrong, done the way they should have been. There is no deep agent integration and no attempt to invent a new way of working with agents. You get a sensible minimum out of the box, plus a complete control API and CLI on top. Almost everything is scriptable, so anything past the defaults you build yourself instead of waiting for it to ship.

What it does:

- **Workspaces.** Sessions are grouped under named workspaces like "work" and "personal", which keeps a screen of concurrent sessions organized. You reach a session by name, by recency, or from the keyboard.
- **Control API and CLI.** A bundled tool, `agtermctl`, drives almost everything over a local socket: create sessions, type into them, run a program in an overlay and read its exit status, move and resize windows, or post a notification tied to a specific session. A script or an agent can set up and drive its own layout, and send you a notification from the session it was working in.
- **Splits, scratch, and overlays.** Split a session into two shells, open a scratch terminal over it, or run a program in a full or floating overlay without disturbing the shell underneath.
- **Agent skill.** An installable skill (Help ▸ Install Agent Skill…) teaches Claude Code or Codex the control model and the `agtermctl` commands, so an agent running inside agterm can build its own layout, run overlays, manage windows, and show images inline without you explaining the API.
- **Agent status.** A coding agent reports its state (active, blocked, or completed) onto its session's row, so you can see which of many running agents needs you. Status hooks for Claude Code, Codex, and other agents install from Help ▸ Install Agent Status Hooks….

For the real terminal work, rendering, VT parsing, and shell I/O, `agterm` embeds [Ghostty](https://ghostty.org)'s engine (libghostty); everything above is `agterm`'s own.

![agterm](docs/screenshots/main.png)

<details>
<summary>More screenshots</summary>

An agent's interactive prompt mid-session, with attention glyphs on the sessions that need you:

![Agent prompt](docs/screenshots/agent-prompt.png)

The attention list, collecting every session that needs you, sorted blocked then active then completed:

![Attention list](docs/screenshots/attention.png)

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

A split session, two panes side by side on different color themes:

![Split session](docs/screenshots/split-theme.png)

A file open in the quick terminal, the window's shared scratch overlay:

![Quick terminal](docs/screenshots/quick-terminal.png)

</details>

## Install

Pre-built releases are for **Apple Silicon (arm64) Macs running macOS 14 or later**.

Releases are signed with a Developer ID certificate and notarized by Apple, so macOS Gatekeeper opens them with no extra steps.

Homebrew:

```sh
brew install --cask umputun/apps/agterm
```

The cask also installs the `agtermctl` command-line tool, so cask users should not run the in-app installer as well.

> [!NOTE]
> **Homebrew upgrade note (July 2026).** A recent Homebrew change (installed-cask metadata stored as JSON) can make `brew upgrade` fail for agterm with `It seems there is already an App at '/Applications/agterm.app'`. It affects third-party tap casks in general, not only agterm. Recover with a one-time reinstall, which rewrites the install receipt:
>
> ```sh
> brew reinstall --cask --force agterm
> ```
>
> Regular `brew upgrade` works afterward. This is an upstream Homebrew issue, and the note will be removed once it is fixed.

Direct download:

Download the latest `.dmg` from the [releases page](https://github.com/umputun/agterm/releases), open it, and drag `agterm.app` into `/Applications`.

### Optional Help-menu installers

The app's **Help** menu has three one-time installers. None are needed to use agterm as a terminal; each connects it to a wider workflow, and you can run any of them later.

- **Install Command Line Tool…** puts the bundled `agtermctl` on your `PATH` (a symlink in `/usr/local/bin`) so you can script the app from a shell. The Homebrew cask already installs it, so cask users can skip this one. See [Scripting agterm](#scripting-agterm).
- **Install Agent Status Hooks…** lets a coding agent (Claude Code, Codex, or others) report its state onto its session's sidebar row, so you can tell at a glance which of several running agents is active, blocked, or finished. See [Agent status](#agent-status).
- **Install Agent Skill…** teaches Claude Code or Codex how to drive agterm through `agtermctl`, so an agent running inside a session can build its own layout, run overlays, and manage windows without you explaining the API. It drives the app through the command-line tool, so install that one too.

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

## Concepts

agterm arranges terminals into a small hierarchy. These are the only terms you need; the sidebar, menus, and shortcuts all map onto them.

**Session.** A session is one running shell with a name, a working directory, and its own scrollback. It is the unit you work in and the row you see in the sidebar. A new session takes its name from the basename of its directory; rename it to pin a custom name, clear the name to go back to the basename. New sessions open in your home directory by default, or in the current session's directory, or in a fixed folder (set in Settings). A session runs until you close it or its shell exits, and it comes back on the next launch with its directory, font size, and split state restored.

**Panes.** A session can split into two shells side by side. Both panes are part of the same session and share one sidebar row; a split is one session with two terminals, not two sessions. One pane is focused at a time, and the divider position is remembered.

**Scratch terminal.** Every session has an extra shell, the scratch terminal, that you toggle on over the session and hide again without killing it. It opens in the session's directory and is for a quick aside next to your main work. It belongs to that one session and is not restored across launches.

**Quick terminal.** The quick terminal is a single throwaway shell per window, not tied to any session. It drops over whatever session is active, for a command unrelated to what you are working on, and hiding it keeps the shell alive. It is not restored across launches.

**Overlay.** An overlay runs one program in a temporary terminal over a session and disappears when the program exits, leaving the session as it was. It is mostly driven from the control API to launch an interactive program (a diff viewer, a process monitor) over a session without replacing its shell. See [Scripting agterm](#scripting-agterm).

**Workspace.** A workspace is a named group of sessions for one project or context, for example "work" or "personal". Sessions belong to a workspace and can move between workspaces while still running, keeping their shell and scrollback. There is always at least one workspace.

**Window.** A window is a whole set of workspaces and sessions in its own on-screen macOS window, with its own sidebar. Each window has its own sessions, so "work" and "personal" can run as two separate windows at once, each with its own tree. You keep a library of windows and open one per on-screen window; the windows open at quit reopen on the next launch with their frames.

**Flagging and focus.** Two ways to cut down a busy sidebar. Flag a few sessions from different workspaces to get a flat working-set view of just those; a flag is durable and survives a move. Focus a single workspace to hide the others, with a one-click way back. The two are independent.

**Notifications.** A program in any session can raise a desktop notification (via OSC 9 / 777, or the control API). It shows as a banner and a count badge on the session's row; clicking the banner jumps to the exact pane that raised it. The badge clears when you visit the session, or headlessly with `agtermctl session seen` — so an orchestrator driving a session over the socket can acknowledge its notifications without pulling focus to it (`agtermctl tree --json` reports each session's `unseen` count). For a coding agent that just needs to say it is waiting on you, [Agent status](#agent-status) is usually the better fit.

**Agent status.** A coding agent in a session can report its state (active, blocked, completed) onto that session's row, so a screen of concurrent agents shows which one needs you. See [Agent status](#agent-status) for wiring it up.

## Keyboard and navigation

agterm is built to run from the keyboard. Every action has a shortcut and appears in the menus, and three fuzzy palettes cover the rest (type to filter, Enter to run, Esc to dismiss):

- the **session switcher** (Ctrl-P) jumps to any open session by name or working directory;
- the **action palette** (Ctrl-Shift-P) runs any command by name (new, rename, close, split, toggle scratch, move a session, change font size, and so on);
- the **custom-commands palette** (Ctrl-Shift-O) lists the shell commands you define in `keymap.conf`.

For jumping back to sessions you have been working in, a Ctrl-Tab switcher walks a most-recently-used list across every workspace, macOS app-switcher style: hold Ctrl and tap Tab to move through it, release to switch, and a single tap flips straight back to the session you were just in. The list survives a relaunch, so the switcher works right after your sessions restore. Shortcuts also step between adjacent sessions, panes, and windows.

## Settings

Settings (Cmd+,) has five tabs. **General** covers mouse scroll speed and right-click-to-paste, where a new session opens, an opt-in toggle to re-run each pane's foreground command on restart, an opt-in confirmation before closing a session, and whether to load your global Ghostty config. **Appearance** sets the terminal font and theme (512 bundled themes), the toolbar mode, the window background opacity and blur, the sidebar tint, and how much the inactive split pane dims; a "Follow system appearance" toggle (off by default) reveals a second picker for the other appearance, so the theme tracks macOS light/dark mode live. The toolbar has three modes: **Normal** shows the title with the working directory beneath it, **Compact** (the default) is a single title row, and **Hidden** drops the whole titlebar row and the window's traffic-light buttons for a full-bleed terminal with no chrome — an invisible strip along the top edge still moves the window and double-click-zooms it, and you close, minimize, or zoom the window from the keyboard or the Window menu. **Notifications** toggles the banner, the unseen-count badge, and the title-bar attention indicator. **Agent Status** sets the status-glyph colors, the blocked-session sound, and an idle timeout to auto-follow blocked sessions. **Key Mapping** points at the directory holding `keymap.conf`, lists any parse errors, and reloads it. Changes apply live to the open terminals.

The theme picker (View ▸ Select Theme…, or the action palette) previews each bundled theme on the open terminals as you move through the list, so you see it before committing. Enter commits and syncs it to Settings; Esc reverts to the one you started on. While following the system appearance, the picker edits the theme for the appearance you are in; the control channel drives both slots with `agtermctl theme set --light NAME --dark NAME` (or either flag alone).

## Scripting agterm

`agterm` can be driven from a script over a local unix-domain socket through a companion CLI, `agtermctl`. This is for personal scripting — fire-and-forget commands that manage workspaces and sessions, inject text, and invoke control actions. There is no terminal-output streaming and no event subscription.

The sections below cover the common cases. All 57 commands, with every argument, return value, and error, are documented in the **[Command reference](https://agterm.com/commands)**.

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
agtermctl session new --after active             # create right after the current session (--before to precede it); the anchor's workspace is used
agtermctl session type --target 9f3c $'make test\n'      # inject text into a session by id prefix
echo 'make test' | agtermctl session type --target active --stdin
agtermctl session go --to next                   # step to the next session (next|prev|first|last; stops at ends)
agtermctl session move --to up                   # reorder the active session within its workspace (up|down|top|bottom)
agtermctl session move "$ws"                      # relocate the active session to another workspace (appends)
agtermctl session move --after 9f3c              # place the active session right after another (--before to precede it); relocates cross-workspace if the anchor lives elsewhere
agtermctl workspace move --to top                # reorder a workspace among its siblings (up|down|top|bottom)
agtermctl session split toggle                   # split the active session
agtermctl session resize --split-ratio 0.7       # set the split divider (left-pane fraction); or --grow-left/--grow-right D
agtermctl session scratch toggle                 # show/hide the active session's scratch terminal (on|off|toggle)
agtermctl session flag on                        # flag the active session for the flagged working-set view (on|off|toggle|clear)
agtermctl session seen --target 9f3c             # clear a session's unseen-notification badge without visiting it (focus-free)
agtermctl sidebar mode flagged                   # show only the flagged sessions as a flat list (tree|flagged|toggle)
agtermctl workspace focus on                     # collapse the sidebar tree to the active workspace (on|off|toggle)
agtermctl session search "error"                 # open the search bar and highlight matches; prints the "N of M" counter
agtermctl session search --next                  # step to the next match (--prev steps back, --close hides the bar)
agtermctl quick toggle                           # toggle the quick terminal (show|hide|toggle)
agtermctl quick type 'ls -la'$'\n'               # type into the frontmost window's quick terminal (or --stdin); quick text reads it back
agtermctl font inc                               # increase the active surface's font size
agtermctl theme set --light "Builtin Light" --dark Dracula  # set the light/dark theme slots (--dark none turns following off)
```

`session type` types the text as real keystrokes, and every newline is a real Return press — so a trailing newline submits the command, and a multi-line payload runs line by line (a multi-line shell construct like a `for` loop is entered across the shell's continuation prompts and runs as one command). Note the `$'…\n'` quoting: a literal `\n` inside plain single quotes reaches the CLI as two characters, not a newline; use `$'…\n'` or pipe a real newline via `--stdin`. Typing goes to the session's left (main) pane by default; `--pane right` types into the split pane instead (an error when the session has no split), and `--pane scratch` reaches the session's scratch terminal even while it is hidden. `session text` takes the same `--pane`, so an agent can read a hidden scratch's output (e.g. a deploy you ran there) without leaving it open.

`session copy` returns the target session's selected text in the response (it does not touch the system clipboard), so a script can move a selection from one session to another:

```sh
sel=$(agtermctl session copy --target 9f3c)      # the selected text in session 9f3c
agtermctl session type --target work --select "$sel"  # paste it into another session
```

With no selection it exits non-zero with `no selection`. The selection must be made in the terminal (drag/Shift-click); `session copy` only reads it.

`session paste` pastes the system clipboard into a session (the socket analogue of ⌘V), and `session select-all` selects the session's entire buffer (the analogue of ⌘A) — pair `select-all` with `copy` to grab the whole buffer:

```sh
printf 'deploy staging' | pbcopy
agtermctl session paste --target work            # lands at the prompt, not submitted
agtermctl session select-all --target 9f3c       # then read it all back
agtermctl session copy --target 9f3c
```

These are also the Edit menu's Copy/Paste/Select All (⌘C/⌘V/⌘A), which act on the focused terminal (or a focused text field).

`session overlay open` runs a program in an ephemeral terminal on top of a session (full size, hiding the single/split content underneath). It is meant for launching an interactive program over a session — the overlay grabs focus, and when the program exits the overlay vanishes and the session reappears unchanged:

```sh
agtermctl session overlay open "revdiff HEAD~3" --target 9f3c  # review the last 3 commits over session 9f3c
agtermctl session overlay open "htop"                          # on the active session
agtermctl session overlay open "htop" --size-percent 70        # a floating, framed panel at 70% of the pane
agtermctl session overlay open "revdiff HEAD~3" --size-percent 80 --background-color "#2a1a3a"  # tint the overlay pane
agtermctl session overlay open "revdiff HEAD~3" --target 9f3c --follow  # switch the user to session 9f3c as the overlay opens
agtermctl session overlay open "make test" --wait              # keep the overlay open after exit (press a key to close)
agtermctl session overlay open "make test" --block             # block until it exits; exit with its status
agtermctl session overlay resize --size-percent 60 --target 9f3c  # resize an open overlay to a floating 60% panel
agtermctl session overlay resize --full --target 9f3c          # switch it back to the full-pane overlay
agtermctl session overlay close --target 9f3c                  # close it from a script
```

By default an overlay opens on its `--target` without switching the active session — full and floating both run their program in the background and appear when the user visits that session; pass `--follow` to select the target as the overlay opens (a no-op if it is already active). `session overlay resize` changes an already-open overlay in place — `--size-percent N` (1–100) makes it a floating panel, `--full` switches it back to full size — and the program keeps running across the change. By default it closes the instant the program exits; `--wait` keeps it on a "press any key to close" prompt so you can read the program's final output. A `*` `(overlay)` tag in `agtermctl tree` marks a session whose overlay is open.

`--block` runs the program in the overlay (rendering normally) and blocks until it exits, then exits with the program's status — useful in a script that needs the outcome of an interactive run. The program's output stays its own concern: a TUI writes its result to its own file (for example `revdiff --output=…`) which the script reads, while `--block` reports only the exit status (the overlay never captures stdout). `--block` can't be combined with `--wait`; `session overlay result` reports the last overlay's exit status on demand for a manual open → poll flow.

By default the overlay fills the pane, drawn translucent, hiding the session beneath it. Pass `--size-percent N` (1–100) for a *floating* variant instead: an opaque, framed panel sized to N% of the pane in both dimensions and centered in it, with the session still visible around it. Useful for a small auxiliary program (a picker, a monitor) that you want floating over — not replacing — the terminal you're working in. It composes with `--block` (a blocking floating overlay). Like a full overlay it opens in the background and runs even when the target is not active; pass `--follow` to switch the user to the target as it opens.

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

Inside a session's shell, `agterm` injects environment variables a script can read: `AGTERM_ENABLED=1`, `AGTERM_WINDOW_ID`, `AGTERM_WORKSPACE_ID`, `AGTERM_SESSION_ID`, `AGTERM_SOCKET` (the live control-socket path), and `AGTERM_PANE` (which pane this shell runs in — `left` for the main pane, `right` for the split, or `scratch`; unset in an overlay). So a script running in a session can drive its own window without hard-coding ids:

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

A chord is modifier words joined by `+` and a base key, e.g. `cmd+shift+e` or `ctrl+\``. The modifiers are `ctrl`, `cmd`, `opt`, and `shift`. The base key is a single character or one of `tab`, `space`, `return`, `delete`. A key you type with Shift is written as `shift+<base key>` (the base key, not the shifted symbol): `shift+/` for `?`, `shift+5` for `%`, `shift+=` for `+`, `shift+.` for `>`. A custom command's chord may also be a leader sequence — chords separated by `>`, e.g. `ctrl+a>g` (press `ctrl+a`, then `g`). A `command` with no chord is palette-only. A custom command's chord must include a modifier: a bare key like `a` is rejected with a diagnostic and the line is treated as palette-only, so a binding can't silently shadow a plain terminal key (and a palette-only shell line that happens to start with a single-character token isn't swallowed as a binding).

The bindable built-in action names are:

```
new_window         rename_window      delete_window
new_workspace      rename_workspace   delete_workspace
new_session        open_directory     rename_session
close_session      reopen_recent      undo_close         clear_status
increase_font_size decrease_font_size reset_font_size
toggle_split       toggle_scratch     toggle_search
toggle_sidebar     toggle_flag        toggle_flagged_view
focus_left_pane    focus_right_pane   focus_workspace
previous_session   next_session       first_session      last_session
previous_attention_session            next_attention_session
quick_terminal     session_palette    command_palette
custom_command_palette                show_attention
select_theme       toggle_fullscreen
```

The shell line of a `command` may use these `{AGT_X}` tokens, expanded at fire time (the same values are also exported as `$AGT_X` environment variables on the spawned process):

```
{AGT_SESSION_ID}   {AGT_SESSION_NAME}   {AGT_SESSION_PWD}
{AGT_WORKSPACE_ID} {AGT_WORKSPACE_NAME}
{AGT_WINDOW_ID}    {AGT_WINDOW_NAME}
{AGT_PANE}         {AGT_SELECTION}      {AGT_SOCKET}
```

The context is resolved from the focused pane's session, so a custom command runs in that session's working directory and can read its current selection. `{AGT_PANE}` is the pane the shortcut fired from — `left` (main) or `right` (split) — so a script can route a follow-up `agtermctl session type --pane "$AGT_PANE"` back into the very pane it was invoked in. A custom command runs as a detached `/bin/sh -c`; a non-zero exit (or a spawn failure) posts a notification banner.

Because it runs detached with no controlling terminal, a custom command suits fire-and-forget launches — GUI apps (`open -a …`), scripts, one-off shell lines — not interactive or full-screen programs: a TUI like `lazygit` run bare has no TTY to draw into and exits immediately. The `Lazygit` example above launches it the right way, in an overlay terminal that *does* have a TTY (`agtermctl session overlay open`, passing `{AGT_SOCKET}` so the CLI reaches this very app; add `--size-percent 80` for a floating panel instead of full-size). A per-session scratch terminal (`agtermctl session scratch on --command lazygit`) works too.

A `{AGT_X}` token is substituted **raw** into the shell line — convenient, but unsafe for content you don't control. `{AGT_SELECTION}` is the obvious case, but a remote host can also set the session title (OSC) and report the working directory (OSC 7), so `{AGT_SESSION_NAME}` and `{AGT_SESSION_PWD}` are equally unsafe to interpolate raw. For any such content prefer the matching `$AGT_X` environment variable, quoted, e.g. `"$AGT_SELECTION"` — the shell quotes it for you so it can't inject syntax.

Open the file in your editor with **File ▸ Edit Keymap…** or the ⌃⇧P palette ("Edit Keymap"): it opens in a 95% overlay running `$VISUAL`/`$EDITOR` (falling back to `vi`), and reloads automatically when you save and quit. The editor is resolved through your interactive login shell, so an `$EDITOR`/`$VISUAL` set anywhere your normal terminal picks it up (including `~/.zshrc`) is honored.

After editing the file, apply it with **File ▸ Reload Keymap**, the action palette (⌃⇧P → "Reload Keymap"), or `agtermctl keymap reload`. A malformed line never discards the rest of the file — it surfaces in the diagnostics list in Settings ▸ Key Mapping (and `keymap.reload` returns the diagnostic count) while the good lines still apply.

v1 limitations:

- Built-in rebinds are single-chord only; leader sequences (`ctrl+a>g`) work only for custom commands.
- The arrow keys can't be written as a chord, so the arrow-bound actions (`focus_left_pane`, `focus_right_pane`, `previous_session`, `next_session`, `previous_attention_session`, `next_attention_session`) keep their default shortcuts unless you `map` them to a parseable chord. The literal `+` and `>` can't be a bare key token (they are the chord-joiner and leader separators), but those keys are still bindable as `shift+=` and `shift+.`. Only `increase_font_size`'s default ⌘+ shows as a glyph rather than editable text, because its stored form doesn't round-trip through the file.
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

Programs running in the terminal can read and write the macOS clipboard over OSC 52. agterm prompts before a program **reads** your clipboard, because a read hands its contents (which may include passwords or tokens) back to the program; a normal ⌘V paste is never prompted. Clipboard **writes** go through by default, matching other terminals so a remote `tmux`/`vim` yank still reaches your clipboard. To gate writes too, set `clipboard-write = ask` (prompt) or `clipboard-write = deny` (block) in `ghostty.conf`. Each prompt offers *Don't ask again this session*, which remembers your choice until agterm quits.

A ⌘-click on a `file://` link — the kind `ls --hyperlink`, `eza`, and many compilers emit — reveals the file in Finder instead of opening it. A terminal renders untrusted program output, so a link could point at a `.app` or `.command`; revealing selects the file without running it, which is the security boundary — actually opening it stays a separate, explicit action. Web (`http`/`https`) and `mailto` links still open as before. A `file://` link that names another host is ignored rather than revealed, so a stray link can't trigger a Finder network mount.

Open the file with **File ▸ Edit ghostty.conf…** or the ⌃⇧P palette ("Edit ghostty.conf"): it opens in a 95% overlay running `$VISUAL`/`$EDITOR` (falling back to `vi`), the same as Edit Keymap, and reloads when you save and quit. Apply edits made elsewhere with **File ▸ Reload Config**, the action palette ("Reload Config"), or `agtermctl config reload`. A malformed line does not break the load: the bad lines are skipped and the good ones still apply. The diagnostic count (shown in a banner and returned by `config.reload`) covers every ghostty config source, not just `ghostty.conf`, because the diagnostics do not record which file they came from. The Console log shows the offending line.

## Agent status

A coding agent running in a session can flag its status on that session's sidebar row, so you can tell at a glance which of many concurrent agents needs you. The status shows as a small tinted SF Symbol just left of the notification badge: `active` is a blue ellipsis, `blocked` an amber exclamation, `completed` a green check, and `idle` is nothing. The glyph shows on every non-idle session, the selected one included. A one-time `completed` flash auto-clears once you visit the session.

When the sidebar is hidden the per-session glyphs go with it, so the same signal is available two more ways. An optional **title-bar bell** (turn on **Show attention indicator** in Settings ▸ General ▸ Notifications; off by default) reflects the window at a glance: dimmed when nothing needs attention, plain when a session is active or completed, and a filled amber bell when any session is blocked. Clicking it — or pressing ⌃⇧I, choosing **Navigate ▸ Go to Attention…**, or the action palette's "Show Attention" — opens the **attention list**: a palette of just this window's non-idle sessions, each with its status glyph, sorted blocked → active → completed (newest change first). Enter jumps to the session. Over the control channel, `agtermctl tree --json` now reports each session's `status` (omitted when idle) and `statusPane` (`left`|`right`|`scratch` — which pane set the status, omitted when idle or unset).

**Auto-follow blocked sessions.** When several agents run at once, a session that blocks is easy to miss. Turn on **Settings ▸ Agent Status ▸ Auto-follow blocked sessions** (Disabled by default, or a 5s/10s/30s/60s/5m idle timeout) and, after you have been idle from input for that long, the window selects and focuses the oldest blocked session, so you are pulled to whatever agent is waiting. It is per-window and window-wide (crossing workspaces within the window), and always picks the oldest blocked session first. Being parked on a blocked session suppresses further jumps until you type a reply, which clears its glyph and re-arms the timer for the next one. The opt-in **Don't auto-follow away from a running session** (off by default) also holds the selection put while the current session is `active`. Over the control channel, `agtermctl tree --json` reports the window's `idleMs` (milliseconds since your last input, live) and `autoFollowMs` (the configured timeout in milliseconds, omitted when Disabled); `agtermctl window list --json` reports `autoFollowMs` per window (as of the last refresh), but not the live `idleMs`.

For a coding agent this overlaps with a desktop notification: both are ways for a session to get your attention, and in agentic use either can carry the same "I need you" signal, so the two are largely interchangeable. The difference is what stays behind. A notification (OSC 9/777 or `agtermctl notify`) is a one-shot banner and badge with no lasting state. Agent status is a typed, persistent state that stays on the row until you act on it, tells working (`active`) apart from waiting (`blocked`) and finished (`completed`), and powers the attention list, the title-bar bell, and attention navigation (⌃⌥↑/↓). So for an agent flagging that it needs you, prefer agent status: it is more accurate and plugs into the attention UI, while a notification is best kept for a one-off nudge that needs no follow-up.

An agent sets it over the control channel:

```sh
agtermctl session status active --target "$AGTERM_SESSION_ID"      # agent started working
agtermctl session status blocked --target "$AGTERM_SESSION_ID"     # waiting on you
agtermctl session status completed --auto-reset --target "$AGTERM_SESSION_ID"  # done; clears when seen
agtermctl session status blocked --sound default --target "$AGTERM_SESSION_ID" # waiting on you, with a beep
agtermctl session status blocked --color '#ff0000' --target "$AGTERM_SESSION_ID" # per-call red tint
agtermctl session status blocked --pane right --target "$AGTERM_SESSION_ID" # a split-pane agent tags its pane
agtermctl session status idle --target "$AGTERM_SESSION_ID"        # clear it
```

`<state>` is one of `idle | active | completed | blocked`. `--blink` pulses the icon for attention. `--auto-reset` makes the indicator clear back to idle the moment you visit (select) the session — used for a finished result you only need to notice once; without it the status is kept until something changes it. `--sound` plays a one-shot sound when the status is set — `default` for the system alert sound, or a system sound name (`Basso`, `Blow`, `Bottle`, `Frog`, `Funk`, `Glass`, `Hero`, `Morse`, `Ping`, `Pop`, `Purr`, `Sosumi`, `Submarine`, `Tink`, plus any custom sound in `~/Library/Sounds`); it is optional and entirely caller-driven, so the agent decides when a status change is worth an audible nudge. If you'd rather have a blocked prompt always make a sound without touching the hooks, set **Settings ▸ Agent Status ▸ Blocked sound** to a system sound (default None) — it plays whenever a session becomes `blocked`, and an explicit `--sound` on the call still overrides it. `--color` (`#rrggbb`) overrides the glyph tint for that one call — it rides the status, so the next `session status` without `--color` reverts to the configured color; use it to distinguish states beyond the fixed palette (say, a caller-specific blocked color). `--pane` (`left`|`right`|`scratch`, defaulting to `left` = the main pane when omitted) records which pane set the status, which has two effects: a status set from a background pane survives foreground typing in a *different* pane (only a keystroke in the owning pane clears it), and any GUI selection of the session (auto-follow, attention nav ⌃⌥↑/↓, plain session nav, the command palettes, and a sidebar click) reveals and focuses the tagged pane — flipping to the split, or showing a hidden scratch — instead of the main pane, so an agent running in a split or scratch should set its own pane to be found (the control `session go next-attention` only steps the selection, it does not itself move focus into the pane). It reads back on `tree` as each session's `statusPane`. The target session can live in any window, frontmost or not. Typing into a session that's flagged for your attention (`blocked` or `completed`) clears its status back to idle, so answering a prompt or re-engaging with a finished session drops the glyph immediately. An `active` (working) session is left alone for ordinary typing — except Esc, which interrupts the agent and also clears the glyph, so cancelling a prompt drops it at once even if the `blocked` waiting-state hadn't appeared yet.

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

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for more information.
