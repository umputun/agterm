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
- Rename inline (double-click a row or use its `Rename` context-menu item). Close a session from its context menu, or it closes itself when the shell exits.
- Move a session between workspaces by dragging it onto another workspace (native `NSOutlineView` drag-and-drop) or via the row's `Move to` menu. The same session instance is kept either way, so its surface and live shell survive the move.
- Compact git status in each sidebar session row: ahead/behind arrows and a dirty marker (for example `↑5 ↓2 *3`, where `*3` is the conventional git dirty marker plus the changed-file count), shown only when the session's working directory is a git work tree and there is something to report. The name truncates before the tokens.
- A detailed git pill in the window title bar for the active session, alongside the session name: branch (or `detached @ <shortsha>`), ahead/behind, a linked-worktree chip, and a dimmed `*N` dirty marker. No pill when the directory is not a git work tree.
- A quick terminal: a single scratch terminal overlaid at 90% of the window (toolbar button next to the split toggle), opening in the active session's directory. Click the button again or the surrounding margin to dismiss; hiding keeps its shell alive. It is not persisted across launches.
- A standard macOS menu bar mirrors the in-app actions with keyboard shortcuts: **File** — New Session (⌘N), New Workspace (⇧⌘N), Open Directory… (⌘O), Rename Session/Workspace, Close Session (⌘W, terminal-style: closes the active session); **View** — Split (⌘D), Quick Terminal (⌃`), the command palettes, Increase/Decrease/Actual font size (⌘+/⌘−/⌘0), Hide/Show Status Bar (⌘/).
- Two fuzzy-search command palettes (type to filter, ↑/↓ to move, Enter to run, Esc to dismiss): the **session switcher** (⌃P) jumps between open sessions by name or working directory, and the **action palette** (⌃⇧P) runs any command (new/rename/close, split, quick terminal, font size, move session to a workspace, …). Results sort by match quality then alphabetically. Both are also in the View menu.
- A Ctrl-Tab session switcher (macOS app-switcher style): hold Ctrl and tap Tab to walk a most-recently-used list of sessions across all workspaces (the previous session pre-selected on top, Ctrl+Shift+Tab reverses), then release Ctrl to switch. A quick tap of Ctrl+Tab flips straight to the previously visited session.
- A Settings window (Cmd+,) with **General**, **Appearance**, and **Key Mapping** tabs (General and Key Mapping are placeholders for now). **Appearance** sets the terminal font family, default font size, and ghostty theme (any of the 512 bundled themes); changes persist and apply live to open terminals. Applying an appearance change resets per-session cmd-+/- zoom to the default.
- Auto-persist on every change and on quit; restore the tree, names, selection, each session's working directory and font size, the split state, and the status-bar visibility on the next launch.

## Restore limitations

Restore reconstructs the structure, not the running processes. Three limitations follow from the design:

1. Live processes are not reattached. A running `vim` or `npm run dev` does not survive a restart. Each restored session re-spawns a fresh login shell in its saved working directory. True process survival would require a tmux-style backend, which is out of scope.
2. The saved working directory depends on the `GHOSTTY_ACTION_PWD` callback, which only fires when the shell has Ghostty shell-integration / OSC 7 active (auto-injected for zsh, bash, fish, and nu when the shell-integration resources are present). If the working directory is never reported, a session restores to the directory it was created in.
3. The live working directory is persisted on quit and on every structural change (adding, closing, moving, renaming, or selecting a session), but not on every `cd` — OSC 7 fires on each prompt redraw, so saving each one would thrash the disk. A crash or force-quit therefore loses only the working-directory changes made since the last structural change or quit.

## Attribution

The libghostty integration files (app initialization, runtime callbacks, surface `NSView`, resource resolution) are adapted from [macterm](https://github.com/thdxg/macterm) (`thdxg/macterm`, MIT), which builds under the same Swift 6 strict-concurrency toolchain `agt` targets. The model, sidebar, and persistence are original to `agt`.
