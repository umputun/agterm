# agt

`agt` is a small native macOS terminal built on [libghostty](https://ghostty.org), Ghostty's terminal embedding library. The app shell is SwiftUI, with two focused AppKit bridges: the terminal surface (libghostty renders into a Metal layer and needs raw key, IME, and mouse events SwiftUI does not expose) and the sidebar, an `NSOutlineView` chosen for first-class native drag-and-drop of sessions between workspaces.

The distinguishing feature is a two-level workspace tree in a vertical sidebar: user-named workspaces (for example "work", "personal") each contain individual shell sessions. Ghostty itself has no vertical tabs and no workspace grouping; `agt` provides exactly that and nothing more.

## Approach

`agt` links the prebuilt `GhosttyKit.xcframework` from the [thdxg/ghostty](https://github.com/thdxg/ghostty) fork's release artifacts. There is no Zig build, no git submodule, and no source checkout of Ghostty. The xcframework and the accompanying ghostty resources (themes, shell-integration scripts, compiled terminfo database) are downloaded by `scripts/setup.sh`, are gitignored, and are never committed.

The project is split into two modules:

- `agtCore` is a host-free Swift package (Foundation and Observation only, no GhosttyKit, AppKit, or Metal). It holds the model, persistence, and naming logic and is covered by unit tests.
- The app target adds the SwiftUI views and the libghostty bridge.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the module split, the surface-ownership rules, and the concurrency contract at the C boundary.

## Requirements

- macOS 14 or later.
- Xcode 26 with `xcodegen` and `gh` on `PATH`.

## Build and run

```sh
scripts/setup.sh   # download the xcframework + ghostty resources (idempotent)
scripts/run.sh     # setup, generate the Xcode project, build Debug, launch
```

`scripts/build.sh` produces a Release build without launching. The unit tests run independently of Xcode and libghostty:

```sh
cd agtCore && swift test
```

`scripts/test.sh` is a wrapper for the same command. UI behavior (rename, close, move, drag, add-session) is covered by XCUITests in `agtUITests/` that drive the running app through the accessibility API:

```sh
xcodebuild test -project agt.xcodeproj -scheme agt -destination 'platform=macOS'
```

## Features

- Two-level sidebar tree: workspaces, each containing sessions. One libghostty surface per session. Each row carries a leading kind icon: a filled folder for a workspace, an outlined terminal for a session.
- Default session name is the basename of the session's working directory. Renaming a session pins a custom name; clearing it reverts to the basename.
- Add workspaces and sessions from a two-icon bar at the bottom of the sidebar: a workspace button, and a session menu offering **New Session** (a shell in the home directory) and **Open Directory…** (a folder picker that roots the session there). The two session actions are also on each workspace row's right-click menu, so a specific or empty workspace can be targeted.
- Rename inline (double-click a row or use its `Rename` context-menu item). Close a session from its context menu, or it closes itself when the shell exits. Delete a whole workspace from its right-click menu (also in the menu bar and the action palette); a non-empty workspace asks to confirm first, and the last remaining workspace can't be deleted.
- Move a session between workspaces by dragging it onto another workspace (native `NSOutlineView` drag-and-drop) or via the row's `Move to` menu. The same session instance is kept either way, so its surface and live shell survive the move.
- Compact git status in each sidebar session row: ahead/behind arrows and a dirty marker (for example `↑5 ↓2 *3`, where `*3` is the conventional git dirty marker plus the changed-file count), shown only when the session's working directory is a git work tree and there is something to report. The name truncates before the tokens.
- A detailed git pill in the window title bar for the active session, alongside the session name: branch (or `detached @ <shortsha>`), ahead/behind, a linked-worktree chip, and a dimmed `*N` dirty marker. No pill when the directory is not a git work tree.
- A quick terminal: a single scratch terminal overlaid at 90% of the window (toolbar button next to the split toggle), opening in the active session's directory. Click the button again or the surrounding margin to dismiss; hiding keeps its shell alive. It is not persisted across launches.
- A standard macOS menu bar mirrors the in-app actions with keyboard shortcuts: **File** — New Session (⌘N), New Workspace (⇧⌘N), Open Directory… (⌘O), Rename Session/Workspace, Delete Workspace, Close Session (⌘W, terminal-style: closes the active session); **View** — Split (⌘D), Quick Terminal (⌃`), the command palettes, Increase/Decrease/Actual font size (⌘+/⌘−/⌘0), Hide/Show Status Bar (⌘/).
- Two fuzzy-search command palettes (type to filter, ↑/↓ to move, Enter to run, Esc to dismiss): the **session switcher** (⌃P) jumps between open sessions by name or working directory, and the **action palette** (⌃⇧P) runs any command (new/rename/close, delete workspace, split, quick terminal, font size, move session to a workspace, …). Results sort by match quality then alphabetically. Both are also in the View menu.
- A Ctrl-Tab session switcher (macOS app-switcher style): hold Ctrl and tap Tab to walk a most-recently-used list of sessions across all workspaces (the previous session pre-selected on top, Ctrl+Shift+Tab reverses), then release Ctrl to switch. A quick tap of Ctrl+Tab flips straight to the previously visited session.
- A Settings window (Cmd+,) with **General**, **Appearance**, and **Key Mapping** tabs (General and Key Mapping are placeholders for now). **Appearance** sets the terminal font family, default font size, and ghostty theme (any of the 512 bundled themes); changes persist and apply live to open terminals. Applying an appearance change resets per-session cmd-+/- zoom to the default.
- Auto-persist on every change and on quit; restore the tree, names, selection, each session's working directory and font size, the split state, and the status-bar visibility on the next launch.

## Scripting agt

`agt` can be driven from a script over a local unix-domain socket through a companion CLI, `agtctl`. This is for personal scripting — fire-and-forget commands that manage workspaces and sessions, inject text, and invoke control actions. There is no terminal-output streaming and no event subscription.

`agtctl` lives in the `agtCore` Swift package and builds without Xcode or libghostty:

```sh
cd agtCore && swift build -c release
# the binary is at agtCore/.build/release/agtctl
```

Each command targets a session or workspace by its UUID, a unique prefix of that UUID (git-style), or the keyword `active` (the selected session / current workspace). `--target` defaults to `active`, so the current one rarely needs to be named. Mutating commands print the affected id; `tree` prints the workspace and session tree. Add `--json` for the raw response, or `--socket PATH` to override the socket path. The exit code is zero on success, non-zero on error.

`--workspace`/`--target` take an id, a unique id prefix, or `active` — never a name. To create a workspace and then open a session in it, capture the printed id:

```sh
agtctl tree                                   # print the workspace/session tree with ids
ws=$(agtctl workspace new work)               # create a workspace, capture its id
agtctl session new --workspace "$ws" --cwd ~/src/agt  # open a session in it, print its id
agtctl session type --target 9f3c $'make test\n'      # inject text into a session by id prefix
echo 'make test' | agtctl session type --target active --stdin
agtctl session split toggle                   # split the active session
agtctl quick toggle                           # toggle the quick terminal
agtctl statusbar off                          # hide the status bar
agtctl font inc                               # increase the active surface's font size
```

`session type` types the text as real keystrokes, and every newline is a real Return press — so a trailing newline submits the command, and a multi-line payload runs line by line (a multi-line shell construct like a `for` loop is entered across the shell's continuation prompts and runs as one command). Note the `$'…\n'` quoting: a literal `\n` inside plain single quotes reaches the CLI as two characters, not a newline; use `$'…\n'` or pipe a real newline via `--stdin`.

`session copy` returns the target session's selected text in the response (it does not touch the system clipboard), so a script can move a selection from one session to another:

```sh
sel=$(agtctl session copy --target 9f3c)      # the selected text in session 9f3c
agtctl session type --target work --select "$sel"  # paste it into another session
```

With no selection it exits non-zero with `no selection`. The selection must be made in the terminal (drag/Shift-click); `session copy` only reads it.

`session overlay open` runs a program in an ephemeral terminal on top of a session (full size, hiding the single/split content underneath). It is meant for launching an interactive program over a session — the overlay grabs focus, and when the program exits the overlay vanishes and the session reappears unchanged:

```sh
agtctl session overlay open "revdiff HEAD~3" --target 9f3c  # review the last 3 commits over session 9f3c
agtctl session overlay open "htop"                          # on the active session
agtctl session overlay open "make test" --wait              # keep the overlay open after exit (press a key to close)
agtctl session overlay close --target 9f3c                  # close it from a script
```

The overlay renders only for the active session, so select it first (or target `active`). By default it closes the instant the program exits; `--wait` keeps it on a "press any key to close" prompt so you can read the program's final output. A `*` `(overlay)` tag in `agtctl tree` marks a session whose overlay is open.

A session's terminal surface is created lazily — it does not exist until the session has been shown at least once. Injecting text into a never-shown session therefore fails with `session not realized` unless you pass `--select`, which selects the session (realizing its surface) before injecting:

```sh
id=$(agtctl session new --cwd ~/src/agt)
agtctl session type --target "$id" --select $'echo hello\n'
```

## Restore limitations

Restore reconstructs the structure, not the running processes. Three limitations follow from the design:

1. Live processes are not reattached. A running `vim` or `npm run dev` does not survive a restart. Each restored session re-spawns a fresh login shell in its saved working directory. True process survival would require a tmux-style backend, which is out of scope.
2. The saved working directory depends on the `GHOSTTY_ACTION_PWD` callback, which only fires when the shell has Ghostty shell-integration / OSC 7 active (auto-injected for zsh, bash, fish, and nu when the shell-integration resources are present). If the working directory is never reported, a session restores to the directory it was created in.
3. The live working directory is persisted on quit and on every structural change (adding, closing, moving, renaming, or selecting a session), but not on every `cd` — OSC 7 fires on each prompt redraw, so saving each one would thrash the disk. A crash or force-quit therefore loses only the working-directory changes made since the last structural change or quit.

## Attribution

The libghostty integration files (app initialization, runtime callbacks, surface `NSView`, resource resolution) are adapted from [macterm](https://github.com/thdxg/macterm) (`thdxg/macterm`, MIT), which builds under the same Swift 6 strict-concurrency toolchain `agt` targets. The model, sidebar, and persistence are original to `agt`.
