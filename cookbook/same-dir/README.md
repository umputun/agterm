# Same directory split

Sync the active pane's working directory into the opposite split pane.

## What it does

One key chord syncs your current working directory to the opposite split pane (`cd <cwd>`).

- **Bidirectional:** If you are sitting in the left pane, it syncs to the right pane. If you are sitting in the right pane, it syncs to the left pane.
- **Auto-split:** If no split is currently shown, it opens the right split first and navigates it to the active directory.
- **TUI Protection:** If the target pane is currently running a foreground process or TUI (such as `claude`, `lazygit`, or `nvim`), it stops immediately and displays an agterm notification rather than typing commands into an active program. This includes hidden splits: a pane hidden with `session split off` keeps its shell alive, and the script checks its foreground process before re-showing it.

## Requirements

- agterm 0.10.0 or later, where custom commands began exporting `AGT_*` environment variables and `tree` gained `splitFocused`, `foreground`, and `splitForeground`.
- `jq`, for parsing `agtermctl tree --json`.
- `zsh`, the script's interpreter.

## Setup

Place `same-dir.zsh` in your `PATH` or a scripts directory (e.g. `~/.agterm-cookbook-bin/same-dir.zsh`) and make it executable (`chmod +x same-dir.zsh`).

Add a custom command line to `~/.config/agterm/keymap.conf`:

```
command "Same Dir" ctrl+a>c ~/.agterm-cookbook-bin/same-dir.zsh
```

Apply the keymap with File ▸ Reload Keymap or `agtermctl keymap reload`.

## Usage

Press `ctrl+a` then `c` (or select `Same Dir` from the custom action palette with `ctrl+shift+o`).

The script reads the active pane's working directory (`$AGT_SESSION_PWD`), checks whether the target pane is sitting idle at a shell prompt, and types `cd "<cwd>"` into it.

## How it works

`agtermctl tree --json` reports the layout state for every session:
- `.split` indicates whether a split pane is currently **shown** (not whether one exists). `session split off` hides the pane while keeping its shell alive.
- `.splitFocused` reports which pane currently holds keyboard focus (`true` for right/split, `false` for left/main).
- `.foreground` and `.splitForeground` report the live foreground process of each pane. When a pane is sitting idle at its shell prompt, its foreground process field is `null`.

The script reads the active session from the tree, picks the opposite pane, and checks its foreground process. A non-null foreground means something is running there, so it notifies and exits. Otherwise it types `cd "<cwd>"` into the target pane with `agtermctl session type --stdin --pane <target>`.

When the split does not exist yet, `session split on` creates it, but the surface appears asynchronously. The script retries the type up to ten times to let the pane become ready.

## Limits

- **Shell prompts only:** If the target pane is running a process (e.g. `claude` or `lazygit`), the script will not change its directory and displays a notification instead.
- **Standard shells:** Typing `cd "<cwd>"` assumes the target pane is running a shell that understands `cd` (such as `zsh`, `fish`, or `bash`).
- **Realization delay:** A freshly opened split may take up to a second to become ready for typed input. The retry loop waits up to one second; if the surface still has not appeared, the script displays a failure notification.
