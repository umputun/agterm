# Troubleshooting

A guide to checking what agterm is doing, the most common problems, and how to report one that turns out to be a bug.

## Where things live

Paths assume the defaults. When `AGTERM_STATE_DIR` is set, the state files move under that directory instead of `~/Library/Application Support/agterm`.

- **Keymap**: `~/.config/agterm/keymap.conf` (or `$AGTERM_STATE_DIR/config/keymap.conf`, or a custom directory set in Settings ▸ Key Mapping).
- **Ghostty config**: `~/.config/agterm/ghostty.conf` (same directory as the keymap), an agterm-scoped ghostty config that overrides the bundled defaults and your global `~/.config/ghostty/config`.
- **Settings**: `~/Library/Application Support/agterm/settings.json`.
- **Window and session state**: `~/Library/Application Support/agterm/windows.json` plus one `windows/<id>.json` per window.
- **Control socket**: `~/Library/Application Support/agterm/agterm.sock` (or `$AGTERM_CONTROL_SOCKET` when set). A spawned shell sees the bound path in `$AGTERM_SOCKET`.
- **Logs**: the macOS unified logging system, under the subsystem `com.umputun.agterm`.

## Reading the logs

agterm logs to the unified logging system, so use `log` or Console:

```bash
# the last 30 minutes, all categories
log show --predicate 'subsystem == "com.umputun.agterm"' --info --last 30m

# follow live while you reproduce the problem
log stream --predicate 'subsystem == "com.umputun.agterm"' --info

# narrow to one area
log show --predicate 'subsystem == "com.umputun.agterm" && category == "CustomCommandRunner"' --info --last 30m
```

The categories are `CustomCommandRunner`, `SettingsModel`, `GhosttyApp`, `NotificationManager`, and `ControlServer`. In Console.app, filter on the same subsystem.

## Checking the keymap

After editing `keymap.conf`, nothing changes until you reload it.

- **Settings ▸ Key Mapping** shows a read-only list of parse problems (a malformed line, a dropped binding, a conflict). This is the first place to look when a binding does not behave.
- **File ▸ Reload Keymap** re-reads the file. A reload that found problems posts a banner with the count.
- **`agtermctl keymap reload`** does the same from the command line and prints the diagnostic count (`0` means a clean reload).

## The keymap editor will not open

**Edit Keymap** (File ▸ Edit Keymap…, or the `⌃⇧P` palette) opens `keymap.conf` in `$VISUAL`, else `$EDITOR`, else `vi`, inside a floating overlay over the active session. The overlay runs the editor through your login shell, so the editor resolves the same way it does in a normal terminal — whether your login shell is zsh/bash or fish.

Common causes when nothing usable appears:

1. **A GUI editor without its blocking flag.** Editors like VS Code, Sublime, Zed, and TextMate launch a detached window and return immediately, so the overlay opens and closes in a flash. Set the editor's wait flag so the launcher blocks until you close the file:

   ```bash
   export EDITOR='code -w'     # VS Code; also: 'subl -w', 'zed -w', 'mate -w', 'cursor -w'
   ```

2. **`$EDITOR` unset.** You get `vi` inside the overlay. Press `i` to start typing, then `Esc` and `:wq` to save and quit; the keymap reloads when the editor exits.
3. **No active session, or an overlay is already open.** Edit Keymap is a no-op with no session selected, or while another overlay or the quick terminal is up. Select a session and close any overlay first.

Set and **export** `$EDITOR` or `$VISUAL` in your shell startup file (`export EDITOR=…` in `~/.zshrc`/`~/.bashrc`, or `set -gx EDITOR …` in `~/.config/fish/config.fish`), not just in the current shell. The overlay reads the *exported* value from your login shell, so a value that lives in one terminal session only — or one set without `export` — is not seen and falls back to `vi`.

## A custom action does nothing

Work down this list:

1. **Read the diagnostics.** Open Settings ▸ Key Mapping. A malformed `command` line is listed there and skipped.
2. **Chord conflict.** If your chord collides with a built-in shortcut or with another custom command, the binding is dropped and the command becomes palette-only. It still runs from the action palette (`⌃⇧P`), where it is listed with a `custom` tag. Pick a free chord, or run it from the palette.
3. **Reserved chords.** `ctrl+tab` / `ctrl+shift+tab` (the session switcher) and `ctrl+1` / `ctrl+2` (pane focus) are reserved and cannot be bound.
4. **Modifier-less keys are rejected.** A custom chord needs at least one modifier so it cannot shadow a plain terminal key. `command "x" g …` is palette-only; `command "x" cmd+g …` binds.
5. **Focus.** A custom chord fires only while a terminal pane holds keyboard focus. When the sidebar, the inline rename field, a Settings field, or a palette has focus, the chord passes through. Click into the terminal first.
6. **The command runs in a plain `/bin/sh -c`, not your login shell.** It does not load `~/.zshrc` or `~/.bashrc`, so shell aliases and functions are not available and `PATH` may be shorter than in your terminal. Use absolute paths, or wrap the body in `$SHELL -lc '…'`.
7. **Exit status.** A non-zero exit posts a failure banner with the code. No banner and no effect usually means the chord never fired (causes above). A banner means it ran and failed, which points at the command itself, its `PATH`, or its arguments.
8. **Token quoting.** `{AGT_SELECTION}` and the other `{AGT_*}` tokens expand raw into the shell line. For content that may contain shell metacharacters, use the `$AGT_SELECTION` environment form, which is already quoted. The token list is in the keymap section of the README.

Reload after every edit (File ▸ Reload Keymap, or `agtermctl keymap reload`). Edits are not applied until you do.

## Changing ghostty settings

Most terminal behavior comes from ghostty. The common knobs (font, theme, background opacity and blur, scroll speed) are in agterm's Settings, but any other ghostty key (`macos-option-as-alt`, `keybind`, `window-padding-*`, and so on) is set in a config file.

agterm reads four config sources, each overriding the one before it:

```
ghostty's bundled defaults  →  ~/.config/ghostty/config  →  <config dir>/ghostty.conf  →  agterm Settings
       (lowest)                    (your global config)         (agterm-scoped)             (UI wins)
```

- `<config dir>/ghostty.conf` (default `~/.config/agterm/ghostty.conf`, next to `keymap.conf`) is scoped to agterm only; the standalone Ghostty.app never reads it. Use it for keys you want in agterm but not everywhere.
- `~/.config/ghostty/config` is your global ghostty config, shared with Ghostty.app, and already in the chain.
- The keys agterm sets from its Settings window load last, so the Settings picker wins for what it manages. Put everything else in `ghostty.conf`.

Edit `ghostty.conf` with **File ▸ Edit ghostty.conf…** (or the ⌃⇧P palette), which opens it in `$EDITOR` and reloads on exit, the same as Edit Keymap. After editing it elsewhere, apply it with **File ▸ Reload Config**, the action palette, or `agtermctl config reload`. A malformed line is skipped while the good ones still apply. The diagnostic count (shown in a banner and printed by `config.reload`, where `0` means a clean reload) covers every ghostty config source, not just `ghostty.conf`, because the diagnostics do not record which file they came from. Check the Console log for the offending line.

A reload applies most keys to your open terminals right away — colors, theme, `cursor-style`, `macos-option-as-alt`, and the mouse and clipboard keys all take effect on the visible pane. Two kinds of key cannot change for a terminal that is already running, though:

- **Layout keys** — `window-padding-x`, `window-padding-y`, and other size-affecting keys — do not re-apply to an open pane. libghostty re-derives a surface's padding only when it is first laid out, so a reload (and even resizing the window) leaves existing panes on their old padding. Open a new session or new window to pick up the change; the panes that were already open need a relaunch.
- **Spawn-time keys** — `term` and `shell-integration-features` — are read once when the shell starts, so a reload cannot change them for a shell that is already running. Open a new session, whose shell is spawned fresh, to apply them.

The full ghostty key reference is at <https://ghostty.org/docs/config>.

## Copy/paste and shortcuts on a non-Latin or alternative layout

⌘C and ⌘V copy and paste on any keyboard layout, non-Latin ones (Russian, Greek, and so on) included, because agterm binds them to the physical key positions rather than to the character a layout prints. The physical C and V keys then work no matter what those keys produce in the active layout.

The reason is that ghostty's own copy/paste binds match the produced character: on a Russian layout the physical V key yields `м`, so the built-in `super+v` bind never fires. The bundled agterm defaults add physical-key binds (`super+key_c`, `super+key_v`) that match by position instead.

The same distinction lets you remap any shortcut for your layout:

- A physical key name (`key_c`, `key_v`, `key_a`, and so on) matches the key's position, whatever character it prints.
- A bare letter (`c`, `v`) matches the character the active layout produces at that key.

If you use a Latin alternative layout (Dvorak, Colemak, AZERTY) and want ⌘C/⌘V at your layout's own C and V letters instead of the QWERTY physical positions, override them in `~/.config/agterm/ghostty.conf` with character-based binds, and unbind the physical defaults so the QWERTY positions are freed:

```
keybind = super+key_c=unbind
keybind = super+key_v=unbind
keybind = super+c=copy_to_clipboard
keybind = super+v=paste_from_clipboard
```

Reload with **File ▸ Reload Config** or `agtermctl config reload`. The keybind syntax is at <https://ghostty.org/docs/config/keybind/reference>.

## Other common issues

- **`agtermctl: command not found`.** Install it from Help ▸ Install Command Line Tool… (it symlinks into `/usr/local/bin`). You can also call it by its full path inside the app bundle: `agterm.app/Contents/MacOS/agtermctl`.
- **No desktop notifications.** macOS must have granted permission (System Settings ▸ Notifications ▸ agterm), and Settings ▸ General ▸ Notifications must be on. The unseen-count badge still tracks even when banners are off.
- **Agent-status glyph does not update.** Install the hooks from Help ▸ Install Agent Status Hooks…. For shell-integrated agents, start a fresh shell so the `source` line added to your shell rc takes effect. For Pi, restart it or run `/reload` so it loads `~/.pi/agent/extensions/agterm-status.ts`; Pi status is only installed when `~/.pi/agent` already exists. The hooks call `agtermctl session status`, so `agtermctl` must resolve first (see above).
- **Agent-status glyph updates the wrong session.** One session's glyph blinks while the work happens in another — typically when agents run inside tmux (or a tmux-backed session manager such as agent-deck). The working process inherited another session's `AGTERM_SESSION_ID`: the status hooks target whatever id is in their environment, and a long-lived daemon started from inside an agterm session (a tmux server is the usual carrier) captures that session's `AGTERM_*` variables into its global environment and passes them to every child it ever creates. Check `tmux show-environment -g | grep AGTERM` — if present, clear them with `tmux set-environment -g -r AGTERM_SESSION_ID` (and the other `AGTERM_*` names), then restart the affected panes. To avoid it, start such daemons with the variables scrubbed (`env -u AGTERM_SESSION_ID … <command>`) or from a terminal outside agterm.

## Claude Code's question or permission prompt stops responding after switching apps

While Claude Code shows an interactive prompt (a question menu or a permission dialog), switching to another app and back can leave that prompt unresponsive to the keyboard: the arrow keys and Return do nothing. The regular Claude Code prompt and the shell are unaffected, so you can still type there.

This is a Claude Code bug, not an agterm bug. When a window regains focus, agterm sends the standard terminal focus-in report (`ESC[I`, DEC private mode 1004), which any terminal does once an application turns focus reporting on. Claude Code's dialog input handler consumes that report instead of treating it as focus state, which wedges the prompt. It is tracked upstream as [anthropics/claude-code#72188](https://github.com/anthropics/claude-code/issues/72188); the mouse-click variant is [#72273](https://github.com/anthropics/claude-code/issues/72273).

agterm is behaving correctly: it emits paired focus-in and focus-out reports with nothing stray, and it follows the macOS focus-first convention, so a click that refocuses the window only focuses it and is not forwarded into the terminal. The trigger is the focus report itself, so any terminal with focus reporting on is affected the same way.

Workaround until the upstream fix: answer the prompt before switching away, or if you have already returned to a stuck prompt, press `Esc` to dismiss it and let Claude Code re-ask.

## Reporting a problem

Collect this before filing:

- agterm version (Agterm ▸ About Agterm).
- macOS version.
- The exact steps, what you expected, and what happened instead.
- A log excerpt from the `log show` command above, covering the moment you reproduced it.
- The relevant `keymap.conf` lines, if it is keymap-related.

Scrub anything private (tokens, internal hostnames, usernames embedded in paths) before sharing.

If you run a coding agent inside agterm (Claude Code or Codex with the agterm skill installed), it can help you write and file the report: it drafts an issue for a bug, or a Discussion for a feature request or question, shows it to you first, and never posts without your go-ahead.

Otherwise open one directly:

- Bug: <https://github.com/umputun/agterm/issues/new>
- Idea or question: <https://github.com/umputun/agterm/discussions/new>
