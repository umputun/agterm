# Agent Status Glyph Shapes

## Overview

The three agent-status glyphs in the sidebar (`active`, `blocked`, `completed`) all render as
`.circle.fill` variants, deliberately sharing one silhouette. That makes hue the only channel carrying
the meaning. Discussion #277 reports the practical consequence: a daily user read all three as plain
colored dots, never noticed the interior marks (they are a small knockout inside an identical filled
circle at a fixed 16pt slot), and mis-mapped the colors — ignoring the amber `blocked` glyph as "busy,
leave it alone" when that is exactly the state that wanted attention. The tooltips added in #283 do not
reach this: the sidebar is scanned peripherally, and the whole value is noticing a session needs you
without aiming at it first. Hue-only encoding also fails the color-blind case.

This adds a fixed set of six glyph shapes, selectable per status from Settings and per call from the
control API. The built-in default becomes a PLAIN CIRCLE for all three states: the interior marks never
read at the sidebar's render size (they only show up in the popup), which is the reporter's complaint, so
keeping them as the default would ship the feature on top of the problem it exists to fix.

Key benefits:

- silhouette becomes a second encoding channel alongside hue, so statuses differ peripherally
- color-blind users get a non-hue signal
- scriptable: an agent can mark one session with a distinct shape for the duration of a run
- zero-cost for anyone who does not want it (no new width, no layout change)

## Context (from discovery)

Files/components involved:

- `agtermCore/Sources/agtermCore/AgentStatus.swift` — `AgentStatus.symbolName`, `AgentIndicator`, `StatusPane`
- `agtermCore/Sources/agtermCore/AppSettings.swift` — the three `*StatusColorHex` fields (~208-210) and the
  `effectiveDockBounce` tolerant-decode accessor (~395)
- `agtermCore/Sources/agtermCore/ControlProtocol.swift` — `ControlArgs`, `ControlSessionNode` (`statusColor` ~417)
- `agtermCore/Sources/agtermCore/ControlModes.swift` — `ControlSessionStatusUpdate` (~139-165); NOT in `ControlProtocol.swift`
- `agtermCore/Sources/agtermCore/ControlEvents.swift` — `ControlEventPayload`, which carries `color` (~19)
- `agtermCore/Sources/agtermCore/AppStore+Status.swift` — `setAgentIndicator` emitting the `.status` event with `color` (~43-54)
- `agtermCore/Sources/agtermCore/ControlDispatcher.swift` — the `.sessionStatus` arm (~320), already dispatcher-owned
- `agtermCore/Sources/agtermCore/AppStore.swift` — `controlTree` (~183), builds the node incl. `statusColor` (~226).
  **Currently 995 lines against the swiftlint 1000-line cap — 5 lines of headroom.**
- `agtermCore/Sources/agtermctlKit/SessionCommands.swift` — `struct Status` (~345) with its `--color` option + `validate()`
- `agterm/Control/ControlServer+SessionActions.swift` — `setSessionStatus` (~343)
- `agterm/Ghostty/GhosttyApp.swift` — `setAgentStatusColors` (~246), `statusColor(for:override:)` (~268)
- `agterm/Views/SidebarRowViews.swift` — `StatusIconView` (~150-215), AppKit render site
- `agterm/Views/StatusGlyph.swift` — SwiftUI render site
- `agterm/Views/Palette.swift`, `agterm/AppActions+Palette.swift`, `agterm/Views/SessionSwitcher.swift`,
  `agterm/Views/WindowContentView+RecentSessions.swift` — the three item models feeding `StatusGlyph`
- `agterm/SettingsModel.swift` — color setters (~278-280), reset (~410-412), `applyAgentStatusColors` (~763)
- `agterm/Views/SettingsView.swift` — Agent Status tab Colors section (~542-560), bindings (~596-609)

Related patterns found:

- **`--color` is the exact template, and it has FIVE legs.** A per-call `#rrggbb` override (1) rides the
  ephemeral `AgentIndicator`, (2) is validated in the dispatcher, (3) reads back on `tree` as
  `statusColor`, (4) falls back to a Settings-configured per-status value, and (5) **is carried on the
  `.status` control event payload** (`ControlEventPayload.color`, emitted by `AppStore+Status.swift`).
  Shape mirrors all five. The fifth is easy to miss and is load-bearing: `setAgentIndicator`'s
  `guard previous != indicator else { return }` means a shape-only change DOES fire a `.status` event, so
  an `events.read` consumer would otherwise receive an event it cannot explain.
- **Tolerant decode.** `AppSettings` stores raw `String?` and exposes an `effective*` accessor doing
  `raw.flatMap(Enum.init(rawValue:)) ?? fallback`, so an unknown value never fails the read (`effectiveDockBounce`).
- **Shared resolver against drift.** Both render sites already call one `GhosttyApp.statusColor(for:override:)`
  so the AppKit and SwiftUI glyphs cannot diverge; shape gets the same treatment.
- **Live repaint exists.** The sidebar Coordinator observes `.agtermAppearanceChanged` and calls
  `reapplyStatusGlyphs()`, which already repaints every visible row on a settings change.

Dependencies identified: none new. No new package, no new persisted session state, no new control command.

Discovery evidence (already performed, do not redo):

- SF Symbols pairs all three current marks (`ellipsis` / `exclamationmark` / `checkmark`) with only
  `circle` and `bubble`. "Keep the mark, change the container" is therefore not a viable fixed set.
- Rendered at the real 13pt symbol size in the 16pt slot, `hexagon`, `octagon`, `pentagon` and `seal`
  are indistinguishable from `circle`; `app` duplicates `square` and `rhombus` duplicates `diamond`;
  `shield`, `bubble` and `rectangle` are marginal. Six shapes read as genuinely distinct.

## Development Approach

- **testing approach**: Regular (code first, then tests, within each task)
- **work in an isolated git worktree**: `git fetch origin master` FIRST so the worktree forks the current
  remote tip, create it with Claude Code's native `EnterWorktree` (never a manual `git worktree add`),
  then symlink the gitignored prebuilt artifacts BEFORE building — `GhosttyKit.xcframework` and
  `agterm/Resources/{ghostty,terminfo}` — using ABSOLUTE targets for the two Resources symlinks
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional - they are a required part of the checklist
  - write unit tests for new functions/methods
  - write unit tests for modified functions/methods
  - add new test cases for new code paths
  - update existing test cases if behavior changes
  - tests cover both success and error scenarios
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- run `cd agtermCore && swift test` after each change; the app must build and `make lint` must pass
- maintain wire/settings compatibility: an unset shape must stay valid and decode to nil, rendering the
  built-in default (now the plain circle)

### Settled decisions (do not re-litigate)

1. **Plain shapes only, no interior marks.** Every glyph is a bare silhouette — the marked circles are
   gone from the codebase, not merely unselected.
2. **Fixed set of exactly six**: `circle`, `square`, `triangle`, `diamond`, `capsule`, `star`.
3. **The built-in default is `StatusShape.circle` for all three states** (maintainer decision during
   implementation, superseding the original "nothing changes by default"): the interior ellipsis /
   exclamation / check do not read at 13pt in the sidebar — they are only legible in the popup — so the
   default is now a plain circle and hue alone separates the states until a shape is picked. An unset
   setting and an explicit `circle` render identically, which is why the Settings picker stores nil for
   `circle`.
   **The trade-off is deliberate and was re-confirmed in review.** Code review proposed per-status default
   shapes (`.circle`/`.triangle`/`.square`) so the non-hue channel would be on out of the box; the
   maintainer DECLINED. Shapes stay OPT-IN, which means a fresh install still encodes the three states by
   hue alone and a color-blind user gets the second channel only after visiting Settings ▸ Agent Status.
   Accepted: a silent silhouette change on every existing install is a bigger cost than the opt-in step,
   and the discussion-#277 complaint (the marks are invisible at render size) is answered by dropping the
   marks regardless of which shape is default. Do not re-litigate `symbolName`'s both-nil branch.
4. **Precedence**: per-call `--shape` override → Settings shape for that status → built-in default.
5. **No control command for the Settings shapes.** Settings pickers are keep-in-sync EXEMPT
   (the `dockBounce` / notification-sound precedent). The per-call `--shape` is the control surface.
6. **`--shape` on `idle` is accepted and ignored** (idle renders no glyph), same as `--color` today.
7. **The dashboard is not affected.** `DashboardCaptionPill` is a colored capsule reading `statusColor`
   only; it draws no symbol.
   **Recorded as a KNOWN GAP, not just a description of the current render:** the dashboard grid stays
   HUE-ONLY (`Capsule().fill(statusColor)`, `DashboardView.swift` ~262/~290), so a user who picks shapes
   precisely to stop depending on hue gets no second channel there. Accepted for this feature: the pill is
   a name chip sized around text, not a glyph slot, so carrying a silhouette means designing a new
   dashboard affordance (where the symbol sits, how it reads against the filled capsule, what it does at
   the 9-cell size) — that is its own change, not a line in this one.

## Testing Strategy

- **unit tests**: required for every task, host-free in `agtermCore` wherever the logic allows
  (`swift test`, no app host). The precedence resolver, the settings accessor, the protocol round-trip,
  the dispatcher validation, the tree read-back and the CLI request building are ALL host-free.
- **e2e tests**: this project has XCUITest e2e coverage under `agtermUITests/`.
  - control-channel change → extend `agtermUITests/ControlSidebarStatusUITests.swift` in the same task
  - Settings UI change → extend `agtermUITests/SettingsUITests.swift` in the same task
  - treat e2e tests with the same rigor as unit tests (must pass before next task)
- **App-target exemption, stated explicitly so no task silently skips its gate.** Tasks 6, 7 and 8 wire
  app-target render sites and the `GhosttyApp`/`SettingsModel` mirrors. The app target has NO unit-test
  host (`.claude/rules/settings.md`: "the mirror wiring is app-target — build/manually verified, no app
  unit-test host"), so those three tasks gate on `make build` and their BEHAVIOR is covered downstream:
  Task 9's e2e covers the Settings path (model setters → picker → persistence) and Task 10's e2e covers
  the control path (indicator → render site → tree). Each of the three names its downstream coverage in
  a checkbox. This is the one place the "tests in the same task" rule bends, and only because there is
  no host to run them in — every host-free line of this feature is unit-tested in Tasks 1-5.
- **Known assertion limit, mirrored from `--color`**: the rendered silhouette is no more
  accessibility-observable than the tint is (`StatusIconView` exposes only the state *name* as its
  accessibility value). The e2e therefore asserts command success, the unchanged `agent-status` state
  name, rejection of a bad shape leaving the status untouched, and the `tree` read-back — not the drawn
  pixels. The visual result is verified by eye on a dev instance, like the cursor-focus case.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview

A new host-free `StatusShape` enum in `agtermCore` names the six shapes; its raw value maps 1:1 to the
SF Symbol base name, so `symbolName` is `"\(rawValue).fill"`.
Adding a shape later is one line in the enum plus the doc sites that enumerate the set BY HAND — the
`ControlArgs.shape` doc comment, `site/commands.html` and the agent skill — since only the dispatcher's
rejection message and the CLI's `--shape` help/rejection derive their list from `allCases`.

`AgentStatus.symbolName` stops being a property and becomes a resolver taking two optional shapes —
the per-call override and the Settings-configured value. It returns the first non-nil shape's symbol,
else `StatusShape.circle`'s, so the built-in default is expressed as a shape rather than a second
hardcoded string. Putting the precedence there (rather than at each render site) means it is unit-tested
once, host-free, and the two render sites cannot drift.

The per-call value rides `AgentIndicator.shape`, ephemeral exactly like `AgentIndicator.color` — never
persisted, discarded by the next `session.status` that omits `--shape`. The Settings value lives in
`AppSettings` as three raw `String?` fields with a single `effectiveStatusShape(for:)` accessor doing the
tolerant decode.

The app target mirrors the settings into `GhosttyApp` (as it already does for colors) and exposes one
`statusSymbolName(for:override:)` that both render sites call. `SettingsModel` pushes the mirror in
`applyAgentStatusShapes()` next to `applyAgentStatusColors()`; the existing `.agtermAppearanceChanged`
→ `reapplyStatusGlyphs()` path repaints live with no new notification.

The control side adds one argument, one read-back field and one event-payload field — no new command.
Validation happens once in the already dispatcher-owned `.sessionStatus` arm, so every downstream
consumer receives a typed `StatusShape?` and is total.

Key design decisions and rationale:

- **Enum on the indicator, raw `String?` in settings.** The dispatcher validates at the boundary, so the
  runtime value is always a valid case; settings must survive hand-editing, so they decode tolerantly.
- **Resolver in `agtermCore`, not `GhosttyApp`.** Colors live in `GhosttyApp` only because `NSColor` is
  AppKit. Shapes are strings, so the whole precedence is host-free and testable without an app host —
  the standing "hoist host-free logic down" direction.
- **Read-back reports the per-call override only.** `statusShape` is nil when the glyph uses the Settings
  shape or the default, exactly matching `statusColor`, so record-then-restore scripts treat both alike.
- **Six shapes, not fifteen.** A picker entry that does not actually differentiate is worse than absent:
  the user believes they have distinguished a status and has not.

## Technical Details

New type in `agtermCore/Sources/agtermCore/AgentStatus.swift`, beside `StatusPane`:

```swift
public enum StatusShape: String, Codable, Sendable, CaseIterable {
    case circle, square, triangle, diamond, capsule, star
    public var symbolName: String { "\(rawValue).fill" }
    public var displayName: String { rawValue.capitalized }
    public static var validNamesList: String { validNames.joined(separator: "|") }
    public static var validNamesPhrase: String { validNames.joined(separator: ", ") }
    private static var validNames: [String] { allCases.map(\.rawValue) }
}
```

`displayName` is the host-free picker label, read by the Settings options and the picker's accessibility
value, so the six names have ONE definition.
`validNamesList` (pipe-joined) builds the dispatcher's rejection message and `validNamesPhrase`
(comma-joined) the `agtermctl --shape` help text and its local rejection — both derived from `allCases`,
the `WatermarkConfig.validFits` precedent.

Resolver replacing the `AgentStatus.symbolName` property:

```swift
public func symbolName(override: StatusShape?, configured: StatusShape?) -> String {
    guard self != .idle else { return "" }
    return (override ?? configured ?? .circle).symbolName
}
```

Neither parameter is defaulted, deliberately: a render site that forgot to pass the Settings shape would
silently draw the wrong glyph, so the omission has to be a compile error.

The leading `idle` guard is what makes settled decision 6 hold (`--shape` on `idle` is accepted and
ignored) — without it a shape would win over the empty string and idle would draw a glyph.

`AgentIndicator` gains `public var shape: StatusShape?` (ephemeral, `Equatable` participation is automatic).

`AppSettings` gains `activeStatusShape` / `blockedStatusShape` / `completedStatusShape` as `String?`, plus:

```swift
public func effectiveStatusShape(for status: AgentStatus) -> StatusShape? {
    let raw: String?
    switch status {
    case .active: raw = activeStatusShape
    case .blocked: raw = blockedStatusShape
    case .completed: raw = completedStatusShape
    case .idle: return nil
    }
    return raw.flatMap(StatusShape.init(rawValue:))
}
```

Wire format additions, in three different files — note `ControlSessionStatusUpdate` is NOT in `ControlProtocol.swift`:

- `ControlProtocol.swift`: `ControlArgs.shape: String?` and `ControlSessionNode.statusShape: String?` (omitted when nil)
- `ControlModes.swift`: `ControlSessionStatusUpdate.shape: StatusShape?`, whose init parameter MUST default
  to `nil` (`shape: StatusShape? = nil`, as `color`/`pane`/`paneID` already do) — otherwise Task 3 fails to
  compile at the existing dispatcher call site, which does not pass a shape until Task 4
- `ControlEvents.swift`: `ControlEventPayload.shape: String?`, likewise defaulted in the init

`StatusShape` declares `Codable` to match its sibling `StatusPane`/`AgentStatus` declarations, not because
anything encodes it directly — the wire carries raw strings on both the args and the node.

Dispatcher validation, beside the existing color check in the `.sessionStatus` arm:

```swift
var shape: StatusShape?
if let raw = request.args?.shape {
    guard let parsed = StatusShape(rawValue: raw) else {
        return ControlResponse(ok: false, error: "invalid shape: \(raw) (\(StatusShape.validNamesList))")
    }
    shape = parsed
}
```

The message is derived from `allCases` (via `StatusShape.validNamesList`, the pipe-joined form; the CLI's
help text and its own rejection use the comma-joined `validNamesPhrase`) so it can never go stale when the
set changes.

Tree read-back in `AppStore.controlTree`, directly beside the existing `statusColor` line:

```swift
statusShape: idle ? nil : session.agentIndicator.shape?.rawValue,
```

`AppStore.swift` is at 995 of its 1000-line budget, so this must stay a ONE-line addition with no inline
comment. Raising the swiftlint limit is not an acceptable fix (project rule).

Event payload in `AppStore+Status.swift`, beside the existing `color: indicator.color`:

```swift
shape: indicator.shape?.rawValue
```

Processing flow for a `session.status blocked --shape triangle`:

1. `agtermctl` validates the raw string locally in `Status.validate()` and sends `args.shape`
2. `ControlDispatcher` parses it to `StatusShape`, rejects unknown values before any mutation
3. `ControlServer.setSessionStatus` folds it into the new `AgentIndicator`
4. `AppStore.setAgentIndicator` stores it and emits a `.status` control event carrying `shape: "triangle"`
5. `RowContent` (Equatable) sees the indicator change and reloads only that row
6. `StatusIconView.apply` calls `GhosttyApp.statusSymbolName(for:override:)`, which calls
   `AgentStatus.symbolName(override:configured:)` with the per-call shape and the Settings shape
7. `tree` reports `statusShape: "triangle"` until the next `session.status` without `--shape`

## What Goes Where

- **Implementation Steps** (`[ ]` checkboxes): code, tests and documentation changes in this repo
- **Post-Completion** (no checkboxes): visual acceptance on a dev instance, and the reply on
  discussion #277

## Implementation Steps

### Task 1: Add StatusShape enum and the symbolName resolver

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AgentStatus.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AgentStatusTests.swift`
- Modify: `agterm/Views/SidebarRowViews.swift` (call-site fixup only)
- Modify: `agterm/Views/StatusGlyph.swift` (call-site fixup only)

- [x] add `public enum StatusShape: String, Codable, Sendable, CaseIterable` with the six cases and
      `symbolName` returning `"\(rawValue).fill"`, placed next to `StatusPane`, with a godoc comment
      explaining the set was chosen for distinctness at the sidebar's render size
- [x] replace the `AgentStatus.symbolName` property with
      `symbolName(override:configured:)`, whose both-nil branch is `StatusShape.circle` (the marked-circle
      switch is gone — see settled decision 3)
- [x] add `public var shape: StatusShape?` to `AgentIndicator` (ephemeral, documented as discarded by the
      next `session.status` without `--shape`, mirroring `color`) and extend its `init`
- [x] rewrite the `AgentStatus.symbolName` godoc, which currently describes it as a property with a fixed
      mapping, to document the two-level precedence
- [x] update every in-repo caller of the old property (`agterm/Views/SidebarRowViews.swift`,
      `agterm/Views/StatusGlyph.swift`) to compile — full render wiring lands in Tasks 6 and 7
- [x] write tests for `StatusShape.symbolName` covering all six cases
- [x] write tests for the resolver precedence: override wins over configured (including an explicit
      `circle` override), configured wins over default, both nil returns the plain `circle.fill` for all
      three states, `idle` returns the empty string in every combination
- [x] update the existing `AgentStatusTests` assertions that call the old `symbolName` property
- [x] run `cd agtermCore && swift test` - must pass before next task
- [x] run `make build` - this task edits app-target files, so the app must compile before next task

### Task 2: Add the three Settings shape fields

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppSettings.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppSettingsTests.swift`

- [x] add `activeStatusShape` / `blockedStatusShape` / `completedStatusShape` as `public var String?`
      beside the three `*StatusColorHex` fields, and extend the memberwise `init`
- [x] add `effectiveStatusShape(for:)` doing the tolerant decode, documented as the single read point so
      callers never touch the raw strings (the `effectiveDockBounce` precedent)
- [x] write tests for the three fields round-tripping through encode/decode
- [x] write tests that an unknown raw string decodes to nil from `effectiveStatusShape` rather than
      throwing, and that absent fields decode to nil
- [x] write a test that `effectiveStatusShape(for: .idle)` returns nil
- [x] fix the stale godoc directly above the color fields (~205-206), which says the `active` default is
      blue — `GhosttyApp.defaultActiveStatusColor` is `#DBD9E6`, a muted lavender-grey, and `.systemBlue`
      is only an unreachable parse fallback
- [x] run `cd agtermCore && swift test` - must pass before next task

### Task 3: Add the wire fields, the tree read-back and the event payload

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift` (`ControlArgs`, `ControlSessionNode`)
- Modify: `agtermCore/Sources/agtermCore/ControlModes.swift` (`ControlSessionStatusUpdate`)
- Modify: `agtermCore/Sources/agtermCore/ControlEvents.swift` (`ControlEventPayload`)
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift` (`controlTree`)
- Modify: `agtermCore/Sources/agtermCore/AppStore+Status.swift` (`setAgentIndicator` event emission)
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlEventProtocolTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreEventTests.swift`

- [x] add `shape: String?` to `ControlArgs` with a doc comment matching the `color` one
- [x] add `shape: StatusShape? = nil` to `ControlSessionStatusUpdate` in `ControlModes.swift` — the init
      default is REQUIRED so this task compiles before Task 4 passes a shape at the dispatcher call site
- [x] add `statusShape: String?` to `ControlSessionNode`, documented as the read side of
      `session.status --shape` reporting the per-call override only
- [x] add `shape: String?` to `ControlEventPayload`, beside the existing `color`, also init-defaulted
- [x] set `statusShape: idle ? nil : session.agentIndicator.shape?.rawValue` in `AppStore.controlTree`,
      directly beside the existing `statusColor` line — ONE line, no inline comment, since `AppStore.swift`
      sits at 995 of its 1000-line swiftlint budget and raising the limit is not an acceptable fix
- [x] emit `shape: indicator.shape?.rawValue` in the `.status` event from `AppStore+Status.swift`, beside
      the existing `color:` — a shape-only change passes the `guard previous != indicator` check and DOES
      fire an event, so an `events.read` consumer must be able to explain it
- [x] write tests for `ControlArgs.shape` and `ControlSessionNode.statusShape` round-tripping, and for
      both being omitted from the JSON when nil
- [x] write a `ControlEventProtocolTests` case for `ControlEventPayload.shape` round-tripping and being
      omitted when nil
- [x] write a test that `controlTree` reports `statusShape` for a session carrying a per-call shape and
      nil for one without, and nil for an idle session that somehow retains a shape
- [x] extend `AppStoreEventTests.normalizedStatusChangesEmitCompletePayloadsAndIdleEdge` (which already
      asserts `payload.color`) to assert `payload.shape`, and add a case that a shape-only change emits an
      event carrying it
- [x] run `cd agtermCore && swift test` - must pass before next task

### Task 4: Validate and apply --shape in the control path

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift`
- Modify: `agterm/Control/ControlServer+SessionActions.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherTests.swift`

- [x] add the shape parse/validate block to the `.sessionStatus` arm beside the color check, deriving
      the error message from `StatusShape.allCases`
- [x] pass the parsed shape into `ControlSessionStatusUpdate`
- [x] fold `update.shape` into the `AgentIndicator` built by `setSessionStatus`
- [x] write tests that a valid shape is accepted and reaches the update, and that an absent shape is
      accepted as nil
- [x] write tests that an invalid shape is rejected with the `allCases`-derived message AND that no
      mutation reached the mock actions
- [x] write a test that `--shape` alongside `status: idle` is accepted (and simply carries no glyph)
- [x] run `cd agtermCore && swift test` - must pass before next task
- [x] run `make build` - this task edits `agterm/Control/ControlServer+SessionActions.swift`, so the app
      must compile before next task

### Task 5: Add the agtermctl session status --shape option

**Files:**
- Modify: `agtermCore/Sources/agtermctlKit/SessionCommands.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/CommandsTests.swift`

- [x] add the `--shape` `@Option` to `struct Status` beside `--color`, help text listing the six shapes
      and stating it reverts on the next status set without it
- [x] extend `Status.validate()` to reject an unknown shape locally, beside the existing color guard
- [x] pass `shape` through `makeRequest()` into `ControlArgs`
- [x] write a test that `session status blocked --shape triangle` builds a request carrying the shape
- [x] write a test that an unknown shape fails `validate()` without a round-trip
- [x] run `cd agtermCore && swift test` - must pass before next task

### Task 6: Mirror shapes into GhosttyApp and render in the sidebar

**Files:**
- Modify: `agterm/Ghostty/GhosttyApp.swift`
- Modify: `agterm/Views/SidebarRowViews.swift`

- [x] add three `private(set) var …StatusShape: StatusShape?` properties and
      `setAgentStatusShapes(active:blocked:completed:)` beside the color equivalents
- [x] add `statusSymbolName(for:override:)` delegating to `AgentStatus.symbolName(override:configured:)`
      with the mirrored Settings shape, documented as the single resolver both render sites share
- [x] change `StatusIconView.icon(for:override:)` to take the indicator's shape and resolve the symbol
      through `statusSymbolName`, leaving the tint path untouched
- [x] update the `StatusIconView` doc comment, which currently states all three glyphs are `.circle.fill`
- [x] verify by build that the accessibility value still reports the state name (unchanged behavior)
- [x] build the app (`make build`) - must succeed before next task
- [x] no unit tests here by the app-target exemption stated in Testing Strategy; this task's behavior is
      covered by Task 10's control e2e (indicator → render site → tree)
- ⚠️ CORRECTION (review): that coverage claim was overstated for HALF this task. Task 10's e2e drives only
      the PER-CALL override, and `tree` deliberately reports the override only, so the `configured` branch
      of `statusSymbolName(for:override:)` and the three-way `setAgentStatusShapes` mapping are NOT reached
      by any test at any level. They are not reachable either: the drawn silhouette is not
      accessibility-observable (`StatusIconView` exposes only the state NAME), so no e2e can assert which
      symbol a Settings shape produced. What IS covered: the precedence they delegate to is unit-tested
      host-free (`AgentStatusTests.symbolNameConfiguredWinsOverDefault`), the settings→mirror path is
      exercised end to end by Task 9's e2e up to persistence, and the mapping itself is build-verified and
      confirmed by eye on a dev instance — the cursor-focus/tint precedent.

### Task 7: Render shapes in the SwiftUI glyph and its three item models

**Files:**
- Modify: `agterm/Views/StatusGlyph.swift`
- Modify: `agterm/Views/Palette.swift`
- Modify: `agterm/AppActions+Palette.swift`
- Modify: `agterm/Views/SessionSwitcher.swift`
- Modify: `agterm/Views/WindowContentView+RecentSessions.swift`

- [x] add `var shape: StatusShape?` to `StatusGlyph` beside `colorHex` and resolve through
      `GhosttyApp.statusSymbolName(for:override:)`
- [x] add the parallel shape field to `PaletteItem` (beside `statusColor`) and thread it through
      `paletteItem(for:in:status:statusColor:)` in `AppActions+Palette.swift`
- [x] add the parallel shape field to `SessionSwitcherRow` (the switcher row type, beside
      `statusColorHex` — there is no `SessionRowModel`) and pass it to `StatusGlyph`
- [x] add the parallel shape field to `SessionPopoverRow` and populate it from `session.agentIndicator.shape`
      at both construction sites (the nil-status one and the populated one)
- [x] update the four doc comments that name only the color override: `StatusGlyph`'s type doc,
      `SessionSwitcherRow`'s field doc, `SessionPopoverRow`'s doc, and `paletteItem`'s doc
- [x] confirm no other `agentIndicator.color` read site was missed (grep) and that the dashboard is
      untouched, since `DashboardCaptionPill` draws only `Text` + `Capsule().fill`
- [x] build the app (`make build`) - must succeed before next task
- [x] no unit tests here by the app-target exemption stated in Testing Strategy; this task's behavior is
      covered by Task 10's control e2e

### Task 8: Wire the Settings model

**Files:**
- Modify: `agterm/SettingsModel.swift`

- [x] add `setActiveStatusShape(_:)` / `setBlockedStatusShape(_:)` / `setCompletedStatusShape(_:)` beside
      the color hex setters, each calling `persistAndApply()`
- [x] add `applyAgentStatusShapes()` beside `applyAgentStatusColors()` and call it from both existing
      call sites (init-time apply and the settings-changed apply)
- [x] clear the three shape fields in the reset-to-defaults path alongside the color hexes, and update
      `resetAgentStatus()`'s doc comment, which currently enumerates only the three colors and the sound
- [x] verify the existing `.agtermAppearanceChanged` → `reapplyStatusGlyphs()` path repaints the sidebar
      on a shape change with no new notification
- [x] build the app (`make build`) - must succeed before next task
- [x] no unit tests here by the app-target exemption stated in Testing Strategy; this task's behavior is
      covered by Task 9's Settings e2e (setter → picker → persistence → reset)

### Task 9: Add the Settings Shapes pickers

**Files:**
- Modify: `agterm/Views/SettingsView.swift`
- Modify: `agtermUITests/SettingsUITests.swift`

- [x] merge the Agent Status tab's Colors section into a **Colors and Shapes** section with ONE ROW PER
      STATUS (Active / Blocked / Completed) — a `LabeledContent` row whose trailing side carries that
      status's `ColorPicker` and its shape `Picker` side by side, both `.labelsHidden()`, the shape
      picker at a fixed width so the three rows align (user-requested layout; there is NO separate
      Shapes section)
- [x] each picker offers exactly the six shapes, built from `StatusShape.allCases` so the set cannot
      drift from the enum, each option drawn as the SYMBOL ALONE (its name kept as the accessibility
      label) and tinted with that status's current color
- [x] bind each picker so `circle` — the built-in default — maps back to nil, keeping `settings.json`
      minimal (the sound-picker convention); nil and `circle` render identically
- [x] keep the existing color-well identifiers (`settings-status-active`/`-blocked`/`-completed`) and
      give the shape pickers `settings-status-shape-active`/`-blocked`/`-completed`, both derived from
      the `AgentStatus` raw value so the row and its ids cannot drift
- [x] update the `AgentStatusSettingsView` doc comment (it enumerates the tab's sections) and the
      `SettingsView.swift` file header
- [x] write an e2e test that selecting a shape persists it across a relaunch, and that selecting Circle
      clears it back out of `settings.json`; it also asserts the option list is the six shapes with no
      "Default" entry, and the merged layout (color well and shape picker on one row, the rows aligned,
      Reset still reachable without scrolling)
- [x] ➕ (review) the first version of that e2e drove only the BLOCKED row and never clicked Reset, so the
      three shape-clearing lines in `SettingsModel.resetAgentStatus()` had zero coverage at any level and a
      copy-pasted binding driving the wrong status would have passed. `testAgentStatusShapePickerPersists`
      now also picks Star on the ACTIVE row, asserts each row writes its OWN key (and leaves its sibling
      alone) across the relaunch, and finally clicks `settings-status-reset` and asserts the shape key is
      cleared and the picker falls back to Circle. The two geometry assertions were also loosened from
      1–2pt coordinate equality to same-row / same-column overlap checks (they pinned SwiftUI layout finer
      than anything else in the suite and would break on any Form-style or OS-metric change), and the
      Active picker is now fetched through the retrying `settingsControl` helper like its neighbours
- [x] run the settings UI tests - must pass before next task

### Task 10: Add the control e2e coverage

**Files:**
- Modify: `agtermUITests/ControlSidebarStatusUITests.swift`

- [x] add a test sending `session.status` with a valid `shape` and asserting `ok`
- [x] assert the `agent-status` element still reports the state name (the silhouette itself is not
      accessibility-observable, mirroring the `--color` test's documented limitation)
- [x] assert the `tree` read-back returns `statusShape` for the session
- [x] assert an invalid shape is rejected with the expected error and leaves the status unchanged
- [x] assert a following `session.status` without `--shape` clears `statusShape` from the tree
- [x] add a comment stating the assertion limit explicitly, as the `--color` test does
- [x] run the control UI tests - must pass before next task

### Task 11: Update README and the website

**Files:**
- Modify: `README.md`
- Modify: `site/docs.html`
- Modify: `site/commands.html`

- [x] update the glyph-legend sentence in `README.md` (~433, "`active` is a blue ellipsis, `blocked` an
      amber exclamation, `completed` a green check") to note the shapes are configurable, and document
      the Settings Agent Status shape pickers and the six-shape set. While rewriting that sentence, fix
      its stale "blue" — the `active` default is `#DBD9E6`, a muted lavender-grey
- [x] add a `--shape` line to the `agtermctl session status … --color` example block in `README.md` (~448)
- [x] mirror both into `site/docs.html` — the legend is a three-swatch visual block (~1794-1815), not
      prose, so it needs the same treatment in its own markup, including the same stale "blue ellipsis"
      label at ~1795
- [x] add `--shape` to the `session.status` invocation line in `site/commands.html` (~988-989), which
      spells out the full flag list
- [x] add `statusShape` in BOTH places `statusColor` appears in `site/commands.html`: the `tree` entry's
      session-node field list (~432) and the `session.status` entry's read-back sentence (~1022)
- [x] verify no other command entry needed a change (this adds an argument, not a command)
- [x] run `make lint` - must pass before next task

⚠️ Pre-existing, unrelated site drift found while verifying the last item: `events.read` has no entry in
`site/commands.html` and the page still reads "All 64 commands" while `Command` now has 66 cases (65
public plus the exempt `debug.appearance`).
Not caused by this feature (which adds an argument, not a command) and left untouched here.
RESOLVED in Task 12 as a ➕ item, per the project's fix-what-you-encounter policy: the count and the
missing `events.read` entry were corrected on `site/commands.html`, `site/docs.html` and
`.claude/rules/control-api.md`.

### Task 12: Update the agent skill and the rule notes

**Files:**
- Modify: `agterm/Resources/agent-skill/SKILL.md`
- Modify: `agterm/Resources/agent-skill/reference.md`
- Modify: `agterm/Resources/agent-skill/examples.md`
- Modify: `.claude/rules/notifications.md`
- Modify: `.claude/rules/control-api.md`
- Modify: `.claude/rules/settings.md`

The agent skill is FOUR files, not one — `--color`/`statusColor` appear in three of them, and each site
needs the shape twin. Edit ONLY `agterm/Resources/agent-skill/`; the installed copies under
`~/.claude/skills/agterm/` are regenerated outputs and must never be touched.

- [x] `SKILL.md` (~157): add `statusShape` to the tree-field paragraph naming `statusBlink`/`statusColor`
- [x] `SKILL.md` (~252): add `[--shape ...]` to the `session status` command-summary flag list
- [x] `reference.md` (~111-112): add `statusShape` to the tree-field description beside `statusColor`
- [x] `reference.md` (~333, ~343-344): add `--shape` to the `session status` signature and a prose
      paragraph matching the `--color` one (rides the status, reverts on the next set without it)
- [x] `reference.md` (~790): add the `allCases`-derived `invalid shape: …` string to the error-string
      catalog, beside `invalid color (expected #rrggbb)`
- [x] `examples.md` (~506): add a `--shape` example beside the existing `session status blocked --color`
- [x] confirm the skill's command COUNT is unchanged (this adds an argument, not a command) — SKILL.md
      already reads "Command summary (65 commands)", which matches the enum, so it needed no edit
- [x] update the agent-status glyph bullet in `.claude/rules/notifications.md`, which currently states
      the three symbols are fixed `.circle.fill` variants
- [x] record the `--shape` argument, the `statusShape` read-back AND the `.status` event payload field in
      `.claude/rules/control-api.md`
- [x] record the three shape settings and the picker in `.claude/rules/settings.md`
- [x] use semantic line breaks (one sentence per line) in all rule/skill edits
- [x] confirm `CHANGELOG.md` was NOT touched (release-only)
- [x] ➕ fix the pre-existing `site/commands.html` drift Task 11 found: the page said "All 64 commands"
      while the public catalog is 65 (`Command` has 66 cases, less the UI-test-only exempt
      `debug.appearance` — the same definition the old 64 used), and `events.read` had no entry.
      Corrected the count in the two meta descriptions and the intro, added an `events` section (invocation,
      the five kinds and their payloads, the `run`/`next` cursor contract, the hard cursor errors) plus its
      nav link, and replaced the now-false "no event subscription" claim in the Overview. Cross-checked the
      count against the agent skill, which was already right at 65, and against
      `.claude/rules/control-api.md`, which carried the SAME stale 64 in three places and omitted
      `events.read` from its catalog list — both fixed there too
- [x] ➕ `site/docs.html` carried the same two stale statements (its "All 64 commands" pointer to the
      command reference and its own "no event subscription" claim); corrected both, since a count that
      disagrees between the two pages is worse than the original drift
- [x] ➕ the `status` control event's payload description was stale in `README.md` (~211) and the skill's
      `reference.md` events section — both listed "optional pane and color" without the `shape` field
      Task 3 added; that is this feature's own drift, so both now name `shape`
- [x] run `make lint` - must pass before next task

### Task 13: Verify acceptance criteria

- [x] verify a fresh profile with no shape settings renders the plain circle for all three states, tinted
      as before, and that an explicit `circle` selection is indistinguishable from it — code-verified:
      `AgentStatus.symbolName(override:configured:)` returns `StatusShape.circle.symbolName` with both
      nil, and the Settings picker maps `circle` back to nil (`SettingsView.swift` ~689-694), so unset
      and explicit-`circle` take the identical path; the tint path is untouched. The by-eye render is
      deferred to Post-Completion manual verification
- [x] verify the precedence chain end to end: Settings shape shows, a per-call `--shape` overrides it, and
      the next `session.status` without `--shape` falls back to the Settings shape — the resolver's
      `override ?? configured ?? .circle` is unit-covered in `AgentStatusTests`, and the e2e
      `testSessionStatusShapeValidatesAndReadsBack` asserts the per-call set plus the omit-clears-it leg
- [x] verify an invalid shape is rejected by both `agtermctl` locally and the dispatcher remotely —
      CLI `Status.validate()` (`SessionCommands.swift` ~377) throws before any round-trip; the dispatcher
      (`ControlDispatcher.swift` ~327-335) rejects with the `allCases`-derived message before any mutation
- [x] verify all five `--color` legs have a shape twin: indicator, dispatcher validation, `tree` read-back,
      Settings fallback, and the `.status` event payload — all five read back in source:
      `AgentIndicator.shape`, the dispatcher parse block, `AppStore.controlTree` `statusShape:` (line 227,
      beside `statusColor`), `AppSettings.effectiveStatusShape(for:)` mirrored via
      `GhosttyApp.statusSymbolName(for:override:)`, and `AppStore+Status.swift` `shape:` (line 53)
- [x] ➕ SIXTH leg found while auditing the five: `EventFormatter.human` (`agtermctlKit/EventCommands.swift`)
      printed `color=` for a `status` event with no `shape=` twin, so the human-readable `events.read`
      output silently dropped the shape that `ControlEventPayload.shape` carries — this feature's own
      drift, not pre-existing. Emitted `shape=` beside `color=` following the neighbouring fields'
      convention, and extended `EventCommandsTests.formattersCoverEveryKindAndNDJSONIsOneBareEvent` with a
      both-present case (the existing shape-absent status event already covers the omitted leg)
- [x] run the full host-free suite: `cd agtermCore && swift test` — 1765 tests in 73 suites passed
- [x] run the e2e suite (`agtermUITests`), including the settings and control status tests — scoped to the
      two methods this feature added, per the `.claude/rules/ui-tests.md` cadence rule (a full run
      re-executes 77 unrelated classes for ~460 s):
      `ControlSidebarStatusUITests/testSessionStatusShapeValidatesAndReadsBack` and
      `SettingsUITests/testAgentStatusShapePickerPersists`, both passed
- [x] run `make lint` - must report zero findings (`--strict`) — clean
- [x] confirm no source file crossed the 1000-line limit as a result of these edits — largest source is
      `AppStore.swift` at 996 (the plan's one-line `statusShape` addition, from 995); every test file is
      under the 2000-line test budget (largest `AppStoreTests.swift` at 1934)
- ⚠️ HEADROOM NOTE (review): after the review-round test additions the two biggest test files sit at
      `AppStoreTests.swift` 1949 and `ControlDispatcherTests.swift` 1936 — roughly 50/65 lines under the
      HARD 2000-line budget, which the project forbids raising. Not a violation, but the next feature that
      touches either will have to split it by concern first rather than discovering the cap mid-change.

### Task 14: [Final] Update documentation

- [x] confirm README.md, `site/docs.html`, `site/commands.html`, the agent skill and the three rule
      notes are all consistent with the shipped behavior — swept every surface for the mid-flight default
      change and for the six-leg audit. No surviving `ellipsis`/`exclamationmark`/`checkmark` claim, no
      stale "blue" `active` color, no "Default" picker entry and no "nothing changes by default"
      statement anywhere outside the source-accurate note in `.claude/rules/notifications.md` that says
      the marked circles are GONE. The `shape` event-payload field is named in all five places that
      enumerate the `status` payload (README ~211, `reference.md` ~35, `SKILL.md`, `site/commands.html`
      ~525, `site/docs.html`); no doc enumerates `EventFormatter.human`'s field list, so the `shape=`
      arm needed no doc twin. Three real drifts found and fixed, listed below
- [x] ➕ `site/commands.html` line 9 still read "all 64 control commands" — Task 12 corrected the `og:`
      and `twitter:` descriptions and the intro but missed the plain `<meta name="description">`.
      Verified against source: `Command` has 66 cases, 65 public less the UI-test-only `debug.appearance`,
      matching every other count on the page
- [x] ➕ `.claude/rules/menu-actions.md` (~335) still described the attention palette's `StatusGlyph` as
      "the shared `AgentStatus.symbolName` + `GhosttyApp.statusColor(for:)` mapping" — stale twice over
      since Task 7: `symbolName` is no longer a property, and `PaletteItem` now carries `statusColor` and
      `statusShape` which the glyph resolves through `GhosttyApp.statusSymbolName(for:override:)` +
      `.statusColor(for:override:)`. Rewritten to the shipped pair
- [x] ➕ `.claude/rules/control-api.md` still claimed `--shape` has FIVE legs; Task 13 found the sixth
      (`EventFormatter.human` printing `shape=` beside `color=`) and fixed the code without recording it.
      Corrected to SIX, added the formatter to the keep-in-sync audit's CLI point and its test
      (`EventCommandsTests.formattersCoverEveryKindAndNDJSONIsOneBareEvent`)
- [x] update `CLAUDE.md` only if a new cross-cutting pattern was discovered — yes, one: an argument whose
      value rides a control EVENT owes the CLI's human line, not just the payload field, because a
      `ControlEventPayload` field with no `EventFormatter.human` arm is invisible in `agtermctl events`'
      default non-`--json` mode. Added as a keep-in-sync bullet with the six-vs-five miss as its evidence.
      Also fixed CLAUDE.md's own read-back list, which paired `session.status` with
      `statusBlink`/`statusColor` and had not gained `statusShape` for `--shape`
- [ ] move this plan to `docs/plans/completed/` — performed by the orchestrator after the review phases,
      not by this task
- [x] run the full suite one final time (`cd agtermCore && swift test`, `make lint`) - must pass —
      1765 tests in 73 suites passed; `make lint` clean under `--strict`

## Post-Completion

*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification**:

- launch an isolated dev instance (`open -n --env AGTERM_STATE_DIR=<tmp>` with a SHORT `/tmp` socket
  path, never touching the deployed `~/Applications/agterm.app`) and confirm by eye that the six shapes
  read as distinct in the sidebar at the default and at an increased sidebar font size
- confirm the shapes remain legible against both a light and a dark theme, and while blinking
- confirm the SwiftUI glyph in the ⌃P attention palette, the Ctrl-Tab switcher and the attention-bell
  popover matches the sidebar for the same session

**External follow-up**:

- reply on GitHub discussion #277 describing the shipped option, since the reporter raised the
  hue-only-channel and color-blind concerns that motivated it. Draft goes through approval before posting.

---

Smells pre-check: skipped — non-Go project

Plan review (plan-review agent, 2026-07-24): 13 findings, all verified against source and applied —
the missing `.status` event-payload leg (`--color` has five legs, not four), the agent skill being four
files rather than one, the Tasks 6/7/8 test-gate contradiction (resolved by stating the app-target
exemption explicitly), missing `make build` gates on Tasks 1 and 4, three incomplete Files lists,
`ControlSessionStatusUpdate` living in `ControlModes.swift` not `ControlProtocol.swift`,
`SessionSwitcherRow` misnamed as `SessionRowModel`, the `AppStore.swift` 995/1000-line headroom, the
required init default on the new `ControlSessionStatusUpdate` parameter, both `statusColor` sites in
`site/commands.html`, stale doc comments across four tasks, and missing run gates on Tasks 12 and 14.

Default change (maintainer request, after Task 9): the built-in glyph default moved from the three marked
circles (`ellipsis`/`exclamationmark`/`checkmark`) to a PLAIN `circle.fill` for all three states, and the
Settings picker dropped its "Default" entry for a six-glyph, symbol-only list where `circle` stores nil.
Reason: the interior marks do not read at the sidebar's 13pt render size — they are legible only in the
popup — which is the exact complaint the feature exists to answer, so shipping them as the default would
have preserved the problem. Tasks 1, 9 and 13 and the settled decisions above were rewritten to match;
the shipped picker also tints every option with that status's current color (a non-template `NSImage`,
because a menu recolors a template symbol and `.foregroundStyle` does not survive into the popup).
