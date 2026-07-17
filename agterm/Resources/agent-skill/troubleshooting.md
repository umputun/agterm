<!-- agterm-skill -->

# Troubleshooting agterm and reporting problems

Two jobs: (1) diagnose a problem from inside an agterm session, (2) help the user file it on the repo
as a bug (issue) or a feature/question (Discussion) — safely, never posting without approval.

The full user-facing version of the diagnostics below is the repo's `docs/troubleshooting.md`.

## Diagnosing from inside a session

You are inside agterm (`AGTERM_ENABLED=1`). Use:

- **Live state** — `agtermctl tree --json`, `agtermctl window list --json`.
- **Keymap problems** — `agtermctl keymap reload` prints the parse-diagnostic count (`0` = clean). A
  non-zero count means `keymap.conf` has problems; the user sees the list in Settings ▸ Key Mapping.
- **Ghostty settings** - `agtermctl config reload` re-reads the ghostty config and prints the diagnostic
  count (`0` = clean). The count covers every config source, not just `ghostty.conf` (libghostty does not
  record which file a diagnostic came from), so check the Console log for the offending line. `ghostty.conf`
  (next to `keymap.conf`, always loaded) is where agterm customizations go; it overrides the bundled
  defaults, and the global `~/.config/ghostty/config` is NOT loaded unless Settings ▸ General ▸ Use my
  global Ghostty config is on. agterm's Settings (font/theme/opacity/scroll) still win. Use it for keys the UI does not expose, e.g.
  `macos-option-as-alt`. Most keys apply to open panes on reload, but layout keys (`window-padding-*`)
  and spawn-time keys (`term`, `shell-integration-features`) only take effect in a new session/window
  or after a relaunch. Full reference: https://ghostty.org/docs/config
- **Logs** (unified logging, subsystem `com.umputun.agterm`):
  ```bash
  log show --predicate 'subsystem == "com.umputun.agterm"' --info --last 30m
  ```
  Categories: `CustomCommandRunner`, `SettingsModel`, `GhosttyApp`, `NotificationManager`, `ControlServer`.
- **Files** — keymap `~/.config/agterm/keymap.conf`; agterm-scoped ghostty config
  `~/.config/agterm/ghostty.conf`; settings `~/Library/Application Support/agterm/settings.json`;
  socket path in `$AGTERM_SOCKET`.

### "Keymap editor won't open"

Edit Keymap runs `$VISUAL`/`$EDITOR` (else `vi`) in an overlay via the login shell. The most common
cause is a **GUI editor launched without a blocking flag** (`code`, `subl`, `zed`, `mate`, `cursor`):
it returns immediately, so the overlay flashes shut. Fix: `export EDITOR='code -w'` (the editor's wait
flag) in the shell rc. `$EDITOR`/`$VISUAL` must be **exported** (`export EDITOR=…`, or fish `set -gx
EDITOR …`) so it resolves regardless of your login shell — a non-exported value falls back to `vi`. It
also no-ops with no session selected or an overlay already open.

### "Custom action does nothing"

Causes, in order: a parse error (see the diagnostics); the chord conflicts with a built-in or another
custom command and was dropped to palette-only (it still runs from `⌃⇧P`, tagged `custom`); a reserved
chord (`ctrl+tab`, `ctrl+1`/`ctrl+2`); a modifier-less key (rejected — a custom chord needs a
modifier); it only fires while a terminal pane has keyboard focus; it runs in a non-interactive
`/bin/sh -c` (no aliases/functions, a smaller `PATH` — use absolute paths or `$SHELL -lc '…'`); a
non-zero exit posts a failure banner (meaning it DID fire and failed). Reload after edits:
`agtermctl keymap reload`.

### "An overlay or --command session opens then instantly closes"

The program exited immediately. Check `agtermctl session overlay result --json` — `exitCode: 127` is
"command not found": `session overlay open`, `session scratch --command`, and `session new --command`
run the program with the app's GUI `PATH` (the launchd default — no `/opt/homebrew/bin`), NOT your login
shell's PATH, so a bare Homebrew or other non-default binary isn't found. Fix: give an absolute path
(`/opt/homebrew/bin/htop`) or wrap in a login shell (`zsh -lc 'htop'`). Any OTHER exit code just means
the program ran and exited on its own — the overlay/session closes when its command finishes, by design.

⌘C/⌘V/⌘A copy/paste/select-all on any layout by default, via two layers.

The **Edit menu** owns them first: its stock Copy/Paste/Select All items carry ⌘C/⌘V/⌘A as menu key
equivalents, which AppKit matches against the character the layout produces. An enabled item consumes the
key before the terminal sees it. The items enable only when the terminal can service them — Copy needs a
selection, Paste needs something pasteable on the clipboard (text, or a file/web URL, which pastes as a
shell-escaped path), Select All needs a live surface. Cut stays disabled for the terminal (it still works in
a text field, such as the inline rename or a palette's search box). Undo and Redo are not in the menu at all:
agterm has no undo, and ⌘Z belongs to File ▸ Reopen Closed Item. Because these are standard menu shortcuts,
⌘C/⌘V/⌘A are NOT rebindable through `ghostty.conf`.

agterm's bundled ghostty defaults are the **fallback**, binding all three to the physical key POSITIONS
(`super+key_c`/`super+key_v`/`super+key_a`), matched by keycode regardless of the character the layout
prints. They fire whenever the menu equivalent does not: on a Russian/Greek/etc. layout the physical C key
yields `с`, so the menu's ⌘C never matches and the keycode bind runs instead; likewise a ⌘C with no
selection leaves the menu item disabled, so the key falls through (and ghostty's `performable:` prefix makes
it a no-op). This is why copy, paste, and select-all all keep working on a non-Latin layout. (ghostty's own
`super+c`/`super+v`/`super+a` match the produced CHARACTER, so alone they would miss there — `super+key_a`
in particular exists because without it ⌘A would silently do nothing on a Cyrillic layout.)

To remap a shortcut ghostty still owns: a physical key name (`key_c`, `key_v`, …) matches by position on
any layout; a bare letter (`c`, `v`) matches the produced character. Edit `~/.config/agterm/ghostty.conf`,
then `agtermctl config reload`.

### "The agent-status glyph does not update"

Install the hooks from Help ▸ Install Agent Status Hooks…. For shell-integrated agents, start a fresh shell
so the installer-added `source` line takes effect. For Pi, restart it or run `/reload` so it loads
`~/.pi/agent/extensions/agterm-status.ts`; the extension installs only after Pi has created `~/.pi/agent`.
The installed wrapper resolves the bundled `agtermctl` itself; a bare development build instead needs
`agtermctl` on `PATH`.

### "The agent-status glyph updates the wrong session"

One session's glyph blinks/changes while the work is happening in a DIFFERENT session — typically when
the agents run inside tmux (or a tmux-backed session manager like agent-deck). Cause: the working
process inherited another session's `AGTERM_SESSION_ID`, and the agent-status hook targets whatever id
it finds in its environment. The usual carrier is a long-lived daemon started from inside an agterm
session — a tmux server captures the spawning shell's `AGTERM_*` into its GLOBAL environment
(`tmux show-environment -g | grep AGTERM`), and every pane created on that server inherits it, no
matter which client attaches. Diagnose: find the agent's pid and check its real environment —
`ps eww <pid> | tr ' ' '\n' | grep AGTERM_SESSION_ID` — if the id is not the session the process
lives in, it leaked. Fix a poisoned tmux server without restarting it:
`for v in AGTERM_ENABLED AGTERM_PANE AGTERM_PANE_ID AGTERM_SESSION_ID AGTERM_SOCKET AGTERM_WINDOW_ID AGTERM_WORKSPACE_ID; do tmux set-environment -g -r "$v"; done`,
then restart the affected panes/processes (a respawn is enough; existing processes keep their
inherited copy). Prevent it: start daemons and session managers with the variables scrubbed
(`env -u AGTERM_SESSION_ID … <cmd>`, full list in SKILL.md), or from a shell outside agterm.

### "Claude Code's question/permission prompt is unresponsive after switching apps"

Known upstream Claude Code bug, NOT agterm. Do not file an agterm issue for it. While Claude Code shows
an interactive prompt (a question menu or a permission dialog), switching to another app and back leaves
it deaf to the keyboard (arrows and Return do nothing); the normal prompt and the shell still work. On
refocus agterm sends the standard focus-in report (`ESC[I`, DEC mode 1004); Claude Code's dialog handler
mishandles it. agterm emits correct paired focus-in/focus-out and is already macOS focus-first (the
refocus click is not forwarded into the pty), so the terminal is not at fault. Tracked as
anthropics/claude-code#72188 (mouse-click variant #72273). Workaround: answer before switching away, or
`Esc` the stuck prompt and let it re-ask.

## Reporting: decide bug vs unsupported FIRST

- A **supported** thing misbehaves (a documented command/feature does the wrong thing, a crash, a parse
  bug) → a GitHub **issue**.
- The user wants something **not supported**, or it is a question / idea / "can it do X" → a GitHub
  **Discussion** (category `Ideas` for a feature request, `Q&A` for a question). Do NOT file a feature
  request as a bug.

## Hard rules for filing

1. **Never run any `gh` command without the user's explicit approval in this conversation.** Drafting
   is fine; posting needs a clear go-ahead ("post it").
2. **Check tooling first** — `gh auth status`. If `gh` is missing or not logged in, do NOT install or
   authenticate it. Give the user the prefilled content plus the URL to paste it into:
   - issue: <https://github.com/umputun/agterm/issues/new>
   - discussion: <https://github.com/umputun/agterm/discussions/new>
3. **Draft first.** Show the user the full title and body, and get explicit approval before any `gh`.
4. **Scrub sensitive content** before showing or posting: API tokens/keys, passwords, internal
   hostnames/IPs, usernames embedded in absolute paths (replace with `~` or `<user>`), private repo
   names, and the contents of a selection / `session.copy` / clipboard. When unsure, ask.
5. **Gather the repro facts yourself** where you can: agterm version (the user reads it from
   Agterm ▸ About Agterm), `agtermctl tree --json` shape, a scrubbed `keymap.conf` excerpt, a scrubbed
   `log show` excerpt.

## Issue template (bug)

```
Title: <short, specific>

What happened: <one or two sentences>
Expected vs actual: <…>
Steps to reproduce:
1. …
2. …
Environment: agterm <version>, macOS <version>
Logs: <scrubbed `log show --predicate 'subsystem == "com.umputun.agterm"'` excerpt>
Config: <scrubbed keymap.conf lines, if keymap-related>
```

File it (only after approval) with `--body-file -` so a multi-line body is not mangled by quoting:

```bash
gh issue create -R umputun/agterm --title "<title>" --body-file - <<'EOF'
<body>
EOF
```

## Discussion (feature request / question)

```bash
gh discussion create -R umputun/agterm --category "Ideas" --title "<title>" --body-file - <<'EOF'
<body>
EOF
```

Use `--category "Ideas"` for a feature request, `"Q&A"` for a question. Same draft-first, scrub, and
explicit-approval rules apply.
