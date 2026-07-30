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

- `<configDir>/keymap.conf` (default `~/.config/agterm`) rebinds built-in menu shortcuts and defines
  custom shell commands, which appear in the action palette as `custom`. One parsed `Keymap` drives the
  menu, custom-command monitor, and palette; host-free logic lives in `agtermCore`.
- `parseKeymap` never throws. `map <chord> <action>` accepts one chord, not a leader.
  `command "<name>" [chord] <shell...>` treats the token after the quoted name as a shortcut only when
  `parseKeybind` accepts it with a modifier; a bare key is diagnosed and the command stays palette-only.
  Empty shell text is invalid. Both verbs split on spaces/tabs. Blank lines and comments are skipped;
  inline `#` starts a comment only after whitespace and outside double quotes. Each bad line yields
  `KeymapDiagnostic{line,message}` without stopping later lines. `{AGT_X}` text remains verbatim.
- Pure types live in `Keybind.swift`, `KeybindMatcher`, `CustomCommand`/`CommandContext`,
  `BuiltinAction` (42 cases, pinned by `BuiltinActionTests`), `Keymap`, and `ConfigPaths`.
  `CommandContext` owns the shared expansion/environment token table.
- Built-ins use AppKit menu key equivalents from `keymap.equivalent(for:)`; apply only non-nil
  `KeyboardShortcut`s. SwiftUI rebuilds menu shortcuts on the next activation, not immediately after
  `keymap reload`, and resolves stock collisions by unbinding agterm's item.
- `AppDelegate.applyCloseSessionChord` clears stock File > Close ⌘W while `close_session` owns it and
  restores it otherwise. Run at launch, `.agtermKeymapChanged`, asynchronously after `didBecomeActive`,
  and during menu tracking because every rebuild can reapply the collision. ⌘W is the only built-in with
  a stock competitor.
- Diagnose live shortcut state with `agtermctl keymap list`, whose `actions` and `menu` expose parsed and
  dispatched chords through host-free `namedKey(forKeyEquivalent:)`. Test the reload path, not only a
  seeded file: see `CloseSessionChordTests` and
  `KeymapUITests.testCloseSessionReclaimsCommandWAfterReload`.
- `CustomCommandRunner` uses an app-wide local `.keyDown` monitor. Its `KeybindMatcher` supports simple
  chords and leaders such as `ctrl+a>g`, ignores repeats, and times leaders out after 1.5 seconds.
  `.fired` launches detached `/bin/sh -c` with cwd, selection, and `$AGT_*`; non-zero exit calls
  `notifyCommandFailure`. Rebuild the matcher on `.agtermKeymapChanged`.
- Fire with a focused `GhosttySurfaceView`, or in an agterm terminal window whose focus is not an `NSText`
  field editor, including a zero-session window. Pass through text fields and auxiliary windows;
  `WindowRegistry.contains(keyWindow)` gates no-surface dispatch.
- Palette `run(_:)` no-ops without an active session. A no-surface chord uses the active session when
  available; otherwise `spawnSessionless` supplies empty session fields plus frontmost window/socket so
  launchers still work. If `referencesSessionScopedContext` finds any session/workspace/selection token
  in `{...}` or `$...` form, no-op with notice; empty `{AGT_SESSION_PWD}` can turn `rm -rf .../*` into a
  root glob. Commands using only `AGT_SOCKET`/`AGT_WINDOW`/`AGT_PANE` may run sessionless.
- `{AGT_PANE}`/`$AGT_PANE` is `left`, `right`, or `scratch`, derived from the firing surface for keybinds
  and `splitFocused` for palette runs. Scratch is the only sessionless surface with a pane; quick terminal
  and overlays use active-session context. A single pane is always `left`. Primary exit promotes the
  split into the main slot, clears `isSplitPane`, and makes it addressable only as `left`.
- `resolveBuiltinOverrides` is order-independent: fold last-wins candidates, resolve all final chords,
  then detect collisions. An override loses to another action's unmoved default; for two overrides, the
  later line loses. Diagnostics name the owner and sort by line. Moving `toggle_split` off `cmd+d` lets
  `new_session` take it in either line order.
- Final cross-section validation runs after parsing all lines. A custom shortcut becomes palette-only
  with a diagnostic when its first chord hits a final built-in, any chord is reserved, or
  `keybindConflicts` finds another custom shortcut; both custom sides lose in the last case.
  `isReservedMonitorChord` covers control+tab with any extra modifiers and control+1/2 with Control alone,
  anywhere in a leader, and also rejects built-in maps. This keeps menu and monitor registrations
  disjoint without relying on dispatch order. Standard menu items such as ⌘Q/⌘C/⌘, remain AppKit's
  responsibility.
- `BuiltinAction.defaultChord` is the sole built-in default. Every menu item resolves
  override-or-default, including the six arrow actions. `undo_close` is the one keyed action delivered
  by `UndoCloseShortcut`, not a menu equivalent, so native text undo still works.
- Write shifted symbols as `shift+<base>`: `shift+/` for `?`, `shift+=` for `+`, `shift+5` for `%`, and
  `shift+.` for `>`. `CustomCommandRunner` uses `characters(byApplyingModifiers: [])` to recover that
  base; keep `KeymapUITests.testCustomCommandShiftedSymbolFires`.
- Named keys are `left/right/up/down/tab/space/return/delete`. `parseMapLine` rejects modifier-less
  arrows because an always-on menu equivalent would swallow navigation in terminals, palettes,
  dashboard, and text fields. Bare non-arrow built-in maps remain legal, and a bare arrow can be a
  leader tail such as `ctrl+a>left`; custom shortcuts always require modifiers.
- Host-free `namedKey(forKeyCode:)` is shared by `CustomCommandRunner` and `UndoCloseShortcut`.
  `KeybindTests` pins its range exactly to `bindableNamedKeys`; keep
  `KeymapUITests.testCustomCommandArrowChordFires` because a private-use AppKit glyph can otherwise
  create an unspellable runtime chord.
- **Resolve chords per layout, not per produced key** (issue #306).
  `KeyboardLayout.isASCIICapable` reads
  `kTISPropertyInputSourceIsASCIICapable` on every keypress (about 0.22 microseconds, no cache/observer).
  `chordKey` uses the produced character for ASCII-capable layouts and ANSI
  `latinKey(forKeyCode:)` position for non-ASCII layouts. Do not use a per-key ASCII fallback: Greek Q
  emits `;`, Hebrew Q emits `/`, and Hebrew can collapse two physical positions to `,`, causing false
  firing plus consumed input.
- Drop ISO section key code 10 on non-ASCII layouts because Ukrainian-PC `\` and Hebrew-PC `;` collide
  with table codes 42/41. Keypad/number-row aliases are deliberate because keypad output is
  layout-independent. Keep `latinKey` disjoint from named-key codes and pin every entry individually;
  real ANSI constants are non-monotonic at 4/5, 22/23, and 25/26/28/29. Non-ASCII layouts can bind only
  Latin positions, not their produced Cyrillic glyphs.
- Do not merge this policy with `InterruptKeystroke`, which classifies one produced letter.
  The live non-Latin monitor branch cannot be unit-tested because tests cannot change the input source.
  `characters(byApplyingModifiers: [])` re-translates synthesized runner events through the live layout;
  `UndoCloseShortcut` uses verbatim `charactersIgnoringModifiers`. Hosted tests pin wiring and named-key
  precedence; host-free tests take `layoutIsASCIICapable`.
- Do not switch the runner to `charactersIgnoringModifiers`: it breaks shifted-symbol normalization and
  still cannot test the non-Latin branch. The accessor means `undo_close` cannot match shifted
  punctuation/digits on ASCII layouts (`shift+/` parses `/`, but runtime reports `?`); shifted letters
  work, and non-ASCII physical lookup works. Hosted tests skip when the machine layout is non-ASCII.
  After monitor changes, manually verify a letter, `cmd+r>t`, `ctrl+a>d`, and ⌘Z on isolated
  Russian-Phonetic and U.S. instances. Russian-Phonetic does not cover Greek/Hebrew punctuation, which
  host-free measured-data tests cover.
- `ghostty.conf` has a separate upstream grammar: bare `g` is Unicode and `key_g` physical; Unicode
  triggers cannot fire on non-Latin layouts. agterm matches Ghostty.app and cannot fix this app-side.
  Use `key_`, as `ghostty-defaults.conf` does for `super+key_c/key_v/key_a` (issue #30). README and
  `site/docs.html` document the distinction.
- Built-in leaders remain unsupported; leaders are custom-only. Literal `+`/`>` are separators and not
  bare tokens, but bind as `shift+=`/`shift+.`. `increase_font_size`'s stored `Chord(key:"+")` cannot
  round-trip and prints `(not expressible)` in the starter file. Ctrl-Tab and Ctrl-1/2 are reserved,
  monitor-driven, and not rebindable. Palette custom hints use raw kitty syntax, not macOS glyphs.
- **`{AGT_X}` interpolation is intentionally raw and unquoted.** Selection, OSC title, and OSC 7 pwd can
  inject visible shell metacharacters. `TerminalText.sanitized` strips control characters, not `;`,
  `$()`, or backticks. Prefer quoted exported `"$AGT_X"` variables for untrusted text. Do not add quoting
  to `CommandContext.expand`.
- File > Reload Keymap, the palette entry, and `keymap.reload` all call
  `AppActions.reloadKeymap()` > `SettingsModel.reloadKeymap()`, which reparses and posts
  `.agtermKeymapChanged`. Apply the Control API four-point audit.
- Edit Keymap is GUI-only. `AppActions.editKeymap()` opens a 95% floating overlay with
  `ConfigPaths.editorCommand(forPath:)`:
  `${SHELL:-/bin/zsh} -ilc 'exec /bin/sh -c '\''${VISUAL:-${EDITOR:-vi}} "$1"'\'' agterm-config-edit '<path>''`.
  The interactive login shell loads exported editor variables; inner POSIX `sh` handles
  `${VAR:-default}` for fish and receives the single-quoted path as `$1`. Supported shells must accept
  `-ilc` and preserve single quotes (sh/bash/zsh/fish, not csh/tcsh); non-exported editor variables fall
  back to vi. Running POSIX expansion directly under fish exits 127. `ConfigPathsTests` cover zsh,
  optional fish, VISUAL precedence, rc sourcing, and quoting.
  Overlay close reloads only the recorded edit session. No control command is needed because scripts can
  compose `session overlay open "$EDITOR <path>" --size-percent 95`.
