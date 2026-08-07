# Same directory split

Sync the active pane's working directory into the opposite split pane.

## What it does

One key chord syncs your current working directory to the opposite split pane (`cd <cwd>`).

- **Bidirectional:** If you are sitting in the left pane, it syncs to the right pane. If you are sitting in the right pane, it syncs to the left pane.
- **Auto-split:** If no split is currently shown, it opens the right split first and navigates it to the active directory.
- **TUI Protection:** If the target pane is currently running a foreground process or TUI (such as `claude`, `lazygit`, or `nvim`), it stops immediately and displays an agterm notification rather than typing commands into an active program.

## Requirements

- agterm 0.10.0 or later.
- `jq`, for parsing `agtermctl tree --json`.

## Setup

Place `same-dir.sh` in your `PATH` or a scripts directory (e.g. `~/.agterm-cookbook-bin/same-dir.sh`) and make it executable (`chmod +x same-dir.sh`).

Add a custom command line to `~/.config/agterm/keymap.conf`:

```
command "Same Dir" ctrl+a>c ~/.agterm-cookbook-bin/same-dir.sh
```

Apply the keymap with File ▸ Reload Keymap or `agtermctl keymap reload`.

## Usage

Press `ctrl+a` then `c` (or select `Same Dir` from the custom action palette with `ctrl+shift+o`).

The script reads the active pane's working directory (`$AGT_SESSION_PWD`), checks whether the target pane is sitting idle at a shell prompt, and types `cd "<cwd>"` into it.

## How it works

`agtermctl tree --json` reports the layout state for every session:
- `.split` indicates whether a split pane is currently open.
- `.splitFocused` reports which pane currently holds keyboard focus (`true` for right/split, `false` for left/main).
- `.foreground` and `.splitForeground` report the live foreground process of each pane. When a pane is sitting idle at its shell prompt, its foreground process field is `null`.

The script inspects the session tree to identify the non-active target pane (`left` or `right`). If the target pane's foreground process is non-null, the script calls `agtermctl notify` to alert you that the pane is busy and exits without typing. Otherwise, it uses `agtermctl session type --stdin --pane <target>` to inject `cd "<cwd>"` with shell quoting (`printf 'cd %q\n'`).

## Limits

- **Shell prompts only:** If the target pane is running a process (e.g. `claude` or `lazygit`), the script will not change its directory and displays a notification instead.
- **Standard shells:** Typing `cd "<cwd>"` assumes the target pane is running a shell that understands `cd` (such as `zsh`, `fish`, or `bash`).
