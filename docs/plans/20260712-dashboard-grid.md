# Dashboard Grid Overlay

## Overview

A per-window modal overlay that shows a user-picked set of live terminal sessions in a grid (max 9,
laid out `ceil(sqrt(n))`). The dashboard is **view-only**: no cell receives input (keyboard or mouse),
the keyboard navigates a highlight between cells, and Enter jumps into the highlighted session
interactively. It is **opened over the control socket** (`agtermctl dashboard <ids…>`) and **closed over
the socket** (`--close`) **or from the keyboard** (Esc, or Enter which also jumps in). Once open, the
keyboard drives it. Font size is controllable over the API: `--font-size <pt>` (absolute) or `--auto-size`
(relative to the Settings default font size, shrinking as the grid grows so dense grids stay readable).

It solves the "watch several agents/builds at once" problem: today you can only see one session (or a
2-pane split) at a time. The dashboard reparents each picked session's live surface into a grid cell —
the same reparent mechanism terminal-zoom already uses, generalized from 1 surface to N, with focus
inverted (zoom focuses its surface; the dashboard focuses none).

## Context (from discovery)

Files/components involved:
- **Reparent precedent**: `agterm/Views/WindowContentView+Zoom.swift` — `deckHostsSurface(session:surface:)`,
  `zoomedSessionTerminal`, `handleZoomTargetChange` (the modal lifecycle: closes palette/search/quick
  terminal on open, restores focus on close). The dashboard generalizes all of this.
- **Surface bridge**: `agterm/Views/TerminalView.swift` — `makeNSView` returns the session-owned
  `GhosttySurfaceView` (`:39`). `isActive:false` only stops auto-focus and resigns first responder if
  held (`:50`); it does **not** disable `mouseDown`/keyboard/first-responder eligibility. So view-only
  requires `.allowsHitTesting(false)` + a separate hit target, not just `isActive:false`.
- **Font machinery** (the correctness crux): there is **no absolute font setter** — only relative
  bindings (`increase/decrease/reset_font_size`, `GhosttySurfaceView.swift:519`) and whole-config
  `update_config` (`:557`, `:574`). A font change round-trips into the model: `reportFontSize` →
  `onFontSizeChange` (`:641`) → `store.setFontSize` (`agtermApp.swift:239`). Reloads reset+re-emit
  `session.fontSize` (`SettingsModel.reloadConfigClearingSessionZoom` → `resetSessionFontSizesAllWindows`;
  `GhosttyApp.reloadConfig` → `reapplySessionConfigIfNeeded`, `:329`). ⇒ a transient dashboard font must be
  a real surface-level override, not a record-restore of `session.fontSize`.
- **Surface resolution**: `Session.addressableSurface` = `surface ?? splitSurface` (`Session.swift:309`)
  exists because a promoted-survivor session has `surface == nil` with the live shell in `splitSurface`
  (`AppStore+Panes.closePrimaryPane`). Dashboard members must resolve through `addressableSurface`, not
  always `\.surface`, and be deduped by resolved UUID.
- **Overlay placement**: `WindowContentView.windowOverlayLayer` (ZStack sibling inset by `titlebarHeight`
  at `zIndex 1`; zoom is higher at `zIndex 10/11`). `deckInteractive` (`WindowContentView.swift:333`)
  currently gates pane/scratch/overlay interactivity on zoom-closed; the dashboard must join that gate.
- **Host-free controller + registry precedent**: `agtermCore/…/TerminalZoom.swift` —
  `@Observable @MainActor public final class TerminalZoomController` + `TerminalZoomRegistry`
  (`register`/`unregister`/`controller(for:)`); `ControlServer` reaches a specific window's controller
  through it (`ControlServer.swift:455`, `+SessionActions.swift:790`).
- **Host-free tree read-back**: `AppStore.controlTree(...)` (`AppStore.swift:181`) threads read-backs as
  app-supplied closures (`quickVisible`, `zoomedSurface`) into `ControlTree(...)`.
- **Control seam**: `ControlProtocol.swift`, `ControlDispatcher.swift` (host-free parse/validate/response +
  the `ControlActions` protocol), `ControlServer*.swift` (app side effects; window resolution via
  `ControlTargetResolver.swift:32` honoring `ControlArgs.window`), `agtermctlKit/MiscCommands.swift`
  (CLI "misc" family; tests in `agtermctlKitTests/CommandsTests.swift`).

Related patterns / facts:
- Pure logic hoisted into `agtermCore`; app target is a thin side-effect adapter (dispatcher-first rule).
- `ControlArgs` has no `fontSize`/`autoSize`/`close` fields yet. `AppSettings.fontSize` is `Double?`
  (nil = ghostty default → resolve to the ghostty default when computing the auto-size base).
- Adding a `ControlActions` requirement leaves the **app target non-building until `ControlServer`
  implements it** — see the build-order note in Task 4.

## Development Approach

- **Testing approach**: **test-alongside** — each task writes the code, then its tests, before moving on.
- **Host-free-first**: `DashboardLayout`, `DashboardController` + registry, the protocol additions, the
  `AppStore.controlTree` closures, and the dispatcher + `ControlActions` method (Tasks 1–5) live in
  `agtermCore`/`agtermctlKit` and are covered by `swift test` in the same task.
- **App-target tasks (6–10)**: the app target (SwiftUI/AppKit/libghostty) is **not** host-free
  unit-testable — verified by XCUITest e2e (Task 11) plus `make build` + `make lint` gates per task, plus a
  manual dev-instance check for the font/reload interplay. Tasks 6–10 note which Task-11 assertion covers
  them. This is the project's real testing model, not a coverage gap.
- **Build-order**: Tasks 3–5 gate on `swift test` (agtermCore/agtermctlKit) — they do NOT build the app.
  The **first `make build` is Task 6**, which implements the `ControlActions.setDashboard` conformance that
  Task 4 declared, so no task ever crosses a red `make build` gate.
- **CRITICAL**: all gates pass before the next task; small focused changes; run gates after each change.
- Backward compatible: all additions are new commands/fields/defaulted closure params; nothing existing
  changes shape.

## Testing Strategy

- **Unit (agtermCore / agtermctlKit)**, in-task for Tasks 1–5:
  - `DashboardLayoutTests` — grid table `n=1…9`; cell placement; `move` clamp in all directions incl. the
    **ragged last row** (`n=3,5,7,8`); `dashboardFontSize` factors × base (13 and 16) + floor at small base.
  - `DashboardControllerTests` — open/close, highlight init + movement (incl. ragged count), member set,
    `fontMode` + applied-size state; registry register/unregister/lookup.
  - `ControlProtocolTests` — round-trip the `dashboard` command + new `ControlArgs`
    (`targets`/`close`/`fontSize`/`autoSize`) + the new `ControlTree` fields (members/highlighted/font/mode).
  - `AppStoreTests` — `controlTree(...)` populate test for the new closures (present + omitted-when-nil).
  - `ControlDispatcherTests` — empty targets→error, both font flags→error, non-positive `--font-size`→error,
    `--close` with ids/font flags→error, `>9`→capped-with-reported-drop, and the arm **routes to
    `ControlActions.setDashboard`** (mock conformer) with the right args (incl. the `window` passthrough).
  - `CommandsTests` (`agtermctlKitTests`) — `dashboard <ids>`, `--font-size N`, `--auto-size`, `--close`,
    `--window`, and the mutually-exclusive/invalid-arg rejections at the CLI layer.
- **e2e (XCUITest, Task 11)** `agtermUITests/DashboardUITests.swift` (`launchForUITest` + control-socket per
  `.claude/rules/ui-tests.md`):
  - open (2–3 sessions) → overlay + correct `dashboard-cell` count; arrows move `dashboard-highlighted`;
    Enter selects+closes (selection changed); Esc closes (selection unchanged);
  - **view-only**: neither typing nor a click into a cell reaches any terminal (no input, cursor stays hollow);
  - **font**: `--auto-size` open → a member's font changed → close → restored; and an explicit config reload
    while open does not strand the dashboard font (override reasserted / cleanly cleared);
  - **busy/resize**: exercise 1/4/9 members with output flowing + a live window resize (no blank cells).

## Progress Tracking

- Mark completed items `[x]` immediately; add discovered tasks with ➕, blockers with ⚠️.
- Keep this plan in sync if scope changes.

## Solution Overview

The dashboard = terminal-zoom's reparent pattern generalized to N surfaces, focus inverted, plus a real
transient font override:

- **Host-free core** (`agtermCore`): `DashboardLayout` (pure grid geometry + highlight nav + auto-size
  font math) and `@Observable @MainActor DashboardController` (per-window state: `members: [UUID]`,
  `highlighted`, `fontMode`, applied-size) + `DashboardControllerRegistry` — all unit-tested.
- **Control path**: one `dashboard` command (open with `targets`, `--close`, `--font-size`/`--auto-size`),
  honoring `--window` (default frontmost). Validated host-free in `ControlDispatcher`, routed to
  `ControlActions.setDashboard(...)`. `ControlServer` resolves ids via `ControlTargetResolver` inside the
  target window, **dedups by resolved UUID**, resolves each to its `addressableSurface`, caps to 9 (reports
  the drop in the response), closes any active zoom, and drives that window's controller through the
  registry. `AppStore.controlTree(...)` gains closures for `dashboardMembers`/`dashboardHighlighted`/
  `dashboardFontSize`/`dashboardFontMode`.
- **Transient font override**: `GhosttySurfaceView` gains `dashboardFontOverride: Double?`. The per-surface
  config composer uses `dashboardFontOverride ?? session.fontSize`; `reapplySessionConfigIfNeeded` includes
  it (so a reload reasserts it); `reportFontSize` does not persist while it is set (so the CELL_SIZE round-
  trip can't write the dashboard size into `session.fontSize`). Clearing the override rebuilds from the
  session model. No record-restore dictionary.
- **App-side rendering**: a `windowOverlayLayer` branch renders `DashboardView` — a grid of cells, each a
  `TerminalView` of the member's resolved `addressableSurface` slot (`\.surface`, or `\.splitSurface` for a
  promoted survivor) with `.allowsHitTesting(false)`, a stable `.id`, a dimmed name caption, an accent
  highlight ring, and a transparent hit target above for highlight/double-click. A generalized
  `deckHostsSurface` makes the eager deck yield each member's hosted surface (`Color.clear` placeholder).
  An AppKit key-catcher owns first responder and consumes all keys — no cell is ever first responder, so
  every cursor draws hollow.

Key decisions:
- **Members resolve via `addressableSurface`, deduped** — never `\.surface` blindly (would spawn a new
  shell for a promoted survivor) and never the same NSView twice.
- **Font via transient override, not record-restore** — the only way to apply a temporary size without
  persisting it or being clobbered by a reload.
- **View-only = hit-testing off + key-catcher + `deckInteractive` gate + modal lifecycle** — a click must
  not focus a terminal; opening also closes palette/search/quick-terminal/switcher and pauses auto-follow.
- **Zoom ↔ dashboard mutually exclusive both ways.**
- **`--window` honored** (default frontmost); `>9` capped with a reported drop.

## Technical Details

`DashboardLayout` (pure, `agtermCore`):
- `grid(count:) -> (cols,rows)` = `ceil(sqrt(n))` / `ceil(n/cols)`; `count` clamped `1…9` at the call site.
- `cell(index:cols:) -> (col,row)` row-major; `move(from:direction:cols:count:) -> Int` clamped 2-D nav
  (no wrap), `count` clamps into a partial last row.
- `dashboardFontSize(cols:rows:base:) -> Double` = `max(minFont, (base * factor(cols,rows)).rounded())`;
  factors `1×1=1.00, 2×1=0.85, 2×2=0.75, 3×2=0.62, 3×3=0.55`, `minFont` floor (e.g. 6).

`DashboardController` (`@Observable @MainActor public final class`) + `DashboardControllerRegistry`:
- `members: [UUID]`, `highlighted: UUID?`, `fontMode: DashboardFontMode` (`.untouched`/`.fixed(Double)`/
  `.auto`), `appliedFontSize: Double?` (set by the wiring when it applies, for read-back).
- `open(members:highlighted:fontMode:)`, `close()`, `move(_:)`, `isOpen`. Registry mirrors `TerminalZoomRegistry`.

`ControlProtocol`:
- `Command.dashboard`; `ControlArgs`: `close/fontSize/autoSize` (ids reuse `targets`, window reuses `window`).
- `ControlTree`: `dashboardMembers: [String]?`, `dashboardHighlighted: String?`, `dashboardFontSize: Double?`
  (applied absolute size, nil = untouched), `dashboardFontMode: String?` (`auto`/`fixed`/`untouched`) —
  LIVE, `tree`-only. `AppStore.controlTree(...)` gains four defaulted closure params.

`ControlDispatcher` (host-free) `dashboard` arm → `ControlActions.setDashboard(targets:window:close:fontMode:)`:
- validation: not-`--close` + empty targets → error; `--font-size` + `--auto-size` → error; non-finite/
  non-positive `--font-size` → error; `--close` with ids/font flags → error; `>9` unique targets → cap to
  first 9, report the dropped count in the response message.

`ControlServer` (app): `setDashboard` resolves ids via `ControlTargetResolver` inside `args.window ?? frontmost`,
dedups by resolved UUID, drops unresolved (reported), resolves each to `addressableSurface`, closes any
active zoom, drives that window's `DashboardController`. Tree-build supplies the four read-back closures.

`GhosttySurfaceView.dashboardFontOverride: Double?` — composer uses `override ?? session.fontSize`;
`reapplySessionConfigIfNeeded` reasserts it; `reportFontSize` suppressed while set; clearing rebuilds from model.

Wiring (font): on open, for each member surface compute the target (`.auto` → `DashboardLayout.dashboardFontSize`
with base `AppSettings.fontSize ?? ghosttyDefault`; `.fixed` → value; `.untouched` → leave nil), set the
override + reapply; record `controller.appliedFontSize`. On close, clear the override + reapply.

## What Goes Where

- **Implementation Steps** (`[ ]`): all code, tests, in-repo docs.
- **Post-Completion** (no checkboxes): manual dev-instance verification (font/reload interplay), pty-resize
  documentation note, release-time site `softwareVersion` bump.

## Implementation Steps

### Task 1: DashboardLayout — pure grid, navigation, auto-size math

**Files:**
- Create: `agtermCore/Sources/agtermCore/DashboardLayout.swift`
- Create: `agtermCore/Tests/agtermCoreTests/DashboardLayoutTests.swift`

- [x] `grid(count:)`, `cell(index:cols:)`, `move(from:direction:cols:count:)`, `dashboardFontSize(cols:rows:base:)`
      — pure, `Int`/`Double` only, tunable factor/floor constants + the direction type
- [x] tests: grid table `n=1…9` + cell placement
- [x] tests: `move` clamp every direction incl. ragged last row (`n=3,5,7,8`) and full grids (`n=2,4,9`)
- [x] tests: `dashboardFontSize` factors × base (13, 16) + floor at small base
- [x] run `cd agtermCore && swift test` + `make lint` — pass before Task 2

### Task 2: DashboardController + registry — host-free observable state

**Files:**
- Create: `agtermCore/Sources/agtermCore/DashboardController.swift`
- Create: `agtermCore/Tests/agtermCoreTests/DashboardControllerTests.swift`

- [x] `@Observable @MainActor public final class DashboardController` with `members`/`highlighted`/`fontMode`/
      `appliedFontSize` + `DashboardFontMode`; `open`/`close`/`move`/`isOpen`; highlight init prefers a
      supplied member else first
- [x] `DashboardControllerRegistry` (mirror `TerminalZoomRegistry`: `shared`/`register`/`unregister`/`controller(for:)`)
- [x] tests: open/close, member set, highlight init, movement (incl. ragged count), fontMode/applied-size state
- [x] tests: registry register/unregister/lookup
- [x] run `cd agtermCore && swift test` + `make lint` — pass before Task 3

### Task 3: ControlProtocol + AppStore.controlTree — command, args, tree read-back

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreTests.swift`

- [x] `Command.dashboard`; add `close/fontSize/autoSize` to `ControlArgs` (init + docs)
- [x] add `dashboardMembers`/`dashboardHighlighted`/`dashboardFontSize`/`dashboardFontMode` to `ControlTree`
      (init + docs matching `zoomedSurface` LIVE/`tree`-only wording)
- [x] add four defaulted closure params to `AppStore.controlTree(...)` and thread into `ControlTree(...)`
- [x] tests: `ControlProtocolTests` round-trips (request + tree fields, present + omitted-when-nil)
- [x] tests: `AppStoreTests` populate test for the new closures
- [x] run `cd agtermCore && swift test` + `make lint` — pass before Task 4

### Task 4: ControlDispatcher — validation, response, ControlActions.setDashboard

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherTests.swift`

- [x] add `setDashboard(targets:window:close:fontMode:) -> ControlResponse` to the `ControlActions` protocol
      (**note**: this leaves the app target non-building until Task 6 implements it — Tasks 4–5 gate on
      `swift test` only; the first `make build` is Task 6)
- [x] `dashboard` dispatch arm: reject empty-targets-without-`--close`, both font flags, non-positive
      `--font-size`, `--close`+ids/font; cap `>9` with a reported drop; build `fontMode`; route to `setDashboard`
- [x] tests (mock `ControlActions`): each rejection, the cap-with-drop, and that a valid open/close routes to
      `setDashboard` with the right args incl. `window`
- [x] run `cd agtermCore && swift test` + `make lint` — pass before Task 5

### Task 5: agtermctl — dashboard CLI subcommand

**Files:**
- Modify: `agtermCore/Sources/agtermctlKit/MiscCommands.swift`
- Modify: `agtermCore/Sources/agtermctlKit/Commands.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/CommandsTests.swift`

- [x] add a `dashboard` `ParsableCommand` in `MiscCommands.swift` (family-grouped): `dashboard <ids…>
      [--font-size <pt>] [--auto-size] [--window <id>]` and `dashboard --close [--window <id>]`
- [x] map to `ControlArgs`; reject `--font-size`+`--auto-size`, non-positive `--font-size`, and `--close`+ids/font
      at the CLI layer; help text covers open/close/font/window
- [x] register in the root tree (`Commands.swift`)
- [x] tests in `CommandsTests.swift` for each form + the invalid-arg rejections
- [x] run `cd agtermCore && swift test` + `make lint` — pass before Task 6

### Task 6: ControlServer — setDashboard side effect + tree read-back closures

**Files:**
- Modify: `agterm/Control/ControlServer.swift` (or `ControlServer+SessionActions.swift`)

- [x] implement `ControlActions.setDashboard`: resolve ids via `ControlTargetResolver` inside `args.window ??
      frontmost`, dedup by resolved UUID (preserve order), drop+report unresolved, resolve each to its
      `addressableSurface`, close any active zoom (`TerminalZoomRegistry`), drive that window's
      `DashboardController` via `DashboardControllerRegistry` (open members/highlighted/fontMode, or `close()`)
- [x] supply `dashboardMembers`/`dashboardHighlighted`/`dashboardFontSize`/`dashboardFontMode` closures at the
      `controlTree(...)` build site (read from the target window's controller via the registry)
- [x] first `make build` — restores app conformance; behavior asserted by Task 11 e2e
- [x] run `cd agtermCore && swift test` + `make build` + `make lint` — pass before Task 7

### Task 7: GhosttySurfaceView — transient dashboard font override

**Files:**
- Modify: `agterm/Ghostty/GhosttySurfaceView.swift`
- Modify: `agterm/Ghostty/GhosttyApp.swift` (if `reapplySessionConfigIfNeeded` lives there / needs the override)

- [x] add `dashboardFontOverride: Double?`; the per-surface config composer uses `dashboardFontOverride ??
      session.fontSize`
- [x] `reapplySessionConfigIfNeeded` reasserts the override (its guard also fires when the override is set)
- [x] `reportFontSize` does not call `onFontSizeChange` while the override is set (so CELL_SIZE can't persist
      the dashboard size into `session.fontSize`); clearing the override rebuilds from the session model
- [x] correctness asserted by the Task 11 font e2e (auto-size + explicit reload while open + close-restore);
      gate on `make build` + `make lint`
- [x] run `make build` + `make lint` — pass before Task 8

### Task 8: DashboardView — grid overlay, cells, key-catcher

**Files:**
- Create: `agterm/Views/DashboardView.swift`

- [x] render the grid from `DashboardLayout.grid(count:)`; each cell a `TerminalView` of the member's resolved
      `addressableSurface` slot (`\.surface`, or `\.splitSurface` for a promoted survivor) with
      `isActive:false, deckVisible:false, reportsFocusChange:false`, `.allowsHitTesting(false)`, and a stable
      `.id` (e.g. `"\(session.id)-dashboard"`)
- [x] a transparent hit target above each cell for click-highlight / double-click-enter (the terminal itself
      takes no hits)
- [x] dimmed `displayName` caption per cell + accent highlight ring on the highlighted cell
- [x] AppKit key-catcher owning first responder that **consumes all keys**: arrows→`controller.move`,
      Enter→select+close, Esc→close, everything else swallowed (never leaks to a terminal)
- [x] no animation on grid geometry / open / close
- [x] a11y ids: `dashboard`, `dashboard-cell`, `dashboard-highlighted`
- [x] behavior asserted by Task 11 e2e; gate on `make build` + `make lint`
- [x] run `make build` + `make lint` — pass before Task 9

### Task 9: WindowContentView wiring — overlay, deck yield, interactivity, font, exclusivity

**Files:**
- Create: `agterm/Views/WindowContentView+Dashboard.swift`
- Modify: `agterm/Views/WindowContentView.swift` (own + register/unregister the `DashboardController`; overlay
  branch; `deckInteractive` gate; call the generalized `deckHostsSurface`)
- Modify: `agterm/Views/WindowContentView+Zoom.swift` (generalize `deckHostsSurface` to exclude zoom-owned
  OR dashboard-hosted surfaces, matched on the member's resolved surface kind)

- [x] own a per-window `DashboardController`; `register`/`unregister` with `DashboardControllerRegistry` on
      window appear/disappear (restore any font override before unregister)
- [x] `windowOverlayLayer` branch renders `DashboardView` when `controller.isOpen` (inset by `titlebarHeight`,
      `zIndex 1`, below the titlebar — never a body-level `.overlay`)
- [x] generalize `deckHostsSurface`: the eager deck renders a `Color.clear` placeholder for each member's
      hosted surface (union with the existing zoom exclusion)
- [x] gate `deckInteractive` (`WindowContentView.swift:333`) to also require the dashboard closed (kills pane
      focus, scratch/overlay auto-focus, drag registration, background-click handling while open)
- [x] modal lifecycle on open (mirror `handleZoomTargetChange`): close palette/search/quick-terminal/switcher,
      pause auto-follow
- [x] reciprocal exclusivity: `.onChange(of: terminalZoom.target)` — a zoom becoming active while the
      dashboard is open closes the dashboard
- [x] font apply/clear: on open set each member surface's `dashboardFontOverride` from `fontMode`
      (`.auto` via `DashboardLayout.dashboardFontSize`, base `AppSettings.fontSize ?? ghosttyDefault`;
      `.fixed`; `.untouched` skip), reapply, and record `controller.appliedFontSize`; on close clear + reapply
      (driven off `.onChange(of: dashboard.members)` so a retarget re-sizes; `AppSettings.fontSize` read via
      `actions.settingsModel?.settings.fontSize`, nil → 13.0 ghostty default)
- [x] focus/exit: Enter→`selectSession(highlighted)`+close+`focusActiveSession`; Esc→close+`focusActiveSession`
      restoring the prior session; verify no cell holds first responder (key-catcher owns it, terminals
      `allowsHitTesting(false)`); added public `DashboardController.highlight(_:)` + unit test for onHighlight
- [x] keep new code in `WindowContentView+Dashboard.swift`; if `WindowContentView.swift` nears the 1000-line
      cap, ASK before relocating existing code — do not bump the swiftlint limit
      (WindowContentView.swift = 986 lines, no relocation needed)
- [x] behavior asserted by Task 11 e2e; gate on `make build` + `make lint`
- [x] run `make build` + `make lint` — pass before Task 10

### Task 10: (reserved) — split Task 9 if it grows

- [x] N/A - Task 9 stayed cohesive: WindowContentView.swift is 986 lines (under the 1000 cap) with only
      the @State controller + overlay call + thin onChange/lifecycle hooks; all logic lives in
      WindowContentView+Dashboard.swift (147 lines). No further split needed.

### Task 11: End-to-end XCUITests

**Files:**
- Create: `agtermUITests/DashboardUITests.swift`

- [ ] follow `.claude/rules/ui-tests.md` (`launchForUITest`, control-socket driving, occlusion-timeout note)
- [ ] open (2–3 sessions) → overlay + correct `dashboard-cell` count
- [ ] arrows move `dashboard-highlighted`; Enter selects+closes (selection changed); Esc closes (unchanged)
- [ ] view-only: neither typing nor a click into a cell reaches a terminal
- [ ] font: `--auto-size` open → member font changed → close → restored; explicit config reload while open
      doesn't strand the dashboard font
- [ ] busy/resize: 1/4/9 members with output flowing + a live window resize (no blank cells)
- [ ] run the e2e scheme + `cd agtermCore && swift test` + `make build` + `make lint` — pass before Task 12

### Task 12: Keep-in-sync documentation surfaces

**Files:**
- Modify: `agterm/Resources/agent-skill/SKILL.md`, `reference.md`, `examples.md`, `troubleshooting.md` (as
  relevant) — the SINGLE source of truth; never edit installed copies
- Modify: `README.md`
- Modify: `site/docs.html`, `site/index.html`
- Modify: `.claude/rules/control-api.md`, `.claude/rules/libghostty.md`

- [ ] document `dashboard` (open/close, `--font-size`/`--auto-size`, `--window`, view-only nav, max 9 +
      reported drop) in the agent skill + bump its command count; add the four `tree` read-backs to the reference
- [ ] update `README.md` + `site/docs.html` (mirror) + `site/index.html` features grid
- [ ] `.claude/rules/control-api.md`: add the command, bump the catalog count (currently 59 → 60; verify live)
- [ ] `.claude/rules/libghostty.md`: add the dashboard reparent/overlay/view-only + transient-font-override +
      zoom↔dashboard-exclusivity + pty-resize notes
- [ ] do NOT touch `CHANGELOG.md` (release-only)
- [ ] run `make lint` — pass before Task 13

### Task 13: Verify acceptance criteria

- [ ] max 9 cells, `ceil(sqrt)` grid; `>9` capped with reported drop; explicit ids only; `--window` honored
      (default frontmost); unresolved ids reported; duplicate ids deduped
- [ ] view-only: no cell takes first responder or hits; arrows navigate (incl. ragged); Enter jumps in; Esc
      closes + restores focus; palette/search/quick/switcher closed + auto-follow paused on open
- [ ] members resolve via `addressableSurface` (promoted survivor shows the live shell, not a new one)
- [ ] font: `--font-size`/`--auto-size` (relative to Settings base, nil→ghostty default) apply via the
      transient override; both-flags/non-positive/`--close`+flags → error; reload while open doesn't strand;
      restored on close; never persisted to `session.fontSize`
- [ ] `tree` reports members/highlighted/font/mode; zoom ↔ dashboard mutually exclusive both ways
- [ ] run full suite: `cd agtermCore && swift test`, `make build`, the e2e scheme, `make lint` (zero findings)

### Task 14: Finalize documentation and archive plan

- [ ] confirm README / agent skill / `site/` / `.claude/rules` reflect shipped behavior
- [ ] update `CLAUDE.md` only if a new cross-subsystem pattern emerged (the N-surface reparent generalization
      + the transient-font-override mechanism are candidates)
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

*Manual / external — no checkboxes.*

**Manual verification:**
- Isolated dev instance (per CLAUDE.md — short `/tmp` `AGTERM_STATE_DIR`, copy the user's config in). Drive
  `agtermctl dashboard <ids> --auto-size`: confirm the live grid renders, cells are view-only (typing AND
  clicking do nothing), arrows/Enter/Esc behave, fonts restore on close. Then, with the dashboard open,
  trigger File ▸ Reload and a Settings font change — confirm the dashboard font is not stranded and restores
  cleanly. Manually inspect scrollback after the close-time font increase (the known blank-drawable class a
  buffer read can't detect). Do NOT touch the deployed `~/Applications/agterm.app`.
- Note the unavoidable pty-resize behavior: opening/closing the dashboard resizes each member's pty to/from
  its cell, so programs receive resize events and may redraw — "view-only" means no input, not no process
  effect. Documented in `.claude/rules/libghostty.md` (Task 12).
- Eyeball the auto-size factors at a couple of Settings base sizes; tune the constants if a 3×3 reads off.

**Release-time (not part of this plan):**
- Bump `softwareVersion` in `site/index.html` JSON-LD when the release carrying this ships.

---
Smells pre-check: skipped — non-Go project
Plan-review (auto): 12 findings addressed (registry Tasks 2/6/9, host-free `AppStore.controlTree` + populate
test Task 3, explicit `ControlActions.setDashboard` Tasks 4/6, ragged-grid tests Tasks 1/2, `@MainActor`
controller, reciprocal zoom exclusivity, CLI in Misc/CommandsTests, cell `.id`, close-path wording).
Codex (auto): folded in all material findings — view-only hit-testing + modal lifecycle + `deckInteractive`
gate (Task 8/9), transient `dashboardFontOverride` replacing record-restore (Task 7/9), dedup +
`addressableSurface` resolution (Task 6/8/9), fuller read-back (`dashboardFontMode`) + validation
(non-positive font / `--close`+flags) + honor `--window`, and hardening (no animation, busy/resize e2e,
scrollback/pty-resize notes). Build-order made explicit (first `make build` = Task 6).
