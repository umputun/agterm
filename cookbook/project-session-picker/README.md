# Project session picker

Use Television to jump to an agterm session or open a zoxide project folder, reusing a session already associated with that folder.

Author: [@sysradium](https://github.com/sysradium), from [discussion #933](https://github.com/umputun/agterm/discussions/933)

## What it does

A key opens Television in an agterm overlay. The list combines the current window's shell sessions with folders from `zoxide query -l`. Pick a session to focus it. Pick a folder to focus a session associated with that exact folder, or create a shell session there when none matches. A new session goes into a workspace named after the folder's basename; an existing workspace with that name is reused.

## Requirements

- agterm 0.39.0 or later. `tree` reports each session's `lastSelectedAt` and `content` from that release; the other commands the script uses predate it.
- `zsh`, `jq`, [zoxide](https://github.com/ajeetdsouza/zoxide), and [Television](https://github.com/alexpasmantier/television) (`tv`).
- zoxide must be initialized in your interactive shell and have folders in its database.

## Setup

Copy the script to your agterm config directory and make it executable:

```sh
mkdir -p ~/.config/agterm
cp project-session-picker.zsh ~/.config/agterm/
chmod +x ~/.config/agterm/project-session-picker.zsh
```

Add this line to `~/.config/agterm/keymap.conf` and reload the keymap. Change `cmd+k` if it is already bound in your configuration:

```text
command "Projects" cmd+k agtermctl session overlay open "zsh -lc '$HOME/.config/agterm/project-session-picker.zsh $AGT_WINDOW_ID'" --size-percent 90 --follow --target "$AGT_SESSION_ID" --window "$AGT_WINDOW_ID" --socket "$AGT_SOCKET"
```

The script prepends `AGT_BIN_PATH` to `PATH`, defaulting to `/opt/homebrew/bin:/usr/local/bin` for common macOS installations. If your tools are elsewhere, `export AGT_BIN_PATH` in `~/.zprofile` with their colon-separated directories. `export AGTERMCTL` there with the CLI's full path if it is not on `PATH`. `zsh -lc` loads that file, but the script runs as its child, so a variable set without `export` never reaches it. The keymap command itself also needs to find `agtermctl`, so use its full path on the keymap line if necessary.

## Usage

Press ⌘K. Type to filter the combined list. Enter chooses a session or folder; Esc cancels. Sessions have a `●` prefix and show their workspace and current directory. Zoxide entries have a `Folder` prefix. Selecting a folder again focuses the same session, even after that session changes directory, provided its origin was recorded.

## How it works

The custom command launches an overlay because Television needs a terminal. The overlay runs the script, and Television calls its `--list` mode to generate rows. Session rows hold agterm IDs. Folder rows hold base64-encoded paths so separators and spaces in paths do not alter the selected value.

For a selected folder, the script reads `tree --json` for the window where the key was pressed. Its state file maps session IDs to folders previously selected through this picker. A saved origin takes precedence over a session's current `cwd`; otherwise an unmapped session matches only when its current `cwd` equals the selected folder. Among matches, the most recently selected session wins. The state lives at `${XDG_STATE_HOME:-$HOME/.local/state}/agterm/project-session-picker.json`.

The overlay starts with agterm's app environment, which may lack Homebrew's `PATH`; the script adds the standard Homebrew directories before calling `tv`, `zoxide`, and `jq`. It passes the overlay's socket to `agtermctl` when available. If the overlay flashes and closes, a tool is likely missing and its error closed with the overlay; run the script from a shell, passing a window ID from `agtermctl tree --json`, to see it.

## Limits

Only sessions in the window where you pressed the key appear or match. The recipe does not search other agterm windows.

An existing session has no recorded launch folder until you select its folder through this picker. Before that, its *current* working directory is the fallback; after you `cd` elsewhere, the script cannot infer where it started. A folder under another folder is not a match: folder paths are compared exactly, not by prefix. If several sessions match, one is selected by recency; the picker does not ask which one.

Selecting a folder with no match creates a session and possibly a workspace. No sessions or workspaces are closed. Projects whose folders share a basename share the same workspace name, though their session matches still use full paths. The JSON state file can retain IDs of closed sessions; they are ignored because matching checks the live tree. If the state file cannot be written, reuse after a session changes directory may fail. Folder names containing newlines are not supported by zoxide's line-based list.
