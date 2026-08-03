# Session HUD — a non-blocking message panel driven by the control API

## Overview

An agent working in a session often needs seconds before it can show anything: computing the items for
`pick`, spawning a slow overlay program, waiting on a network call. Today there is nothing to put in front
of the user during that gap — `session.status` writes a sidebar glyph and `notify` posts a banner, neither
of which is in the session the user is about to be pulled into.

`session.hud` posts a small floating panel over a session carrying a message ("gathering options…"), an
optional dim detail line, an optional spinner, and a vertical position (top, center, or bottom). It is
**passive**: the session keeps first responder and the user keeps typing into the terminal underneath. It is closed by command, replaced by whatever the agent
opens next, or dismissed by the user with Command-W.

The HUD occupies the **session overlay slot** rather than introducing a new cover, so it inherits the
Command-W dismissal ladder, `coverHidesActiveSession`, `searchTarget` gating, and session-close teardown
without a new rung in any of them. The price of that reuse is three deliberate exemptions in the deck, since
the deck currently treats an occupied overlay slot as proof that the session must not be focusable (Task 4).

## Context (from discovery)

Files/components involved:

- `agterm/agtermApp.swift:417-487` — `overlayExitWrapper` and `makeOverlaySurface`; every overlay surface is
  spawned with a command and `autoFocus: true`.
- `agterm/Views/WindowContentView+Detail.swift:58` — `DeckPaneGates(overlaid: session.overlayActive || …)`;
  `:187-190` the floating click catcher; `:275` `backdropWashActive`.
- `agterm/Views/TerminalView.swift:63-69` — an inactive pane has first responder taken away.
- `agtermCore/Sources/agtermCore/AppStore+Panes.swift:169-219` — `openOverlay` / `resizeOverlay` /
  `closeOverlay` / `recordOverlayExit`.
- `agtermCore/Sources/agtermCore/AppStore.swift:259-285` — where `ControlSessionNode` is populated.
- `agtermCore/Sources/agtermCore/Session.swift:243-253` — `overlaySizePercent`, `fullOverlayActive`,
  `floatingOverlayActive`.
- `agtermCore/Sources/agtermCore/ControlProtocol.swift:387` — `ControlSessionNode`; `:40-43`
  `session.overlay.*` cases; `:133` `ControlArgs.color`.
- `agterm/Control/ControlServer.swift:336-356` — an exhaustive `Command` switch with no `default`.
- `agterm/Control/ControlServer+SessionActions.swift:80` — app-side overlay result, where store state is known.
- `agtermCore/Sources/agtermCore/ControlDispatcher.swift` + `ControlDispatcher+Pick.swift` — dispatcher-first
  validation pattern to mirror.
- `agtermCore/Sources/agtermctlKit/SessionCommands.swift:600-740` — the `overlay` subcommand group.
- `agterm/Resources/agent-status` + `project.yml:53` (`sources.excludes`) and `:78-82` (folder reference) —
  the bundled-asset pattern the helper follows; it is **two** entries, not one.

Related patterns found:

- Floating overlays already render as an opaque framed panel at `overlaySizePercent` of the pane
  (`WindowContentView+Detail.swift:185-186`), with the session visible around it — exactly the geometry a HUD
  wants.
- `--background-color` is already carried on the session's overlay slot (`overlayBackgroundColor`) and applied
  in `createSurface` because the overlay is sessionless (`agtermApp.swift:441`).
- `ShellEscape.swift` exists host-free for quoting the helper path into the wrapper's `eval`.

Dependencies and hazards identified (all verified against the code):

- **The deck resigns focus for an occupied overlay slot.** `gates.overlaid` feeds `isActive`, and
  `TerminalView.updateNSView` calls `window.makeFirstResponder(nil)` for an inactive pane. `autoFocus: false`
  is necessary but not sufficient — without Task 4 the HUD is not passive and typing goes nowhere.
- **A floating overlay also dims and swallows.** The full-frame `.contentShape(Rectangle())` catcher and
  `backdropWashActive` apply to any floating overlay, so an unexempted HUD mutes the session backdrop and eats
  clicks aimed at the terminal.
- `openOverlay` returns **false** when `session.overlayActive` is already true (`AppStore+Panes.swift:179`).
  "`overlay open` replaces a HUD" therefore requires an explicit close-first rung, plus care with the
  surface identity so the replacement actually remounts (Task 3).
- `ControlServer.swift`'s `Command` switch is exhaustive — new cases break the build until it is updated.
- `TerminalZoomSurface.isActive` opens with `let uncovered = !session.overlayActive && !session.scratchActive`
  and every pane arm ANDs it (`TerminalZoom.swift:56-62`). Narrowing the `.overlay` case alone leaves **no**
  case active and falls through to the `?? .primary` fallback the code documents as unreachable.
- **No cell metrics exist anywhere.** `GHOSTTY_ACTION_CELL_SIZE` is handled as a trigger and its payload
  discarded; nothing stores cell width/height. The panel is therefore sized from the configured terminal font
  via CTFont advance (maintainer's decision), not from libghostty.

## Development Approach

- **testing approach**: Regular (code first, then tests) — chosen by the maintainer.
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional — they are a required part of the checklist
  - write tests for new functions/methods and for modified ones
  - add new test cases for new code paths; update existing cases if behavior changes
  - cover both success and error scenarios
- **CRITICAL: all tests must pass before starting the next task** — no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- tests live in the mate file of the source they exercise (project rule: one test file per source file);
  new test files require `xcodegen generate` before `-only-testing:` can address them
- maintain backward compatibility: no existing command's behavior or read-back changes shape

Per project CLAUDE.md, run each gate ONCE at the end (`swift test`, `make test-app`, `make lint`) and scope
everything else to what changed. Never re-run a whole XCUITest suite to verify a narrow change.

## Testing Strategy

- **host-free unit tests** (`agtermCore/Tests/agtermCoreTests/`): sizing math, session state, store lifecycle,
  dispatcher validation, protocol round-trip, tree-node population, zoom resolution. The bulk of coverage.
- **CLI tests** (`agtermCore/Tests/agtermctlKitTests/CommandsTests.swift`): argument parsing and validation.
- **hosted AppKit tests** (`agtermTests/`, via `make test-app`): the first-responder property — the session
  keeps focus and receives typed input while a HUD is up. This is the property that makes it a HUD rather than
  an overlay and must be pinned. Also the HUD→overlay surface swap and the app-side action wiring.
- **e2e UI test** (`agtermUITests/ControlHudUITests.swift`): open → read back from `tree` → update → close over
  the real socket, following `ControlPickUITests.swift`'s shape.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update this plan if implementation deviates from the original scope

## Solution Overview

The HUD is an **app-owned overlay variant**, not a new surface kind and not CLI sugar.

Why a pty at all: every overlay surface is spawned with a command, and agterm drives pty *input* only — it has
no path to paint output into a libghostty surface. A HUD is therefore necessarily a surface running a program
that prints the message and waits. The app owns that program (a bundled helper), so caller text never
round-trips through a shell line the caller composed.

Flow:

1. `session.hud.open` validates host-free, then the app measures the message with the terminal font, writes the
   rendered text to a temp file, and calls the store's `openHud`, which sets the overlay slot's command to the
   bundled helper (path shell-escaped), marks the slot as a HUD, and sets `overlaySizePercent`.
2. The deck sees a HUD slot and keeps the session focusable, unwashed, and clickable; the surface factory
   spawns the helper **non-focusing** (`autoFocus: false`) with the file path, box, and spinner flag in the
   environment.
3. The helper loops: read file → repaint centered in the box → sleep. ~500ms without a spinner, ~100ms with one.
4. `session.hud.update` rewrites the temp file and recomputes the size in place (`resizeOverlay`) — the next
   frame repaints, no respawn, no blink.
5. `session.hud.close`, `overlay.close`, Command-W, session close, or the next `overlay open` tears it down
   through the existing overlay teardown, which also removes the temp file.

Key design decisions:

- **Overlay slot, not a new cover.** One cover concept keeps the Command-W ladder, `coverHidesActiveSession`,
  `searchTarget`, and teardown unchanged. Cost: three deck exemptions (Task 4), a session cannot show a HUD and
  a program overlay at once, and `overlay.result` must refuse a HUD.
- **Non-focusing, and it looks it.** The defining property lives in the deck gates as much as in the surface
  factory, and the chrome follows: framed and opaque, but no drop shadow and no backdrop wash, so the panel
  reads as part of the terminal rather than a window floating above a dimmed session.
- **Sizing app-side, from the font.** The message → columns/rows → percent conversion is pure and host-free;
  the app supplies the metrics by measuring the configured terminal font, so there is no libghostty plumbing
  and no cold-start hole. The min/max clamp absorbs any divergence from ghostty's own cell width.
- **Control-native, no GUI trigger.** No menu item, no chord, no palette entry — there is nothing here for a
  human to invoke by hand. A deliberate exemption from the "toolbar/menu/control share one action seam" rule in
  `.claude/rules/menu-actions.md`, to be stated in `control-api.md` rather than papered over with an invented
  GUI surface.
- **HUD state is poll-only.** `scheduleTreeChanged()` fires from create/close/rename/reorder sites only;
  `openOverlay`/`closeOverlay` do not emit it and neither will a HUD. Callers read `tree`. Do not document an
  event that does not fire.

Explicitly out of scope (cut during design — do not add): TTL/auto-expiry; a window-scoped HUD like `pick`;
`--pane left|right` scoping; tones, accent colors, icons, progress bars, percentages; queueing (a second
`hud.open` replaces the first); any implicit coupling where opening a picker dismisses a HUD.

## Technical Details

**Host-free model** (`agtermCore/Sources/agtermCore/Hud.swift`):

```swift
public struct HudSpec: Codable, Equatable, Sendable {
    public let message: String
    public let detail: String?
    public let spinner: Bool
    public let backgroundColor: String?
    public let sizePercent: Int?     // caller override; nil means auto
    public let position: HudPosition // defaults to .center when the caller omits it
}

public enum HudPosition: String, Codable, CaseIterable, Sendable {
    case top, center, bottom
    /// pane-height fraction held clear at the edge for `.top`/`.bottom`; `.center` ignores it
    public static let edgeMarginPercent = 10
}

public struct PaneMetrics: Equatable, Sendable {   // Double-backed: no CoreGraphics across the boundary
    public let cellWidth: Double
    public let cellHeight: Double
    public let paneWidth: Double
    public let paneHeight: Double
}

public enum HudLayout {
    public static let maxColumns = 60
    public static let maxSizePercent = 80
    public static let minSizePercent = 10
    public static func box(for spec: HudSpec) -> (columns: Int, rows: Int)
    public static func sizePercent(box: (columns: Int, rows: Int), pane: PaneMetrics) -> Int
    public static func renderedBody(for spec: HudSpec) -> String
}
```

**Protocol**: three commands — `session.hud.open`, `session.hud.update`, `session.hud.close` — mirroring the
`session.overlay.*` grouping. `ControlArgs` gains `message`, `detail`, `spinner`, and reuses the existing
`sizePercent` and **`color`** (the field is named `color`, not `backgroundColor` — do not add a duplicate).

**Read-back**: `ControlSessionNode.hud` — an object with `message`, `detail`, `spinner`, `backgroundColor`,
`sizePercent`, `position` — omitted when there is no HUD, populated in `AppStore.swift`. `position` always
reports the effective value, including the `center` default, so a script never has to know the default. While a HUD is up, the node's
`overlay` field reports **false** and `overlaySizePercent` stays omitted, so a script polling "is a program
covering this session" cannot mistake a HUD for a running program; the HUD's size is reported inside `hud`.

**Helper contract** (`agterm/Resources/hud/hud.sh`), driven entirely by environment:

- `AGTERM_HUD_FILE` — path to the rendered message file (message and detail, newline separated).
- `AGTERM_HUD_COLS` / `AGTERM_HUD_ROWS` — the box the app computed, so centering needs no `stty`/`tput`.
- `AGTERM_HUD_SPINNER` — `1` enables the frame counter and the faster tick.

The helper re-reads the file and the box every tick, so an update needs no signal. It exits when the file
disappears. POSIX `sh`, nothing beyond `printf` and `sleep`.

**Lifecycle**: HUDs are live-only. Nothing persists across restart, matching overlays.

## What Goes Where

- **Implementation Steps**: everything below — code, tests, and doc surfaces inside this repository.
- **Post-Completion**: manual verification in a Debug instance and skill-copy propagation.

## Implementation Steps

### Task 1: Host-free HUD spec, metrics, and sizing math

**Files:**
- Create: `agtermCore/Sources/agtermCore/Hud.swift`
- Create: `agtermCore/Tests/agtermCoreTests/HudTests.swift`

- [x] create `HudSpec` (message, detail, spinner, backgroundColor, sizePercent, position) as a `Codable`, `Sendable` value, defaulting `position` to `.center`
- [x] create `HudPosition` (`top`/`center`/`bottom`, `CaseIterable` so validation and CLI help derive from it) with the `edgeMarginPercent` constant
- [x] create `PaneMetrics` with Double-backed cell and pane dimensions — no CoreGraphics types cross the module boundary
- [x] add `HudLayout.box(for:)` — wrap message and detail at `maxColumns`, add the padding frame, return columns/rows
- [x] add `HudLayout.sizePercent(box:pane:)` — cell box to pane percentage, clamped to `minSizePercent...maxSizePercent`
- [x] add `HudLayout.renderedBody(for:)` — the exact bytes the app writes to `AGTERM_HUD_FILE`
- [x] write tests for wrapping (short message, long single word, message plus detail, embedded newlines)
- [x] write tests for the percent conversion (typical pane, tiny pane clamping to min, huge message clamping to max, zero-size pane)
- [x] write tests for the position default (omitted decodes to `center`) and that every `HudPosition` case round-trips
- [x] run `cd agtermCore && swift test --filter HudTests` — must pass before task 2

### Task 2: Session state for the HUD slot

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Session.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/SessionTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/SnapshotRoundTripTests.swift`

- [x] add `hudSpec: HudSpec?` and `hudFile: String?` to `Session`, both non-persisted (live-only, like overlay state)
- [x] add `hudActive` (derived: `overlayActive && hudSpec != nil`) and audit `fullOverlayActive`/`floatingOverlayActive` call sites so program-overlay questions stay program-only
- [x] confirm no persistence path in `Snapshot.swift` picks up the new fields
- [x] write tests in `SessionTests.swift` for the derived flags across four states (no cover, program overlay, HUD, HUD replaced by overlay)
- [x] write a test in `SnapshotRoundTripTests.swift` that a snapshot round-trip drops HUD state
- [x] run both filters — must pass before task 3

### Task 3: Store lifecycle and replacement semantics

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore+Panes.swift`
- Modify: `agtermCore/Sources/agtermCore/Session.swift` (added during Task 3: `overlaySlotGeneration`)
- Modify: `agtermCore/Tests/agtermCoreTests/AppStorePaneTests.swift`

- [x] add `openHud(_:spec:file:sizePercent:)` — sets the overlay slot to the helper command, stores `hudSpec`/`hudFile`, sets `overlaySizePercent`, marks the slot active
- [x] add `updateHud(_:spec:file:sizePercent:)` — rewrites spec/size in place without touching the surface (no respawn)
- [x] add `closeHud(_:)` — delegates to `closeOverlay`, and clear the HUD fields inside `closeOverlay` so every teardown path (explicit close, Command-W, session close) clears them
- [x] change `openOverlay` so an active **HUD** is closed first and the open proceeds, while an active **program overlay** still returns false — a HUD is replaceable, a running program is not
- [x] make a second `openHud` replace an existing HUD rather than failing
- [x] pin the surface swap for HUD→program overlay: `overlayPanel`'s representable identity must change (or the re-open must be deferred), or `makeNSView` is never re-invoked and `updateNSView` runs against a torn-down view with `overlaySurface` nil
- [x] write tests for open/update/close, HUD-replaces-HUD, overlay-replaces-HUD, HUD refused over a live program overlay, and that `closeOverlay` clears `hudSpec`/`hudFile`
- [x] run `swift test --filter AppStorePaneTests` — must pass before task 4

### Task 4: Deck exemptions — make the HUD actually passive

**Files:**
- Modify: `agterm/Views/WindowContentView+Detail.swift`
- Modify: `agtermCore/Sources/agtermCore/Session.swift` (added during Task 4: `programOverlayActive`)
- Modify: `agtermCore/Tests/agtermCoreTests/SessionTests.swift`
- Create: `agtermTests/HudDeckGatesTests.swift`

- [x] exempt a HUD from `gates.overlaid` (`:58`) so the session's pane stays `isActive` and keeps first responder — without this `TerminalView.updateNSView` resigns it and typing goes nowhere
- [x] exempt a HUD from the floating click catcher (`:187-190`) so clicks reach the panes underneath
- [x] exempt a HUD from `backdropWashActive` (`:275`) so the session is not dimmed behind a message
- [x] place the panel vertically from `HudSpec.position` inside `overlayPanel`'s `GeometryReader` (`:181+`): `center` as today, `top`/`bottom` offset by `HudPosition.edgeMarginPercent` of the pane height. Program overlays stay centered — do not change their geometry
- [x] give the HUD its own chrome parameters in the SAME modifier chain (`:201-208`): opaque backing kept, `shadow(radius: 0)` instead of 24 so it does not read as a window hovering over the session, a stronger border (~0.30 versus 0.18, since neither shadow nor backdrop wash separates it from the text behind), and a tighter corner radius. Flip parameters only — the chain stays constant, per the rule the code states there
- [x] ➕ append `session.overlaySlotGeneration` to `overlayPanel`'s `.id("\(session.id.uuidString)-overlay")`
  (`:209`) — Task 3 made the store bump it on every slot open, and a replacement (HUD→HUD, HUD→program) keeps
  `overlayActive` true across the swap, so without it `makeNSView` never re-runs and `updateNSView` hits a
  torn-down view with `overlaySurface` nil. Only the `.id` VALUE changes; the chain stays constant
- [x] ➕ exempt a HUD from the SCRATCH's focus gate (`:101`, `isActive: focusable && !session.overlayActive`)
  — a fourth exemption of the same class the plan missed: with the scratch shown it owns first responder, and
  an unexempted HUD resigns it exactly as `gates.overlaid` would have for the panes
- [x] ➕ add `Session.programOverlayActive` (`overlayActive && !hudActive`) as the one predicate all four
  exemptions read, so "a caller's program occupies the slot" cannot be spelled two ways that disagree
- [x] keep every change a **value flip**: `sessionDetail`/HSplitView shape and pane modifiers must not change on HUD state, per `.claude/rules/control-api.md`
- [x] write hosted tests for all three exemptions (gates computed with a HUD vs a program overlay vs scratch)
- [x] write tests for the three vertical placements, including that a `top`/`bottom` panel stays fully inside the pane when the message is at `maxSizePercent`
- [x] write tests for the chrome parameters: a HUD gets no shadow and the stronger border, a program overlay keeps 24 and 0.18
- [x] run `xcodegen generate`, then the new class via `-only-testing:` — must pass before task 5

### Task 5: Protocol commands, arguments, read-back, and server routing

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`
- Modify: `agterm/Control/ControlServer.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift` (added during Task 5: the exhaustive routing switch)
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`
- Create: `agtermCore/Tests/agtermCoreTests/AppStoreHudTests.swift` (replaced `AppStoreTests.swift`, see below)

- [x] add `Command` cases `sessionHudOpen = "session.hud.open"`, `sessionHudUpdate = "session.hud.update"`, `sessionHudClose = "session.hud.close"`
- [x] add `message`, `detail`, `spinner`, `position` to `ControlArgs`; reuse the existing `sizePercent` and `color` — do NOT add a `backgroundColor` field (`position` already existed for `session.background`, so only its doc grew)
- [x] add the `hud` node type and field to `ControlSessionNode` (`:387`)
- [x] populate `hud` in `AppStore.swift:259-285`, and make `overlay`/`overlaySizePercent` report false/omitted while a HUD occupies the slot
- [x] add the three cases to `ControlServer.swift:336-356` — the switch is exhaustive with no `default`, and these are dispatcher-handled, so they belong on the `preconditionFailure` arm alongside the pick commands
- [x] ➕ add the three cases to `ControlDispatcher.dispatch`'s equally exhaustive switch, returning nil until Task 6 routes them to `dispatchHudCommand` — without it `agtermCore` does not build
- [x] ⚠️ `AppStore.swift` is 982 lines against SwiftLint's 1000-line warning and `make lint` requires zero findings. Resolved at 993 lines: the population is one flipped argument plus an 8-line `hudNode` helper, so no split was needed
- [x] ➕ `AppStoreTests.swift` was 1972 lines against the 2000-line test limit, so the population tests went into a new `AppStoreHudTests.swift`, following the existing `AppStore<Concern>Tests.swift` split
- [x] write round-trip tests for the three commands and their arguments
- [x] write population tests: `hud` present with every field, omitted when absent, and `overlay` false while a HUD is up
- [x] run both filters — must pass before task 6

### Task 6: Dispatcher validation and control actions

**Files:**
- Create: `agtermCore/Sources/agtermCore/ControlDispatcher+Hud.swift`
- Create: `agtermCore/Tests/agtermCoreTests/ControlDispatcherHudTests.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift`
- Modify: `agtermCore/Sources/agtermCore/Hud.swift` (added during Task 6: `HudSpec.maxTextLength`)
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher+Pick.swift` (added during Task 6: shared control-character check)
- Modify: `agterm/Control/ControlServer+SessionActions.swift` (added during Task 6: refusing conformance stubs)
- Modify: `agtermCore/Tests/agtermCoreTests/MockControlActions.swift`

- [x] add `openHud`/`updateHud`/`closeHud` to the `ControlActions` protocol and to `MockControlActions`
- [x] create `dispatchHudCommand` mirroring `ControlDispatcher+Pick.swift`: require a non-empty message on open, reject control characters in message and detail, cap length, validate `sizePercent` 1...100 and `color` through the shared `#rrggbb` validator, and validate `position` against `HudPosition.allCases` (absent means `center`, per the `StatusShape` precedent)
- [x] reject `session.hud.update` with no message; route `session.hud.close` with no extra arguments
- [x] wire the three cases into `ControlDispatcher`'s routing — never into the fallback switch
- [x] write tests for every validation branch (empty message, control characters, oversized message, bad percent, bad color, unknown position, update without message)
- [x] write tests asserting the dispatcher calls the right action with the parsed spec
- [x] ➕ add `HudSpec.maxTextLength` (256, matching `WatermarkConfig.maxTextLength`) as the shared message/detail
  cap, and drop `private` from `ControlDispatcher+Pick.swift`'s `containsControlCharacters` so the HUD arm
  reuses it instead of adding a fourth copy of the predicate
- [x] ➕ add three refusing `openHud`/`updateHud`/`closeHud` stubs to `ControlServer+SessionActions.swift` —
  the new required protocol members break the app target's `ControlActions` conformance, and Task 8 replaces
  the bodies with the real effects
- [x] run `swift test --filter ControlDispatcherHudTests` — must pass before task 7

### Task 7: Bundled helper script

**Files:**
- Create: `agterm/Resources/hud/hud.sh`
- Modify: `project.yml`
- Create: `agtermCore/Tests/agtermCoreTests/HudHelperTests.swift`

- [ ] write `hud.sh`: each tick read `AGTERM_HUD_FILE` plus `AGTERM_HUD_COLS`/`AGTERM_HUD_ROWS`, clear, print the message centered in that box with the detail line dimmed, sleep ~500ms (~100ms and advance the spinner frame when `AGTERM_HUD_SPINNER=1`), exit when the file disappears
- [ ] keep it POSIX `sh` with nothing beyond `printf`/`sleep` — the box comes from the environment, so no `stty`, `tput`, `$COLUMNS`, or SIGWINCH trap
- [ ] add `agterm/Resources/hud` to the `agterm` target's `sources.excludes` (`project.yml:53` pattern) **and** as a folder-reference resource entry (`:78-82` pattern), landing at `Contents/Resources/hud`
- [ ] write tests that run the script against a temp file and assert it renders the message, picks up a rewritten file, honors the box, and exits when the file is removed
- [ ] run the new tests and `xcodegen generate` — must pass before task 8

### Task 8: App wiring — font measurement, non-focusing surface, temp-file lifecycle

**Files:**
- Modify: `agterm/agtermApp.swift`
- Modify: `agterm/Control/ControlServer+SessionActions.swift`
- Modify: `agtermTests/ControlServerSessionActionsTests.swift`

- [ ] measure the configured terminal font (name + size) with CTFont advance to build `PaneMetrics`, and derive the pane's live size from the session's surface bounds
- [ ] in `makeOverlaySurface`, spawn a HUD slot with `autoFocus: false` and the HUD environment (`AGTERM_HUD_FILE`, `AGTERM_HUD_COLS`, `AGTERM_HUD_ROWS`, `AGTERM_HUD_SPINNER`), leaving program overlays byte-for-byte unchanged
- [ ] resolve the bundled helper path and shell-escape it through `ShellEscape` into the existing `overlayExitWrapper`
- [ ] implement `openHud`/`updateHud`/`closeHud` in `ControlServer+SessionActions.swift`: write/rewrite the temp file, compute the size via `HudLayout`, honor an explicit `sizePercent` override, and delete the temp file on teardown
- [ ] make the exit-code capture path ignore HUD surfaces so a HUD never records an `overlayExitCode`
- [ ] write tests for environment and command composition, size computation from measured metrics, and temp-file cleanup on close
- [ ] run via `-only-testing:` — must pass before task 9

### Task 9: Zoom resolution

**Files:**
- Modify: `agtermCore/Sources/agtermCore/TerminalZoom.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/TerminalZoomTests.swift`

- [ ] narrow the `.overlay` case so a HUD is not the active zoom target **and** widen `uncovered` (`:56-62`) for the HUD case — narrowing alone leaves no case active and falls through to the `?? .primary` fallback the code documents as unreachable
- [ ] decide once whether the explicit `surface:<id>:overlay` address resolves a HUD or is refused, and pin it
- [ ] verify Command-W dismisses a HUD through the existing cover ladder, and that `coverHidesActiveSession` and `searchTarget` need no change (a floating cover leaves pane search available)
- [ ] write tests asserting mutual exclusivity across all five `isActive` cases with a HUD up, plus the explicit-address decision
- [ ] run `swift test --filter TerminalZoomTests` — must pass before task 10

### Task 10: Overlay-command interplay (app-side)

**Files:**
- Modify: `agterm/Control/ControlServer+SessionActions.swift`
- Modify: `agtermTests/ControlServerSessionActionsTests.swift`

- [ ] make `session.overlay.result` error with a clear message when the slot holds a HUD (`:80`, where store state is known — the host-free dispatcher cannot see slot occupancy)
- [ ] assert `session.overlay.close` closes a HUD as a courtesy — free once Task 3 clears HUD state in `closeOverlay`, but pin it
- [ ] decide and pin `session.overlay.resize` against a HUD — allow it (same field, documented) and assert the HUD survives
- [ ] write tests for all three interactions
- [ ] run via `-only-testing:` — must pass before task 11

### Task 11: agtermctl `session hud`

**Files:**
- Modify: `agtermCore/Sources/agtermctlKit/SessionCommands.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/CommandsTests.swift`

- [ ] add a `hud` subcommand group next to `overlay`: `hud <message> [--detail T] [--spinner] [--position top|center|bottom] [--background-color #rrggbb] [--size-percent N] [--target T] [--window W]`, mapping `--background-color` to `ControlArgs.color` as the overlay group does (`:648`) and deriving the position help text from `HudPosition.allCases`
- [ ] add `hud update <message> [--detail T] [--position P]` and `hud close`, matching the overlay group's shape
- [ ] validate locally what can be validated locally (mutually exclusive arguments, percent range); leave semantic validation to the dispatcher
- [ ] write parsing tests for every flag combination and the rejected ones
- [ ] write tests asserting the emitted request shape for open, update, and close
- [ ] run `swift test --filter CommandsTests` — must pass before task 12

### Task 12: End-to-end UI test

**Files:**
- Create: `agtermUITests/ControlHudUITests.swift`

- [ ] following `ControlPickUITests.swift`'s isolation and socket setup, open a HUD and assert `tree` reports `hud` with the message and `overlay` false
- [ ] assert `position` reads back as `center` when omitted and as the requested value when set
- [ ] update the HUD and assert the read-back changes
- [ ] close it and assert both `hud` and `overlay` are gone
- [ ] assert `overlay result` against a HUD errors
- [ ] run `xcodegen generate`, then only this class via `-only-testing:agtermUITests/ControlHudUITests` — must pass before task 13

### Task 13: Documentation surfaces and command count

**Files:**
- Modify: `plugins/agterm/skills/agterm/SKILL.md`, `reference.md`, `examples.md`
- Modify: `README.md`, `site/commands.html`, `site/docs.html`
- Modify: `.claude/rules/control-api.md`
- Modify: `agtermCore/Tests/agtermCoreTests/SkillInstallTests.swift`

- [ ] add the three commands to the skill's command summary, full reference, and one worked recipe (post a HUD, compute items, open the picker, close the HUD)
- [ ] document the read-back contract everywhere: `hud` object present with the effective `position`, `overlay` false, `overlay.result` refuses, state is poll-only via `tree` with no event
- [ ] document `--position top|center|bottom`, the `center` default, and that `top`/`bottom` hold a fixed edge margin automatically
- [ ] update the count from 71 to 74 in: `SKILL.md:147`, `README.md:187`, `site/commands.html` (four mentions — lines 9, 21, 33, 239), `site/docs.html:1147`, `.claude/rules/control-api.md:86`, and `SkillInstallTests.swift:26`. Search the count pattern rather than assuming these are the only hits
- [ ] add the HUD paragraphs to `control-api.md` under "Overlay, zoom, dashboard, and picker": the deck exemptions, the HUD-replaces/overlay-refuses rule, the zoom narrowing, and the explicit no-GUI-trigger exemption
- [ ] add the three commands to the public catalog list in `control-api.md`
- [ ] decide whether `site/index.html` needs the feature (CLAUDE.md lists it as reflecting major features) and either update it or state the exemption here
- [ ] run `swift test --filter SkillInstallTests` — must pass before task 14

### Task 14: Verify acceptance criteria

- [ ] a HUD posted on a background session appears without stealing selection or focus, and the user can type into the session while it is up
- [ ] the session is neither dimmed nor click-blocked while a HUD is up
- [ ] all three positions place the panel correctly and stay inside the pane at the largest allowed size; an omitted position centers
- [ ] `hud update` changes the text with no visible respawn and resizes the panel when the message grows
- [ ] `overlay open`, `hud` again, `hud close`, Command-W, and session close all tear it down cleanly with no leftover temp file, and the replacing overlay actually renders
- [ ] `tree` never reports a HUD as a program overlay
- [ ] run the full host-free suite: `cd agtermCore && swift test`
- [ ] run `make test-app`
- [ ] run `make lint` — zero findings required

### Task 15: [Final] Update documentation

- [ ] update `README.md` if the feature needs more than the command-reference line
- [ ] update `CLAUDE.md` only if a new pattern was discovered worth recording
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

*Items requiring manual intervention or external systems — no checkboxes, informational only*

**Manual verification:**

- Launch an isolated Debug instance (short `/tmp` `AGTERM_STATE_DIR`, `mkdir -p "$AGTERM_STATE_DIR/windows"`
  to skip the welcome alert) and post a HUD on a background session, then visit it — the panel should already
  be there, typing should reach the terminal, and clicking the session should work.
- Check the spinner's CPU cost with a HUD open for several minutes.
- Check `--position top` and `--position bottom` against a split session and a very short window, where the
  10% edge margin has the least room to work with.
- Check the shadowless frame over busy terminal content (a full-screen TUI, a wall of log output) — that is
  where a border alone has to do the separation the shadow and wash used to do.
- Check the panel against a light theme and a dark theme, with and without `--background-color`, and after a
  manual window resize (the box is app-computed, so a resize without an update will not re-center).

**External system updates:**

- Installed skill copies under `~/.claude/skills/agterm/` and `~/.codex/skills/agterm/` only refresh when the
  user re-runs Help ▸ Install Agent Skill…, and the plugin cache keys on the manifest version — a release bump
  is what propagates the new commands.

Smells pre-check: skipped — non-Go project.
