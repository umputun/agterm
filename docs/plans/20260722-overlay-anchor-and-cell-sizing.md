# Overlay 9-Point Anchor Positioning + Exact Cols/Rows Sizing

## Overview

Floating (non-full) session overlays today support only a single `--size-percent N` (1–100), applied as
one uniform fraction to BOTH width and height, and are always centered in the pane. This adds two
capabilities to floating overlays, driven entirely over the control channel:

1. **Exact cols×rows sizing** — `session.overlay.open`/`.resize` gain `--cols N --rows M`, sizing the
   floating panel to an exact terminal grid via the surface's live cell metrics
   (`ghostty_surface_size()`), as an alternative to `--size-percent`.
2. **9-point anchor positioning** — `--anchor <pos>` places the floating panel at one of nine positions
   (`top-left · top · top-right · left · center · right · bottom-left · bottom · bottom-right`), default
   `center` (today's behavior).

Both are **adaptive/clamped**: a cols×rows (or percent) request larger than the pane is clamped to fit
whole cells, and a 9-point anchor is always fully on-screen by construction (the panel is ≤ pane after
clamp, so SwiftUI `Alignment` places it against an edge or centered without any manual position math).

Benefits: scripts can size an overlay to fit a known TUI layout or an inline image at an exact cell size,
and can park it out of the way (corner) instead of dead-center over the session.

## Review Revisions (incorporated before implementation)

This plan was reviewed by the `plan-review` agent and by Codex (GPT-5.6). Both findings and three
maintainer decisions are folded in below:

- **Retina pixel↔point conversion (Codex, blocking).** `ghostty_surface_size()` returns **backing
  pixels** (`GhosttySurfaceView.updateMetalLayerSize` pushes `convertToBacking(bounds)` ×
  `backingScaleFactor` to libghostty, `GhosttySurfaceView.swift:783`), while `GeometryReader` and
  `WindowGeometry.Size` are **points**. Cell metrics MUST be converted px→points at the app boundary
  before entering the host-free resolver, or cols×rows panels come out ~2× on Retina.
- **Reactive metrics lifecycle (Codex, blocking).** `Session.overlaySurface` is `@ObservationIgnored`
  and assigned imperatively in `TerminalView.makeNSView`, so reading metrics from the SwiftUI view body
  does not invalidate the panel. Metrics flow through **observed** live-only `Session` state, refreshed
  app-side on `GHOSTTY_ACTION_CELL_SIZE` (`GhosttyCallbacks.swift:50`), surface realization, and
  backing-scale changes; the view consumes the observed value.
- **Task 2 compile-break + missed callers (both reviews, blocking).** Removing
  `Session.overlaySizePercent` orphans readers the original Task 2 file list missed:
  `AppStore.controlTree` (`AppStore.swift:215`), the two editor-overlay callers
  `AppActions.swift:357`/`:390` (`sizePercent: 95`), `TerminalZoomTests.swift:104`, and the
  sizePercent-heavy `AppStorePaneTests.swift`. All are migrated inside Task 2.
- **Decision 1 — read-back reports REQUESTED + APPLIED.** `tree` carries the requested cols/rows (the
  record-then-restore key) AND the actual applied grid after clamping (so a script can detect it was
  clamped), the applied grid supplied app-side from the realized overlay surface.
- **Decision 2 — anchor is PRESERVED and ALWAYS REPORTED.** A `--full` round-trip keeps the anchor (only
  `closeOverlay` resets it to center), and `overlayAnchor` is emitted on `tree` whenever an overlay is
  open (including full), so there is no hidden anchor state.
- **Decision 3 — open validation is TIGHTENED to match resize (intentional behavior change).** Today
  `session overlay open` does not validate `--size-percent` (the store silently clamps 250→100, 0→1).
  Open now hard-errors on an out-of-range percent / bad cols·rows / bad anchor in the dispatcher + CLI
  `validate()`, exactly like resize. The store keeps its defensive clamp for internal callers; the
  wire/CLI change is documented, not silent.
- **Stronger e2e (Codex).** Wire/echo round-trips alone would pass even with the Retina bug — the e2e
  additionally runs `stty size` inside the overlay to assert the actual grid, and asserts the floating
  panel's frame vs the pane via an accessibility id.
- **Exactness scope.** Sizing is best-effort-exact from correctly-scaled metrics; the derived padding
  (`width_px − columns·cell_width_px`) is treated as an estimate, and the **applied** read-back exposes
  any residual drift or clamp rather than hiding it. A bounded post-realization correction loop is
  explicitly OUT of scope for v1 (revisit only if manual verification shows real drift).

## Context (from discovery)

- **Files/components involved:**
  - Host-free model + protocol: `agtermCore/Sources/agtermCore/` — `Session.swift`, `AppStore.swift`
    (`controlTree`), `AppStore+Panes.swift` (`openOverlay`/`resizeOverlay`), `ControlProtocol.swift`
    (`ControlArgs`, `ControlSessionNode`), `ControlDispatcher.swift`
    (`ControlActions`, `ControlSessionOverlayOpenOptions`, validation/routing). New file:
    `OverlayLayout.swift` (the pure size/anchor model + resolver).
  - App target: `agterm/AppActions.swift` (editor-overlay callers), `agterm/Control/ControlServer+SessionActions.swift`
    (overlay arms), `agterm/Ghostty/GhosttySurfaceView.swift` + `agterm/Ghostty/GhosttyCallbacks.swift`
    (cell-metrics readout + `CELL_SIZE` signal), `agterm/Views/WindowContentView.swift` (`overlayPanel`
    rendering).
  - CLI: `agtermCore/Sources/agtermctlKit/SessionCommands.swift` (`Overlay` subcommand tree).
  - Docs/keep-in-sync: `agterm/Resources/agent-skill/{reference.md,examples.md,SKILL.md}`,
    `site/commands.html`, `site/docs.html`, `README.md`, `.claude/rules/control-api.md`.
  - Tests: `agtermCore/Tests/agtermCoreTests/` (`OverlayLayoutTests.swift` new, `SessionTests.swift`,
    `AppStorePaneTests.swift`, `TerminalZoomTests.swift`, `ControlProtocolTests.swift`,
    `ControlDispatcherTests.swift`, `MockControlActions.swift`),
    `agtermCore/Tests/agtermctlKitTests/CommandsTests.swift`,
    `agtermUITests/ControlOverlaySplitUITests.swift`.

- **Related patterns found:**
  - **Dispatcher-first control commands** — host-free arg validation, error strings, and response shape
    live in `ControlDispatcher.dispatch(_:)` (`ControlDispatcher.swift:489-522` already owns overlay
    open/resize); `ControlServer` supplies only side effects via `ControlActions`.
  - **State-mutating command owes a read-back field** on `ControlSessionNode` — existing pair is
    `session.overlay.resize` ↔ `overlaySizePercent`; extended here with requested + applied cols/rows and
    the anchor.
  - **App-supplied live values in `controlTree`** — the `fontSize`/`splitFontSize`/`scratchFontSize`
    precedent (app-side closures read a live surface value the host-free tree can't). The applied overlay
    grid follows the same idea, but simpler: the app writes the realized grid into observed `Session`
    state, which `controlTree` reads directly.
  - **`ghostty_surface_size()`** (`GhosttyKit.xcframework/.../ghostty.h:482`) returns
    `columns`/`rows`/`width_px`/`height_px`/`cell_width_px`/`cell_height_px` in **backing pixels** — the
    cell + padding + realized-grid source, live and font-accurate.
  - **`GHOSTTY_ACTION_CELL_SIZE`** (`GhosttyCallbacks.swift:50`) — fires on font/DPI change; the trigger
    to refresh the observed metrics.
  - **NSSplitView-overrun invariant** (`.claude/rules/libghostty.md`) — `overlayPanel` is an
    always-present, constant-shape `sessionDetail` ZStack sibling at `.zIndex(3)`; its inner content is
    gated inside `if session.overlayActive` (`WindowContentView.swift:531-564`). Changing frame size and
    ZStack `alignment` does NOT change child count and must not introduce anchor-specific `if`/`switch`
    view branches, so the split is never re-hosted.
  - **CoreGraphics-free `agtermCore`** — the resolver uses the Double-backed `WindowGeometry.Size`, never
    `CGSize`; the app converts to/from `CGFloat` at the call site.

- **Dependencies identified:** overlay state is **live-only** (absent from `SessionSnapshot`), so there is
  NO persistence/restore migration. No new `Command` case (both capabilities are new args on the existing
  `session.overlay.open`/`.resize`), so the public command count stays **64**.

## Development Approach

- **Testing approach**: Regular (code first, then tests) — per user selection. Tests are still a required
  deliverable of every task and must pass before the next task starts.
- complete each task fully before moving to the next; make small, focused changes.
- **CRITICAL: every code-change task MUST include new/updated tests** (unit tests for new/modified
  functions, new cases for new code paths, success + error scenarios).
- **CRITICAL: all tests must pass before starting the next task.**
- **Intermediate build state (expected):** the **app target** intentionally does not compile from the
  middle of Task 2 through Task 5 (removed/changed overlay symbols in `WindowContentView`/`ControlServer`).
  Tasks 2–4 gate on `cd agtermCore && swift test` (the host-free module, which DOES compile after each
  task); the app build is first re-verified in Task 5. This is by design, not a regression.
- **CRITICAL: update this plan file when scope changes during implementation.**
- run `swift test`, the app build, and `make lint` as applicable; keep backward compatibility EXCEPT the
  documented Decision-3 open-validation tightening (existing `--size-percent`/`--full` behavior and the
  default-center anchor are otherwise unchanged).

## Project-Rule Gates (agterm — verify against every task before marking complete)

- **Module boundary**: `agtermCore` stays host-free — no GhosttyKit/AppKit/Metal AND no CoreGraphics.
  The layout model, resolver, and `OverlayCellMetrics` use `WindowGeometry.Size` (Double, in **points**).
  Reading pixel metrics, converting px→points, applying the SwiftUI frame/alignment, and populating the
  applied grid are app-target only.
- **Dispatcher-first**: all overlay arg validation, error strings, and one-of rules live in
  `ControlDispatcher`; `ControlServer` arms only resolve the target and call the store.
- **Read-back obligation (Decision 1)**: the write path owes matching read-back on `ControlSessionNode`,
  populated in `AppStore.controlTree`, omitted from JSON when nil, covered by round-trip
  `…RoundTrips`/`…OmitsWhenNil` tests + a `controlTree` populate test. Requested cols/rows/anchor are the
  restore key; applied cols/rows expose clamp/drift.
- **Anchor state (Decision 2)**: anchor preserved across `--full`; reset only on `closeOverlay`; emitted
  on `tree` whenever an overlay is open.
- **Open validation (Decision 3)**: dispatcher + CLI hard-error on out-of-range percent / bad cols·rows /
  bad anchor for BOTH open and resize (documented tightening); the store keeps a defensive clamp.
- **Options struct for 4+ params** (CLAUDE.md): overlay-open params go through an `OverlayOpenOptions`
  struct, not a 7-positional-arg signature; both internal callers (`AppActions.swift:357/390`) migrate.
- **NSSplitView-overrun invariant**: keep `overlayPanel`'s ZStack child count constant; only frame
  parameters and ZStack `alignment` may change; no anchor-specific view branches.
- **One test file per source file**; **keep-in-sync (HARD)**: agent-skill (incl. `SKILL.md`) +
  `site/commands.html` + README + `site/docs.html` + `.claude/rules/control-api.md` in lockstep (Task 8);
  `CHANGELOG.md` is release-only — do NOT touch it here.

## Testing Strategy

- **unit (agtermCore, `swift test`)**: resolver clamp/anchor + 1× / 2× (Retina) scaling + rounding +
  degenerate guards (`OverlayLayoutTests`); Session predicates + anchor-preserve-on-full + close-reset
  (`SessionTests`); store open/resize incl. migrated sizePercent/clamp tests (`AppStorePaneTests`,
  `TerminalZoomTests`); wire round-trips incl. applied + anchor (`ControlProtocolTests`); dispatcher
  validation incl. tightened open (`ControlDispatcherTests`); CLI mapping/validate (`CommandsTests`).
- **e2e (XCUITest, `ControlOverlaySplitUITests`)**: open with cols/rows/anchor, resize, re-anchor,
  read-back off `tree` (requested + applied + anchor); **actual grid via `stty size` marker**; **floating
  panel frame vs pane via accessibility id**; error cases; repeated re-anchor/full/cell transitions while
  a split is visible (NSSplitView guard). Must pass before the next task.

## Progress Tracking

- mark completed items with `[x]` immediately; add ➕ for new tasks, ⚠️ for blockers; keep the plan in
  sync with actual work.

## Solution Overview

- **Host-free model** (`agtermCore/OverlayLayout.swift`):
  - `OverlaySize` enum: `.full` | `.percent(Int)` | `.cells(cols: Int, rows: Int)` — replaces stored
    `Session.overlaySizePercent: Int?`.
  - `OverlayAnchor` string enum (9 cases, `CaseIterable`, default `.center`) with host-free
    `unitX`/`unitY` ∈ {0, 0.5, 1}.
  - `OverlayCellMetrics` — Double-backed, **in points** (`cellWidth`, `cellHeight`, `padWidth`,
    `padHeight`); the app converts pixel metrics ÷ backing scale before constructing it.
  - `OverlayLayout.panelSize(_:pane:cell:) -> WindowGeometry.Size` — pure resolver: `.full` → pane;
    `.percent(p)` → `pane * p/100`; `.cells(c,r)` → whole-cell clamp against the pane (`usedCols =
    max(1, min(c, floor((pane.w − padW)/cellW)))`, width `= usedCols·cellW + padW`; same for rows),
    with explicit guards for nil metrics (fallback to pane), zero/invalid cell size, and pane smaller
    than one cell + padding.
- **Session state** (all observed / host-free): `overlaySize: OverlaySize = .full`, `overlayAnchor:
  OverlayAnchor = .center`, `overlayCellMetrics: OverlayCellMetrics?` (points; app-maintained, drives
  the view), `overlayAppliedCols: Int?`/`overlayAppliedRows: Int?` (app-maintained realized grid, for
  read-back). `fullOverlayActive` = `overlayActive && overlaySize == .full`; `floatingOverlayActive` =
  `overlayActive && overlaySize != .full`.
- **Store API**: `openOverlay(_:options:)` takes `OverlayOpenOptions` (command/cwd/wait/size/anchor/
  backgroundColor); `resizeOverlay(_:size:anchor:)` with optional size/anchor (nil = keep current) so a
  resize, a re-anchor-in-place, or both are one call. `--full` keeps the anchor; `closeOverlay` resets
  size→`.full`, anchor→`.center`, metrics/applied→nil.
- **Wire**: `ControlArgs` gains `cols`/`rows`/`anchor`; `ControlSessionNode` gains
  `overlayCols`/`overlayRows` (requested, cells mode only), `overlayColsApplied`/`overlayRowsApplied`
  (realized grid, any floating overlay), `overlayAnchor` (any open overlay); `overlaySizePercent` kept.
- **Dispatcher**: validates one-of {`--size-percent`, `--cols`+`--rows`} for open (no `--full` on open —
  absence of a size = full) and one-of {`--full`, `--size-percent`, `--cols`+`--rows`} or none for
  resize; cols·rows paired; percent 1…100 hard-error; anchor one of nine; anchor requires a floating
  size on open; resize needs at least one of {size, anchor}; `--full` ⊥ `--anchor`.
- **App rendering**: `GhosttySurfaceView.overlayPixelMetrics()` reads `ghostty_surface_size()`; the app
  converts px→points via `backingScaleFactor` and writes `session.overlayCellMetrics` (on realization,
  `CELL_SIZE`, backing-scale change) and `session.overlayAppliedCols/Rows` (from the realized grid).
  `overlayPanel` sizes via `OverlayLayout.panelSize(session.overlaySize, pane: geo.size, cell:
  session.overlayCellMetrics)` and positions via `ZStack(alignment: floating ? anchor.swiftUIAlignment :
  .center)`; a stable accessibility id on the floating panel enables the e2e frame assertion.

## Technical Details

**Host-free types (`agtermCore/Sources/agtermCore/OverlayLayout.swift`):**

```swift
public enum OverlaySize: Equatable, Sendable {
    case full
    case percent(Int)                 // caller pre-validates 1...100
    case cells(cols: Int, rows: Int)  // caller pre-validates cols>=1, rows>=1
}

public enum OverlayAnchor: String, CaseIterable, Sendable {
    case topLeft = "top-left", top, topRight = "top-right"
    case left, center, right
    case bottomLeft = "bottom-left", bottom, bottomRight = "bottom-right"
    public var unitX: Double { /* 0 | 0.5 | 1 */ }
    public var unitY: Double { /* 0 | 0.5 | 1 */ }
}

public struct OverlayCellMetrics: Equatable, Sendable {   // POINTS, not pixels
    public let cellWidth: Double, cellHeight: Double, padWidth: Double, padHeight: Double
    public init(cellWidth: Double, cellHeight: Double, padWidth: Double, padHeight: Double)
    public var isUsable: Bool { cellWidth > 0 && cellHeight > 0 }
}

public enum OverlayLayout {
    public static func panelSize(_ size: OverlaySize, pane: WindowGeometry.Size,
                                 cell: OverlayCellMetrics?) -> WindowGeometry.Size
    // .full -> pane; .percent -> pane*p/100 (<=pane); .cells -> whole-cell clamp; nil/unusable cell -> pane
}
```

**Pixel→point conversion (app-side, `GhosttySurfaceView`):**
```swift
func overlayPixelMetrics() -> (cellW: Double, cellH: Double, padW: Double, padH: Double,
                               cols: Int, rows: Int)? // from ghostty_surface_size(surface), all *_px
// app converts to points: OverlayCellMetrics(cellWidth: cellW/scale, cellHeight: cellH/scale,
//   padWidth: (width_px - cols*cellW)/scale, padHeight: (height_px - rows*cellH)/scale)
// with scale = window.backingScaleFactor. padding is an ESTIMATE (total non-cell remainder).
```

**`Session`:** remove `overlaySizePercent`; add `overlaySize`/`overlayAnchor`/`overlayCellMetrics`/
`overlayAppliedCols`/`overlayAppliedRows`; re-express `fullOverlayActive`/`floatingOverlayActive` against
`overlaySize` (the `topmostSurface` accessor reads `overlayActive`, NOT the percent — leave it alone).

**Wire read-back (`ControlSessionNode`, populated in `AppStore.controlTree`, omitted when nil):**
- `overlaySizePercent: Int?` — set only when `overlaySize == .percent` (unchanged; back-compat).
- `overlayCols`/`overlayRows: Int?` — REQUESTED grid; set only when `overlaySize == .cells`.
- `overlayColsApplied`/`overlayRowsApplied: Int?` — realized grid from `overlayAppliedCols/Rows`; set for
  ANY open floating overlay (percent or cells), so a script sees what actually rendered / any clamp.
- `overlayAnchor: String?` — anchor `rawValue`, set whenever an overlay is open (incl. full).

**Dispatcher validation.** Open: at most one of {`sizePercent`, (`cols`&`rows`)}; `cols` and `rows` both
or neither ("provide both --cols and --rows"); `sizePercent` 1…100 (hard error — Decision 3); `cols`/
`rows` >= 1; `anchor` parses to `OverlayAnchor`; `anchor` without a floating size errors. No size = full
overlay (open has no `--full`). Resize: one-of {`full`, `sizePercent`, `cols`+`rows`} OR none; at least
one of {a size mode, `anchor`}; `full` ⊥ `anchor`; same range/pairing/anchor rules.

**Processing flow:** CLI parse+validate → `ControlRequest` args {sizePercent|cols,rows, anchor / full} →
`ControlDispatcher.dispatch` validates + builds `OverlayOpenOptions` / resize call → `ControlActions` arm
→ `AppStore.openOverlay/resizeOverlay` sets `overlaySize`/`overlayAnchor` → app keeps
`overlayCellMetrics`/`overlayAppliedCols/Rows` fresh via `CELL_SIZE`/realization → `overlayPanel` renders
via `OverlayLayout.panelSize` + anchor alignment. `tree` reports requested + applied + anchor.

## What Goes Where

- **Implementation Steps** (`[ ]`): all code, tests, and in-repo docs (agent-skill, site, README, rules).
- **Post-Completion** (no checkboxes): manual dev-instance verification of rendered placement and
  cell-exact fit (not accessibility-observable beyond the e2e frame check), and the exactness/drift call.

## Implementation Steps

### Task 1: Host-free overlay layout model + resolver

**Files:**
- Create: `agtermCore/Sources/agtermCore/OverlayLayout.swift`
- Create: `agtermCore/Tests/agtermCoreTests/OverlayLayoutTests.swift`

- [x] add `OverlaySize`, `OverlayAnchor` (with `unitX`/`unitY`), `OverlayCellMetrics` (points, `isUsable`)
- [x] add `OverlayLayout.panelSize(_:pane:cell:)` — full/percent/whole-cell-clamp with guards: nil or
      unusable cell → pane; pane smaller than one cell + padding → clamp to >=1 cell but never exceed pane
- [x] write tests: percent (incl. 100), cells within pane, cells wider/taller than pane (whole-cell
      clamp), **1× and 2× (Retina) metrics producing the correct point size**, sub-pixel rounding cases,
      nil/unusable metrics fallback, min-1-cell floor, all-9 anchor unit points
- [x] run `cd agtermCore && swift test` — must pass before next task

### Task 2: Session state + store API + controlTree percent migration (single compiling unit)

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Session.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+Panes.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`
- Modify: `agterm/AppActions.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/SessionTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStorePaneTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/TerminalZoomTests.swift`

- [x] replace `Session.overlaySizePercent` with `overlaySize: OverlaySize = .full`; add `overlayAnchor:
      OverlayAnchor = .center`, observed `overlayCellMetrics: OverlayCellMetrics?`, `overlayAppliedCols:
      Int?`, `overlayAppliedRows: Int?`; re-express `fullOverlayActive`/`floatingOverlayActive`
- [x] add `OverlayOpenOptions`; `AppStore.openOverlay(_:options:)` (defensive percent clamp retained);
      `resizeOverlay(_:size:anchor:)` (nil = keep; `.full` keeps anchor); `closeOverlay` resets
      size/anchor/metrics/applied
- [x] migrate `AppStore.controlTree` percent read to derive from `overlaySize` (keep `overlaySizePercent`
      wire field populated); migrate `AppActions.swift:357/390` to `openOverlay(options:
      .init(... size: .percent(95) ...))`
- [x] update `AppStorePaneTests` (open/resize via new API; keep the 250→100 / 0→1 defensive-clamp cases)
      and `TerminalZoomTests:104`
- [x] write tests: open sets size/anchor; resize percent→cells→full; resize anchor-only keeps size;
      size-only keeps anchor; **`--full` preserves the anchor**; predicates per mode; close resets to
      full/center/nil
- [x] run `cd agtermCore && swift test` — must pass before next task (app target not yet built)

### Task 3: Wire protocol — args + read-back node (requested + applied + anchor)

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStorePaneTests.swift`

- [ ] add `ControlArgs.cols`/`rows`/`anchor`; thread through its init
- [ ] add `ControlSessionNode.overlayCols`/`overlayRows`/`overlayColsApplied`/`overlayRowsApplied`/
      `overlayAnchor`; thread through its init (keep `overlaySizePercent`)
- [ ] populate the new node fields in `AppStore.controlTree`: requested cols/rows when `.cells`; applied
      cols/rows from `overlayAppliedCols/Rows` when floating; `overlayAnchor` rawValue when
      `overlayActive`; all omitted when nil
- [ ] write tests: `ControlArgs` round-trip with cols/rows/anchor; `ControlSessionNode` round-trip for
      cells+applied+anchor and for percent+applied+anchor; `…OmitsWhenNil` for full overlay and no
      overlay; a `controlTree` populate test in `AppStorePaneTests` (requested vs applied, anchor emitted
      while full)
- [ ] run `swift test` — must pass before next task

### Task 4: Dispatcher validation + routing (tightened open)

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/MockControlActions.swift`

- [ ] extend `ControlActions.openSessionOverlay`/`resizeSessionOverlay` + `ControlSessionOverlayOpenOptions`
      to carry `OverlaySize`/`OverlayAnchor`; update `MockControlActions`
- [ ] `.sessionOverlayOpen`: parse size (percent/cells, no `--full`), validate one-of + cols·rows pairing
      + **percent 1…100 hard-error (Decision 3)** + anchor parse + anchor-requires-floating; build options
- [ ] `.sessionOverlayResize`: validate one-of {full/percent/cells} or none, at-least-one-of {size,
      anchor}, `full` ⊥ `anchor`; pass `size: OverlaySize?`/`anchor: OverlayAnchor?`
- [ ] factor size/anchor parsing into shared pure helpers used by both arms
- [ ] write tests: each valid open/resize mode routes correctly (assert mock call args); each error
      (both cols/rows required, **percent out-of-range now errors on open**, unknown anchor,
      anchor-without-floating, full+anchor, resize-with-nothing)
- [ ] run `swift test` — must pass before next task

### Task 5: App-side arms + observable metrics + overlayPanel rendering

**Files:**
- Modify: `agterm/Control/ControlServer+SessionActions.swift`
- Modify: `agterm/Ghostty/GhosttySurfaceView.swift`
- Modify: `agterm/Ghostty/GhosttyCallbacks.swift`
- Modify: `agterm/Views/WindowContentView.swift`

- [ ] update the overlay arms to pass `size`/`anchor` into `openOverlay(options:)`/`resizeOverlay(_:size:anchor:)`
- [ ] add `GhosttySurfaceView.overlayPixelMetrics()` from `ghostty_surface_size()`; app converts px→points
      via `backingScaleFactor` and writes `session.overlayCellMetrics` + `session.overlayAppliedCols/Rows`
      on surface realization, `GHOSTTY_ACTION_CELL_SIZE` (`GhosttyCallbacks.swift:50`), and backing-scale
      change (view consumes the observed metrics — no view-body polling of the imperative NSView)
- [ ] `overlayPanel`: size via `OverlayLayout.panelSize(session.overlaySize, pane: geo.size, cell:
      session.overlayCellMetrics)`; position via `ZStack(alignment: floating ?
      session.overlayAnchor.swiftUIAlignment : .center)`; add the app-side `OverlayAnchor.swiftUIAlignment`
      mapping; add a stable accessibility id to the floating panel
- [ ] confirm ZStack child count unchanged and no anchor-specific view branches (NSSplitView-overrun
      rule); full path + `hideForOverlay` untouched
- [ ] app builds (`make build`); `make lint` passes
- [ ] verify in an isolated dev instance (short `AGTERM_STATE_DIR` + its own socket) that cols/rows fit,
      each anchor places correctly, and Retina scaling is right — record in Post-Completion
- [ ] run `swift test` (host-free unchanged) — must pass before next task

### Task 6: agtermctl CLI — open/resize flags

**Files:**
- Modify: `agtermCore/Sources/agtermctlKit/SessionCommands.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/CommandsTests.swift`

- [ ] `session overlay open`: add `--cols`/`--rows`/`--anchor`; `validate()` mirrors dispatcher (one-of
      size, cols&rows together, **percent 1…100 now enforced on open**, anchor value, anchor-requires-
      floating); map into `ControlArgs`
- [ ] `session overlay resize`: add `--cols`/`--rows`/`--anchor`; extend `validate()` to one-of size or
      none, at-least-one of {size, anchor}, `full` ⊥ `anchor`
- [ ] update help text
- [ ] write tests: request mapping for each open/resize mode; `validate()` accepts valid combos and
      rejects each invalid one (incl. the new open percent-range error) with the expected message
- [ ] run `swift test` — must pass before next task

### Task 7: End-to-end XCUITests (wire + actual grid + frame)

**Files:**
- Modify: `agtermUITests/ControlOverlaySplitUITests.swift`

- [ ] e2e: open a floating overlay with `--cols/--rows` + `--anchor`; assert `tree` read-back (requested
      `overlayCols/Rows`, applied `overlayColsApplied/RowsApplied`, `overlayAnchor`)
- [ ] e2e: assert the **actual grid** — run `stty size > marker; cat` in the overlay and assert the
      marker reports the requested (or clamped) rows/cols (would catch the Retina bug)
- [ ] e2e: assert the floating panel's **frame vs the pane** via its accessibility id for a corner anchor
- [ ] e2e: open `--size-percent`, resize to `--cols/--rows`, re-anchor with `--anchor` only, resize back
      to `--full` (read-back: cols/rows cleared, anchor retained); cycle these while a split is visible
- [ ] e2e: error cases over the socket (anchor without floating, both cols/rows required, full+anchor,
      **open --size-percent out of range now errors**)
- [ ] run the overlay e2e target — must pass before next task

### Task 8: Keep-in-sync documentation surfaces

**Files:**
- Modify: `agterm/Resources/agent-skill/reference.md`
- Modify: `agterm/Resources/agent-skill/examples.md`
- Modify: `agterm/Resources/agent-skill/SKILL.md`
- Modify: `site/commands.html`
- Modify: `site/docs.html`
- Modify: `README.md`
- Modify: `.claude/rules/control-api.md`

- [ ] agent-skill `reference.md`: update the `session overlay open`/`resize` entries with
      `--cols/--rows/--anchor`, the tightened open validation, the clamp/adaptive note, and the read-back
      fields (requested + applied + anchor); command count stays 64
- [ ] agent-skill `SKILL.md`: update the overlay invocation line + the `overlaySizePercent` schema note
      (NOT optional — it carries the overlay schema)
- [ ] agent-skill `examples.md`: add a cols/rows + anchor recipe and a re-anchor-only example
- [ ] `site/commands.html`: update the overlay entries (invocation, args, `tree` read-back fields)
- [ ] `README.md` + `site/docs.html`: update the overlay section (mirror each other)
- [ ] `.claude/rules/control-api.md`: update the overlay command **args** doc (not only the read-back
      note) — new flags, tightened open validation, requested+applied read-back, anchor-preserved-on-full
- [ ] grep the skill + `control-api.md` for stale percent-only / "centered" / old-state-shape wording and
      fix; note in the plan that `site/index.html` is intentionally untouched (non-major, non-release)
- [ ] re-run `make lint` to confirm nothing regressed

### Task 9: Verify acceptance criteria
- [ ] verify Overview: cols/rows sizing, 9 anchors, size clamp, percent/full unchanged, default center,
      requested+applied+anchor read-back, Decision-3 open tightening
- [ ] verify edge cases: cols/rows > pane (clamped, applied reflects it), 1×1, Retina 2× correct,
      anchor with no floating size (error), resize anchor-only, `--full` preserves anchor, no new
      `Command` case (count 64), no persistence changes
- [ ] run full host-free suite: `cd agtermCore && swift test`
- [ ] run e2e: the `ControlOverlaySplitUITests` overlay cases (incl. `stty size` + frame assertions)
- [ ] `make lint` clean; app builds (`make build`)

### Task 10: Final documentation + close-out
- [ ] update `CLAUDE.md`/`.claude/rules` only if a genuinely new pattern emerged (e.g. the observed-
      metrics-from-`CELL_SIZE` bridge, if worth recording)
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems — no checkboxes, informational only*

**Manual verification:**
- Placement and cell-exact fit: verify by eye in an isolated dev instance (`open -n --env
  AGTERM_STATE_DIR=/tmp/agt-overlay --env AGTERM_CONTROL_SOCKET=/tmp/agt-overlay.sock <Debug>/agterm.app`,
  drive via `agtermctl … --socket /tmp/agt-overlay.sock`): each of the nine anchors places against the
  correct edge/corner; `--cols/--rows` renders the exact grid on BOTH a 1× and a Retina display; an
  oversized request clamps to whole cells and `overlayColsApplied/RowsApplied` report the clamp. Never
  touch the deployed `~/Applications/agterm.app`.
- **Exactness/drift call:** if manual verification shows the realized grid is consistently off by a cell
  from the request (padding-estimate drift), open a follow-up to add a bounded post-realization frame
  correction — deliberately OUT of v1 scope, with the applied read-back exposing the drift meanwhile.
- Cell metrics when the overlay font differs from the main pane's: the overlay is created with
  `session.fontSize` (`agtermApp.swift:435`), so the pre-realization main-surface fallback matches in the
  normal case; the differing-font case to sanity-check is an overlay zoomed AFTER creation, or a main
  surface under a transient dashboard font override — not a merely-zoomed main pane.

**External system updates:** none — no consuming projects, no deployment/config changes.

---
Smells pre-check: skipped — non-Go project (no `go.mod`; the Go-specific planning rules — go-architect,
code-quality block, Design Contract, smells pre-check — do not apply). agterm project-rule gates are in
the "Project-Rule Gates" section above. Reviewed by plan-review + Codex; findings and three maintainer
decisions folded into "Review Revisions".
