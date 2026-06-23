# Keymap Config File (kitty-style)

## Overview

A user-editable, kitty-flavored keymap config file that lets the user (1) **rebind existing built-in
actions** (the menu shortcuts) and (2) **define custom shell commands** bound to keys, with custom
commands surfaced in the command palette marked `custom`. A new Settings field points at a config
**directory** (default `~/.config/agterm`); the keymap lives at `<dir>/keymap.conf`.

Problem it solves: today every shortcut is hardcoded in `agtermApp`'s `.commands` and there is no way
to add custom command launchers. This makes the keymap user-owned (like kitty's `kitty.conf`) while
keeping the app's defaults working out of the box.

Two-section verb-based format:

```
# built-in keys (override default; single chord only)
map cmd+shift+d   toggle_split
map ctrl+shift+k  command_palette

# custom commands (leaders ok; "name" for palette)
command "Open in Zed"  cmd+shift+e  open -a Zed {AGT_SESSION_PWD}
command "Lazygit"      ctrl+a>g     lazygit
command "Deploy"                    ./deploy.sh   # palette-only, no key
```

The design splits cleanly along the existing app/core boundary and reuses a large, already-unit-tested
body of pure logic from the (unmerged, pre-rename) `custom-commands` branch.

## Context (from discovery)

- **agterm** is a native macOS SwiftUI terminal on libghostty. `agtermCore` is the host-free
  model/logic package (`swift test`, no Xcode/GhosttyKit); the app target owns SwiftUI + AppKit +
  libghostty. The `agtermctl` CLI lives in the same SwiftPM package (`agtermctlKit` + `agtermctl`).
- **Reuse source — branch `custom-commands`** (predates the `agt`→`agterm` rename, so it uses `agt`/
  `agtCore`/`com.umputun.agt`; port with names fixed). Read via `git show custom-commands:<path>`:
  - `agtCore/Sources/agtCore/Keybind.swift` (+ `KeybindTests.swift`) — `Modifier`/`Chord`/`Keybind`/
    `parseKeybind` + `keybindConflicts`. kitty grammar (chords split on `>`, tokens on `+`, mods
    `ctrl/cmd/opt/shift`; leaders supported). Host-free, unit-tested.
  - `agtCore/Sources/agtCore/KeybindMatcher.swift` (+ `KeybindMatcherTests.swift`) — leader/sequence
    state machine (`.fired`/`.armed`/`.unmatched`, deadline-free). Unit-tested.
  - `agtCore/Sources/agtCore/CustomCommand.swift` (+ `CustomCommandTests.swift`) — `CustomCommand`
    `{id,name,command,shortcut}` + `CommandContext` token expansion (`{AGT_X}` tokens == `$AGT_X`
    env, single source-of-truth table). Unit-tested.
  - `agt/Commands/CustomCommandRunner.swift` — app-side NSEvent local monitor → matcher → detached
    `/bin/sh -c` spawn with the focused-pane session context; leader timeout (1.5 s), key-repeat
    ignore, focus-gating, failure banner. The branch also touched `WindowLibrary.swift` (+17,
    `windowSession(forSurface:)`), `NotificationManager.swift` (+14, `notifyCommandFailure`),
    `AppActions.swift` (+16), `Session.swift` (+7), `GhosttyApp.swift` (+4) — port the supporting
    helpers the runner needs.
  - Reference: `docs/plans/completed/20260620-custom-commands.md` on that branch.
- **Master files this plan modifies** (current layout):
  - `agtermCore/Sources/agtermCore/AppSettings.swift` (+ `AppSettingsTests.swift`) — optional-field
    Codable settings; add `configDirectory`.
  - `agtermCore/Sources/agtermCore/ControlResolve.swift` — pure path resolvers (`socketPath(...)`);
    add the config-dir / keymap-path resolver alongside it.
  - `agtermCore/Sources/agtermCore/ControlProtocol.swift` — `Command` enum (33 cases today); add
    `keymapReload`.
  - `agterm/SettingsModel.swift` — `@Observable` loader; add keymap load/parse/reload + starter-file.
  - `agterm/Views/SettingsView.swift` — replace the "Key Mapping" `PlaceholderSettings` tab.
  - `agterm/Views/Palette.swift` — `PaletteItem` + `CommandPalette.row`; add the `custom` badge.
  - `agterm/AppActions.swift` — `paletteActions()` (append custom commands); a `reloadKeymap()` action.
  - `agterm/agtermApp.swift` — `.commands` data-driven `.keyboardShortcut`; wire the runner + reload.
  - `agterm/Control/ControlServer.swift` — dispatch arm for `keymap.reload`.
  - `agtermCore/Sources/agtermctlKit/Commands.swift` + `SocketClient.swift` — `keymap reload` subcommand.
- **Patterns observed**: pure logic lives in `agtermCore` (unit-tested); the app target wires it.
  NSEvent local monitors already drive `SessionSwitcher` (Ctrl-Tab) and `PaneShortcuts` (Ctrl-1/2).
  `.commands` already reads the `@Observable` `library` reactively (e.g. `.disabled(...)`), so a menu
  `.keyboardShortcut` can be made data-driven from another `@Observable` the same way. Settings persist
  under `AGTERM_STATE_DIR` (test isolation). XCUITests use `launchForUITest()` and the observable-side-
  effect pattern (write a tty/touch a tempfile, assert it appears).

## Development Approach

- **Testing approach: Regular** (implement each unit, then write its tests before moving on). Tests
  are required per task, not optional.
- **Keep `agtermCore` host-free**: NO AppKit / GhosttyKit / Metal. The keybind parser, matcher, token
  expansion, `BuiltinAction`, `Keymap`, `parseKeymap`, validation, and path resolution are all pure
  agtermCore logic; the app target maps `NSEvent.ModifierFlags` → the agtermCore `Modifier`, drives
  the menu, and spawns processes.
- **Use the `swiftui-expert` skill** for ALL SwiftUI/AppKit work (the data-driven menu rebind, the
  NSEvent monitor, the Settings tab, the directory picker). **Use `swift-concurrency`** for
  `@MainActor`/`Sendable` questions and **`swift-testing-expert`** for tests. When stuck (4+ failed
  attempts on the same problem), consult `ask-codex`.
- Complete each task fully before the next; small focused changes; match existing agterm patterns and
  the project CLAUDE.md working norms (methods-over-functions, private-by-default visibility, lowercase
  non-godoc comments, **one test file per source file**).
- **Every task includes new/updated tests** and **all tests pass before starting the next task.**
- Do NOT rename the `{AGT_X}` / `$AGT_X` token prefix — keep it exactly as the branch has it.

## Testing Strategy

- **Unit tests (`agtermCore`, `swift test`)** — the bulk:
  - `parseKeybind` / `KeybindMatcher` / `CommandContext` expansion — carried over from the branch.
  - `parseKeymap` — both verbs; the optional-chord rule (chord present vs palette-only); quoted names
    with spaces; `{AGT_X}` preserved in the shell line; comments (`#`) + blank lines ignored; malformed
    lines → diagnostics with line numbers while good lines still parse.
  - `BuiltinAction` — name → case round-trip, every case has a default, reject unknown name, reject a
    leader given to a built-in.
  - `Keymap.equivalent(for:)` — override wins, default otherwise.
  - Cross-section validation — custom chord == built-in default; custom chord == an *overridden*
    built-in chord (and the old default is free again once the built-in moves); custom leader whose
    first chord == a built-in chord; custom-vs-custom via existing `keybindConflicts`.
  - Path resolution — `configDirectory` nil → `~/.config/agterm`; keymap path = `<dir>/keymap.conf`.
  - `AppSettings.configDirectory` round-trips and decodes nil when absent.
- **e2e (`agtermUITests`, XCUITest, observable-side-effect)** — seed `<AGTERM_STATE_DIR>/config/
  keymap.conf` via launch env, `launchForUITest()`:
  - Built-in override fires at the new chord AND the old default no longer fires.
  - Custom single chord + custom leader (`ctrl+a>g`) → body `touch <tempfile>`, assert the file appears.
  - Palette shows the `custom` badge and runs the command from the palette.
  - "Reload Keymap" picks up a rewritten file (new binding fires after reload).
- **Gates after each task**: `cd agtermCore && swift test`; `xcodegen generate` + `xcodebuild` Debug;
  the relevant `agtermUITests` for UI tasks; Swift formatting (`~/.claude/format.sh`). This is Swift —
  no Go tooling. **Per CLAUDE.md, ASK which UI-test scope to run before committing** (focused vs the
  full ~460 s suite); this touches menu wiring + an NSEvent monitor, so focused classes, not the whole
  suite.

## Progress Tracking

- Mark completed items `[x]` immediately when done.
- Add newly discovered tasks with ➕ prefix; blockers with ⚠️ prefix.
- Keep this plan in sync with actual work; update if scope changes.

## Solution Overview

Two layers, matching the agtermCore/app split.

**agtermCore (pure, unit-tested):**
- Ported: `Keybind` (`Modifier`/`Chord`/`Keybind`/`parseKeybind`/`keybindConflicts`), `KeybindMatcher`,
  `CustomCommand`/`CommandContext`.
- New: `BuiltinAction` (enum of rebindable built-ins, each with canonical name + shipped default
  chord); `Keymap` (parse result — built-in overrides + custom commands — with `equivalent(for:)`);
  `parseKeymap` (two-verb line parser → `Keymap` + `[KeymapDiagnostic]`, never throws); cross-section
  validation; the config-dir / keymap-path resolver.

**app target:**
- `agtermApp.commands` — each built-in menu `Button` gets `.keyboardShortcut(keymap.equivalent(for:
  .action))` instead of a hardcoded literal, driven by the `@Observable` keymap on `SettingsModel`.
  AppKit menu dispatch handles built-ins exactly as today.
- `CustomCommandRunner` (ported) — NSEvent local monitor + `KeybindMatcher` for custom commands
  (single chord OR leader); detached `/bin/sh -c` spawn with focused-pane context; rebuilds on the
  keymap-changed notification.
- `SettingsModel` — resolves `<configDir>/keymap.conf`, reads + `parseKeymap`, holds the `@Observable`
  `Keymap`; creates the dir + a commented starter file on first launch; `reloadKeymap()` re-reads.
- `SettingsView` "Key Mapping" tab — directory picker + read-only diagnostics list + Reload button.
- `Palette` — `PaletteItem` gains a `custom` badge; `paletteActions()` appends custom commands.
- Control: `keymap.reload` end-to-end.

**Data flow:** config dir → `keymap.conf` → `parseKeymap` → `Keymap` (`@Observable`) →
(a) built-ins re-render `.commands` shortcuts; (b) the runner rebuilds its matcher + the palette lists
customs. Cross-section validation (a SINGLE final pass over the fully-resolved built-in chord set)
drops any custom keybind whose first chord equals an active built-in chord (the command still shows in
the palette, just unkeyed).

**Why there is no precedence fight (precise):** the NSEvent monitor only consumes chords registered in
its matcher, and validation guarantees those registered chords are disjoint from the active built-in
(menu) chords. So every physical chord is owned by exactly one mechanism — the menu OR the monitor,
never both — regardless of AppKit's menu-key-equivalent-vs-local-monitor dispatch order (the design does
NOT rely on asserting that order). Caveat: validation covers agterm's own 24 built-ins, NOT system/
standard menu items (⌘Q/⌘C/⌘,); binding a custom command to one of those is the user's call and resolves
by AppKit's own dispatch — documented, not validated.

**v1 scope cut (confirmed):** the Ctrl-Tab MRU session switcher (needs modifier-hold) and Ctrl-1/
Ctrl-2 direct pane focus (NSEvent monitors, not menu items) are NOT rebindable in v1; they keep their
current keys. Folding them in would mix monitor-driven built-ins with menu-driven ones and reintroduce
a precedence question. Menu-backed rebinds only for now.

## Technical Details

### Types (agtermCore, pure)

```swift
// ported verbatim (module names fixed): Modifier, Chord, Keybind, parseKeybind, keybindConflicts,
// KeybindMatcher / MatchResult, CustomCommand{id,name,command,shortcut}, CommandContext.

// one case per rebindable, MENU-BACKED built-in action.
public enum BuiltinAction: String, CaseIterable, Sendable {
    case newWindow = "new_window", renameWindow = "rename_window", deleteWindow = "delete_window"
    case newWorkspace = "new_workspace", renameWorkspace = "rename_workspace", deleteWorkspace = "delete_workspace"
    case newSession = "new_session", openDirectory = "open_directory", renameSession = "rename_session"
    case closeSession = "close_session", clearStatus = "clear_status"
    case increaseFontSize = "increase_font_size", decreaseFontSize = "decrease_font_size", resetFontSize = "reset_font_size"
    case toggleSplit = "toggle_split", focusLeftPane = "focus_left_pane", focusRightPane = "focus_right_pane"
    case previousSession = "previous_session", nextSession = "next_session"
    case firstSession = "first_session", lastSession = "last_session"
    case quickTerminal = "quick_terminal", sessionPalette = "session_palette", commandPalette = "command_palette"

    // the shipped default chord, or nil for an action that has no default key today.
    public var defaultChord: Chord? { ... }
}

// the parsed keymap.
public struct Keymap: Equatable, Sendable {
    public let builtinOverrides: [BuiltinAction: Chord]   // single-chord only
    public let commands: [CustomCommand]                  // shortcut may be "" (palette-only) or a leader
    // the active chord for a built-in: the override if present, else the shipped default.
    public func equivalent(for action: BuiltinAction) -> Chord?
}

public struct KeymapDiagnostic: Equatable, Sendable {
    public let line: Int          // 1-based; 0 for whole-file/cross-section diagnostics
    public let message: String
}

// never throws; bad lines become diagnostics and are skipped.
public func parseKeymap(_ text: String) -> (keymap: Keymap, diagnostics: [KeymapDiagnostic])
```

Default-chord mapping (from `agtermApp`'s current `.commands`): `new_window` ⌘⌥N, `new_workspace` ⌘⇧N,
`new_session` ⌘N, `open_directory` ⌘O, `close_session` ⌘W, `toggle_split` ⌘D, `quick_terminal` ⌃\`,
`session_palette` ⌃P, `command_palette` ⌃⇧P, `increase_font_size` ⌘+, `decrease_font_size` ⌘−,
`reset_font_size` ⌘0; the rest (`rename_*`, `delete_*`, `clear_status`, `first_session`, `last_session`)
have **no** default (nil) — they gain a key only when the user `map`s one.

**Arrow defaults return nil too (implementation decision, Task 3).** `focus_left_pane` ⌘⌥←,
`focus_right_pane` ⌘⌥→, `previous_session` ⌥⌘↑, and `next_session` ⌥⌘↓ are bound to ARROW keys in the
menu, which `parseKeybind` cannot express (it accepts only single-char keys or `tab`/`space`/`return`/
`delete`). Rather than invent a non-round-trippable `Chord` representation, `defaultChord` returns nil
for these four; the menu keeps its hardcoded arrow `.keyboardShortcut` as the fallback when
`equivalent(for:)` is nil (Task 9). A user CAN still `map` these to a parseable chord, which then wins.

### Parser grammar

- Split into lines; trim; skip blank lines and lines starting with `#`. Strip trailing ` # comment`
  cautiously (only when not inside the quoted name / not part of the shell line — simplest: a `#` is a
  comment only at line start or preceded by whitespace AND outside quotes; document the chosen rule).
- First token = verb. `map` → built-in; `command` → custom; anything else → diagnostic + skip.
- **`map <chord> <action>`**: parse `<chord>` via `parseKeybind`; reject if it's a leader (count > 1)
  → diagnostic; `<action>` must be a `BuiltinAction` raw value → else diagnostic. Duplicate built-in
  chord (two `map`s to the same chord, or an override colliding with another action's active chord) →
  diagnostic + skip the later one.
- **`command "<name>" [chord] <shell...>`**: require a quoted name (supports spaces). The token right
  after the closing quote is the chord **iff** `parseKeybind` accepts it; otherwise there is no chord
  and the whole remainder is the shell line (palette-only). The shell line keeps `{AGT_X}` tokens
  verbatim. Document the rare ambiguity (a palette-only command whose shell begins with a lone
  chord-like token — `tab`, a single letter, `mod+key`); an explicit `:` separator can be added later
  if it bites.

### Cross-section validation

Applied as a SINGLE FINAL PASS after ALL `map`/`command` lines are parsed (NOT incrementally during
line parsing — otherwise a custom line parsed before a later keyless-built-in `map` would be validated
against an incomplete built-in set), inside `parseKeymap` (so diagnostics ride along):
- Compute the active built-in chords = `{ equivalent(for: a) for a in BuiltinAction.allCases }`
  (every override applied first).
- For each custom command with a non-empty `shortcut`: if its FIRST chord equals any active built-in
  chord → conflict → drop the keybind (clear `shortcut` to `""`, keeping the palette entry) +
  diagnostic. (Built-ins are single-chord, so any custom bind *starting* with that chord — single or
  leader — is shadowed by the menu.)
- Custom-vs-custom duplicate/prefix conflicts → existing `keybindConflicts` → drop both keybinds +
  diagnostic.

### Config / settings

- `AppSettings.configDirectory: String?` (nil → `~/.config/agterm`). Persisted by the existing
  `SettingsStore`; optional-field forward-compat (no version field), matching siblings.
- Resolver (agtermCore, pure, next to `ControlResolve.socketPath`): `configDirectory(override:home:)`
  → URL; `keymapPath(configDirectory:)` → `<dir>/keymap.conf`. App passes the real home/override.
- `SettingsModel`: at init and on `reloadKeymap()`, read the keymap file → `parseKeymap` → set the
  `@Observable var keymap: Keymap` and `var keymapDiagnostics: [KeymapDiagnostic]`. First launch:
  if the file is absent, `createDirectory` + write the commented **starter `keymap.conf`** (lists every
  `BuiltinAction` raw name + its default, the `command` syntax, and the `{AGT_X}` token list). A keymap
  change posts `.agtermKeymapChanged` (renamed from the branch's `.agtCustomCommandsChanged`) so the
  runner rebuilds.

### Reload

- `AppActions.reloadKeymap()` → `settingsModel.reloadKeymap()`. Exposed as a View-menu item + an
  action-palette entry. Same path runs at launch (init) and when the config dir changes in Settings.
- Because `keymap` is `@Observable` and `.commands` reads it, the menu shortcuts re-render on reload;
  the posted notification rebuilds the runner's matcher and the palette re-reads `paletteActions()`.

### Control API

- `keymap.reload` — `Command.keymapReload = "keymap.reload"`; `ControlServer` arm calls
  `settingsModel.reloadKeymap()` and returns the diagnostic count in `result` (e.g.
  `result.count`); `agtermctl keymap reload` subcommand + `SocketClient`; round-trip + e2e tests.
  (No `command.run` — `session.type`/`notify` composition already covers scripting, per the design.)

## What Goes Where

- **Implementation Steps** (`[ ]`): all code, tests, the starter-file content, and README/CLAUDE.md
  updates — achievable in this repo.
- **Post-Completion** (no checkboxes): manual smoke of a real command (`open -a Zed …`) and a real
  built-in rebind; any future work (rebinding the Ctrl-Tab/Ctrl-1/2 monitor interactions; an optional
  `:` shell separator; a file watcher for live reload) — explicitly out of scope this round.

## Implementation Steps

### Task 1: Port Keybind + KeybindMatcher into agtermCore

**Files:**
- Create: `agtermCore/Sources/agtermCore/Keybind.swift`
- Create: `agtermCore/Sources/agtermCore/KeybindMatcher.swift`
- Create: `agtermCore/Tests/agtermCoreTests/KeybindTests.swift`
- Create: `agtermCore/Tests/agtermCoreTests/KeybindMatcherTests.swift`

- [x] port `Keybind.swift` from `custom-commands` (`git show custom-commands:agtCore/Sources/agtCore/Keybind.swift`), fixing module/comment naming only (logic unchanged): `Modifier`, `Chord`, `Keybind`, `parseKeybind`, `keybindConflicts`, `KeybindConflict`
- [x] port `KeybindMatcher.swift` (`MatchResult`, `KeybindMatcher` leader state machine) likewise
- [x] port `KeybindTests.swift` and `KeybindMatcherTests.swift` (adjust `@testable import agtermCore`)
- [x] run `cd agtermCore && swift test` — must pass before next task

### Task 2: Port CustomCommand + CommandContext into agtermCore

**Files:**
- Create: `agtermCore/Sources/agtermCore/CustomCommand.swift`
- Create: `agtermCore/Tests/agtermCoreTests/CustomCommandTests.swift`

- [x] port `CustomCommand` `{id,name,command,shortcut}` (Codable, Sendable, Identifiable) and
      `CommandContext` (`{AGT_X}` token table, `expand`, `environment`, `tokenNames`) — keep the `AGT_`
      token prefix exactly as on the branch
- [x] port `CustomCommandTests.swift` (expand substitution/repeat/unknown→empty/no-tokens, environment
      key/value, the symmetric-table guarantee, Codable round-trip)
- [x] run `swift test` — must pass before next task

### Task 3: BuiltinAction enum (names + default chords)

**Files:**
- Create: `agtermCore/Sources/agtermCore/BuiltinAction.swift`
- Create: `agtermCore/Tests/agtermCoreTests/BuiltinActionTests.swift`

- [x] add `BuiltinAction: String, CaseIterable, Sendable` with the 24 cases + raw kitty-style names (see Technical Details)
- [x] add `defaultChord: Chord?` returning the shipped default for each case (nil for the keyless ones)
- [x] write tests: every raw name round-trips to a case; `BuiltinAction(rawValue:)` rejects an unknown name; each `allCases` element's `defaultChord` matches the documented table (the keyless set returns nil)
- [x] run `swift test` — must pass before next task

**Deviation (arrow defaults).** `parseKeybind` accepts only single-char keys or `tab`/`space`/`return`/
`delete` — arrows (↑/↓/←/→) are NOT expressible as a parsed `Chord`. So the four arrow-bound actions
(`focus_left_pane` ⌘⌥←, `focus_right_pane` ⌘⌥→, `previous_session` ⌥⌘↑, `next_session` ⌥⌘↓) return
`defaultChord == nil` (alongside the eight genuinely keyless actions). The menu keeps its hardcoded
arrow `.keyboardShortcut` as the fallback whenever `equivalent(for:)` is nil; see the Task 9 note.

### Task 4: Keymap model + equivalent(for:)

**Files:**
- Create: `agtermCore/Sources/agtermCore/Keymap.swift`
- Create: `agtermCore/Tests/agtermCoreTests/KeymapTests.swift`

- [x] add `Keymap { builtinOverrides: [BuiltinAction: Chord], commands: [CustomCommand] }` (Equatable, Sendable) with an `init`
- [x] add `equivalent(for:) -> Chord?` returning the override if present, else `action.defaultChord`
- [x] write tests: override wins; absent override falls back to default; a keyless action with an override now returns the override; a keyless action with no override returns nil
- [x] run `swift test` — must pass before next task

### Task 5: parseKeymap two-verb parser + diagnostics

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Keymap.swift` (add `parseKeymap` + `KeymapDiagnostic`)
- Modify: `agtermCore/Tests/agtermCoreTests/KeymapTests.swift`

- [x] add `KeymapDiagnostic { line: Int, message: String }`
- [x] add `parseKeymap(_:) -> (keymap: Keymap, diagnostics: [KeymapDiagnostic])` — never throws; skip blanks/comments; dispatch on the `map`/`command` verb
- [x] implement `map` parsing: `parseKeybind` the chord, reject leaders for built-ins, resolve the action name, detect duplicate built-in chords → diagnostics for each failure
- [x] implement `command` parsing: required quoted name (spaces allowed), optional-chord rule (chord iff `parseKeybind` accepts the post-name token, else palette-only), remainder is the shell line with `{AGT_X}` preserved
- [x] write tests: both verbs happy-path; quoted name with spaces; chord-vs-palette-only disambiguation; `{AGT_X}` preserved; comments/blank lines ignored; unknown verb / unknown action / leader-on-builtin / malformed line each yield a diagnostic with the right line number while valid lines still parse
- [x] run `swift test` — must pass before next task

### Task 6: Cross-section validation in parseKeymap

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Keymap.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/KeymapTests.swift`

- [x] run validation as a SINGLE final pass AFTER every `map`/`command` line is parsed (assert in code/comment it is not incremental), so customs are checked against the fully-resolved built-in set
- [x] compute active built-in chords (overrides applied) and drop any custom keybind whose FIRST chord collides (clear its `shortcut` to "", keep the palette entry) + emit a diagnostic
- [x] apply existing `keybindConflicts` to the custom set; drop both conflicting keybinds + diagnostic
- [x] write tests: custom chord == a built-in default → keybind dropped, command still present; custom chord == an *overridden* built-in chord; the freed old default is usable by a custom command once the built-in moves; custom leader whose first chord == a built-in chord → dropped; custom-vs-custom duplicate/prefix → both dropped
- [x] run `swift test` — must pass before next task

### Task 7: AppSettings.configDirectory + ConfigPaths resolver

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppSettings.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppSettingsTests.swift`
- Create: `agtermCore/Sources/agtermCore/ConfigPaths.swift`
- Create: `agtermCore/Tests/agtermCoreTests/ConfigPathsTests.swift`

- [x] add `AppSettings.configDirectory: String?` (optional; update the memberwise `init` keeping argument order stable for existing callers — append the new param at the end with a default so existing call sites still compile)
- [x] add the resolver in its OWN host-free file `ConfigPaths.swift` (NOT `ControlResolve.swift`, which is control-channel-only): `configDirectory(setting:stateDir:home:) -> URL` with precedence explicit setting → `<stateDir>/config` (test isolation, when `AGTERM_STATE_DIR` is set) → `<home>/.config/agterm`; and `keymapPath(configDirectory:) -> URL` (`<dir>/keymap.conf`). 3 params, no option struct needed
- [x] write tests: `configDirectory` round-trips and decodes nil when absent (extend `AppSettingsTests`)
- [x] write tests (`ConfigPathsTests`): explicit setting wins; `stateDir` used when set and no setting; `~/.config/agterm` default when neither; keymap path is `<dir>/keymap.conf`
- [x] run `swift test` — must pass before next task

### Task 8: SettingsModel keymap load/parse/reload + starter file

**Files:**
- Modify: `agterm/SettingsModel.swift`
- Modify: `agterm/Ghostty/GhosttyApp.swift` (co-locate `.agtermKeymapChanged` in the existing `extension Notification.Name` block, next to `.agtermAppearanceChanged`)

- [x] add `@Observable` `keymap: Keymap` and `keymapDiagnostics: [KeymapDiagnostic]` to `SettingsModel`; load + `parseKeymap` at init using `ConfigPaths.configDirectory(setting:stateDir:home:)` — pass `setting = settings.configDirectory`, `stateDir = AGTERM_STATE_DIR` (so UI tests under a temp state dir read `<stateDir>/config/keymap.conf`, matching the Testing Strategy), `home = FileManager.default.homeDirectoryForCurrentUser`
- [x] add `setConfigDirectory(_:)` (persist + reload) and `reloadKeymap()` (re-read + re-parse + post `.agtermKeymapChanged`)
- [x] add `ensureStarterKeymap()` — on first launch, if the keymap file is absent, create the dir and write a commented starter `keymap.conf` documenting every `BuiltinAction` name + default, the `command` syntax, and the `{AGT_X}` tokens
- [x] define the `.agtermKeymapChanged` `Notification.Name` (replacing the branch's `.agtCustomCommandsChanged`) — co-located in `GhosttyApp.swift`'s `extension Notification.Name` block where `.agtermAppearanceChanged` lives
- [x] manual check: launch once, confirm `~/.config/agterm/keymap.conf` (or the test dir) is created with the documented content; confirm a malformed line surfaces in `keymapDiagnostics` (verified via build; launched the fresh Debug build with an isolated `AGTERM_STATE_DIR` and confirmed `<stateDir>/config/keymap.conf` was created with all 24 action names + their defaults and all 9 `{AGT_X}` tokens; diagnostics surfacing rides the same `parseKeymap` path the 512 agtermCore tests cover and is observably checked by the Task 14 UITests)
- [x] (no agtermCore tests here — app-side; covered by the UITests in Task 14)

### Task 9: Data-driven menu shortcuts in agtermApp .commands

**Files:**
- Modify: `agterm/agtermApp.swift`

- [x] thread `settingsModel` into the `.commands` builder (it already constructs `settingsModel` as `@State`)
- [x] replace each built-in `Button`'s hardcoded `.keyboardShortcut(...)` with a helper that maps `settingsModel.keymap.equivalent(for: .action)` → a SwiftUI `KeyboardShortcut?` (Chord → `KeyEquivalent` + `EventModifiers`); apply `.keyboardShortcut(shortcut)` only when non-nil so keyless actions stay keyless until mapped (SwiftUI's `.keyboardShortcut(_:KeyboardShortcut?)` accepts nil and removes the shortcut)
- [x] add the app-side `Chord` → `KeyboardShortcut` mapping (mirror of the runner's `NSEvent`→`Chord`); cover letters, digits, `+`/`-`/`0`/backtick, and the named keys (`tab`/`space`/`return`/`delete`) — arrows are NOT in the parseable-chord set (see below)
- [x] **Arrow-bound actions keep their hardcoded arrow `.keyboardShortcut` as a FALLBACK** (per the Task 3 deviation): `focus_left_pane` ⌘⌥←, `focus_right_pane` ⌘⌥→, `previous_session` ⌥⌘↑, `next_session` ⌥⌘↓ have `defaultChord == nil` (arrows can't round-trip through `parseKeybind`). For these four: `equivalent(for:)` returns nil unless the user `map`s an override → when nil, apply the literal arrow `.keyboardShortcut(.leftArrow, …)` etc. (today's hardcoded value); when non-nil, the user override wins. So these four are NOT pure-`defaultChord`-driven, by design — the "SINGLE source of truth" claim below holds for the other 20
- [x] confirm NO hardcoded `.keyboardShortcut` literal remains for any of the 24 `BuiltinAction`s EXCEPT the four arrow fallbacks above — every other one reads `equivalent(for:)`, so `BuiltinAction.defaultChord` is the SINGLE source of truth for those 20 once this task lands (closes the defaultChord↔menu drift risk); the four arrow actions read `equivalent(for:)` first and fall back to the hardcoded arrow literal only when it is nil
- [x] manual check: build + run; default shortcuts still work; add a `map cmd+shift+d toggle_split` to the keymap, Reload, confirm the menu now shows ⌘⇧D and ⌘D no longer toggles (verified via build; behavior in Task 14)
- [x] (behavior verified by the UITest in Task 14)

### Task 10: Port CustomCommandRunner + wire into the scene

**Files:**
- Create: `agterm/Commands/CustomCommandRunner.swift`
- Modify: `agterm/Notifications/NotificationManager.swift` (port `notifyCommandFailure`)
- Modify: `agterm/agtermApp.swift` (own the runner as `@State`, start in scene `.task`, stop on terminate)

- [x] port `CustomCommandRunner` (NSEvent local monitor → `KeybindMatcher` → detached `/bin/sh -c` with focused-pane `CommandContext`; leader timeout, key-repeat ignore, focus-gating); rebuild from `settingsModel.keymap.commands` on `.agtermKeymapChanged`
- [x] resolve the owning session APP-SIDE (NOT via an AppKit method on host-free `agtermCore.WindowLibrary`): read the focused `GhosttySurfaceView.session`, then use master's existing host-free `library.store(forSession:)` / `windowID(forSession:)` for ids; do NOT port the branch's `windowSession(forSurface:)` into core
- [x] port the selection read + `notifyCommandFailure`; adapt to master's `WindowLibrary`/`AppActions`/`NotificationManager` API where the branch differs
- [x] expose a PUBLIC palette-run entry point on the runner (e.g. `run(_ command: CustomCommand)` resolving context from the active session) so Task 11's palette items can invoke it
- [x] construct the runner in `agtermApp.init`, `start()` it in the scene `.task` (alongside `sessionSwitcher.start()`/`paneShortcuts.start()`), `stop()` from `AppDelegate.applicationWillTerminate`
- [x] manual check: a keyed custom command fires from a focused terminal; a leader (`ctrl+a>g`) fires; a failing command shows the failure banner; verify the matcher only consumes registered chords (an unregistered chord passes through to the terminal), which together with the Task 6 validation is what keeps the menu and monitor from contending — independent of AppKit dispatch order (verified via build; behavior in Task 14)
- [x] (behavior verified by the UITest in Task 14)

### Task 11: Palette "custom" badge + custom commands in paletteActions

**Files:**
- Modify: `agterm/Views/Palette.swift`
- Modify: `agterm/AppActions.swift`
- Modify: `agterm/agtermApp.swift` (wire the settable references in the scene `.task`)
- Create: `agtermUITests/KeymapUITests.swift` (shared with Task 14; this task adds the palette case)

- [x] add an optional `badge: String?` to `PaletteItem` (default nil) and render it as a small trailing capsule in `CommandPalette.row` (next to the existing shortcut glyph)
- [x] thread `settingsModel` + the runner into `AppActions`: because both are constructed AFTER `actions` in `agtermApp.init`, add them as settable properties (`var settingsModel: SettingsModel?` / `var customCommandRunner: CustomCommandRunner?`) assigned in the scene `.task`, mirroring how `NotificationManager.shared.actions`/`library` are wired — do NOT change the `AppActions(library:)` init (avoids the init-order break)
- [x] in `paletteActions()`, append each `settingsModel?.keymap.commands` entry as a `PaletteItem(badge: "custom", ...)` whose `run` calls `customCommandRunner?.run(command)` (the Task 10 public entry point); show its chord (if any) in the shortcut column
- [x] write a UITest in `KeymapUITests.swift`: seed a keymap with a palette-only `command "Touch File" touch <tempfile>`, open the action palette, assert an item with the `custom` badge exists (accessibility) and running it creates the file
- [x] run the focused `KeymapUITests` class — must pass before next task

### Task 12: Key Mapping Settings tab + Reload action

**Files:**
- Modify: `agterm/Views/SettingsView.swift`
- Modify: `agterm/AppActions.swift` (add `reloadKeymap()`)
- Modify: `agterm/agtermApp.swift` (add the "Reload Keymap" menu item + palette entry)

- [x] replace the "Key Mapping" `PlaceholderSettings` with a `KeyMappingSettingsView`: a directory field + "Choose…" button (`NSOpenPanel` `canChooseDirectories`), a read-only diagnostics list (line + message), and a "Reload" button
- [x] wire the directory field to `settingsModel.setConfigDirectory(_:)` and Reload to `settingsModel.reloadKeymap()`; show `keymapDiagnostics`
- [x] add `AppActions.reloadKeymap()` and a "Reload Keymap" item in the View `.commands` group + an entry in `paletteActions()`
- [x] manual check: change the dir in Settings reloads; the diagnostics list shows a deliberately broken line; the menu/palette "Reload Keymap" works (verified via build; reload behavior in Task 14; native panel verified manually per convention)
- [x] (reload behavior verified by the UITest in Task 14)

### Task 13: keymap.reload control API

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agterm/Control/ControlServer.swift`
- Modify: `agterm/agtermApp.swift` (give `ControlServer` access to `settingsModel`)
- Modify: `agtermCore/Sources/agtermctlKit/Commands.swift`
- Modify: `agtermCore/Sources/agtermctlKit/SocketClient.swift` (only if a new helper is needed)
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`
- Modify: `agtermUITests/ControlAPIUITests.swift`

- [x] add `case keymapReload = "keymap.reload"` to the `Command` enum
- [x] give `ControlServer` access to `settingsModel`: it is built as `ControlServer(library:actions:)` BEFORE `settingsModel` in `agtermApp.init` — REORDER `agtermApp.init` to build `settingsModel` right after `actions` (it depends only on `library`), then add `settingsModel` to the `ControlServer` init signature and pass it. Verify the reorder doesn't break `sessionSwitcher`/`paneShortcuts`/`controlServer` construction
- [x] add the `ControlServer` dispatch arm: call `settingsModel.reloadKeymap()` (hop to `@MainActor`), return the diagnostic count in `result` (added `ControlResult.count: Int?`; the arm returns `ControlResult(count: settingsModel.keymapDiagnostics.count)`)
- [x] add the `agtermctl keymap reload` subcommand in `agtermctlKit` (mirror an existing simple command; human output prints `ok` / the count, `--json` returns the structured result)
- [x] confirm the four-point keep-in-sync audit for `keymap.reload`: (1) `Command` case, (2) `ControlServer` arm, (3) `agtermctl` subcommand, (4) round-trip + e2e tests — note the GUI half (Reload Keymap menu/palette from Task 12) and `keymap.reload` are the SAME `reloadKeymap()` path
- [x] write a `ControlProtocolTests` round-trip for the new command/response
- [x] add an e2e in `ControlAPIUITests` that drives the socket `keymap.reload` and asserts an ok response (and the diagnostic count for a seeded broken file)
- [x] run `swift test` + the focused control e2e — must pass before next task

### Task 14: Keymap UITests (built-in override, custom chord/leader, reload)

**Files:**
- Modify: `agtermUITests/KeymapUITests.swift` (created in Task 11; add the key-firing + reload cases here)

- [x] built-in override: seed `map cmd+shift+y new_session`, `launchForUITest()`, press ⌘⇧Y, assert a new `session-row` appears (count 1→2); assert the old default ⌘N no longer creates a session (count stays 2). **Deviation from the plan's `toggle_split` wording:** used `new_session` because new sessions are countable `session-row` accessibility elements — a far more robust observable than "is split", and the prompt explicitly recommended it. Built-ins fire via the menu key-equivalent, so no terminal focus is needed.
- [x] custom single chord: seed `command "Touch A" cmd+shift+e touch <tempfileA>`, focus the terminal (the runner only fires when a `GhosttySurfaceView` holds first responder), press ⌘⇧E, poll that `<tempfileA>` appears (observable-side-effect pattern)
- [x] custom leader: seed `command "Touch B" ctrl+a>g touch <tempfileB>`, focus the terminal, press ctrl+a then g (two `typeKey` calls), poll that `<tempfileB>` appears
- [x] reload: launch with ⌘⇧J bound to touch `<tempfileC1>`, rewrite `<stateDir>/config/keymap.conf` so ⌘⇧J touches `<tempfileC2>`, invoke "Reload Keymap" (View menu), press ⌘⇧J, assert `<tempfileC2>` appears (proves the reload re-reads the file)
- [x] run the focused `KeymapUITests` class — must pass before next task (all 5 pass: the Task 11 palette test + the 4 new cases)

### Task N-1: Verify acceptance criteria

- [x] verify all Overview requirements: directory setting (default `~/.config/agterm`); `map` rebinds + adds built-in keys; `command` defines custom commands (chord/leader/palette-only); palette shows `custom`; Reload works; `keymap.reload` over the socket — all confirmed by reading the code: `ConfigPaths.configDirectory` + `AppSettings.configDirectory` + `SettingsModel.keymapURL()`; `parseMapLine` + data-driven `agtermApp.shortcut(for:)` (all 24 BuiltinActions read `equivalent(for:)`, the 4 arrow ones fall back to hardcoded arrow literals); `parseCommandLine` + `CustomCommandRunner` (single chord, leader, palette-only); `Palette.swift` `badge: "custom"` (a11y id `palette-badge`) + `AppActions.paletteActions()`; `SettingsModel.reloadKeymap()` driven by the View menu/palette item AND the `keymap.reload` ControlServer arm (one shared path); the four-point control audit is complete (`Command.keymapReload`, `ControlServer.reloadKeymap`, `agtermctl keymap reload`, round-trip + e2e tests)
- [x] verify edge cases: malformed lines → diagnostics, file still partly applies; cross-section conflict drops only the custom keybind; missing file → starter created; the Ctrl-Tab/Ctrl-1/2 scope cut still works unchanged — `parseKeymap` never throws and skips bad lines (unit test `parseDiagnosticLineNumbersWhileGoodLinesParse`); `validateCommands` clears only the custom command's `shortcut` and keeps the palette entry (`customChordEqualsBuiltinDefaultIsDropped` et al.); `SettingsModel.ensureStarterKeymap()` writes the commented starter when the file is absent; `SessionSwitcher.swift`/`PaneShortcuts.swift` are NOT in the branch's changed-files (Ctrl-Tab / Ctrl-1/2 untouched), and `CustomCommandRunner.handleKeyDown` passes unregistered chords through (`.unmatched`), so those monitors keep their keys
- [x] run `cd agtermCore && swift test` (517 tests, 26 suites — all passed); `xcodegen generate` + `xcodebuild` Debug (BUILD SUCCEEDED); UI-test scope per the prompt's explicit instruction — Task 9 rewired every menu key-equivalent, so a regression-meaningful set was run, NOT just keymap tests: `KeymapUITests`, `ControlAPIUITests`, `SplitUITests`, `SidebarUITests`, and `MenuUITests` (MenuUITests added because it directly exercises menu key-equivalents, the surface Task 9 changed) — one `xcodebuild test` invocation with 5 `-only-testing` flags: 77 tests, 0 failures, TEST SUCCEEDED. `~/.claude/format.sh` does NOT apply (it is Go-only `gofmt`/`goimports` and errors on a Swift project; no Swift formatter is configured) — new code matches surrounding agterm style

### Task N: Documentation

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`

- [x] README: document the keymap file (location, the `map`/`command` syntax, the action-name list, `{AGT_X}` tokens, Reload, the v1 scope cut)
- [x] CLAUDE.md: add a "Keymap" section (the two-section format, menu-driven built-in override vs monitor-driven custom, the cross-section validation rule + the ownership-by-disjoint-registration reasoning); record the new keep-in-sync surface (`BuiltinAction` ↔ the menu items, now collapsed to `defaultChord` as the single source after Task 9) and `keymap.reload` in the Control API catalog (now 34 commands) WITH its four-point audit, matching the `workspace.move` precedent
- [x] move this plan to `docs/plans/completed/` (moved by exec finalize step)

### ➕ Task A1: Keymap diagnostics warning banner on load/reload

Added per user request after review phase 1: keymap conflicts / parse errors are only visible in Settings ▸ Key Mapping; surface them proactively. Discard-on-conflict is already implemented (per-binding skip + diagnostic); this adds the proactive signal.

**Files:**
- Modify: `agterm/Notifications/NotificationManager.swift`
- Modify: `agterm/SettingsModel.swift`
- Modify: `agterm/agtermApp.swift`

- [x] add a session-less app banner method to `NotificationManager` (mirror `notifyCommandFailure`): e.g. `notifyKeymapDiagnostics(count:)` posting title "Keymap" / body "N issue(s) — see Settings ▸ Key Mapping". No focus-suppression; no session attribution.
- [x] fire it from `SettingsModel.reloadKeymap()` whenever `keymapDiagnostics` is non-empty (runtime reload path — banner is safe here).
- [x] fire the STARTUP case from the scene `.task` AFTER `NotificationManager.shared.start()` (auth/registration is requested there, and `SettingsModel` loads the keymap at init before that) — if `settingsModel.keymapDiagnostics` is non-empty, post the banner once. Do NOT post from `SettingsModel.init` (too early, before notification registration). Gated on `!library.hasReopened` so only the launch window's `.task` posts (the latch is still false there before `reopenWindows()` flips it; subsequent windows see it true and skip), avoiding a duplicate banner per window.
- [x] fires for ANY diagnostic (parse errors AND conflicts), not just double-binds — both ride the same `keymapDiagnostics` array.
- [x] validate: `xcodegen generate` + `xcodebuild` Debug BUILD SUCCEEDED; `cd agtermCore && swift test` green (522 tests). Banner is system UI (verified via build; banner is system UI, manually verified per convention); no XCUITest banner assertion.

## Post-Completion
*Items requiring manual intervention or external systems — no checkboxes, informational only*

**Manual verification:**
- Smoke a real built-in rebind (e.g. `map cmd+shift+d toggle_split`) and a real custom command
  (`command "Open in Zed" cmd+shift+e open -a Zed {AGT_SESSION_PWD}`) against a deployed build.
- Confirm `make deploy` + re-install the CLI picks up `agtermctl keymap reload` (the deployed copy in
  `~/Applications` shadows the dev build for the PATH CLI).

**Future work (out of scope this round):**
- Rebinding the Ctrl-Tab MRU switcher and Ctrl-1/Ctrl-2 pane-focus monitor interactions.
- An optional `:` separator to disambiguate palette-only commands whose shell starts with a chord-like token.
- A file watcher for live reload (kitty's optional auto-reload) instead of the manual Reload action.

Smells pre-check: skipped — non-Go project.
