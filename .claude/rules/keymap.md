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
  `BuiltinAction` (the 42 rebindable actions + `defaultChord`, the count pinned by
  `BuiltinActionTests.swift`), `Keymap`/`parseKeymap` (`Keymap.swift`),
  `ConfigPaths` (the path resolver).
  All unit-tested under `agtermCoreTests`.
- **MENU-driven built-in override vs MONITOR-driven custom commands — two different mechanisms.** Built-ins
  ride AppKit menu-key-equivalents: each built-in `Button` in `agtermApp`'s `.commands` reads `settingsModel.keymap.equivalent(for: .action)`
  via the `shortcut(for:)` helper (`Chord` → SwiftUI `KeyboardShortcut?`,
  applied only when non-nil so a keyless action stays keyless until mapped).
  **`keymap` being `@Observable` does NOT make the menu track it live — do not assume a reload reaches the
  key equivalents.**
  SwiftUI defers its menu rebuild to the next app ACTIVATION, so after a `keymap reload` the live
  `NSMenuItem` key equivalents keep the OLD chords until the app is deactivated and reactivated.
  The rebuild is also where SwiftUI's conflict resolution runs, and it resolves a collision by unbinding
  **agterm's** item, never the stock one.
  So once the stock File ▸ Close (`performClose:`) holds ⌘W, giving `close_session` the chord back leaves
  agterm's item with NO chord and ⌘W closing the whole window.
  `AppDelegate.applyCloseSessionChord` asserts that split from AppKit: clear the stock item's ⌘W while the
  keymap gives the chord to `close_session`, restore it while it does not.
  Re-run it at launch, on `.agtermKeymapChanged`, on `didBecomeActive` (async, so it lands after SwiftUI's
  rebuild), and on menu tracking — SwiftUI re-applies its resolution on every rebuild, so a one-shot does
  not stick (the `removeNativeFullScreenMenuItem` pattern).
  ⌘W is the only chord asserted this way because it is the only built-in chord with a stock competitor;
  every other rebind takes effect on the next activation.
  **Diagnose this class with `agtermctl keymap list`, not by reading the file.**
  It returns BOTH what the keymap resolved (`actions`) and what the menu bar is dispatching (`menu`), so a
  model-correct-but-menu-stale chord is one command away instead of an instrumented build.
  Its menu chords go through the host-free `namedKey(forKeyEquivalent:)` so arrows and return render as
  the same named keys the file uses and the two lists compare as strings; see the control-api rule.
  **A change affecting menu shortcuts needs a RELOAD-path test — seeding `keymap.conf` before launch does
  not exercise reload.**
  Cover both in `agtermTests/CloseSessionChordTests.swift` and
  `KeymapUITests.testCloseSessionReclaimsCommandWAfterReload`.
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
  EVERY built-in menu item reads `equivalent(for:)` (override else `defaultChord`) with NO hardcoded
  `.keyboardShortcut` literal, so adding/changing a default chord happens in `defaultChord` alone.
  ONE keyed built-in carries no menu shortcut at all: `undo_close` (File ▸ Reopen Closed Item) is
  delivered by the `UndoCloseShortcut` NSEvent monitor instead, so native text undo keeps working in the
  rename/palette/Settings fields — it resolves the SAME `equivalent(for:)`, just not as a key-equivalent.
  There is NO exception any more: the six formerly arrow-bound actions (`focus_left_pane` ⌘⌥←,
  `focus_right_pane` ⌘⌥→, `previous_session` ⌥⌘↑, `next_session` ⌥⌘↓, `previous_attention_session` ⌃⌥↑,
  `next_attention_session` ⌃⌥↓) return their real chords from `defaultChord` now that `parseKeybind`
  accepts the four arrows, so EVERY keyed built-in is pure-`defaultChord`-driven and the menu holds no
  hardcoded `.keyboardShortcut` at all.
  The old props are gone — `agtermApp.arrowShortcut(for:)`, `BuiltinAction.arrowGlyphFallback`, and
  `glyphHint`'s `?? arrowGlyphFallback` were deleted, and the starter file's six `(no default)` lines
  became real chords.
  This also CLOSED a hole: `firstBuiltinCollision` and `validateCommands` resolve through `defaultChord`,
  so while the six were nil their live ⌥⌘↑/↓/←/→ were invisible to the conflict checker — a `map cmd+opt+up new_session`
  would have double-bound the chord silently.
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
- **Arrows are bindable; a BARE arrow is not (`map` only).**
  `bindableNamedKeys` carries `left`/`right`/`up`/`down` alongside `tab`/`space`/`return`/`delete`, and
  `bindableArrowKeys` names the four separately for the one rule that treats them specially.
  `parseMapLine` REJECTS a modifier-less arrow (`map left previous_session` → `bare arrow chord '<x>' needs a modifier; map skipped`)
  because a built-in becomes an always-on menu key-equivalent with NO text-field pass-through — unlike
  the custom-command monitor, which returns false for an `NSText` responder — so a bare arrow would
  swallow the key in the terminal, both palettes, the dashboard grid's key-catcher, and every text field
  at once.
  `parseCommandLine` already required a modifier on every custom chord, so the two verbs now agree for
  arrows; a bare NON-arrow key stays legal for `map` (pre-existing, `map a new_session`).
  The grammar itself accepts a bare arrow — the modifier rule is a `map` rule, not a parse rule, so a
  leader tail like `ctrl+a>left` still works.
- **The keyCode→name half of `NSEvent`→`Chord` is ONE host-free function.**
  `namedKey(forKeyCode:)` (`Keybind.swift`) is the single source of truth, used by BOTH app-side monitors
  — `CustomCommandRunner.chord(from:)` and `UndoCloseShortcut.chord(from:)`, which each carried their own
  copy of the table before.
  This matters because a name the GRAMMAR accepts but the keyCode map can't produce parses fine and then
  never fires: an arrow would fall through to the character branch, whose `characters(byApplyingModifiers: [])`
  yields the private-use `NSUpArrowFunctionKey` glyph — a VALID `Chord` no keymap line can spell.
  That is exactly the shifted-symbol failure mode that shipped once (see the shift-symbol note above),
  which is why `KeybindTests` pins `namedKey(forKeyCode:)`'s range to equal `bindableNamedKeys` exactly,
  and why the runner path has its own e2e (`KeymapUITests.testCustomCommandArrowChordFires`).
- **A chord resolves per LAYOUT, not per key — `chordKey(forKeyCode:produced:layoutIsASCIICapable:)` owns the policy.**
  A `keymap.conf` chord is spelled in Latin (`cmd+o`), but the character an `NSEvent` reports is whatever the ACTIVE input
  source puts on that key, so matching the produced character alone left EVERY letter/digit chord dead on a Cyrillic/Greek/Hebrew
  layout, where the O key yields `щ` (issue #306).
  The app target reads ONE bit — `KeyboardLayout.isASCIICapable` (`agterm/Commands/KeyboardLayout.swift`,
  `TISCopyCurrentKeyboardLayoutInputSource` + `kTISPropertyInputSourceIsASCIICapable`) — and the host-free
  `chordKey` branches on it: an ASCII-capable layout (US, Dvorak, Colemak, US-International, French, German) binds the produced
  character, EXACTLY as master did, so no existing user's binding changes; a layout that cannot type ASCII (every Russian variant,
  Greek, Hebrew, Arabic, Thai, Ukrainian) binds by physical position via `latinKey(forKeyCode:)`, the ANSI table.
  The property is read FRESH on every key press — measured at ~0.22 µs, so it needs no cache and no
  `kTISNotifySelectedKeyboardInputSourceChanged` observer, and cannot go stale mid-session.
  **Do NOT "optimize" this into a per-key ASCII test** (keep the produced character whenever it happens to be ASCII).
  That was the first attempt and it is measurably wrong on real layout data: Greek types `;` on the physical Q and Hebrew types
  `/` there, so Latin-spelled LETTER chords stayed dead on two of the three layouts the fix targets; and it let two physical keys
  collapse onto one chord key — on Hebrew the `'` key produces `,` while the `,` key falls back to `,`, so one binding fired from
  a key the user never pressed AND the monitor ate the keystroke (`handleKeyDown` returns true on `.fired`/`.armed`).
  Resolving the whole layout at once keeps `latinKey`'s one-key-per-position mapping intact, so no two TABLE positions can
  collapse.
  Two positions OUTSIDE the table still need care, because an unclaimed key code keeps whatever it types and that can equal a
  table value: the ISO section key (keyCode 10, the extra key an ISO keyboard has) types `\` on Ukrainian-PC and `;` on
  Hebrew-PC, colliding with keyCodes 42 and 41 — it is therefore DROPPED on a non-ASCII layout (`isoSectionKeyCode`), and
  removing that guard reintroduces the collapse.
  The keypad also aliases (keypad `5` and the number row both give `"5"`), which is deliberate and pre-dates all of this — the
  keypad's output does not vary by layout, so binding it by what it types is correct.
  This is a DIFFERENT rule from `InterruptKeystroke.isInterrupt`, which tests the produced CHARACTER (is it a Latin letter?)
  rather than the layout — do not "unify" them: that one classifies a single hardcoded key and needs no layout context, while a
  chord needs the whole ANSI vocabulary including punctuation.
  `latinKey` and `namedKey(forKeyCode:)` claim DISJOINT key codes (pinned by `KeybindTests`) because both monitors resolve the
  named key first; every `latinKey` entry is pinned INDIVIDUALLY there too, since the aggregate set/uniqueness assertions hold
  under any permutation and the real `kVK_ANSI_*` constants are non-monotonic at 4/5, 22/23 and 25/26/28/29.
  Consequence to keep in mind: on a non-ASCII layout a chord can only be spelled by position, so such a layout cannot bind the
  Cyrillic character it types.
  **The NON-Latin branch of either monitor's `NSEvent` seam is NOT unit-testable — the branch is chosen by the LIVE input source.**
  A test cannot set the machine's keyboard, so a hosted test runs on whatever the tester has (a Latin layout everywhere in
  practice) and can only reach the ASCII-capable branch.
  Two separate reasons, and both stand: `CustomCommandRunner.chord(from:)` additionally reads
  `characters(byApplyingModifiers: [])`, which AppKit RE-TRANSLATES from the key code through the live input source — a
  synthesized `NSEvent` carrying `characters: "щ"` comes back `"o"` on a Latin-layout machine (verified) — while
  `UndoCloseShortcut.chord(from:)` reads `charactersIgnoringModifiers`, which a synthesized event DOES report verbatim.
  So the hosted tests (`agtermTests/UndoCloseShortcutTests.swift`) pin the WIRING (right key code, right accessor, named keys win)
  and `KeybindTests` carries the whole layout policy host-free, taking `layoutIsASCIICapable` as a parameter.
  Do NOT "fix" the split by switching the runner to `charactersIgnoringModifiers` for testability — that reintroduces the
  shifted-symbol bug (see the shift-symbol note above), and it would not make the non-Latin branch reachable anyway.
  **The accessor split has a live consequence the shift-symbol bullet above does NOT cover: `undo_close` is exempt from
  `shift+<base>` normalization.**
  `charactersIgnoringModifiers` KEEPS shift, so a real Shift+/ press reaches `UndoCloseShortcut` as `(shift, "?")` while
  `map shift+/ undo_close` parsed to `(shift, "/")` — the comparison fails and File ▸ Reopen Closed Item is silently dead, for
  every shifted punctuation/digit (shifted LETTERS are fine, `chordKey` lowercases).
  The deadness is pre-existing (master read the same accessor), but the layout branch now SPLITS it: on a non-ASCII layout the
  press resolves through `latinKey`, which is shift-independent, so the identical `map` line FIRES on Cyrillic and stays dead on
  US.
  `undo_close` is the only built-in delivered by a monitor rather than a menu key-equivalent, so it is the only action this
  reaches.
  The hosted tests skip themselves when the tester's own layout is not ASCII-capable (`XCTSkipUnless`), so running `make
  test-app` while hand-verifying on Russian reports skips rather than false failures.
  VERIFIED BY HAND on a Russian-Phonetic layout against an isolated dev instance: a simple letter chord, a `cmd+r>t` leader, a real
  `ctrl+a>d` leader from the maintainer's own keymap, and ⌘Z undo-close all fire on Cyrillic and keep working on U.S.
  Re-run that way after touching either monitor's `chord(from:)` — the automated suites cannot catch a regression there.
  Russian-Phonetic is the most FORGIVING layout in the set (every one of its punctuation positions emits correct ASCII), so it
  alone does not exercise the Greek/Hebrew cases; those are covered by the host-free tests using measured layout data.
- **A `keybind` in `ghostty.conf` does NOT get this treatment — that is libghostty's matcher, and its rule is different.**
  ghostty parses a bare `g` as a UNICODE trigger and `key_g` as a PHYSICAL one, then matches physical → the produced utf8 → the
  unshifted codepoint (`Binding.Set.getEvent`), so a unicode trigger cannot fire on a non-Latin layout.
  agterm builds the key event exactly as Ghostty.app does (same `characters(byApplyingModifiers: [])` for `unshifted_codepoint`),
  so this is upstream behavior, identical in Ghostty.app, and NOT fixable app-side — verified against the pinned rev AND
  ghostty `main`.
  The answer is the `key_` form, which is why `ghostty-defaults.conf` ships `super+key_c`/`key_v`/`key_a` (issue #30).
  README + `site/docs.html` document the split; do not conflate the two files' chord grammars when answering a layout report.
- **v1 scope cut (confirmed).**
  Built-in rebinds are single-chord only (leaders only for custom commands).
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

