# Session Attention List & Titlebar Indicator

## Overview

When the sidebar is hidden you can still navigate (palettes, ⌃Tab, session-nav), but you lose all per-session status visibility — the agent-status glyphs live only on the sidebar rows. This adds:

1. A **titlebar bell icon** (opt-in, off by default) that reflects window-wide attention state at a glance: dimmed/disabled when nothing is non-idle, plain when something is non-idle, and a filled bell in the blocked color when any session is blocked.
2. An **attention list** — a new `.attention` command-palette mode listing only the window's non-idle sessions (blocked/active/completed), each row carrying the same status glyph the sidebar shows, sorted blocked→active→completed with newest status-change first. Reachable by clicking the icon, a hotkey (⌃⇧I), a Navigate menu item, and a ⌃⇧P launcher entry.
3. **Control-read coverage**: `tree` now reports each session's status (you could already *set* `session.status` but never *read* it back).

Problem solved: recover the "what needs me right now" signal without the sidebar, and jump straight to the session that needs it.

## Context (from discovery)

- **Status model** (`agtermCore/Sources/agtermCore/AgentStatus.swift`): `AgentStatus` enum (idle/active/completed/blocked) + `AgentIndicator{status,blink,autoReset}`. Ephemeral, control-driven only, never persisted. `needsAttention` = blocked||completed (drives the existing ⌃⌥↑/↓ attention-nav). The NEW list is broader — ALL non-idle.
- **Sidebar glyph mapping** (`agterm/Views/WorkspaceSidebar.swift:162-164`, a private `StatusIconView: NSImageView`): active=`ellipsis.circle.fill`, blocked=`exclamationmark.circle.fill`, completed=`checkmark.circle.fill`, tinted with `GhosttyApp.shared.{active,blocked,completed}StatusColor` (defaults: muted lavender-grey / `.systemOrange` / `.systemGreen`).
- **Palettes** (`agterm/Views/Palette.swift`): `PaletteMode`(.actions/.sessions/.themes/.customCommands) + `PaletteController` (toggle/open/close) + `CommandPalette` (fuzzy search, ↑/↓, Enter, Esc). `PaletteItem` has id/title/subtitle/shortcut/badge/onSelect/run — no status glyph today. `AppActions.paletteSessions()` (`agterm/AppActions.swift:555`) builds session rows (title=`displayName`, subtitle="`workspace` · `subtitleDetail`") from `store.navigableSessions`.
- **Titlebar** (`agterm/ContentView.swift:629` `customTitlebar`): HStack — sidebarToggle, `titleLabel`, then a trailing cluster (scratch/split/divider/quick-terminal) tinted via `chromeText`. The titlebar is the only persistent chrome when the sidebar is hidden (the "bottomBar" is the sidebar's footer via `.safeAreaInset`, so it vanishes with the sidebar).
- **Per-window**: each window has its own `AppStore` (`WindowLibrary.activeStore`); the icon + list only ever see that window's sessions.
- **Control** (`agterm/Control/ControlServer.swift:1049` `buildTree`): `ControlSessionNode` carries name/cwd/title/active/split/overlay/scratch/flagged/foreground — no status.
- **Settings toggle pattern** (`agterm/Views/SettingsView.swift:58` + binding at `:122`): `Toggle("…", isOn: <Binding>)` over a `model.settings.<flag> ?? <default>` get/set; field declared in `AppSettings` (`agtermCore`).
- **BuiltinAction** (`agtermCore/Sources/agtermCore/BuiltinAction.swift`): raw-name enum + `defaultChord: Chord?` switch; names mirror the menu items in `agtermApp`'s `.commands`.

## Development Approach

- **Testing approach**: **TDD (tests first)** for the host-free `agtermCore` pieces (statusChangedAt stamping, `attentionSessions` ordering, `ControlSessionNode.status` round-trip, `AppSettings` field) — write the failing test, then the code. App-target SwiftUI/AppKit + XCUITest pieces (titlebar icon, palette glyph rendering, e2e) are code-then-test (host-driven).
- Complete each task fully before the next; small focused changes.
- **CRITICAL: every task includes new/updated tests** — listed as separate checklist items, both success and error/edge cases.
- **CRITICAL: all tests pass before starting the next task** — `cd agtermCore && swift test` for core, the app must build (`make build`), XCUITests where noted.
- Keep `agtermCore` host-free (no AppKit/GhosttyKit/Metal, no CoreGraphics geometry types).
- Honor the keep-in-sync conventions: the control surface (protocol/server/CLI/tests) AND the bundled agent-skill are first-class; update them in the same task that changes behavior.

## Testing Strategy

- **Unit tests** (`agtermCore/Tests/agtermCoreTests/`, Swift Testing / XCTest as the file already uses): required every task for core logic — one test file per source file (e.g. `SessionTests.swift`, `AppStoreTests.swift`, `ControlProtocolTests.swift`, `AppSettingsTests.swift`, `AgentStatusTests.swift`).
- **e2e / XCUITest** (`agtermUITests/`): the titlebar icon states, opening the palette (icon click + ⌃⇧I), row-select navigation, and the `tree`-reports-status e2e in `ControlAPIUITests`. Driven via `agtermctl session status` against an isolated `AGTERM_STATE_DIR`/socket instance. Treated with the same rigor as unit tests.

## Progress Tracking

- mark completed items `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document blockers with ⚠️ prefix
- keep this plan in sync with actual work

## Solution Overview

A single source of truth — `AppStore.attentionSessions` (host-free, per-window) — backs both the titlebar icon and the palette rows, so they can never disagree. The icon derives its three states from that set (empty→disabled, non-empty→enabled, contains-blocked→highlighted). The list is a thin new palette mode that reuses the existing `CommandPalette` view; the only view-layer addition is an optional status glyph on `PaletteItem`. Status sort order (blocked→active→completed) and the newest-first tie-break live in `agtermCore` as pure, tested logic. The status→symbol+color mapping is extracted into one shared helper so the new SwiftUI glyph and the existing AppKit `StatusIconView` stop duplicating it. Control gains a read path (`tree` reports status); opening the palette stays interactive-only (keep-in-sync exempt, like every other palette open).

## Technical Details

- `Session.statusChangedAt: Date?` — `@ObservationIgnored`, ephemeral, set in `AppStore.setAgentIndicator` (Date() when new status non-idle, nil on idle). Sort key only; absent from `SessionSnapshot`.
- `AppStore.attentionSessions: [Session]` — `workspaces.flatMap(\.sessions)`, keep non-idle, sort by status rank (blocked=0, active=1, completed=2) then `statusChangedAt` descending (newest first; nil last). Drives both surfaces.
- `AgentStatus` gains pure presentation helpers needed by the shared mapping: `symbolName: String` (SF Symbol per non-idle state) and `attentionRank: Int`. Idle returns a benign default for `symbolName` (unused — idle never renders/lists).
- App-side `GhosttyApp.statusColor(for: AgentStatus) -> NSColor` returns the configured tint; `StatusIconView` and the new `StatusGlyph` both use `AgentStatus.symbolName` + this color lookup.
- `PaletteItem.status: AgentStatus?` (default nil); `CommandPalette.row` renders a leading `StatusGlyph` when set.
- `PaletteMode.attention`; `CommandPalette.allItems`/`placeholder` arms; `AppActions.paletteAttention()`.
- `BuiltinAction.showAttention` (rawValue `show_attention`), `defaultChord` = ⌃⇧I (⌃I alone is Tab, but ⌃⇧I is a distinct chord swallowed by app/menu dispatch like ⌃⇧P). `AppActions.toggleAttentionPalette()` → `palette.toggle(.attention)`. Navigate menu item + ⌃⇧P launcher entry.
- `AppSettings.attentionButtonEnabled: Bool?` (default false). General-tab toggle. Gates only the icon.
- `ControlSessionNode.status: String?` (nil/omit for idle); populated in `buildTree`.

## What Goes Where

- **Implementation Steps** (`[ ]`): all code, tests, control plumbing, agent-skill + doc updates — achievable in this repo.
- **Post-Completion** (no checkboxes): manual dev-instance acceptance pass the maintainer drives.

## Implementation Steps

### Task 1: Session status-change timestamp

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Session.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreTests.swift`

- [x] write failing tests: `setAgentIndicator` to a non-idle status sets `statusChangedAt` (non-nil); to `.idle` clears it to nil; re-asserting a non-idle status updates it
- [x] add `@ObservationIgnored var statusChangedAt: Date?` to `Session` (ephemeral; confirm `SessionSnapshot` does NOT capture it)
- [x] in `AppStore.setAgentIndicator(_:forSession:)` stamp `Date()` when `indicator.status != .idle`, else nil
- [x] run `cd agtermCore && swift test` — must pass before next task

### Task 2: AgentStatus presentation + rank helpers

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AgentStatus.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AgentStatusTests.swift`

- [x] write failing tests for `attentionRank` (blocked < active < completed) and `symbolName` (the three non-idle SF Symbol names; idle returns the empty string `""` — never rendered, idle is filtered before any glyph is built)
- [x] add `var attentionRank: Int` and `var symbolName: String` to `AgentStatus` (pure, no AppKit — symbol names are plain strings); idle's `symbolName` returns `""`
- [x] run `cd agtermCore && swift test` — must pass before next task

### Task 3: AppStore.attentionSessions ordering

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreTests.swift`

- [x] write failing tests: filters out idle; orders blocked→active→completed; within a status group orders by `statusChangedAt` newest-first (nil last); spans all workspaces ignoring focus/flagged filter; empty when all idle
- [x] add `var attentionSessions: [Session]` to `AppStore` — `workspaces.flatMap(\.sessions)`, drop idle, sort by `(attentionRank, statusChangedAt desc)`
- [x] run `cd agtermCore && swift test` — must pass before next task

### Task 4: ControlSessionNode.status protocol field

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`

- [x] write failing round-trip tests: `ControlSessionNode` with a `status` encodes/decodes; nil `status` is omitted from JSON (matches the existing optional-field convention, e.g. `foreground`)
- [x] add `status: String?` to `ControlSessionNode` (optional, omit-when-nil) and thread it through the initializer
- [x] run `cd agtermCore && swift test` — must pass before next task

### Task 5: Populate status in the tree builder

**Files:**
- Modify: `agterm/Control/ControlServer.swift`
- Modify: `agtermUITests/ControlAPIUITests.swift`

- [ ] in `buildTree`, set `status` from `session.agentIndicator.status` — nil when `.idle`, else `rawValue` (so idle sessions omit the field)
- [ ] add an e2e: set a session's status via `agtermctl session status blocked`, read `tree --json`, assert that session's node reports `status: "blocked"`; assert an idle session omits it
- [ ] build (`make build`) and run the new XCUITest — must pass before next task

### Task 6: Shared status→glyph mapping + SwiftUI StatusGlyph

**Files:**
- Modify: `agterm/Ghostty/GhosttyApp.swift`
- Modify: `agterm/Views/WorkspaceSidebar.swift`
- Create: `agterm/Views/StatusGlyph.swift`

- [ ] add `func statusColor(for: AgentStatus) -> NSColor` to `GhosttyApp` (returns the configured active/blocked/completed tint)
- [ ] refactor `StatusIconView.apply` (`WorkspaceSidebar.swift:162-164`) to use `AgentStatus.symbolName` + `GhosttyApp.shared.statusColor(for:)` instead of the inline switch (no behavior change — same symbols/colors)
- [ ] create `StatusGlyph: View` (SwiftUI) rendering `Image(systemName: status.symbolName).foregroundStyle(Color(nsColor: GhosttyApp.shared.statusColor(for: status)))`
- [ ] verify the sidebar still renders identical glyphs (build + visual check noted in Post-Completion); no unit test for AppKit rendering
- [ ] build (`make build`) — must succeed before next task

### Task 7: PaletteItem status glyph capability

**Files:**
- Modify: `agterm/Views/Palette.swift`

- [ ] add `status: AgentStatus?` (default nil) to `PaletteItem` and its initializer (existing call sites keep nil — no behavior change yet)
- [ ] in `CommandPalette.row`, render a leading `StatusGlyph(status:)` when `item.status != nil` (left of the title VStack)
- [ ] build (`make build`) — must succeed before next task

**Note:** no `.attention` mode and no `paletteAttention()` here — added together in Task 8 — so this task introduces no forward reference (`PaletteMode.allItems` is an exhaustive switch with no default, so a `.attention` case without its provider would not compile).

### Task 8: paletteAttention rows + .attention palette mode

**Files:**
- Modify: `agterm/AppActions.swift`
- Modify: `agterm/Views/Palette.swift`

- [ ] add `func paletteAttention() -> [PaletteItem]` to `AppActions` — map `store.attentionSessions` to items (id=`uuidString`, title=`displayName`, subtitle="`workspace` · `subtitleDetail`", `status:` set from Task 7's field), `run` = `store.selectSession(id)` — mirroring `paletteSessions()`
- [ ] add `case attention` to `PaletteMode` with its `allItems` arm (`actions.paletteAttention()`) and `placeholder` ("Go to a session that needs attention…") in the SAME task, so the exhaustive switch and its provider land together
- [ ] confirm `.attention` needs no theme-preview wiring (`syncThemeSession` already guards on `.themes`); verify the empty-query order is the `attentionSessions` order (the palette re-sorts by fuzzy score only once the user types)
- [ ] build (`make build`) — must succeed before next task

### Task 9: Hotkey, menu, and launcher entry points

**Files:**
- Modify: `agtermCore/Sources/agtermCore/BuiltinAction.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/BuiltinActionTests.swift`
- Modify: `agterm/AppActions.swift`
- Modify: `agterm/agtermApp.swift`

- [ ] write failing test: `BuiltinAction.showAttention` exists with rawValue `show_attention` and `defaultChord` = ⌃⇧I (`Chord(mods:[.control,.shift], key:"i")`)
- [ ] update the EXISTING `BuiltinActionTests` assertions broken by the new case: bump `allCases.count == 34` → `35` (line 25) and add `.showAttention: Chord(mods:[.control,.shift], key:"i")` to the exhaustive `expected` map (so `expected.count == allCases.count` at line 72 holds and the per-action chord check passes)
- [ ] add the `showAttention` case + its `defaultChord` arm in `BuiltinAction`
- [ ] add `AppActions.toggleAttentionPalette()` → `palette.toggle(.attention)`; wire `showAttention` to it wherever `BuiltinAction`s dispatch
- [ ] add the Navigate menu item ("Go to Attention…", reading `equivalent(for: .showAttention)`) in `agtermApp`'s Navigate `CommandMenu`, plus a "Show Attention" entry in `AppActions.paletteActions()`
- [ ] run `cd agtermCore && swift test` and build (`make build`) — must pass before next task

**Note:** ⌃I alone is Tab, but ⌃⇧I is a distinct, parseable single-char chord (`key:"i"` + shift) swallowed by menu/keymap dispatch before the terminal, exactly like ⌃⇧P/⌃⇧O. Not a reserved monitor chord, so it passes `parseKeymap` validation.

### Task 10: AppSettings flag + General-tab toggle + GhosttyApp mirror

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppSettings.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppSettingsTests.swift`
- Modify: `agterm/SettingsModel.swift`
- Modify: `agterm/Ghostty/GhosttyApp.swift`
- Modify: `agterm/Views/SettingsView.swift`

- [ ] write failing test: `AppSettings` with `attentionButtonEnabled` set round-trips through encode/decode; absent decodes to nil (treated as false). Mirror the default-OFF precedent (`restoreRunningCommand`/`inheritGlobalGhosttyConfig`), NOT `notificationBadgeEnabled` (default-ON)
- [ ] add `var attentionButtonEnabled: Bool?` to `AppSettings` + its `init` parameter
- [ ] add `private(set) var attentionButtonEnabled: Bool = false` + `func setAttentionButtonEnabled(_:)` to `GhosttyApp` (the non-observable chrome mirror, like `setNotificationBadgeEnabled` at GhosttyApp.swift:141 / `compactToolbar`)
- [ ] add `SettingsModel.setAttentionButtonEnabled(_ value: Bool?)` (`settings.attentionButtonEnabled = value; persistAndApply()`) + an `applyAttentionButtonEnabled()` that pushes `settings.attentionButtonEnabled ?? false` into the `GhosttyApp` mirror, called from `persistAndApply`'s chrome-apply path (alongside `applyCompactToolbar`/`applyNotificationBadgeEnabled`, which posts `.agtermAppearanceChanged`). NOT a ghostty key — no surface reload
- [ ] add a General-tab `Toggle("Show attention button in the title bar", isOn:)` whose `Binding` uses get `model.settings.attentionButtonEnabled ?? false` and set `model.setAttentionButtonEnabled($0 ? true : nil)` — mirror the default-OFF binding at `SettingsView.swift:129-137` (restoreRunningCommand/inheritGlobalGhosttyConfig), NOT the default-ON one at `:122`
- [ ] run `cd agtermCore && swift test` and build — must pass before next task

**Keep-in-sync:** the settings toggle is GUI-only and keep-in-sync EXEMPT — only `theme.set`/`config.reload` touch settings over the control socket (same exemption as `restoreRunningCommand`/`inheritGlobalGhosttyConfig`).

### Task 11: Titlebar bell icon

**Files:**
- Modify: `agterm/ContentView.swift`
- Modify: `agtermUITests/` (new or existing titlebar/control test file)

- [ ] add `@State private var attentionButtonEnabled` to `WindowContentView`, seeded by a `static func resolvedAttentionButtonEnabled() -> Bool` reading the `GhosttyApp.shared.attentionButtonEnabled` mirror (the `compactToolbar`/`resolvedCompactToolbar()` precedent at ContentView.swift:170/572) — do NOT read `model.settings` directly in the titlebar (WindowContentView mirrors chrome flags, not SettingsModel)
- [ ] refresh that `@State` in the existing `.agtermAppearanceChanged` `onReceive` (alongside `compactToolbar`/`terminalColor`), so flipping the Settings toggle re-renders the titlebar live
- [ ] add an `attentionButton` to `customTitlebar`, placed just after `titleLabel`, built only when `attentionButtonEnabled`
- [ ] derive state from `store.attentionSessions`: empty → `bell`, ~0.35 opacity, `.disabled(true)`; non-empty no-blocked → `bell`, `chromeText`, enabled; any `.blocked` → `bell.fill` tinted `Color(nsColor: GhosttyApp.shared.blockedStatusColor)`, enabled. No count, no pulse. Click → `actions.toggleAttentionPalette()`. Reading `attentionSessions` registers the `agentIndicator` observation dependencies, so the icon updates live on status change
- [ ] give it `.accessibilityIdentifier("attention-button")`, a `.help` string, AND an `.accessibilityValue` of `none`|`attention`|`blocked` (empty / non-empty-no-blocked / any-blocked) — mirroring `StatusIconView`'s state-name `accessibilityValue` (WorkspaceSidebar.swift) so XCUITest can read the otherwise-unobservable `bell`↔`bell.fill` highlight
- [ ] add XCUITest: with the toggle on, drive `agtermctl session status` to move a session idle→active→blocked and assert the button's `isEnabled` AND its `accessibilityValue` (`none`→`attention`→`blocked`) transitions; click it opens `command-palette` in attention mode; selecting a row selects the session; with the toggle off the button is absent
- [ ] build + run the XCUITest — must pass before next task

**Keep-in-sync:** the icon is pure visual chrome (it opens the already-controllable attention palette / `session.select`) — keep-in-sync EXEMPT, like the other titlebar buttons and the palette opens.

### Task 12: Keep-in-sync — agent-skill + rules + README/ARCHITECTURE

**Files:**
- Modify: `agterm/Resources/agent-skill/reference.md`
- Modify: `agterm/Resources/agent-skill/SKILL.md` (only if the tree-output section needs it)
- Modify: `.claude/rules/menu-actions.md` (new palette mode + entry points) and/or `.claude/rules/notifications.md` (icon alongside the agent-status glyph)
- Modify: `.claude/rules/keymap.md` (the rebindable-action counts)
- Modify: `.claude/rules/settings.md` (the `attentionButtonEnabled` chrome flag, alongside `notificationBadgeEnabled`/`compactToolbar`)
- Modify: `README.md`, `ARCHITECTURE.md` (if they enumerate palette modes / titlebar chrome / control fields)

- [ ] update the agent-skill `reference.md` so the `tree` command documents the new per-session `status` field (no command-count change — still 46 commands)
- [ ] bump the rebindable-action counts in `.claude/rules/keymap.md`: "the 34 rebindable actions" → 35 and "28 of the 34" → "29 of the 35" (the new `showAttention` is expressible/pure-`defaultChord`-driven, not an arrow exception)
- [ ] document the `.attention` palette mode + ⌃⇧I + the titlebar icon + the `attentionButtonEnabled` setting in the relevant `.claude/rules/*.md`
- [ ] update README/ARCHITECTURE where palette modes, titlebar chrome, or control tree fields are listed
- [ ] no test (docs only) — verify the agent-skill is edited ONLY under `agterm/Resources/agent-skill/` (never the installed copies)

### Task 13: Verify acceptance criteria

- [ ] verify every Overview item is implemented: icon 3 states, opt-in toggle (off by default), list mode with glyphs + sort, ⌃⇧I + menu + launcher, `tree` reports status
- [ ] verify edge cases: all-idle window (icon disabled, list empty, hotkey opens an empty palette gracefully), blocked highlight clears when the session leaves blocked, sort tie-break newest-first, scope spans all workspaces ignoring focus/flagged filter
- [ ] run full core suite: `cd agtermCore && swift test`
- [ ] run the XCUITest suite for the new tests
- [ ] confirm `golangci`-equivalent is N/A (Swift); the app builds clean via `make build`

### Task 14: Update documentation and close out

- [ ] final pass on README.md / CLAUDE.md / `.claude/rules/*.md` for accuracy with what shipped
- [ ] confirm the four keep-in-sync surfaces are consistent (GUI / menu / control-read / agent-skill)
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

*Items requiring manual intervention — no checkboxes, informational only.*

**Manual verification** (maintainer-driven, isolated dev instance — never touch the deployed `~/Applications/agterm.app`):
- Launch an isolated dev instance (`open -n --env AGTERM_STATE_DIR=<tmp> --env AGTERM_CONTROL_SOCKET=<tmp>/agterm.sock build/DerivedData/.../Debug/agterm.app`).
- Turn on the Settings toggle; hide the sidebar; drive a session to `blocked`/`active`/`completed` via `agtermctl session status … --socket <tmp>/agterm.sock` and confirm the bell's dimmed→plain→filled-blocked transitions and that the list opens, shows the glyphs, sorts correctly, and jumps on Enter.
- Confirm the sidebar glyphs are visually unchanged after the Task 6 `StatusIconView` refactor (no symbol/color regression).
- Confirm the toggle defaults off for a fresh `settings.json` and that an existing install is unaffected.

Smells pre-check: skipped — non-Go project
