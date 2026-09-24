# Per-pane session background

## Overview
- `session background image|text|color|clear` gains `--pane left|right|scratch`, so each pane of a split
  session can carry its own tint or watermark (discussion #643). Omitting `--pane` keeps today's behavior.
- Motivating case: two agents in one split (`cookbook/two-agent-chat`, either agent in either pane). The
  inactive-pane wash says which pane has focus, not which agent is which; a per-pane label does.
- Shape follows the #372 decline comment: `--pane` on the existing command, no new command or wire type,
  explicit override with inherit as the default (so #274/#275 scratch inheritance holds), and per-pane
  state migrated in `closePrimaryPane`.

## Context (from discovery)
- Model: `Session.backgroundWatermark` (Session.swift:216), setter `AppStore.setBackgroundWatermark`
  (AppStore+SessionState.swift:57), snapshot `SessionSnapshot.backgroundWatermark` (Snapshot.swift:184,261),
  restore `AppStore+Snapshot.swift:96`.
- Pane lifecycle: `swapPanes` (AppStore+Panes.swift:108), `closeSplit` (:181), `closePrimaryPane` (:237),
  `closeScratch` (:500). Scratch is not persisted; `scratch --command` replacement goes through
  `closeScratch` (ControlServer+SessionActions.swift:346); hide/show keeps the surface.
- Protocol: `ControlRequest.args.pane` already exists; `parsePane` (ControlDispatcher+Panes.swift:21)
  gives left/right/scratch with aliases. Dispatcher `dispatchSessionBackground` (ControlDispatcher.swift:726)
  builds `ControlSessionBackgroundOptions`.
- CLI: `SessionCommands.Background` Image/Text/Color/Clear (SessionCommands.swift:420-520).
- App apply: `ControlServer.setSessionBackground` + `applyWatermark(to:)` (ControlServer+SurfaceIO.swift:204,237).
  Surface reads of the session spec: GhosttySurfaceView+Config.swift:30-31, 58, 71, 135 and
  GhosttySurfaceView.swift:703. A surface knows its pane by `isSplitPane` (right) and `watermarkSession`
  (scratch, sessionless otherwise); left is the remainder.
- Text PNG: `WatermarkStorage.renderedTextURL(sessionID:)` (one file per session), rendered by
  `WatermarkRenderer.materialize`; removed on clear, text-to-other, and session/workspace/window removal.
- Washes: `washColor(for:)` (WindowContentView.swift:478), inactive-pane `paneDim` (WindowContentView+Detail.swift:263,400),
  floating-overlay backdrop wash (Detail:312, one rectangle over the detail frame).
- Read-back: `ControlSessionNode.background` (ControlProjection.swift:257), projected at AppStore.swift:344.
  `ControlProtocolCompatibility.swift` keeps the agterm-linux initializer; new fields get defaults.
- Line budgets: GhosttySurfaceView.swift is at 1000 (the limit, no net lines there), AppStore.swift 987,
  Session.swift 965, SessionCommands.swift 954.

## Development Approach
- **testing approach**: regular, tests written in the same task as the code
- complete each task fully before moving to the next
- every task includes new/updated tests; all tests pass before the next task
- update this plan when scope changes

## Testing Strategy
- host-free: `cd agtermCore && swift test --filter <Suite>` per task
- hosted app tests: `scripts/test-app.sh` forwards no arguments, so scope with the direct call
  `xcodebuild test -project agterm.xcodeproj -scheme agtermTests -destination 'platform=macOS'
  -derivedDataPath build/DerivedData -only-testing:agtermTests/<Class>`
- XCUITest: extend `ControlAPIUITests.testSessionBackgroundSetClearAndValidation` and run only that method
- full gates once at the end: `swift test`, `make test-app`, `make lint`

## Progress Tracking
- mark completed items `[x]` immediately; ➕ for discovered tasks, ⚠️ for blockers

## Solution Overview
- Two layers: the existing session default (`backgroundWatermark`) and per-pane overrides. The effective
  spec for a pane is `override ?? default`.
- Set and clear WITHOUT `--pane` touch only the default; overrides keep winning (symmetric). `--pane X clear`
  drops that override back to inherit; it never forces "no background".
- Overrides follow the terminal, not the position:
  - left/right persist in the snapshot, swap in `swapPanes`, the right one moves to left in
    `closePrimaryPane`, and the right one clears in `closeSplit`;
  - scratch survives hide/show, is dropped inside `closeScratch` on every path (exit, `--command`
    replacement, teardown), and is never persisted.
- Read-back exposes the overrides separately from the default and never the flattened effective value, so
  a caller can tell whether a later default change reaches a pane.
- Rejected: holding the override only on the surface view. It loses the label on relaunch, window close
  and `reattachPane` while Live agents keep running.

## Technical Details
- New host-free value type in agtermCore, `PaneBackgrounds` (`left`, `right`, `scratch`:
  `BackgroundWatermark?`, `Codable`, `Equatable`), stored as `Session.paneBackgrounds` (`@ObservationIgnored`,
  same as `backgroundWatermark`). Accessors take `StatusPane`. `Session.effectiveBackground(for: StatusPane)`
  returns `override ?? backgroundWatermark`.
- `AppStore.setBackgroundWatermark(_:forSession:pane:)` with `pane: StatusPane? = nil`: nil writes the
  default, a pane writes that override. Returns whether it changed (the app-side apply gate stays).
  Setting `.right` without a split, or `.scratch` with no scratch surface, is refused by the app adapter
  (no such pane), matching how `session.text --pane` reports a missing pane.
- Snapshot: `SessionSnapshot.paneBackgrounds` holds left/right only (scratch dropped at capture), decoded
  with `try?` like the neighbours so a bad value becomes nil; right is dropped on restore when the session
  has no split.
- Text PNG names: the default keeps `<sessionID>.png`; an override renders to `<sessionID>-<pane-key>.png`
  where the key is the pane's identity UUID (`paneIdentity` / `splitPaneIdentity`, which follow swap) and
  `scratch` for the scratch. Session removal sweeps the `<sessionID>` prefix; clearing the default keeps
  removing only `<sessionID>.png`; clearing or replacing an override removes that pane's file. Pane
  destruction removes the departing pane's file before its key is lost: `closeSplit` (the split identity),
  `closePrimaryPane` (the exiting primary's identity; the promoted survivor keeps its file), and
  `closeScratch`. `WatermarkRenderer.materialize` takes the resolved URL.
- Surface side: one helper resolves this view's pane (`watermarkSession != nil` and no `session` → scratch,
  `isSplitPane` → right, else left) and every read listed in Context goes through
  `effectiveBackground(for:)`. The GhosttySurfaceView.swift:703 edit replaces the expression in place.
- `applyWatermark(to:)` applies to the targeted surface only when a pane is given. A default change applies
  only to realized surfaces that inherit: re-applying an overridden pane is not harmless, because
  `applyWatermarkFromSession` clears `oscBackgroundColorHex` and replaces the surface config.
- Washes: `paneDim` passes the pane's effective `.color` through its existing `color:` parameter. The
  floating backdrop wash paints ONE non-overlapping wash per visible region, never a pane wash stacked on a
  default wash (stacking dims that pane twice): with the scratch up, the scratch's effective color across
  the frame; otherwise each pane frame gets its own color, a visible pane overlay keeps its existing
  `overlayWashColor`, and the remainder (divider) gets the default. `HudPaneAnchors` carries left/right
  only, which is why the scratch case is decided before pane frames are used. The full-frame click catcher
  stays a separate clear layer. The region choice is a pure function so its composition is unit-tested.
- Read-back: `ControlSessionNode.paneBackgrounds: PaneBackgrounds?`, omitted when every override is nil;
  an absent pane key means inherit. `background` stays the default.
- CLI: `--pane left|right|scratch` on Image/Text/Color/Clear; help text says omitted means the session
  default and a pane clear returns it to inherit.

## What Goes Where
- Implementation Steps: code, tests, docs in this repo.
- Post-Completion: manual Debug-instance check, reply to discussion #643.

## Implementation Steps

### Task 1: Override layer in agtermCore: model, lifecycle, persistence, text files

**Files:**
- Create: `agtermCore/Sources/agtermCore/PaneBackgrounds.swift`
- Modify: `agtermCore/Sources/agtermCore/Session.swift`, `AppStore+SessionState.swift`, `AppStore+Panes.swift`,
  `Snapshot.swift`, `AppStore+Snapshot.swift`, `WatermarkStorage.swift`
- Tests: `PaneBackgroundsTests.swift` (new; also holds the store lifecycle cases, `AppStorePaneTests.swift`
  being at 1980 of 2000 lines), `AppStorePaneSwapTests.swift`, `WatermarkStorageTests.swift`

- [x] `PaneBackgrounds`, `Session.paneBackgrounds`, `Session.effectiveBackground(for:)`, and
  `setBackgroundWatermark(_:forSession:pane:)` with symmetric no-pane set/clear
- [x] lifecycle: swap left/right in `swapPanes`, right→left in `closePrimaryPane`, clear right in `closeSplit`,
  clear scratch in `closeScratch`
- [x] snapshot: capture/restore left/right only, tolerant decode, right dropped without a split
- [x] per-pane text PNG (`<sessionID>-<pane-key>.png`), session-prefix sweep for the permanent-removal
  callers, default clear still removes only `<sessionID>.png`, pane file removed when its override clears
  or leaves `.text`, and the departing pane's file removed in `closeSplit`, `closePrimaryPane` and
  `closeScratch` (the promoted survivor's file kept)
- [x] tests for every rule above: resolution, symmetric default, pane clear to inherit, swap, promotion,
  split close, scratch close, hide/show keeps it, round trip, restore without split, distinct PNG files,
  sweep. The lifecycle file-removal test moved to Task 3: `AppStore` removes files under the default state
  dir, which only the hosted scheme isolates (`AGTERM_STATE_DIR` in project.yml)
- [x] `cd agtermCore && swift test` for the touched suites

### Task 2: Control surface: dispatcher, CLI, read-back

**Files:**
- Modify: `ControlDispatcherOptions.swift`, `ControlDispatcher.swift`, `ControlProtocol.swift` (pane doc),
  `ControlProjection.swift`, `AppStore.swift`, `agtermctlKit/SessionCommands.swift`
- Tests: `ControlDispatcherTests.swift`, `agtermctlKitTests/CommandsTests.swift`,
  `AppStoreTreeProjectionTests.swift`, `ControlProtocolTests.swift`

- [x] `ControlSessionBackgroundOptions.pane` parsed with `parsePane`; `--pane` on the four CLI subcommands
- [x] `ControlSessionNode.paneBackgrounds`, omitted when empty, overrides only (never effective values);
  compatibility initializer unchanged
- [x] tests: each pane and alias, unknown pane rejected, omitted stays nil, CLI encoding for all four modes,
  projection with default/overrides/both, JSON omits empty, decode round trip
- [x] `cd agtermCore && swift test` for the touched suites

### Task 3: App side: apply, surface resolution, washes, end-to-end

**Files:**
- Modify: `agterm/Control/ControlServer+SurfaceIO.swift`, `agterm/Ghostty/GhosttySurfaceView+Config.swift`,
  `agterm/Ghostty/GhosttySurfaceView.swift` (in-place expression, no net lines), `agterm/Ghostty/WatermarkRenderer.swift`,
  `agterm/Views/WindowContentView.swift`, `agterm/Views/WindowContentView+Detail.swift`
- Tests: `agtermTests/GhosttySurfaceViewConfigTests.swift`, `agtermTests/ControlServerSurfaceIOTests.swift` (new),
  `agtermCore/Tests/agtermCoreTests/PaneBackgroundsTests.swift`, `agtermUITests/ControlAPIUITests.swift`

- [x] `setSessionBackground` passes the pane, refuses a missing right/scratch pane, applies to the targeted
  surface; a default change applies only to inheriting surfaces, leaving overridden panes' config and
  live OSC state alone
- [x] surface pane resolution; every session-spec read goes through `effectiveBackground(for:)`, including
  reload, opacity and the OSC baseline; renderer writes override text to its per-pane file
- [x] `washColor(hex:)` fed by `Session.washColorHex(for:)` for `paneDim`; the floating backdrop wash paints
  `Session.backdropWashRegions` (host-free: scratch across the frame when up, each pane's color, a pane
  overlay's own color, default underneath) opaque and fades the group once; click catcher kept separate
- [x] tests: pane resolution and override-beats-default (hosted), a default change leaves an overridden
  pane's OSC latch intact (hosted), region composition (host-free: scratch up, split with differing colors,
  pane overlay visible)
- [x] hosted `ControlServerSurfaceIOTests`: missing-pane refusals, a pane's own text file, file gone after
  split close, after promotion (survivor's file kept), after scratch close, none after repeated cycles
- [x] extend `testSessionBackgroundSetClearAndValidation`: pane override read back, swap, pane clear to
  inherit, `--pane right` without a split fails
- [x] touched hosted classes via the direct scoped `xcodebuild -only-testing` call (11 pass)
- [x] run only the extended XCUITest method (approved; passes)

### Task 4: Verify and document
- [x] every Solution Overview rule has a test
- [x] gates once: `cd agtermCore && swift test`, `make test-app`, `make lint` with zero findings
- [x] `.claude/rules/control-api.md` Session backgrounds: override layer, precedence, lifecycle, read-back
- [x] `site/commands.html` session background entry: `--pane` and `paneBackgrounds`
- [x] `plugins/agterm/skills/agterm/` SKILL.md, reference and examples: `--pane` and a two-agent label example
- [x] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification:**
- isolated Debug instance: two-pane session with DRIVER/PEER text labels, swap, close left pane, scratch
  show/hide/replace, relaunch keeps left/right and drops scratch, translucent window with a text override
  beside an inheriting pane

**External:**
- reply on discussion #643 once merged
