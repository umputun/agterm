# Overlay `--follow` Symmetry (unify full + floating overlay behavior)

## Overview

Make `session overlay open` behave identically for full and floating (`--size-percent`) overlays from
the CLI / control-API / user point of view. The only difference between the two becomes purely visual:
a full overlay hides the session; a floating overlay draws a sized panel over the still-visible session.

- **Default (new):** `overlay open` opens on `--target` and does NOT change the active session. Both kinds
  run their program immediately in the background; the panel appears when the user is on that session.
- **`--follow` (new opt-in flag):** after opening, select/switch to `--target` (no-op if already active).

**Problem it solves:** today a floating overlay ALWAYS auto-selects (switches to) its target, because the
floating surface only mounted for the active session. That is surprising, inconsistent with the full
overlay (which never switches), untested, and invisible to the agent skill. This change removes the
special case and gives the caller explicit control via `--follow`.

## Context (from discovery + brainstorm)

- **Render risk already retired via a spike** on this `overlay-follow-spike` worktree (uncommitted in
  `agterm/Views/WindowContentView.swift`): the floating overlay was moved in-deck into `sessionDetail` as
  an ALWAYS-PRESENT, constant-shape sibling (`floatingOverlayPanel(session:isActive:)`), and the
  `detailPane` `.overlay { floatingOverlayLayer }` was removed. This makes the floating surface mount
  per-session in the eager deck (so it runs regardless of which session is active) WITHOUT re-hosting the
  `NSSplitView` (the titlebar-overrun landmine). Verified: no overrun on a split+floating session (visual,
  user-confirmed), the panel renders correctly, and `ControlOverlaySplitUITests` (18 tests) all pass.
- Today's auto-select lives in `ControlServer+SessionActions.swift` `openSessionOverlay`:
  `if options.sizePercent != nil { store.selectSession(id) }`.
- Full overlay already runs in the background without selecting (mounts in the eager deck) — this is the
  parity target for floating.
- The floating-switch behavior is currently documented on master (`SKILL.md`/`reference.md`/`examples.md`
  + `control-api.md` ~line 463) from the doc commit `98b1f0c`; those notes get rewritten to the
  `--follow` model.

**Files involved:**
- `agterm/Views/WindowContentView.swift` — render (spike done; productionize)
- `agterm/Control/ControlServer+SessionActions.swift` — the select gate (+ a stale scratch-arm comment)
- `agtermCore/Sources/agtermCore/ControlDispatcher.swift` — `ControlSessionOverlayOpenOptions.follow`
  (struct at ~line 65) AND the `.sessionOverlayOpen` construction site (~lines 294-308) that must populate it
- `agtermCore/Sources/agtermCore/ControlProtocol.swift` — the `follow` wire arg
- `agtermCore/Sources/agtermctlKit/SessionCommands.swift` — the `--follow` CLI flag
- `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift` (round-trip),
  `agtermCore/Tests/agtermCoreTests/ControlDispatcherTests.swift` (arg→options routing — the feature crux),
  `agtermCore/Tests/agtermctlKitTests/CommandsTests.swift` (CLI parse)
- `agtermUITests/ControlOverlaySplitUITests.swift` — e2e
- `agterm/Resources/agent-skill/{SKILL,reference,examples}.md`, `.claude/rules/control-api.md`,
  `README.md`, `site/docs.html` — docs (keep-in-sync)

## Development Approach

- **testing approach:** regular (code then tests, in the same task). agtermCore logic is unit-tested with
  `swift test`; app-target behavior is verified by XCUITest e2e.
- complete each task fully before the next; run tests after each change.
- **every task includes its tests.** App-target-only tasks (render, ControlServer gate) have no host-free
  unit test — their behavior is locked by the Task 5 XCUITest e2e; those tasks note the dependency and are
  not considered done until Task 5 is green.
- **Keep-in-sync (HARD control-API convention):** `overlay.open` is an existing command, so no new
  `Command` case — `follow` is a new optional ARG. `overlay.open` is DISPATCHER-FIRST: the wire arg is
  threaded through `ControlDispatcher`'s `.sessionOverlayOpen` arm into `ControlSessionOverlayOpenOptions`,
  which the app-side `ControlServer` reads. Parity requires all of: the arg in `ControlProtocol` +
  `ControlDispatcher` (Task 2), the `ControlServer` arm reading it (Task 3), the `agtermctl` flag (Task 4),
  and dispatcher-routing + round-trip + e2e tests (Tasks 2/4/5). Also the 4th surface (agent skill) +
  rule/README/site docs (Task 6).
- **Behavior change:** flips floating's default from always-switch to never-switch. `CHANGELOG.md` is
  release-only per project rules — do NOT touch it in this work; note the change for release time
  (Post-Completion).
- app must build, `swift test` green, `make lint` clean after every task.

## Testing Strategy

- **unit (`cd agtermCore && swift test`):** protocol round-trip for `follow` (Task 2), CLI `--follow`
  parse/mapping (Task 4).
- **e2e (XCUITest, `ControlOverlaySplitUITests`):** Task 5 — the coverage gap. Assert both full and
  floating open on a BACKGROUND target default to NO switch (active session unchanged) and the floating
  program actually RUNS in the background (via `--block` / `overlay result`), and that BOTH switch WITH
  `--follow`.
- e2e treated with the same rigor as unit tests (must pass before the next task).

## Progress Tracking

- mark completed items `[x]` immediately; add `➕` for new tasks, `⚠️` for blockers; keep the plan in sync.

## Solution Overview

The floating overlay is hosted in the per-session eager deck (like the full overlay) instead of at the
active-only `detailPane` level, so its program runs regardless of active session. The `ControlServer`
auto-select is regated from "is this floating?" to "did the caller pass `--follow`?". `--follow` is a
plain boolean threaded protocol → options → server, plus a CLI flag. Full and floating then differ only
in the panel geometry (`--size-percent`).

## Technical Details

- `ControlSessionOverlayOpenOptions` (in `ControlDispatcher.swift`) gains `follow: Bool = false` (a DEFAULT
  is required so the existing `ControlDispatcherTests` construction and the dispatcher call site stay
  source-compatible); the `.sessionOverlayOpen` dispatcher arm populates it with
  `follow: request.args?.follow ?? false`; `ControlArgs`/wire gains `follow: Bool?` (omitted = false,
  back-compatible with existing clients).
- `openSessionOverlay`: `if options.follow { store.selectSession(id) }` (was `if options.sizePercent != nil`).
- `agtermctl overlay open` gains `@Flag var follow: Bool` → `args.follow`.
- Render: `floatingOverlayPanel(session:isActive:)` is an always-present `sessionDetail` ZStack sibling;
  the panel content (surface + frame + click-catcher) is gated INSIDE it so the ZStack child count is
  constant across open/close (no `NSSplitView` re-host). `isActive` gates the overlay surface's focus, so a
  background floating overlay runs but does not steal focus (mirrors the full overlay).

## What Goes Where

- **Implementation Steps** (checkboxes): render cleanup, protocol/options, server gate, CLI, tests, docs.
- **Post-Completion** (no checkboxes): release-time changelog note; manual "does opening on a background
  session not switch, and appear on visit" sanity check on a dev instance.

## Implementation Steps

### Task 1: Productionize the in-deck floating render

**Files:**
- Modify: `agterm/Views/WindowContentView.swift`

- [x] remove the `SPIKE:` prefixes/notes from the three edited regions (`detailColumn`, `sessionDetail`
      floating sibling, `floatingOverlayPanel`); keep the explanatory comments about the constant-shape
      sibling and the eager-deck mount
- [x] FIX now-false in-code comments the spike left: the scratch-block comment (~lines 308-315) still says
      "The FLOATING overlay is deliberately NOT a sibling here (it renders as a `detailPane` `.overlay`)" —
      now false (it IS a sibling, `floatingOverlayPanel` at `.zIndex(3)`); and correct the renamed-symbol
      references `floatingOverlayLayer` → `floatingOverlayPanel` (~lines 305-306, 417)
- [x] confirm `floatingOverlayPanel` is the sole host of `\.overlaySurface` for the floating case and the
      `detailPane` `floatingOverlayLayer` is fully removed (no duplicate surface mount)
- [x] `make lint` clean; build the app (Debug) succeeds
- [x] run `ControlOverlaySplitUITests` — all pass (render behavior regression; locked further by Task 5)
- [x] (no host-free unit test — app-target render; behavior verified by Task 5 e2e)

### Task 2: Add `follow` to the control protocol + dispatcher overlay-open options (agtermCore)

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherTests.swift`

- [x] add `follow: Bool?` to the overlay-open wire args in `ControlProtocol.swift` (`ControlArgs`),
      omitted-when-nil for back-compat
- [x] add `follow: Bool = false` (DEFAULT required) to `ControlSessionOverlayOpenOptions`
      (`ControlDispatcher.swift` ~line 65) — the default keeps the existing `ControlDispatcherTests`
      construction (~line 800) and the dispatcher call site source-compatible
- [x] in the `.sessionOverlayOpen` arm of `ControlDispatcher.dispatch(_:)` (~lines 294-308), populate the
      options with `follow: request.args?.follow ?? false` — THIS is the wire→options mapping that makes the
      flag reach `ControlServer`; without it the feature is dead while unit tests still pass
- [x] round-trip tests (`ControlProtocolTests`): overlay-open request with `follow: true`/`false`/omitted
      (→ nil) encode/decode stably
- [x] routing tests (`ControlDispatcherTests`, extend `sessionOverlayOpenRoutesOptionsAndEchoesActionResponse`
      or add a sibling): `args.follow == true` → routed `options.follow == true`; omitted → `options.follow == false`
- [x] `cd agtermCore && swift test` — passes
- [x] run tests — must pass before next task

### Task 3: Regate the auto-select on `follow` (behavior change)

**Files:**
- Modify: `agterm/Control/ControlServer+SessionActions.swift`

- [x] in `openSessionOverlay`, change `if options.sizePercent != nil { store.selectSession(id) }` to
      `if options.follow { store.selectSession(id) }`
- [x] update the surrounding doc comment: the select is now the user-facing `--follow`, not a
      floating-surface-mount workaround (the in-deck render makes floating run without it)
- [x] fix the stale cross-reference in the scratch arm (~line 267) — "select the target first (mirrors the
      floating-overlay arm)" no longer holds once the floating select is `--follow`-gated
- [x] `make lint` clean; app builds
- [x] (no host-free unit test — app-target side effect; behavior verified by Task 5 e2e — `[x]` this
      after Task 5 is green)

### Task 4: Add `--follow` to the `agtermctl overlay open` subcommand

**Files:**
- Modify: `agtermCore/Sources/agtermctlKit/SessionCommands.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/CommandsTests.swift`

- [x] add `@Flag var follow: Bool` to the overlay-open command and thread it into the request's
      `follow` arg
- [x] write CLI-parse tests: `overlay open <cmd> --follow` maps to `follow: true`; without it maps to
      `false`/nil; combines cleanly with `--block`, `--size-percent`, `--target`
- [x] `cd agtermCore && swift test` — passes
- [x] run tests — must pass before next task

### Task 5: e2e — background-run, no-switch by default, switch on `--follow`

**Files:**
- Modify: `agtermUITests/ControlOverlaySplitUITests.swift`

- [x] harness note: the tests send raw socket JSON via `sendCommand` (not the `agtermctl --block` CLI), so
      "the program runs in the background" is asserted by polling `session.overlay.result` for an exit code
      (the pattern in `testOverlayResultReportsExitCode`), NOT by `--block`. Set up a BACKGROUND target by
      creating a SECOND session (which becomes active) before opening the overlay on the first
- [x] e2e: FULL overlay opened on the BACKGROUND target with no `--follow` — the active session is
      unchanged (assert selected id), and the overlay's program runs (exit observable via `overlay result`)
- [x] e2e: FLOATING overlay (`--size-percent`) opened on the BACKGROUND target with no `--follow` — active
      session unchanged AND its program runs in the background via `overlay result` (the core parity
      assertion; the case that had zero coverage)
- [x] e2e: FULL and FLOATING with `--follow` — the active session becomes the target
- [x] e2e: `--follow` targeting the ALREADY-active session — succeeds and stays on it (no-op select)
- [x] run `ControlOverlaySplitUITests` — all pass; then mark Task 1 and Task 3 verification items `[x]`
- [x] run tests — must pass before next task

### Task 6: Keep-in-sync docs (agent skill, rule, README, site)

**Files:**
- Modify: `agterm/Resources/agent-skill/SKILL.md`, `reference.md`, `examples.md`
- Modify: `.claude/rules/control-api.md`
- Modify: `README.md`, `site/docs.html`

- [x] rewrite the floating-switch notes committed in `98b1f0c` to the `--follow` model: default opens on
      `--target` without switching (both kinds); `--follow` selects the target. Update the `overlay open`
      entries + the Addressing note as needed
- [x] rewrite the WHOLE `session.overlay.open` passage in `.claude/rules/control-api.md` (spans ~lines
      440-475, not one line): it currently documents the two-render-places architecture, "`ControlServer`
      SELECTS the target when a floating overlay opens," and three `floatingOverlayLayer` references (~444,
      454, 464) — all now wrong. Replace with: floating renders in-deck (`floatingOverlayPanel`, constant-shape
      sibling), both kinds run in the eager deck, and the select is `--follow`-gated (not `sizePercent`-gated)
- [x] update `README.md` and `site/docs.html` overlay wording if they describe the switch behavior; add
      `--follow` to the CLI examples
- [x] verify agent-skill command count unchanged (no new command — `follow` is an arg)
- [x] (docs task — no code tests; `make lint` still clean)

### Task 7: Verify acceptance criteria

- [x] full and floating both: default = open on `--target`, no active-session change, program runs in bg
- [x] full and floating both: `--follow` = switch to target; no-op when target already active
- [x] `--block` works on a background floating overlay (does not hang)
- [x] existing valid overlay forms unaffected; existing clients omitting `follow` get the new no-switch default
- [x] run full suites: `cd agtermCore && swift test`; `ControlOverlaySplitUITests` (+ any sibling overlay
      tests); `make lint`
- [x] manual sanity (skipped - not automatable; covered by Task 5 e2e)

### Task 8: Update documentation and finalize

- [x] confirm all keep-in-sync surfaces (Task 6) match the shipped behavior
- [x] REQUIRED: update `.claude/rules/libghostty.md` — the "Search bar placement (NSSplitView-overrun rule)"
      note (~line 105) references `floatingOverlayLayer` and the "`.overlay { floatingOverlayLayer }` on
      `detailPane`" model as load-bearing fact; the floating overlay is no longer a `detailPane` `.overlay`,
      so rewrite it to the in-deck constant-shape-sibling model (the search bar stays at `detailPane`)
- [x] (physical move deferred to exec finalize step) move this plan to `docs/plans/completed/`

## Post-Completion

*Items requiring manual intervention or external systems — informational only*

**Release-time:**
- `CHANGELOG.md` note at the next release: floating `overlay open --size-percent` no longer switches to its
  target by default; pass `--follow` for the old behavior (behavior change).

**Manual verification:**
- On a dev instance: open a floating overlay on a background session and confirm (a) the active view does
  not change, (b) the program runs (a `--block` open returns), (c) the panel appears when you switch to that
  session AND keyboard focus lands in the overlay (cursor focus is not AX-observable, so manual-only — the
  spike changed the overlay surface from `isActive: true` to `isActive: isActive`), and (d) no titlebar
  overrun on a split session (the spike case).

Smells pre-check: skipped — non-Go project
Plan-review (auto): NEEDS REVISION → 9 findings applied (dispatcher-seam file/test correction, stale
comment/rule rewrites in Tasks 1/3/6/8, e2e assertion mechanism + follow-already-active case, manual
keyboard-focus check). Re-review recommended before implement.
