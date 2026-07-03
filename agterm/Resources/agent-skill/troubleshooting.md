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

### "⌘C/⌘V (or a shortcut) doesn't work on a non-Latin / alternative layout"

⌘C/⌘V copy/paste on any layout by default — agterm's bundled ghostty defaults bind them to the physical
key POSITIONS (`super+key_c`/`super+key_v`), matched by keycode regardless of the character the layout
prints. (ghostty's own `super+c`/`super+v` match the produced CHARACTER, so they miss on a Russian/Greek/
etc. layout where the physical V key yields `м`.) To remap any shortcut: a physical key name (`key_c`,
`key_v`, …) matches by position on any layout; a bare letter (`c`, `v`) matches the produced character.
A Dvorak/Colemak user who wants ⌘C/⌘V at their own letter positions overrides in
`~/.config/agterm/ghostty.conf` (`super+key_c=unbind` + `super+c=copy_to_clipboard`, same for `v`), then
`agtermctl config reload`.

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
