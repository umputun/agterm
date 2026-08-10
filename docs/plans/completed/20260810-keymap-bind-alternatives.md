# Keymap bind alternatives

## Overview

Extend `keymap.conf` so one `map` or `command` line can carry several alternative keybinds, separated by
`|` inside a single whitespace-delimited token:

```
map cmd+t|ctrl+space>s toggle_split
command "Midnight Commander" ctrl+a>m|cmd+a>m  mc
```

Two things this fixes. Built-in actions cannot take a leader sequence at all today —
`parseMapLine` rejects one with "built-in shortcut cannot be a leader sequence" because built-ins dispatch
as AppKit menu key equivalents and `NSMenuItem` holds exactly one key-equivalent character. And neither
verb can offer a second way in, so a user who wants both a mac-native chord and a tmux-style prefix has to
pick one.

Alternatives solve both with one rule instead of two features: a binding is a list, the first single-chord
alternative becomes the menu key equivalent, and every other alternative is matched by the app-wide
`keyDown` monitor that already implements leader sequences for custom commands.

`|` sits one tier above the existing separators — `|` splits alternatives, `>` splits a sequence into
chords, `+` splits a chord into modifiers plus a base key.

**Alternatives are entirely optional and the change is additive.** See Compatibility for the exact
invariant, which is narrower than "nothing changes" and is pinned by tests in Task 6.

## Context (from discovery)

- `agtermCore/Sources/agtermCore/Keybind.swift` — `parseKeybind` (243), `parseChord` (257),
  `keybindConflicts` (306), `Chord.displayString` (198), `Chord.glyphString` (211), `Keybind = [Chord]` (234)
- `agtermCore/Sources/agtermCore/Keymap.swift` — `equivalent(for:)` (16) is
  `builtinOverrides[action] ?? action.defaultChord`, `glyphHint` (22), `resolveBuiltinOverrides` (141),
  `validateCommands` (213), `parseMapLine` (296), `parseCommandLine` (335)
- `agtermCore/Sources/agtermCore/KeybindMatcher.swift` — the leader state machine. **UUID-typed at its
  core**: `MatchResult.fired(UUID)` and `init(_ binds: [(Keybind, UUID)])`.
- `agtermCore/Sources/agtermCore/CustomCommandEngine.swift` — wraps the matcher, resolves id to command
- `agtermCore/Sources/agtermCore/ControlKeymap.swift` — `ControlKeymapAction`, `ControlKeymapCommand`,
  `ControlKeymap.project` (112)
- `agtermCore/Sources/agtermctlKit/SocketClient.swift` — `formatKeymap` (239)
- `agterm/Commands/CustomCommandRunner.swift` — `handleKeyDown(_:in:)` (98), `rebuild` (65) and its
  validity log (68), the `toggle_fullscreen` special case (129). **It receives no `AppActions`** today
  (`agterm/agtermApp.swift:65`).
- `agterm/AppActions+Palette.swift` — `shortcutGlyph(for:)` (12);
  `PaletteCommand.builtinAction` lives in `agtermCore/Sources/agtermCore/PaletteCatalog.swift:144`
- `CustomCommand.shortcut` is a raw `String` re-parsed on demand and **preserved verbatim** into the
  control projection. The model does not change; only parse, validate and dispatch learn about `|`.

**Current `map` grammar, which the first draft of this plan got wrong.** `parseMapLine` requires no
modifier. It rejects only reserved monitor chords (316) and modifier-less arrows (323). `map t
toggle_split` is legal, and `.claude/rules/keymap.md` states so explicitly. The modifier requirement is
custom-command-only (`parseCommandLine`, 353).

## Development Approach

- **testing approach**: Regular (code first, then tests within the same task)
- complete each task fully before moving to the next; every task carries the tests for the code it changes
- **all tests must pass before starting the next task**
- update this plan when scope changes during implementation

## Testing Strategy

- **host-free unit tests** (`agtermCore/Tests/`) carry the weight: parsing, validation, projection, matching
- **hosted tests** (`agtermTests/`) cover only what needs AppKit. `agtermTests/FullScreenChordTests.swift`
  already drives `handleKeyDown(_:in:)` with a window harness and registry setup — extend it rather than
  adding a second hosted file for the same entry point
- do **not** re-assert guards upstream of the change (text-field pass-through, the repeat guard). They are
  unmodified and already covered
- **no new XCUITest.** Nothing here is a new user-visible surface
- run each gate ONCE at the end: `cd agtermCore && swift test`, `make test-app`, `make lint`. Scope
  intermediate runs with `--filter` / `-only-testing:`

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix, blockers with ⚠️ prefix
- keep the plan in sync with the actual work

## Solution Overview

A binding becomes a list of `Keybind`s wherever it is parsed, while the stored models keep their shapes.
`CustomCommand.shortcut` stays the raw string and simply holds `|`. `builtinOverrides` keeps holding one
`Chord` — the menu key equivalent — and `Keymap` gains two small members: `builtinSequences` for the
alternatives the menu cannot carry, and `builtinUnbound` for the case below.

Dispatch splits along the line it already splits on. The menu key equivalent goes through AppKit as today.
Every other alternative, from either verb, is matched by `CustomCommandEngine` inside the existing monitor
— which already fires one built-in (`toggle_fullscreen`) for exactly this reason.

**Key design decisions:**

1. **Alternatives live inside one token, no spaces around `|`.** `parseCommandLine` takes the shortcut as
   the first whitespace-delimited token and hands the rest to the shell. With spaces,
   `command "mc" ctrl+a>m | cmd+a>m mc` would parse the shortcut as `ctrl+a>m` and the shell line as
   `| cmd+a>m mc` — a plausible-looking pipe, silently wrong, no diagnostic. Keeping alternatives inside
   the token means the tokenizer needs no change at all.
2. **A `map` line fully declares the action's bindings.** First single-chord alternative wins the menu
   equivalent; the rest go to the monitor.
3. **`builtinUnbound` exists because absence already means something else.** `equivalent(for:)` is
   `builtinOverrides[action] ?? action.defaultChord` (`Keymap.swift:16`), so "no entry" means "use the
   shipped default". A `map` line with no single-chord alternative must therefore record the action as
   explicitly unbound, or `map ctrl+space>s toggle_split` would silently leave ⌘-whatever live.
4. **The per-alternative grammar follows the dispatch path, not the verb.** The menu-bound alternative
   keeps `map`'s existing rules (bare non-arrow legal, reserved chords and bare arrows rejected). Every
   monitor-bound alternative — from either verb — requires a modifier on its first chord, because a bare
   first key would be swallowed everywhere in the terminal. That is the same rule `parseCommandLine`
   already applies, now stated by where the binding is dispatched.
5. **Conflicts drop only the offending alternative.** Alternatives exist for redundancy; killing a working
   key because a sibling collided is a punishment with no purpose. **A malformed alternative is different
   and deliberately kills the whole line** — `parseKeybinds` returns nil if any part fails to parse. A typo
   is not a collision, and binding half of what the line says would hide the mistake behind a line that
   looks like it worked. Every other parse failure in the file already behaves this way. Do not "fix" this
   into per-alternative recovery.
6. **Both passes see built-in monitor alternatives.** They need pass 1 as much as custom commands do:
   `map cmd+t|cmd+t>s toggle_split` would otherwise let the monitor arm on `cmd+t` and suppress the menu
   equivalent that same line advertises. And they need pass 2, because they share one matcher with custom
   commands, where an unchecked duplicate or prefix silently shadows by registration order.

## Compatibility

**Invariant: a `keymap.conf` with no `|` and no multi-chord `map` binding behaves identically before and
after.** Task 6 pins it rather than leaving it to reasoning.

The multi-chord `map` carve-out is the feature itself: `map ctrl+a>g toggle_split` today emits "built-in
shortcut cannot be a leader sequence" and binds nothing; afterwards it binds and emits no diagnostic. That
line contains no `|`, so the blanket claim would be false without the carve-out.

Why the invariant holds elsewhere:

- `parseKeybind` is untouched; `parseKeybinds` on a `|`-free token returns a one-element list wrapping
  exactly its result
- a single-chord `map` takes the same path as today: one alternative, menu-bound, `builtinSequences` and
  `builtinUnbound` both empty for that action
- `builtinOverrides` keeps its type and its last-wins fold; `resolveBuiltinOverrides` and its fixpoint are
  not touched
- `CustomCommand.shortcut` stays a raw `String` holding the same text
- the validation passes degrade to today's behavior at one alternative: a per-alternative drop of the only
  alternative is the wholesale drop, and `shortcut` still ends up `""`
- `ControlKeymapAction.alternates` is optional and omitted when empty, so existing JSON consumers see an
  unchanged payload; `formatKeymap` joins with `|` only when alternatives exist

**Two things the implementation must actively preserve, not merely avoid breaking:**

- **Diagnostic text must degrade to today's exact wording** for a single-alternative binding, printing the
  **raw substring** from the file. Rebuilding it from `Keybind.displayString` canonicalizes spelling
  (`command+shift+a` → `cmd+shift+a`, whitespace normalized) and would change `keymap list` diagnostics for
  `|`-free files.
- **Dedupe must not canonicalize.** `shortcut` is preserved verbatim from parse through control projection;
  dropping a duplicate alternative must splice raw substrings, never re-render.

**Two accepted imperfections, both deliberate:**

- `command "x" a|b echo hi` — today `a|b` fails `parseChord` (multi-char, not a named key) so the whole
  tail is shell with no diagnostic. Afterwards it splits into two modifier-less chords and the existing
  "shortcut must include a modifier" diagnostic fires. **The shell line is identical either way** and the
  command still works; only an extra diagnostic appears. Narrowing the parse to dodge it costs more than
  the case is worth.
- `cmd+|` stops parsing as a chord, since `parseChord` accepts any single character (`Keybind.swift:275`)
  and `|` now splits first. Harmless: no unshifted key produces `|`, so such a binding parses today but can
  never fire — the spelling that fires is `shift+\`.

`keybindConflicts`, `KeybindMatcher` and `CustomCommandEngine.Outcome` are `public` in `agtermCore` and
change signature. Their only consumers are `Keymap.swift:244`, `CustomCommandRunner.swift:140`,
`CustomCommandEngine`, and their own tests — all in this repository, so this is a source-compatible
refactor, not a published API break.

## Technical Details

**`Keybind.swift`:**

```swift
public func parseKeybinds(_ s: String) -> [Keybind]?   // splits on "|", nil if any part is malformed or list empty
public extension Array where Element == Chord {
    var displayString: String   // kitty syntax, chords joined with ">"
    var glyphString: String     // macOS glyphs, chords joined with " "
}
public enum KeybindTarget: Hashable, Sendable { case command(UUID), builtin(BuiltinAction) }
public func keybindConflicts(_ binds: [(keybind: Keybind, target: KeybindTarget)]) -> [KeybindConflict]
```

`KeybindConflict` changes from a UUID pair to a `KeybindTarget` pair. `KeybindMatcher` changes from
`UUID` to `KeybindTarget` in `init` and `MatchResult.fired`.

**`Keymap`:**

```swift
public let builtinSequences: [BuiltinAction: [Keybind]]   // monitor-bound alternatives
public let builtinUnbound: Set<BuiltinAction>             // "explicitly has no menu chord"
public func sequences(for action: BuiltinAction) -> [Keybind]
public func equivalent(for action: BuiltinAction) -> Chord?   // nil when in builtinUnbound
```

Both new members default to empty in the memberwise `init`, so the existing
`Keymap(builtinOverrides:commands:)` call sites keep compiling.

`glyphHint(for:)` returns the menu chord's glyph plus each alternative's glyph string, space-joined
(`⌘T ⌃␣S`); with no menu chord it returns the alternatives alone; nil when there is neither.

**`CustomCommandEngine`** takes `(commands:builtinSequences:)` and its `Outcome.fired` payload becomes
`KeybindTarget`. `AppActions.perform(_:in:)` reverse-looks-up `PaletteCommand.allCases` on `builtinAction`
and falls back to a small switch for the few actions with no palette row — no new 42-case table.

## What Goes Where

- **Implementation Steps**: parser, validation, dispatch, projection, tests, docs — all in-repo
- **Post-Completion**: manual keyboard verification on a Debug instance, which no automated test replaces

## Implementation Steps

### Task 1: Parse alternatives, render a Keybind, retarget the matcher

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Keybind.swift`
- Modify: `agtermCore/Sources/agtermCore/KeybindMatcher.swift`
- Modify: `agtermCore/Sources/agtermCore/Keymap.swift`
- Modify: `agtermCore/Sources/agtermCore/CustomCommandEngine.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/KeybindTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/KeybindMatcherTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/KeymapTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/CustomCommandEngineTests.swift`

- [x] add `parseKeybinds(_:) -> [Keybind]?` splitting on `|`, nil when any alternative is malformed or the
      list is empty; leave `parseKeybind` untouched so existing callers keep compiling
- [x] add `displayString` and `glyphString` on `Array where Element == Chord`
- [x] add `KeybindTarget` and retarget `KeybindMatcher` (`init` and `MatchResult.fired`) from `UUID` to it
- [x] switch `parseCommandLine`'s first-token check to `parseKeybinds`, requiring a modifier on the first
      chord of EVERY alternative; keep the existing palette-only fallback and its exact diagnostic wording
      for a token that is not a keybind at all
- [x] dedupe identical alternatives by splicing raw substrings, never re-rendering
- [x] have `CustomCommandEngine` emit one matcher entry per alternative, all sharing the command's target
- [x] write tests: one/two/three alternatives, sequence alternatives, empty part (`a||b`), leading and
      trailing `|`, one malformed alternative poisoning the list, both renderers on a multi-chord keybind,
      a two-alternative command firing from either, an alternative without a modifier failing the line
- [x] pin the accepted imperfection: `command "x" a|b echo hi` keeps the shell line `a|b echo hi` verbatim
      and stays palette-only
- [x] run `swift test --filter "KeybindTests|KeybindMatcherTests|KeymapTests|CustomCommandEngineTests"` —
      must pass before task 2

### Task 2: Accept alternatives on `map` lines

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Keymap.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/KeymapTests.swift`

- [x] replace the `keybind.count == 1` guard (`Keymap.swift:310`) with `parseKeybinds`, splitting the
      result into the first single-chord alternative (menu-bound) and the rest (monitor-bound)
- [x] add `builtinSequences` and `builtinUnbound` to `Keymap`, both defaulting to empty in the memberwise
      init; make `equivalent(for:)` return nil for an action in `builtinUnbound`
- [x] record an action as unbound when its `map` line has no single-chord alternative, so the shipped
      default does not silently survive
- [x] apply the grammar by dispatch path: the menu-bound alternative keeps today's `map` rules (bare
      non-arrow legal, reserved chords and modifier-less arrows rejected); every monitor-bound alternative
      requires a modifier on its first chord
- [x] keep `isReservedMonitorChord` rejected at any position in any alternative; fold last-wins per action
      per line; dedupe identical alternatives
- [x] leave `resolveBuiltinOverrides` and its fixpoint untouched, and let a built-in that loses its menu
      chord there KEEP its monitor alternatives
- [x] write tests: `map cmd+t|ctrl+space>s toggle_split` yields both; `map ctrl+space>s toggle_split`
      leaves the action unbound rather than on its default; `map t toggle_split` still works (bare
      non-arrow); a bare first chord on a monitor-bound alternative is rejected; two single-chord
      alternatives put the first on the menu and the second on the monitor; a later `map` line replaces the
      whole earlier one; reserved-chord and bare-arrow rejection; `map cmd+t|cmd+t toggle_split` dedupes
- [x] run `swift test --filter KeymapTests` — must pass before task 3

### Task 3: Per-alternative validation across both verbs

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Keybind.swift`
- Modify: `agtermCore/Sources/agtermCore/Keymap.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/KeybindTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/KeymapTests.swift`

- [x] rework pass 1 to test each alternative separately against the active built-in menu chord set,
      **including built-in monitor alternatives**, dropping only the offending alternative
- [x] change `keybindConflicts` to take `(Keybind, KeybindTarget)` pairs and return `KeybindTarget` pairs,
      keeping the prefix-or-duplicate rule, and feed it every alternative from both verbs
- [x] drop only the conflicting alternative from each side in pass 2, keeping siblings; set `shortcut = ""`
      only when every alternative is gone, preserving today's palette-only outcome
- [x] name the dropped alternative by its raw substring in the diagnostic, and make the single-alternative
      case produce today's exact wording character for character
- [x] extend the diagnostics to name a built-in action where one is the offender
- [x] ➕ fix the built-in collision fixpoint so an action in `builtinUnbound` contributes no chord: today
      `resolveBuiltinOverrides`/`firstBuiltinCollision` still count its shipped `defaultChord`, so
      `map ctrl+a>d toggle_split` followed by `map cmd+d new_session` drops the second line against a chord
      `toggle_split` no longer uses. Built-in-versus-built-in only — `validateCommands` already reads
      `equivalent(for:)`, which is nil for an unbound action
- [x] write tests: one of two alternatives shadowed by a built-in leaves the other live; both shadowed
      empties the shortcut; a built-in alternative shadowed by its own line's menu chord
      (`map cmd+t|cmd+t>s`); command-vs-built-in-alternative losing only that key; built-in-vs-built-in;
      a prefix conflict (`ctrl+space` vs `ctrl+space>s`); single-alternative diagnostics byte-identical to
      today's
- [x] run `swift test --filter "KeybindTests|KeymapTests"` — must pass before task 4

### Task 4: Fire built-in alternatives from the monitor

**Files:**
- Modify: `agterm/Commands/CustomCommandRunner.swift`
- Modify: `agterm/AppActions+Palette.swift`
- Modify: `agterm/agtermApp.swift`
- Modify: `agtermTests/FullScreenChordTests.swift`

- [x] inject `AppActions` into `CustomCommandRunner` (it receives none today, `agtermApp.swift:65`)
- [x] add `AppActions.perform(_ action: BuiltinAction, in window: NSWindow?)` as a reverse lookup over
      `PaletteCommand.allCases` on `builtinAction`, running the palette row's body under the MENU item's
      modal rule and its `isVisible(in:)` enablement so an alternative behaves as its line's menu chord
      does; a small switch covers the few actions with no palette row
- [x] dispatch `.builtin` from `handleKeyDown(_:in:)` without the `focusedSurface` / `runNoSurface` split —
      a built-in acts on the active session and key window like a palette row
- [x] rebuild the engine on `.agtermKeymapChanged` from both commands and built-in sequences
- [x] fix the validity log at `CustomCommandRunner.swift:68` to use `parseKeybinds`, so a `|` shortcut no
      longer logs a false "invalid shortcut; skipping keybind" while the engine binds it
- [x] leave `guard !event.isARepeat` where it is: holding a key bound to a built-in fires once
- [x] extend `FullScreenChordTests` to drive `handleKeyDown(_:in:)` through a built-in sequence alternative,
      asserting the action ran and the key was consumed
- [x] run `make test-app -only-testing:` scoped to the new case — must pass before task 5

### Task 5: Read-back and display

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlKeymap.swift`
- Modify: `agtermCore/Sources/agtermCore/Keymap.swift`
- Modify: `agtermCore/Sources/agtermctlKit/SocketClient.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlKeymapTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/KeymapTests.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/SocketClientTests.swift`

- [x] add `alternates: [String]?` to `ControlKeymapAction`, omitted when empty, each alternative in kitty
      syntax; leave `chord` meaning the menu key equivalent so the `menu` half stays comparable
- [x] populate it in `ControlKeymap.project` from `sequences(for:)`, and report an unbound action's `chord`
      as absent rather than as its shipped default
- [x] render the actions column in `formatKeymap` as the full binding set joined with `|`, keeping `-` for
      an action with no binding at all
- [x] extend `glyphHint(for:)` to append each alternative's glyph string after the menu chord's, returning
      the alternatives alone when there is no menu chord and nil when there is neither
- [x] leave `shortcutGlyph(for:)` and its callers untouched — it stays the single resolver behind the
      action palette and the toolbar/sidebar tooltips
- [x] write tests: action with chord plus one alternative, chord plus two, alternatives only, neither, an
      unbound action, and the human formatter's joined column
- [x] run `swift test --filter "ControlKeymapTests|KeymapTests|SocketClientTests"` — must pass before task 6

### Task 6: Pin compatibility and verify acceptance criteria

**Files:**
- Modify: `agtermCore/Tests/agtermCoreTests/KeymapTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlKeymapTests.swift`

- [x] add a test parsing a realistic `keymap.conf` with no `|` and no multi-chord `map` — several `map`
      lines including a bare non-arrow one, keyed and palette-only `command` lines, a deliberate conflict —
      asserting `builtinOverrides`, `commands` and diagnostic strings match today's output exactly, with
      `builtinSequences` and `builtinUnbound` empty
- [x] assert an empty keymap leaves every built-in on its shipped default chord
- [x] assert `ControlKeymap.project` omits `alternates` entirely for that keymap and `formatKeymap`'s output
      is byte-identical to the pre-change format
- [x] verify by hand against the plan: both alternatives fire a command; a sequence-only `map` leaves the
      action with no menu shortcut; a conflicting alternative drops alone with its siblings still firing —
      each already asserted by `CustomCommandEngineTests.eitherAlternativeFiresTheSameCommand`,
      `KeymapTests.mapSequenceOnlyLineLeavesTheActionWithoutAMenuChord`, and
      `KeymapTests.commandAlternativeShadowedByABuiltinDropsAloneAndKeepsTheSibling`
- [x] run the full gates ONCE: `cd agtermCore && swift test`, `make test-app`, `make lint`

### Task 7: [Final] Update documentation

**Files:**
- Modify: `.claude/rules/keymap.md`, `.claude/rules/control-api.md`
- Modify: `plugins/agterm/skills/agterm/SKILL.md`, `plugins/agterm/skills/agterm/reference.md`
- Modify: `README.md`, `site/docs.html`, `site/commands.html`

- [x] rewrite `.claude/rules/keymap.md:18` ("`map <chord> <action>` accepts one chord, not a leader") and
      `:109` ("Built-in leaders remain unsupported; leaders are custom-only") — both become wrong
- [x] document the `|` tier, the first-single-chord-wins-the-menu rule, the unbound case, the
      grammar-follows-dispatch-path rule, and per-alternative conflict dropping in `keymap.md`; document
      `alternates` in `control-api.md`
- [x] update the bundled skill (`SKILL.md`, `reference.md`), the sole source for installed Claude/Codex
      copies
- [x] update README's keymap section, mirror it in `site/docs.html`, add `alternates` to
      `site/commands.html`
- [x] ➕ correct the starter `keymap.conf` text in `ConfigPaths.swift`, which still told users built-ins
      take no leader sequences, and add an alternatives example (`ConfigPathsTests` counts updated)
- [x] leave `cookbook/` alone — it is not a synchronized surface
- [ ] move this plan to `docs/plans/completed/` — owned by the orchestrator, not this task

### Task 8: [Scope expansion, approved mid-run] One predicate owns menu enablement

Task 4 kept menu/monitor equivalence by hand in three places, and review closed the drift twice more. Two of
the three hand-maintained pieces go: `survivesModalCover`, the list of actions whose menu item carries no
`modalActive` mirror, and the "no active session / no current workspace" terms each menu item spells itself
while the matching `AppActions` method merely happens to guard the same way. The `close_session` body
special case STAYS — removing it would change what the palette's Close Session row does.

`PaletteCommand.isEnabled(in:)` becomes the single owner: the menu item's `.disabled(…)`, the palette row
and `perform(_:in:)` all read it. The palette keeps showing rows the menu disables (Rename Session with no
session), so it needs a shown-but-inert state rather than the rows vanishing.

**Files:**
- Modify: `agtermCore/Sources/agtermCore/PaletteCatalog.swift`
- Modify: `agterm/AppActions+Palette.swift`, `agterm/agtermApp+Menus.swift`, `agterm/Views/Palette.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/PaletteCatalogTests.swift`
- Modify: `agtermTests/AppActionsPaletteTests.swift`, `agtermTests/CustomCommandRunnerTests.swift`
- Modify: `.claude/rules/menu-actions.md`, `.claude/rules/keymap.md`, `README.md`, `site/docs.html`,
  `docs/backlog/toggle-fullscreen-menu-chord-bypasses-the-modal-gate.md`

- [x] widen `PaletteContext` with `hasActiveSession`, `hasCurrentWorkspace` and the three covers
      (`terminalZoomActive`, `dashboardOpen`, `pickerActive`) plus a derived `modalActive`
- [x] add `PaletteCommand.isEnabled(in:)` = `isVisible` then the modal cover then the presence terms, with
      the cover arm carrying what `survivesModalCover` listed, and keep `isVisible` deliberately wider
- [x] have every `PaletteCommand`-backed menu item read it, leaving the bare `modalActive` only for the
      items with no palette row (window management, Open Recent, the three palette launchers)
- [x] have `perform(_:in:)` read it and delete `survivesModalCover`; leave the `close_session` body case
- [x] give `PaletteItem` an `enabled` flag; the row renders the system disabled-control color, takes no
      hover tint, and `runItem` neither runs nor dismisses it
- [x] write tests: host-free enablement sweeps over every command for each cover and each presence term,
      plus rows staying visible where they go inert; hosted, a palette row listed-but-inert and live again
      once a session exists, a monitor alternative inert on the same term its menu item disables on, and
      close session dismissing the cover its sidebar sibling is blocked by
- [x] update `menu-actions.md` (the owner), `keymap.md` (cross-reference), README, `site/docs.html` and the
      `toggle_fullscreen` backlog item's now-stale wording
- [x] run the full gates ONCE: `cd agtermCore && swift test`, `make test-app`, `make lint`

### Task 9: [Scope expansion, approved mid-run] One conflict rule, and a palette flag that is not a snapshot

Two interacting conflict rules plus a `dropSiblingShadowedAlternatives` pre-pass produced order-dependence
twice. Review found both in the shipped code: `targetRank` still derived the traversal from file order, so
`A = ctrl+a>b`, `B = ctrl+a`, `C = ctrl+a>c` kept whichever of A and C the file listed last; and the sibling
pre-pass dropped a longer alternative for a shorter sibling that then died itself. They are replaced by ONE
rule, stated in `keymap.md`. Separately, `PaletteItem.enabled` cached enablement in `filtered`, which
refreshes only on appear/query/mode, so a row that went inert under an open palette still passed the guard
and dismissed it.

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Keymap.swift`
- Modify: `agterm/Views/Palette.swift`, `agterm/AppActions+Palette.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/KeymapTests.swift`, `agtermTests/AppActionsPaletteTests.swift`
- Modify: `.claude/rules/keymap.md`, `.claude/rules/menu-actions.md`

- [x] keep the menu-shadow pass first and unchanged; compute the conflict relation ONCE over its survivors
      and settle it in one pass — both sides of a cross-target pair, the longer side of a same-target prefix
      pair — with no fixpoint, no re-derivation, no target ranking and no ordering tie-break
- [x] accept that an alternative charged for a conflict with one that also dropped still dies; add no
      recovery pass
- [x] delete `dropSiblingShadowedAlternatives`, the `targetRank`/canonical-ordering machinery and the
      comments explaining them; keep `isStrictKeybindPrefix`, shared with `KeybindMatcher`
- [x] replace `aCrossTargetConflictLeavesTheLoserUnableToDropAThirdBinding`, which encoded the
      order-dependent outcome of counterexample (i), and add order-independence tests over reordered
      alternatives and reordered lines
- [x] make `PaletteItem.enabled` a live `isEnabled` closure, read during row body evaluation and again by
      the new `runIfEnabled()`, which is what `runItem` dismisses on
- [x] write tests: a row flipping live→inert→live under an open palette, and an inert row running and
      dismissing nothing
- [x] run the full gates ONCE: `cd agtermCore && swift test`, `make test-app`, `make lint`

## Post-Completion

**Manual verification** (no automated test replaces this):
- launch a Debug instance with an isolated `AGTERM_STATE_DIR` and a `keymap.conf` using alternatives on
  both verbs; confirm the menu item, the alternative sequence, and the palette hint agree
- confirm a half-typed leader still times out after 1.5s and that Esc abandons it
- confirm ⌘Q and the reserved chords (ctrl+tab, ctrl+1/2) are unaffected

**Out of scope, worth a look afterward:**
- `toggle_fullscreen`'s special case (`CustomCommandRunner.swift:129`) becomes expressible as an ordinary
  built-in monitor bind once this lands. Not bundled here.

Smells pre-check: skipped — non-Go project
