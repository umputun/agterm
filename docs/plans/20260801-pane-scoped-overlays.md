# Pane-Scoped Overlays

## Overview

Overlays today belong to a session and cover its whole detail area — both split panes plus a shown
scratch. This adds a second, pane-scoped kind: an overlay that belongs to ONE split pane and always
covers exactly that pane, leaving the sibling pane live, visible, and interactive.

The driving case: an agent running in the right pane needs to show a diff, picker, or TUI over its own
pane without blanking the user's left pane. Left and right pane overlays are independent and may be open
at the same time.

Delivered as a `--pane left|right` flag on the existing `session.overlay.*` commands. Omitting `--pane`
keeps today's session-wide behavior unchanged.

## Context (from discovery)

- `agtermCore/Sources/agtermCore/Session.swift:142-183` — the eight session-overlay fields and the
  `fullOverlayActive` / `floatingOverlayActive` derivations.
- `agtermCore/Sources/agtermCore/AppStore+Panes.swift` — `openOverlay` / `resizeOverlay` /
  `recordOverlayExit` / `closeOverlay`, plus the split lifecycle (`closeSplit`, `closePrimaryPane`,
  `closeSplitPane`) whose promotion path already migrates `restoreCommand` / `splitRestoreCommand`
  (line 108) — the exact precedent for migrating a pane overlay.
- `agterm/Views/WindowContentView.swift:429-557` — `sessionDetail` with its three render sites, and
  `overlayPanel` (`:562`), the always-present-sibling pattern this feature copies. The boundary note
  about not perturbing the NSSplitView wrapper is at `:514-519`.
- `agtermCore/Sources/agtermCore/ControlDispatcher.swift` — `protocol ControlActions` (`:66-70`),
  `ControlSessionOverlayOpenOptions` (`:106`), and ALL host-free overlay validation (`:523-556`). Per
  `.claude/rules/control-api.md`, validation belongs here, never in the app-side fallback switch.
- `agtermCore/Sources/agtermCore/ControlProtocol.swift:146-152` — `ControlArgs.pane` (reached as
  `request.args?.pane`) already exists and is shared by `session.focus` / `text` / `type` / `status` /
  `restore`, so `--pane` on the overlay commands is zero protocol churn. Its doc comment enumerates the
  consuming commands and must be extended.
- `agterm/agtermApp.swift:399-428` — `makeOverlaySurface`, which already mints a per-overlay temp
  exit-code file, so per-pane exit capture needs no new mechanism. The factory closure is threaded
  through `agterm/ContentView.swift:18,65` and consumed at `agterm/Views/WindowContentView+Zoom.swift:177`.

**Overlay surfaces are torn down at FIVE sites** — all five must learn about pane overlays or a
`GhosttySurfaceView` leaks with a live process, along with the store→session→surface→closure retain cycle
`.claude/rules/libghostty.md` warns about:

| site | context |
|---|---|
| `AppStore+Panes.swift:194` | `closeOverlay` |
| `AppStore.swift:425` | `closeSession` |
| `AppStore.swift:459` | `removeWorkspace` |
| `AppStore+PendingClose.swift:405` | `hardFinalizePendingSession` |
| `agterm/Views/WindowAccessor.swift:151` | window close |

Related patterns to follow: paired pane fields (`surface`/`splitSurface`, `fontSize`/`splitFontSize`,
`restoreCommand`/`splitRestoreCommand`); observed state vs `@ObservationIgnored` surfaces; constant-shape
ZStacks with swapped content.

## Development Approach

- **testing approach**: Regular (code first, then tests) — matching how the surrounding store/protocol
  work is structured, with host-free tests in `agtermCore` and hosted coverage in `agtermUITests`.
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional — they are a required part of the checklist
  - write unit tests for new functions/methods and for modified ones
  - add new test cases for new code paths; update existing cases if behavior changes
  - tests cover both success and error scenarios
- **CRITICAL: all tests must pass before starting the next task** — no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- run tests after each change
- maintain backward compatibility: omitting `--pane` must behave exactly as today

**Task ordering rationale:** the control path (Tasks 4-5) lands BEFORE rendering (Task 6) so the render
work is verifiable end-to-end the moment it exists. Pane overlays are control-native only — there is no
keymap or menu trigger — so rendering built first would have no way to be exercised.

### Project gates (every task)

Per project CLAUDE.md, each task is done only when all of these pass:

- `cd agtermCore && swift test` (host-free)
- `make test-app` (hosted AppKit)
- `make lint` (strict SwiftLint, zero findings — 200-col lines, 1000-line files, 800-line types)
- the change builds

`WindowContentView.swift` is already close to the 1000-line limit. If this feature pushes it over, ask
before splitting — do not raise the limit reflexively.

## Testing Strategy

- **unit tests**: required for every task, one test file per source file, in the module that can import
  the code under test:
  - `agtermCore/Tests/agtermCoreTests/SessionTests.swift` — `Session` derivations and predicates
  - `agtermCore/Tests/agtermCoreTests/AppStorePaneTests.swift` — overlay/split/scratch store lifecycle
  - `agtermCore/Tests/agtermCoreTests/TerminalZoomTests.swift` — surface enum predicates, `TerminalSurfaceID`
  - `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift` — request/response round-trips
  - `agtermCore/Tests/agtermCoreTests/ControlDispatcherTests.swift` — host-free command validation
  - `agtermCore/Tests/agtermctlKitTests/CommandsTests.swift` — **CLI flag parsing lives here**, a separate
    test target; `agtermCoreTests` does not import `agtermctlKit` and cannot test CLI flags
- **hosted UI tests** (`agtermUITests/`): `ControlOverlaySplitUITests.swift` for overlay-plus-split
  behavior, `ControlSurfaceZoomUITests.swift` for zoom addressing.
- **manual verification**: rendering behavior with no automated oracle (titlebar overrun, cursor shape,
  translucency bleed) is verified by eye on an isolated Debug instance at Task 6.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview

A pane overlay is modeled as a pair of explicit slots on `Session` — `leftOverlay` / `rightOverlay` —
rather than a dictionary, matching every existing pane pairing in the codebase. The observed slot being
non-nil IS the "active" signal; the surface lives in a separate `@ObservationIgnored` field because
`TerminalView` writes it back during view update and an observed write there would loop.

Rendering reuses the `overlayPanel` technique: an always-present sibling whose content is gated inside a
`GeometryReader`, placed INSIDE each pane's ZStack. Everything stays inside the NSSplitView arranged
subview, never in a modifier wrapping it.

**Key design decisions and rationale:**

1. **`--pane` on the existing commands, not a new command** — a separate command would duplicate the
   whole open/close/result surface.
2. **Always full-pane, no size percent** — a floating panel already exists at session scope; a
   pane-scoped floating panel adds a variant with no use case. `overlay resize` therefore takes no
   `--pane`.
3. **Paired slots, not a dictionary** — consistent with the codebase, gives plain keyPaths for
   `TerminalView`, and preserves the observed/ignored split the current code deliberately maintains.
4. **`--pane left` allowed on a non-split session** — a non-split session reports `AGTERM_PANE=left`
   (`agtermApp.swift:76` passes `pane: .left` unconditionally), so an agent can pass
   `--pane "$AGTERM_PANE"` without branching on split state.
5. **Opening on an unmounted pane is rejected** — surfaces defer creation until nonzero backing size
   (`pendingSurfaceCreation`), so accepting it would leave a dead state: slot active, no surface, program
   never started. Hiding the split AFTER opening is fine — the surface exists, unmounts, the program
   keeps running, and a re-show remounts it.
6. **Zoom included** — `surfaces[]` is derived from `TerminalZoomSurface.allCases`, so reporting a pane
   overlay in the tree and making it zoomable are the same change. Reporting it without making it
   zoomable would break the documented contract that `surfaces[].id` IS the zoom address.
7. **`⌘W` dismisses a pane overlay before closing the session** — the cover ladder in
   `AppActions.closeActiveSession` currently falls through to closing the session when only a pane
   overlay is up, which is a destructive default. A pane-overlay rung is in scope even though GUI
   *exposure* is not: this is protecting an existing binding, not adding one.
8. **A pane overlay behaves EXACTLY like a session overlay in every respect but geometry and scope.**
   This is a hard requirement, not an aspiration:
   - it stays up for as long as its program runs and closes automatically when the program exits
   - `--wait` holds it open after exit with the press-any-key prompt and final output intact
   - `--block` blocks the CLI invocation, polling `session.overlay.result` until the program exits, then
     exits with the program's own status; `--block` and `--wait` stay mutually exclusive
   - `--background-color`, `--cwd`, and `--follow` behave identically. Each pane overlay owns its own
     surface, so two open at once may carry DIFFERENT background colors; the color is a per-surface
     libghostty config overlay (`GhosttySurfaceView+Config.swift:78`) that also lifts
     `background-opacity` off zero, which is what makes it visible on a full-pane overlay at all. It is
     baked at open time and does not re-track a later window-opacity change — inherited, not new.

   The failure mode to guard against: `--block` currently polls with `target: id` and NO pane
   (`SessionCommands.swift:648`), so against a pane overlay it would query the session-wide slot and hang
   forever. The `resultRequest(id:)` seam in Task 5 exists for this.
9. **`--pane-id` deferred** — the promote-safe token that `session status` and `session restore` accept
   is not in this change. Overlays are ephemeral, so a stale `--pane` after promote+re-split is a narrow
   window. It can be added later without breaking anything.

**Precedence** is a total order that falls out of the existing layering, requiring no re-layering:

```
session overlay (zIndex 3, hides everything)
  > scratch (zIndex 1, full coverage)
    > pane overlay (inside the pane's ZStack)
      > pane
```

Because `.opacity(hideForOverlay ? 0 : 1)` at `WindowContentView.swift:514` wraps the pane Group, a pane
overlay placed inside a pane ZStack is hidden by a full session overlay or the scratch for free.

## Technical Details

### New types (agtermCore)

```swift
/// Which pane a pane-scoped overlay covers. Deliberately two cases rather than reusing `StatusPane`:
/// a scratch overlay is not representable, so no call site needs a scratch guard.
public enum OverlayPane: String, CaseIterable, Codable, Sendable {
    case left
    case right

    public init?(controlName: String)   // "left"/"primary", "right"/"split"; nil otherwise
}

/// One pane's ephemeral overlay. The surface lives beside this in `leftOverlaySurface` /
/// `rightOverlaySurface`, not inside, because `TerminalView` writes that slot back during view update.
public struct PaneOverlay: Equatable, Sendable {
    public var command: String
    public var cwd: String?
    public var backgroundColor: String?
    public var wait: Bool
}
```

### New `Session` fields

```swift
public var leftOverlay: PaneOverlay?                                    // observed; nil == not active
@ObservationIgnored public var leftOverlaySurface: (any TerminalSurface)?
@ObservationIgnored public var leftOverlayExitCode: Int?
public var rightOverlay: PaneOverlay?
@ObservationIgnored public var rightOverlaySurface: (any TerminalSurface)?
@ObservationIgnored public var rightOverlayExitCode: Int?
```

The exit code is a SEPARATE field, not a member of `PaneOverlay`, because `overlay result` must be
readable AFTER the overlay closes and its slot goes nil — mirroring how `overlayExitCode` today survives
`closeOverlay` and is reset on the next open.

### New `Session` members

```swift
public func paneOverlay(_ pane: OverlayPane) -> PaneOverlay?
public func paneOverlaySurface(_ pane: OverlayPane) -> (any TerminalSurface)?
public var openPaneOverlays: [OverlayPane]        // ordered left, right — the tree read-back source
public func rendersPane(_ pane: OverlayPane) -> Bool
/// The focused pane's overlay pane, nil when that pane has none. Backs `topmostSurface`'s pane rung:
/// the focused pane is `.right` when `splitFocused && splitSurface != nil` (the `activeSurface` idiom),
/// else `.left`; the result is nil unless that pane's slot is occupied.
public var focusedOverlayPane: OverlayPane?
```

`rendersPane` is the host-free predicate behind the unmounted-pane rejection, derived from the same
three cases `sessionDetail` branches on (`WindowContentView.swift:454`, `:493`, `:503`):

| Session state | left rendered | right rendered |
|---|---|---|
| `isSplit` | yes | yes |
| `!isSplit && splitFocused && splitSurface != nil` | no | yes |
| otherwise | yes | no |

Note: `rendersPane` is NOT the same predicate as `deckHostsSurface`, which yields a placeholder while
zoom or the dashboard owns a slot. `rendersPane` answers "does `sessionDetail` lay this pane out at all",
which is what surface realization depends on. The two must not be conflated.

### `topmostSurface` precedence

```swift
if overlayActive { return overlaySurface }
if scratchActive { return scratchSurface }
if let pane = focusedOverlayPane { return paneOverlaySurface(pane) }
return activeSurface
```

### `TerminalZoomSurface` additions and predicate exclusivity

Two cases are added: `overlayLeft = "overlay-left"`, `overlayRight = "overlay-right"`.
`TerminalSurfaceID` needs no parser change (still three colon-separated parts; hyphens are irrelevant).

`TerminalZoomController.resolveTarget` (`TerminalZoom.swift:159`) picks the zoom target via
`allCases.first { $0.isActive(in: session) }` and depends on the predicates being MUTUALLY EXCLUSIVE, so
the existing cases must be narrowed in the same change:

| case | `isActive(in:)` |
|---|---|
| `.primary` | `!overlayActive && !scratchActive && !splitFocused && leftOverlay == nil` |
| `.overlayLeft` | `!overlayActive && !scratchActive && !splitFocused && leftOverlay != nil` |
| `.split` | `!overlayActive && !scratchActive && splitFocused && rightOverlay == nil` |
| `.overlayRight` | `!overlayActive && !scratchActive && splitFocused && rightOverlay != nil` |

`.overlay` (`overlayActive`) and `.scratch` (`!overlayActive && scratchActive`) are unchanged and remain
disjoint from all four.

`isAvailable` for the new cases is `paneOverlay(pane) != nil`. `isVisible` mirrors the corresponding
pane's visibility with the slot check, and `.primary`/`.split` `isVisible` each gain
`&& <that pane's overlay> == nil`, since a pane renders at opacity 0 under its own overlay.

`DashboardTarget.init?(rawValue:)` parses with an allowlist (`left`/`right` only, falling to
`default: return nil` at `DashboardTarget.swift:36-40`), so the new cases cannot leak into dashboard
cells — no change needed, but a regression test pins it.

### Control surface

| command | change |
|---|---|
| `session.overlay.open` | accepts `--pane left\|right` |
| `session.overlay.close` | accepts `--pane`; omitted targets the session-wide overlay |
| `session.overlay.result` | accepts `--pane`; omitted targets the session-wide overlay |
| `session.overlay.resize` | rejects `--pane` — pane overlays are always full |

Validation splits by what it needs to know, per `.claude/rules/control-api.md`:

- **host-free, in `ControlDispatcher.swift`** (needs only the request): invalid `--pane` value,
  `--pane` combined with `--size-percent`, `--pane` on `session.overlay.resize`.
- **app-side, in `ControlServer+SessionActions.swift`** (needs the live session): already open, pane
  not visible.

`ControlActions` signature changes — `closeSessionOverlay(_:window:)` and `sessionOverlayResult(_:window:)`
gain a pane parameter, and `ControlSessionOverlayOpenOptions` gains a `pane` member. The `ControlActions`
test double `MockControlActions.swift` must be updated in the same task or the test target will not
compile.

New error strings, added beside the existing overlay error constants:

- `"pane overlay already open"` — that pane already has one
- `"pane not visible"` — the target pane is not currently rendered
- `"session.overlay: --pane must be left or right"` — invalid `--pane` (notably `scratch`)
- `"session.overlay.open: --pane is mutually exclusive with --size-percent"`
- `"session.overlay.resize: --pane is not supported (pane overlays are always full)"`

Read-back on `ControlSessionNode`: `paneOverlays: [String]?` — `["left"]`, `["right"]`, or
`["left","right"]`, omitted when none. `surfaces[]` extends automatically from the new enum cases.

### CLI details

`validatePaneArgument` (`SessionCommands.swift:9`) is SHARED and accepts `left|right|scratch` (it
validates against `StatusPane`). The overlay commands must NOT reuse it — they need their own
`left|right` validator, or `--pane scratch` reaches the socket instead of failing as a clean usage error.

`overlay open --block` builds its poll request inline inside `run()` (`SessionCommands.swift:649`), which
needs a live socket and is therefore unreachable from `CommandsTests`. Extract a `resultRequest(id:)`
helper on `Open` so the `--pane` forwarding is assertable.

### Processing flow (open)

1. Dispatcher: parse `--pane` → `OverlayPane` (reject invalid); reject if `--size-percent` also given.
2. App side: resolve target session.
3. Reject if `session.paneOverlay(pane) != nil`.
4. Reject if `!session.rendersPane(pane)`.
5. Store the `PaneOverlay`, clear that pane's exit code.
6. The detail pane's always-present sibling realizes, calling the overlay factory with the pane so it
   reads that slot's command/cwd/wait/backgroundColor.
7. On exit, `onExitCodeCaptured` records into that pane's exit-code field and `onExit` closes that slot.

## What Goes Where

- **Implementation Steps** (`[ ]` checkboxes): code, tests, and documentation changes in this repo.
- **Post-Completion** (no checkboxes): manual visual verification and anything needing external action.

## Implementation Steps

### Task 1: Add the OverlayPane / PaneOverlay model and Session slots

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Session.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/SessionTests.swift`

- [x] add `OverlayPane` (with `init?(controlName:)`) and `PaneOverlay` to `Session.swift`
- [x] add the six paired slots (`leftOverlay`/`rightOverlay`, their surfaces, their exit codes) with the
      observed vs `@ObservationIgnored` split documented on the surface fields
- [x] add `paneOverlay(_:)`, `paneOverlaySurface(_:)`, `openPaneOverlays`, and `focusedOverlayPane`
- [x] add `rendersPane(_:)` implementing the three-case table in Technical Details
- [x] write tests for `OverlayPane.init?(controlName:)` (left/primary/right/split accepted, `scratch`
      and unknown rejected)
- [x] write tests for `rendersPane` across all three session shapes, including the hidden-split-focused
      case and a session with no split surface
- [x] write tests for `focusedOverlayPane` (nil when the focused pane's slot is empty, `.right` only
      when `splitFocused` AND `splitSurface != nil`, `.left` after a promotion)
- [x] run `cd agtermCore && swift test` — must pass before task 2

### Task 2: Add store open / close / exit-record for pane overlays

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore+Panes.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStorePaneTests.swift`

- [x] add `openPaneOverlay(_:pane:command:cwd:wait:backgroundColor:)` returning a typed failure reason
      (already open / pane not visible) rather than a bare `Bool`, so the caller can pick the error string
- [x] add `closePaneOverlay(_:pane:)` — tears the surface down and clears the slot, leaving the exit code
- [x] add `recordPaneOverlayExit(_:pane:code:)`
- [x] verify opening clears that pane's stale exit code, and that closing does NOT
- [x] write tests for open success on both panes, including left and right open simultaneously and
      independent of a session-wide overlay
- [x] write tests for both rejection paths (already open, pane not rendered)
- [x] write tests for close + exit-code retention and for the next-open reset
- [x] write a test that `wait` round-trips into the stored `PaneOverlay`, so the factory can apply
      `waitAfterCommand` and `--wait` is not silently dropped
- [x] write a test that two pane overlays open at once hold INDEPENDENT `backgroundColor` and `cwd`
      values, so neither slot can shadow the other
- [x] run `cd agtermCore && swift test` — must pass before task 3

### Task 3: Free pane overlays at every teardown site

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Session.swift` (➕ the shared `teardownPaneOverlay(_:)` /
  `teardownPaneOverlays()` / `promotePaneOverlay()` helpers the five sites call)
- Modify: `agtermCore/Sources/agtermCore/AppStore+Panes.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+PendingClose.swift`
- Modify: `agterm/Views/WindowAccessor.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStorePaneTests.swift`

- [x] `closeSplit` tears down the right pane overlay and clears its slot and exit code
- [x] `closePrimaryPane` MIGRATES the right pane overlay (slot, surface, exit code) into the left slot
      alongside the promoted survivor, and tears down the dying left one — following the
      `restoreCommand`/`splitRestoreCommand` migration at the same site (`AppStore+Panes.swift:108`)
- [x] `closeSplitPane` frees the right slot
- [x] free both slots at `AppStore.closeSession` (`:425`), `AppStore.removeWorkspace` (`:459`),
      `AppStore+PendingClose.hardFinalizePendingSession` (`:405`), and `WindowAccessor` window close
      (`:151`) — each alongside the existing `overlaySurface?.teardown()` call
- [x] confirm store-capturing callbacks are nilled on teardown so no store→session→surface→closure cycle
      survives, per `.claude/rules/libghostty.md` — `teardown()` routes to
      `GhosttySurfaceView.destroySurface`, which nils `onExit` / `onExitCodeCaptured` and the rest after
      handing off the captured exit status
- [x] confirm `clearIndicatorOwnedByPane` and `clearSearch` interactions are unaffected — both key off
      `StatusPane` / `searchSurface`, neither of which a pane overlay surface can occupy yet (search
      targeting is Task 7)
- [x] write tests for promotion migrating a right overlay to left with its exit code intact
- [x] write tests for `closeSplit` tearing down only the right overlay, leaving a left one alive
- [x] write tests that session close, workspace removal, and pending-close finalization each free both slots
- [x] run `cd agtermCore && swift test`, `make lint` — must pass before task 4

### Task 4: Extend the control protocol and dispatcher

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`
- Modify: `agtermCore/Sources/agtermCore/Session.swift` (➕ the `paneOverlayExitCode(_:)` accessor the
  `overlay.result --pane` arm reads)
- Modify: `agterm/Control/ControlServer+SessionActions.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/MockControlActions.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStorePaneTests.swift` (➕ the `controlTree` population test,
  which needs a live store)
- Add: `agtermCore/Tests/agtermCoreTests/ControlDispatcherOverlayTests.swift` (➕ `ControlDispatcherTests`
  was at 1960 of its 2000-line cap, so the `session.overlay.*` family moved out whole, following the
  existing `ControlDispatcherDashboardTests` / `…PickTests` / `…WorkspaceTests` carve-outs)

- [x] add the five new error strings beside the existing overlay error constants
- [x] extend the `ControlArgs.pane` doc comment (`ControlProtocol.swift:146-152`) to name the overlay
      commands and their `left|right`-only semantics
- [x] add `paneOverlays: [String]?` to `ControlSessionNode`, populated from `openPaneOverlays` in
      `AppStore.controlTree` (`AppStore.swift:252` area)
- [x] add `pane` to `ControlSessionOverlayOpenOptions` and to the `closeSessionOverlay` /
      `sessionOverlayResult` signatures on `ControlActions`, updating `MockControlActions`
- [x] put host-free validation in `ControlDispatcher` (invalid pane, `--pane` with `--size-percent`,
      `--pane` on resize) and session-dependent rejections (already open, pane not visible) in
      `ControlServer+SessionActions.swift` — never in the app-side fallback switch
- [x] write dispatcher tests for each host-free rejection asserting the exact error strings, including
      `--pane` on `session.overlay.resize`
- [x] write tests for `paneOverlays` read-back — omitted when none, both panes when both open
- [x] write tests that omitting `--pane` still drives the session-wide overlay unchanged
- [x] run `cd agtermCore && swift test`, `make lint` — must pass before task 5

### Task 5: Add --pane to agtermctl

**Files:**
- Modify: `agtermCore/Sources/agtermctlKit/SessionCommands.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/CommandsTests.swift`

- [x] add `--pane` to `overlay open`, `overlay close`, and `overlay result` with help text stating pane
      overlays are always full-pane
- [x] add an overlay-specific `left|right` validator — do NOT reuse the shared `validatePaneArgument`
      (`SessionCommands.swift:9`), which also accepts `scratch`
- [x] extract `resultRequest(id:)` on `Open` so the `--block` poll request is reachable from tests, and
      forward `--pane` through it
- [x] leave `overlay resize` without a `--pane` option
- [x] write tests for request construction from each flag combination
- [x] write a test that `--pane scratch` fails as a CLI usage error before any socket round-trip
- [x] write a test that `--block` forwards `--pane` into the poll request — without it the poll queries
      the session-wide slot and blocks forever
- [x] write a test that `--block` with `--wait` is still rejected at parse time when `--pane` is given
- [x] run `cd agtermCore && swift test`, `make lint` — must pass before task 6
- ➕ `Open.validate()` also rejects `--pane` with `--size-percent` at parse time, matching the file's
      convention of catching mutually-exclusive combos before the socket; the dispatcher still re-checks it
      for raw socket clients

### Task 6: Render pane overlays at all three sites

**Files:**
- Modify: `agterm/agtermApp.swift`
- Modify: `agterm/ContentView.swift`
- Modify: `agterm/Views/WindowContentView.swift`
- Modify: `agterm/Views/WindowContentView+Zoom.swift`
- Modify: `agtermUITests/ControlOverlaySplitUITests.swift`

- [ ] give `makeOverlaySurface` an `OverlayPane?` parameter so it reads the right slot's
      command/cwd/wait/backgroundColor and routes `onExit`/`onExitCodeCaptured` to that pane, updating
      the closure type threaded through `ContentView.swift:18,65` and its use at
      `WindowContentView+Zoom.swift:177`
- [ ] add `paneOverlayPanel(session:pane:isActive:)` — an always-present sibling with content gated
      inside a `GeometryReader`, modeled on `overlayPanel` (`WindowContentView.swift:562`)
- [ ] place it inside BOTH arranged-subview ZStacks at render site 1, and add the missing ZStack
      wrappers at sites 2 and 3 so the sibling has a home there too
- [ ] hide a pane under its own overlay (opacity 0, hit-testing off) WITHOUT touching any modifier that
      wraps the NSSplitView — see the boundary note at `WindowContentView.swift:514-519`
- [ ] write a hosted test asserting `splitRatio` in `tree --json` is unchanged across a pane-overlay
      open and close — the value is captured from the live NSSplitView, so it is a real oracle for the
      divider-normalize regression
- [ ] write a hosted test asserting the sibling pane stays visible and interactive while one pane's
      overlay is up
- [ ] verify by eye on an isolated Debug instance (see Post-Completion for the procedure)
- [ ] run `make test-app`, `make lint` — must pass before task 7

### Task 7: Per-pane visibility, focus, and cover handling

**Files:**
- Modify: `agterm/Views/WindowContentView.swift`
- Modify: `agterm/AppActions.swift`
- Modify: `agterm/AppActions+Focus.swift`
- Modify: `agterm/Notifications/NotificationManager.swift`
- Modify: `agtermCore/Sources/agtermCore/Session.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/SessionTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreFocusTests.swift`

- [ ] make the pane's `deckVisible` and `isActive` each account for that pane's own overlay, so a
      covered pane registers no drag types and sets no mouse cursor (the issue #225 class)
- [ ] update `topmostSurface` to the four-level precedence in Technical Details
- [ ] pass `isActive` to the pane overlay so one opening on the UNFOCUSED pane does not pull focus, and
      drive the bounded focus retry on close as `session.overlayActive`'s `onChange` does
- [ ] route `focusSplitPane` (`AppActions+Focus.swift:181`) through the pane's overlay when one is up,
      so `session.focus right` cannot make a covered pane first responder
- [ ] extend `searchTarget` (`AppActions.swift:771`) and `coverHidesActiveSession` so ⌘F does not open
      the bar over a pane hidden by its own overlay
- [ ] insert a pane-overlay rung into the `closeActiveSession` cover ladder
      (`AppActions.swift:229-230`), between scratch and closing the session, so ⌘W dismisses the overlay
      instead of closing the session
- [ ] map a pane-overlay surface in `NotificationManager.paneRole` (`:202-206`) so banner-click reveal
      focuses the right surface instead of falling through to `.main`
- [ ] write tests for `topmostSurface` across the precedence matrix (session overlay, scratch, focused
      pane overlay, unfocused pane overlay, bare pane)
- [ ] write tests for focus routing with a pane overlay on the focused and unfocused pane
- [ ] run `cd agtermCore && swift test`, `make test-app`, `make lint` — must pass before task 8

### Task 8: Add the zoom surface cases and restore predicate exclusivity

**Files:**
- Modify: `agtermCore/Sources/agtermCore/TerminalZoom.swift`
- Modify: `agterm/Views/WindowContentView+Zoom.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/TerminalZoomTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/DashboardTargetTests.swift`

- [ ] add `overlayLeft` / `overlayRight` cases with their `controlName` spellings
- [ ] implement `isAvailable` / `isActive` / `isVisible` for both, and NARROW `.primary` / `.split` per
      the table in Technical Details
- [ ] update BOTH exhaustive switches in `WindowContentView+Zoom.swift` — `zoomedSessionTerminal`
      (`:163`) and `focusZoomedSessionSurface` (`:191-196`) — and claim the slot in `deckHostsSurface`
- [ ] write a property test asserting AT MOST ONE case satisfies `isActive` across a matrix of session
      states (split on/off, focus left/right, scratch on/off, session overlay on/off, each pane overlay
      on/off) — this is the exclusivity guarantee `resolveTarget` relies on
- [ ] write tests for `TerminalSurfaceID` round-tripping `surface:<uuid>:overlay-left` and `-right`
- [ ] write a regression test that `DashboardTarget` still refuses `overlay-left` / `overlay-right`
- [ ] run `cd agtermCore && swift test`, `make lint` — must pass before task 9

### Task 9: Hosted UI coverage

**Files:**
- Modify: `agtermUITests/ControlOverlaySplitUITests.swift`
- Modify: `agtermUITests/ControlSurfaceZoomUITests.swift`

- [ ] add a test opening both pane overlays simultaneously and closing them independently
- [ ] add a test asserting the rejection when the split is hidden
- [ ] add a test that ⌘W dismisses a pane overlay rather than closing the session
- [ ] add a zoom test addressing `surface:<id>:overlay-right` and returning to the deck
- [ ] run `make test-app` — must pass before task 10

### Task 10: Update the synchronized documentation surfaces

**Files:**
- Modify: `plugins/agterm/skills/agterm/SKILL.md`
- Modify: `plugins/agterm/skills/agterm/reference.md`
- Modify: `plugins/agterm/skills/agterm/examples.md`
- Modify: `README.md`
- Modify: `site/commands.html`
- Modify: `site/docs.html`

- [ ] document `--pane` on the three overlay commands and the always-full-pane rule in the skill
- [ ] document the `paneOverlays` tree field and the `overlay-left` / `overlay-right` surface ids
- [ ] add an examples.md recipe for the agent case (`--pane "$AGTERM_PANE"` against
      `"$AGTERM_SESSION_ID"`)
- [ ] mirror the command, its arguments, and the read-back field into `site/commands.html`, and the
      feature into `README.md` + `site/docs.html`
- [ ] confirm `plugins/agterm/skills/agterm/troubleshooting.md` needs no change (it mentions overlays)
- [ ] do NOT bump any command count — this adds arguments, not commands, so `SkillInstallTests`'
      `Command summary (N commands)` assertion and the count mentions in `site/commands.html` stay put
- [ ] do NOT touch `CHANGELOG.md` (release-only) or `cookbook/` (not a synchronized surface)
- [ ] run `cd agtermCore && swift test`, `make lint` — must pass before task 11

### Task 11: Verify acceptance criteria

- [ ] verify all requirements from Overview are implemented
- [ ] verify every decision in Solution Overview holds in the shipped code, especially: omitting
      `--pane` is byte-for-byte today's behavior; pane overlays reject a size percent; a non-split
      session accepts `--pane left`; ⌘W dismisses before closing
- [ ] verify the behavioral-equivalence requirement end-to-end on a real pane overlay: it auto-closes on
      program exit, `--wait` holds it open, and `--block` returns the program's own exit status
- [ ] verify the cross-surface contract in project CLAUDE.md: protocol, dispatcher, CLI, read-back,
      and protocol/end-to-end tests all exist for the new arguments
- [ ] verify no overlay surface leaks: grep every `overlaySurface?.teardown()` site and confirm a pane
      equivalent sits beside it
- [ ] run full host-free suite: `cd agtermCore && swift test`
- [ ] run hosted suite: `make test-app`
- [ ] run `make lint` — zero findings required

### Task 12: [Final] Update documentation

- [ ] update `README.md` if any behavior drifted from Task 10
- [ ] update project `CLAUDE.md` / `.claude/rules/libghostty.md` if the per-pane rendering or gating
      established a new constraint worth pinning
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

*Items requiring manual intervention or external systems — no checkboxes, informational only*

**Manual verification** (Task 6 gate, and again before merge):

Launch an isolated Debug instance — never the default socket, never the deployed app:

```bash
mkdir -p /tmp/agt-po
open -n build/DerivedData/Build/Products/Debug/agterm.app --env AGTERM_STATE_DIR=/tmp/agt-po
```

Address its CLI with the Debug binary's full path and the same `AGTERM_STATE_DIR`. Then:

- split a session, set a non-default divider (`session resize --split-ratio 0.3`), open a pane overlay on
  the right, and confirm the divider does not jump to center — the automated oracle covers this, but a
  visual pass catches transient jumps a settled read would miss
- confirm the overlay does not bleed up into the titlebar, in BOTH normal (48px) and compact (30px)
  toolbar modes
- confirm the left pane stays readable and clickable while the right overlay is up
- confirm the mouse cursor over the left pane is not driven by the covered right pane (issue #225 class)
- confirm a file drag onto the covered pane is not accepted
- confirm window translucency: the covered pane does not bleed through its overlay
- stop the instance with SIGTERM on its known PID only

**Follow-up work deliberately out of scope:**

- `--pane-id TOKEN` support on `overlay open`, for promote-safety symmetry with `session status` and
  `session restore`
- GUI / keymap exposure for pane overlays (this change is control-native only, like the session overlay;
  the ⌘W rung in Task 7 protects an existing binding rather than adding one)

---

Smells pre-check: skipped — non-Go project

Plan-review: NEEDS REVISION applied — added the four missed teardown sites, retargeted validation to
`ControlDispatcher`, retargeted CLI tests to `agtermctlKitTests`, defined `focusedOverlayPane`, added the
⌘W / focus / search / notification gaps, and resequenced so the control path precedes rendering.
