# Open selected path

Select a file path an agent printed, press a chord, and read the file in a viewer in an overlay over that session, at the line the path named.

## What it does

Agents print paths all the time: `see docs/plans/2026-09-29-spec.md`, `fixed in src/app/Model.swift:566`. Reading one means copying it, finding the right directory, and typing an editor command.

With this recipe you select the path (a double-click usually does it) and press the chord. The file opens in a 90% overlay over the session, with the cursor on line 566 when the selection carried `:566`. Quitting the viewer closes the overlay.

The path is usually relative to wherever the agent was working, which is often not the pane's directory. The script tries these places in order, and the first that holds a regular file wins:

1. the path itself, when it is absolute or starts with `~/`;
2. the pane's directory;
3. the root of the git repo the pane sits in;
4. the main checkout, when the pane sits in a worktree;
5. the repo's other worktrees, for a path an agent printed from its own worktree;
6. any tracked file in the repo whose path ends with the selection;
7. Spotlight, matching the end of the full path.

One match inside the repo opens directly. Several matches, or any Spotlight match, go through the native picker first, since a Spotlight hit may sit in another repo.

## Requirements

- agterm 0.30.1 or later, for `session hud --hide-after`, which takes the "not found" panel down by itself.
- Python 3.9 or later, which macOS ships as `/usr/bin/python3`.
- A terminal viewer or editor. The default is `$VISUAL`, then `$EDITOR`, then `vi`.

Set `AGTERMCTL` if your binary is somewhere unusual. The script otherwise takes the `agtermctl` on the chord's widened `PATH`. The viewer is resolved to an absolute path, looking in `/opt/homebrew/bin` and `/usr/local/bin` as well, because an overlay runs under agterm's own `PATH`, not your shell's.

## Setup

Copy the script somewhere on your machine, say `~/bin/`, and make it executable:

```sh
mkdir -p ~/bin && cp open-selected-path.py ~/bin/ && chmod +x ~/bin/open-selected-path.py
```

Add an entry to `~/.config/agterm/keymap.conf` and apply it with File ▸ Reload Keymap or `agtermctl keymap reload`:

```
command "Open path ›" cmd+shift+o ~/bin/open-selected-path.py
```

agterm is started by launchd, so `$VISUAL` and `$EDITOR` from your shell profile usually do not reach the chord. Name the viewer on the line instead. `OPEN_PATH_VIEWER` is a command template where `{path}` and `{line}` are replaced, each quoted, and `{line}` is `1` when the selection carried none:

```
command "Open path ›" cmd+shift+o OPEN_PATH_VIEWER='nvim -R +{line} {path}' ~/bin/open-selected-path.py
command "Open path ›" cmd+shift+o OPEN_PATH_VIEWER='bat --paging=always --highlight-line {line} {path}' ~/bin/open-selected-path.py
```

`OPEN_PATH_OVERLAY_PERCENT` sizes the overlay, default `90`. `OPEN_PATH_HUD_SECONDS` sets how long the "not found" panel stays up, default `4`. `OPEN_PATH_MDFIND` replaces the `mdfind` binary, and `OPEN_PATH_MDFIND=false` turns the Spotlight step off.

## Usage

Select a path in any pane and press the chord. The selection may carry quotes, backticks, brackets or trailing punctuation, so `` `README.md`. `` works as well as `README.md`. A trailing `:N`, `:N-M` or `:N:C` becomes the line.

In a split, the overlay covers the pane you pressed the chord in, and the lookup starts from that pane's directory.

The script carries its own tests, which is what to run after editing the lookup:

```sh
./open-selected-path.py --test
```

A selection that is empty, is not a path, or names no file posts a panel over the session saying which. So does a viewer that is not installed.

## How it works

The selection is terminal text, so the script checks its shape before using it: a length cap, no control characters, and a path-like character set. Anything else stops at the panel.

The pane's directory is `$AGT_SESSION_PWD`, which the shell reports through OSC 7. The git steps run `git` with `core.fsmonitor` switched off, so a repo's own config cannot start a program. The suffix step matches whole path components against `git ls-files`, so `Model.swift` never matches `OldModel.swift`.

The viewer command is built with `shlex.join` from the template, so a path with spaces or quotes reaches the viewer as one argument. The overlay starts in the file's directory.

## Limits

- The lookup is local. In a pane running ssh, the pane's directory names a directory on the far machine, and the file opens only if the same path exists here.
- `$AGT_SESSION_PWD` is whatever the program in the pane last reported. A program you do not trust can point it anywhere.
- Keep the viewer a reader or an editor. A viewer such as `open` hands the file to LaunchServices, which runs an `.app` or `.command`, and the selection is text a program printed.
- Spotlight skips hidden directories such as `.claude/worktrees/`, and any repo excluded from indexing. Those files are found through the git steps alone.
