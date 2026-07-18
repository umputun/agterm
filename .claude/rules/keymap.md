---
paths:
  - "agtermCore/Sources/agtermCore/Keybind.swift"
  - "agtermCore/Sources/agtermCore/KeybindMatcher.swift"
  - "agtermCore/Sources/agtermCore/Keymap.swift"
  - "agtermCore/Sources/agtermCore/BuiltinAction.swift"
  - "agtermCore/Sources/agtermCore/CustomCommand.swift"
  - "agtermCore/Sources/agtermCore/ConfigPaths.swift"
  - "agterm/Commands/CustomCommandRunner.swift"
  - "agtermUITests/KeymapUITests.swift"
---

## Keymap

- A user-editable, kitty-flavored keymap file (`<configDir>/keymap.conf`,
  default `~/.config/agterm`) lets the user (1) **rebind built-in menu shortcuts** and (2) **define custom
  shell commands** bound to keys, the latter listed in the action palette marked `custom`.
  Like the Control API, the pure logic lives host-free in `agtermCore` and the app target wires it.
  The feature is the keymap analogue of the toolbar/menu/control seam: the SAME parsed `Keymap` drives
  the menu shortcuts, the custom-command monitor, and the palette, so the three can't drift.
- **Two-section verb-based format (`parseKeymap`, host-free, never throws).**
  `map <chord> <action>` overrides a built-in's shortcut (single chord only — a leader is a diagnostic);
  `command "<name>" [chord] <shell...>` defines a custom command (quoted name with spaces;
  the post-name token is the chord IFF `parseKeybind` accepts it AND it carries a modifier — a bare modifier-less
  key is rejected with a diagnostic and the line falls back to palette-only,
  so a custom shortcut can't shadow a plain terminal key and a palette-only shell line starting with
  a single-char token isn't silently swallowed as a binding; else palette-only;
  the shell remainder keeps `{AGT_X}` tokens verbatim — an EMPTY shell line is a diagnostic,
  not a no-op binding).
  Both verbs tokenize on GENERAL whitespace (space OR tab).
  Blank lines and `#` comments are skipped (an inline `#` is a comment only when preceded by whitespace
  AND outside a double-quoted span).
  A malformed line becomes a `KeymapDiagnostic{line, message}` and is skipped — a bad line never discards
  the rest of the file.
  Pure types: `Modifier`/`Chord`/`Keybind`/`parseKeybind`/`keybindConflicts`/`reservedMonitorChords`
  (`Keybind.swift`), `KeybindMatcher` (leader state machine), `CustomCommand`/`CommandContext` (the `{AGT_X}`
  token table — single source of truth for both `{AGT_X}` expansion and the `$AGT_X` env),
  `BuiltinAction` (the 36 rebindable actions + `defaultChord`), `Keymap`/`parseKeymap` (`Keymap.swift`),
  `ConfigPaths` (the path resolver).
  All unit-tested under `agtermCoreTests`.
- **MENU-driven built-in override vs MONITOR-driven custom commands — two different mechanisms.** Built-ins
  ride AppKit menu-key-equivalents: each built-in `Button` in `agtermApp`'s `.commands` reads `settingsModel.keymap.equivalent(for: .action)`
  via the `shortcut(for:)` helper (`Chord` → SwiftUI `KeyboardShortcut?`,
  applied only when non-nil so a keyless action stays keyless until mapped).
  Because `keymap` is `@Observable` and `.commands` reads it, the menu shortcuts re-render on reload
  — no notification needed for the menu.
  Custom commands ride an app-wide `NSEvent` local `.keyDown` monitor in `CustomCommandRunner` (the same
  monitor pattern as the Ctrl-Tab switcher and Ctrl-1/2): it maps `NSEvent` → `Chord`,
  feeds a `KeybindMatcher` (firing simple chords + leader sequences like `ctrl+a>g`,
  1.5 s leader timeout, key-repeat ignored), and on `.fired` spawns a detached `/bin/sh -c` with the
  focused pane's `CommandContext` (cwd + selection + `$AGT_*` env); a non-zero exit posts a failure banner
  via `NotificationManager.notifyCommandFailure`.
  It fires when the key window's first responder is a `GhosttySurfaceView` (context from that surface) OR
  when the key window is an agterm terminal window whose focus is NOT on a text field — INCLUDING one
  emptied to zero sessions (the SSH-disconnect state where every session's shell exited, `closeSession`
  leaves the window open + empty, and no surface holds first responder).
  It passes through — never eating keystrokes — for a focused text field (the responder is the window's
  `NSText` field editor: Settings editor, inline rename, palette search) and for an auxiliary window
  (Settings) whose focus sits off a text field (`WindowRegistry.contains(keyWindow)` gates the
  no-surface fire to agterm terminal windows only).
  It rebuilds its matcher on `.agtermKeymapChanged`.
  The runner exposes a public `run(_:)` for the palette items; it resolves context from the active session
  and NO-OPS when none is active — firing a session-scoped command with silently-empty tokens is unsafe
  (an empty `{AGT_SESSION_PWD}` turns `rm -rf …/*` into a root glob, defeating even the quoted `$AGT_X`
  form).
  A chord fired with NO focused surface routes through `runNoSurface`: it runs the active session's
  `run(_:)` if one exists (e.g. the dashboard key-catcher holds first responder, or a quick terminal over
  a live session), else `spawnSessionless` fires a session-free context (empty `{AGT_SESSION_*}`, the
  frontmost window id, the socket) so a launcher chord like `agtermctl session new --command "ssh …"`
  stays usable after every session closes (`session.new` defaults to the frontmost window, so no id is
  needed).
  `spawnSessionless` GATES on `CommandContext.referencesSessionScopedContext`: a command whose body names
  a session/workspace/selection token (`AGT_SESSION`/`AGT_WORKSPACE`/`AGT_SELECTION`, in `{…}` or `$…`
  form) NO-OPS with a notice rather than expanding those tokens dangerously empty (an empty
  `{AGT_SESSION_PWD}` makes `rm -rf …/*` a root glob, defeating even the quoted `$AGT_X` form) — the same
  protection the palette's no-op gives, extended to the keybind; a launcher references only
  `AGT_SOCKET`/`AGT_WINDOW`/`AGT_PANE`, so it still fires.
  The sessionless-surface fallback (a quick terminal focused in an emptied window) routes through the
  SAME `runNoSurface`, so a launcher works there too and a session-scoped command is inert there too.
  `CommandContext.pane` (the `{AGT_PANE}`/`$AGT_PANE` token, `left`|`right`|`scratch`)
  carries the fired-from pane: the keybind path derives it from the focused SURFACE's identity
  (`splitSurface === focusedSurface` → `right`; the sessionless-surface branch `runFromSessionlessSurface`
  identifies the active session's `scratchSurface` → `scratch`), the palette path from `session.splitFocused` —
  so a script can feed it back as `agtermctl session type --pane "$AGT_PANE"` to type into the very
  pane the shortcut was pressed in.
  The scratch is the ONLY sessionless surface that reports a pane (the read leg of the `$AGT_PANE` →
  `session type --pane scratch` round-trip, which `--pane` already accepted); the quick terminal and
  overlays are NOT panes, so a chord fired from them takes the active-session palette path (their state
  is queryable via `tree`'s `quickVisible`/`overlay`).
  It reflects the pane's physical surface slot: `left` for any single-pane session, including a promoted
  split survivor.
  When the primary pane's shell exits, `closePrimaryPane` MOVES the surviving split pane from
  `splitSurface` into the `surface` (main) slot and flips its `isSplitPane` flag off, so a
  collapsed-to-single session reports `left` and `session.type --pane left` reaches it —
  the survivor is no longer addressable as `right`, and a later split opens a fresh right pane beside it.
- **Built-in override resolution is ORDER-INDEPENDENT, decided against the FINAL state (`resolveBuiltinOverrides`).**
  Overrides are NOT folded incrementally against a partially-built map (that was order-sensitive — it
  would reject `map cmd+d new_session` when toggle_split still owned cmd+d "so far",
  even if a later line moved toggle_split off cmd+d).
  Instead: (1) fold all overrides last-wins into a candidate map; (2) compute each action's final resolved
  chord (override else `defaultChord`); (3) a chord that TWO DISTINCT actions resolve to is the only
  real conflict — an override colliding with another action's UNMOVED default loses (the default owner
  keeps the chord), two colliding OVERRIDES → the later-in-file one loses,
  each with a diagnostic naming the kept owner.
  So `map cmd+d new_session` + `map cmd+shift+d toggle_split` both succeed in EITHER order.
  The dropped-override diagnostics are emitted sorted by file line for deterministic order.
- **Cross-section validation + ownership-by-disjoint-registration (why there is NO precedence fight).**
  `parseKeymap` runs a SINGLE final validation pass AFTER every line is parsed (NOT incremental — a custom
  line parsed before a later keyless-built-in `map` must still be checked against the override that `map`
  installs): it computes the active built-in chord set (`equivalent(for:)` over every `BuiltinAction`,
  overrides applied) and drops a custom keybind whose FIRST chord collides with a built-in OR whose ANY
  chord is a reserved monitor chord (the monitor consumes its chord wherever it lands in a leader,
  so a later reserved chord like `ctrl+a>ctrl+1` is just as dead as a leading one) — clearing the command's
  `shortcut` to `""`, keeping the palette entry, + a diagnostic — then drops both keybinds of any custom-vs-custom
  conflict via `keybindConflicts`.
  The reserved set is the PREDICATE `isReservedMonitorChord(_:)` (NOT a fixed list):
  control+tab with ANY modifiers (the Ctrl-Tab switcher consumes Tab whenever Control is held — `ctrl+tab`
  / `ctrl+shift+tab` / `ctrl+opt+tab` / `ctrl+cmd+tab`), plus control+1 / control+2 with Control as the
  SOLE modifier (the Ctrl-1/2 pane monitor) — so all of these are un-rebindable.
  The SAME predicate also rejects a built-in `map` line whose (single) chord is reserved (`parseMapLine`),
  so neither a built-in nor a custom command can steal a monitor chord.
  The reasoning: the NSEvent monitor only consumes chords registered in its matcher,
  and validation guarantees those registered chords are disjoint from the active built-in (menu) chords
  AND the reserved monitor chords.
  So every physical chord is owned by exactly one mechanism — the menu OR a monitor,
  never both — regardless of AppKit's menu-key-equivalent-vs-local-monitor dispatch order (the design
  does NOT rely on asserting that order).
  Caveat: validation covers agterm's own built-ins + reserved monitor chords,
  NOT system/standard menu items (⌘Q/⌘C/⌘,); binding a custom command to one of those resolves by AppKit's
  own dispatch — documented, not validated.
- **`BuiltinAction.defaultChord` is the single source of truth for the built-in shortcuts (keep-in-sync
  surface).** Task 9 collapsed the old `BuiltinAction` ↔ menu keep-in-sync convention:
  30 of the 36 built-in menu items now read `equivalent(for:)` (override else `defaultChord`) with NO
  hardcoded `.keyboardShortcut` literal, so adding/changing a default chord happens in `defaultChord`
  alone (`toggle_search` ⌘F, `toggle_sidebar` ⌃⌘S, `toggle_fullscreen` ⌃⌘F, `custom_command_palette` ⌃⇧O,
  and `show_attention` ⌃⇧I are among these — expressible, so pure-`defaultChord`-driven,
  not arrow exceptions).
  The EXCEPTION is the six arrow-bound actions (`focus_left_pane` ⌘⌥←, `focus_right_pane` ⌘⌥→,
  `previous_session` ⌥⌘↑, `next_session` ⌥⌘↓, `previous_attention_session` ⌃⌥↑,
  `next_attention_session` ⌃⌥↓): `parseKeybind` accepts only single-char keys or `tab`/`space`/`return`/`delete`
  — arrows are not expressible as a parsed `Chord`, so `defaultChord` returns nil for them and the menu
  keeps its hardcoded arrow `.keyboardShortcut` as the FALLBACK when `equivalent(for:)` is nil (a user
  can still `map` these to a parseable chord, which then wins).
  So the six arrow actions are NOT pure-`defaultChord`-driven by design;
  the other 29 are.
- **Shifted symbols bind as `shift+<base>` — the runner normalizes to the UNSHIFTED base key.**
  `charactersIgnoringModifiers` KEEPS shift (shift+/ → "?", shift+= → "+"), and the old
  `.lowercased()` only undid that for letters (shift+u → "u"), so punctuation landed on the shifted glyph
  and never matched a `shift+/`-style binding.
  `CustomCommandRunner.chord(from:)` now derives the base key via `characters(byApplyingModifiers: [])`
  (the same call `GhosttySurfaceView` uses for unmodified key input), so the runtime chord for shift+/ is
  `(shift, "/")` and matches the parser's `shift+/`.
  So every shifted symbol is written `shift+<base>` (`shift+/` = `?`, `shift+=` = `+`, `shift+5` = `%`,
  `shift+.` = `>`).
  This is verified END-TO-END by `KeymapUITests.testCustomCommandShiftedSymbolFires` (a real synthesized
  Shift+/ keypress fires a `shift+/`-bound command) — the host-free tests structurally can't reach
  `chord(from:)`, which is exactly why the earlier parser-only version shipped a runtime that never fired.
- **v1 scope cut (confirmed).**
  Built-in rebinds are single-chord only (leaders only for custom commands).
  The arrows aren't expressible as a parsed `Chord` (the six arrow actions keep their defaults unless
  mapped to a parseable chord).
  The literal `+`/`>` still can't be a bare key TOKEN (they are the chord-joiner / leader separator), but
  those keys ARE bindable as `shift+=`/`shift+.` (see the shift-symbol note above).
  `increase_font_size`'s default ⌘+ still renders `(not expressible)` in the STARTER file: its stored
  `Chord(key:"+")` can't round-trip through `displayString` (which emits the `+` glyph, `chordSyntax`
  verifies the round-trip) — a display-side detail, separate from key MATCHING.
  The Ctrl-Tab MRU switcher and Ctrl-1/Ctrl-2 pane focus are NOT rebindable (they are monitor-driven,
  not menu items — folding them in would reintroduce a monitor-vs-monitor precedence question;
  a custom command bound to one is dropped via `reservedMonitorChords`).
  The palette shows a custom command's chord as raw kitty syntax (`cmd+shift+e`),
  not the ⌘⇧E glyphs built-ins use.
- **`{AGT_X}` tokens are substituted RAW into the `/bin/sh -c` line (`CommandContext.expand`).** This
  is the intended raw interpolation (convenient), NOT shell-quoted — so dynamic content like `{AGT_SELECTION}`
  can inject shell syntax.
  `{AGT_SESSION_NAME}` and `{AGT_SESSION_PWD}` are equally unsafe, and worse than `{AGT_SELECTION}`
  because they need no local interaction: a remote host sets the session title (OSC 0/1/2) and the
  working directory (OSC 7), so either can carry attacker content silently.
  OSC-reported title and pwd are stripped of control characters at ingestion (`TerminalText.sanitized`
  in `GhosttySurfaceView.applyTitle`/`applyPwd`), so a newline can no longer split the `sh -c` line,
  but visible metacharacters (`;`, `$()`, backticks) still pass through raw.
  The safe alternative is already provided: the same values are exported as `$AGT_X` env vars (`CommandContext.environment()`),
  naturally shell-quoted as `"$AGT_SELECTION"`.
  The starter `keymap.conf` comments + README recommend `$AGT_X` (quoted) for untrusted content.
  Do NOT add quoting to the `{AGT_X}` expansion — by design.
- **Reload + control.**
  `AppActions.reloadKeymap()` → `SettingsModel.reloadKeymap()` (re-read + re-parse + post `.agtermKeymapChanged`)
  is exposed as File ▸ Reload Keymap, an action-palette entry, AND the `keymap.reload` control command
  — all ONE path.
  See the Control API catalog for the `keymap.reload` four-point audit.
- **Edit Keymap (GUI-only).**
  `AppActions.editKeymap()` (File ▸ Edit Keymap… + the ⌃⇧P palette) opens `keymap.conf` in the user's
  editor inside a 95% FLOATING overlay over the active session via `AppStore.openOverlay(…, sizePercent: 95)`.
  The command is the host-free, unit-tested `ConfigPaths.editorCommand(forPath:)` → `${SHELL:-/bin/zsh} -ilc 'exec /bin/sh -c '\''${VISUAL:-${EDITOR:-vi}} "$1"'\'' agterm-config-edit '<single-quoted path>''`
  (the path comes from `SettingsModel.keymapPath`).
  The user's INTERACTIVE login shell (`$SHELL -ilc`) runs first so it sources its rc and EXPORTS `$EDITOR`/`$VISUAL`,
  then `exec`s a POSIX `/bin/sh` that does the actual `${VISUAL:-${EDITOR:-vi}} "$1"` resolution + launch
  (the path is the inner `/bin/sh`'s positional `$1`, embedded single-quoted so spaces/quotes survive
  — NOT passed positionally to `$SHELL`, which fish has no `$1` for).
  TWO LOAD-BEARING reasons for the shape: (1) the `-ilc` sourcing — the overlay's own process is a bare
  non-interactive `/bin/sh` (libghostty runs `config.command` via `sh -c`,
  NOT the user's interactive shell) that sources none of the user's shell config,
  so a direct `${EDITOR:-vi}` there always fell back to `vi`; (2) the inner-`/bin/sh` hop — `$SHELL`
  may NOT be a POSIX shell (fish), which can't parse POSIX `${VAR:-default}` and died with `fish: ${ is not a valid variable`
  (exit 127, overlay just flashed) when the resolution ran directly under `$SHELL` — the POSIX text now
  rides inside single quotes that fish (and POSIX shells) pass through verbatim to `/bin/sh`.
  Two known limits: it assumes `$SHELL` accepts `-ilc` and passes single-quoted text verbatim (true for
  sh/bash/zsh/fish, NOT csh/tcsh, which reject `-ilc`); and it resolves `$EDITOR`/`$VISUAL` only when
  EXPORTED (their entire convention) — a non-exported, shell-local value does not survive the `exec`
  and falls to `vi`.
  Cross-shell behavior is unit-tested (`ConfigPathsTests` runs the built command under zsh + fish-when-present
  with a fake recorder editor, plus VISUAL-precedence and rc-sourcing cases).
  On the editor exiting the keymap reloads automatically: `editKeymap` records the target in `AppActions.keymapEditOverlaySession`
  and `WindowContentView`'s overlay-close `onChange` calls `reloadKeymap()` for it (then clears it).
  NO control command — a script can already `agtermctl session overlay open "$EDITOR <path>" --size-percent 95`
  (keep-in-sync exempt, like `reveal`, since it composes the controllable `session.overlay.open`).

