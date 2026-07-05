# session new/move: `--after <sid>` / `--before <sid>` placement flags

## Overview

Add reference-based placement to the control channel so a session can be created
or moved directly to a chosen slot — right after or before another session — in a
single round-trip, instead of appending and then walking it up with repeated
`session move --to up`.

- **Problem:** `session new` always appends; positioning it "right after the
  current one" takes O(N) `move --to up` calls, each visibly hopping the row in the
  sidebar. With dozens of sessions this is slow and noisy.
- **Solution (Option A, per the maintainer in
  [discussion #123](https://github.com/umputun/agterm/discussions/123)):** dedicated
  `--after <sid>` / `--before <sid>` value flags on both `session new` and
  `session move`. NOT extending the `--to` keyword enum (kept clean — `--to` stays a
  closed `up|down|top|bottom` enum shared by `session.go`/`session.move`/`workspace.move`).
- **Key design decision (settled):** the anchor sid **carries its own workspace**.
  It is resolved across the whole store (all workspaces), so it identifies both the
  destination workspace and the slot. `--after`/`--before` therefore never combine
  with the workspace parameter — they are a self-contained placement mode, mutually
  exclusive with `--to` and with `--workspace`/the positional workspace/`--workspace-name`.
  Cross-workspace placement falls out for free with no ambiguity:
  - `agtermctl session new --after active` → create right after the current session
    (the headline case), one round-trip.
  - `agtermctl session move --after <sid> --target <sid>` → relocate + position in one
    shot, wherever the anchor lives.
- **Integration:** dispatcher-first — arg validation + error strings in
  `ControlDispatcher` (host-free, unit-tested); the resolve-and-place side effect
  behind `ControlActions`. Reuses the already table-tested `SidebarDrop` drop-index
  math (the "after this row" index + post-removal off-by-one that drag-drop uses) and
  the `AppStore.moveSession(_:toWorkspace:at:)` primitive (which already clamps an
  optional `at index:`). No new command — the catalog stays at 50 commands, only
  `session.new`/`session.move` gain args.

## Context (from discovery)

Files/components involved (with the exact hook points):

- `agtermCore/Sources/agtermCore/ControlProtocol.swift` — `ControlArgs` struct (line
  61) + its `init` (line 161). Add `after`/`before` optional String fields.
- `agtermCore/Sources/agtermCore/ControlModes.swift` — `ControlSessionMove` enum
  (lines 68–72: `.reorder(ReorderDirection)` / `.workspace(String)`). Add a placement
  case. `ControlSessionCreateOptions` (lines 81–100). Add `after`/`before`.
- `agtermCore/Sources/agtermCore/ControlDispatcher.swift` — `.sessionNew` arm (lines
  138–154) and `.sessionMove` arm (lines 170–183). Add mutual-exclusion validation +
  routing for the new mode. `ControlActions` protocol methods `createSession` (line 9)
  and `moveSession` (line 18) keep their signatures (the new data rides inside the
  existing option/enum types).
- `agtermCore/Sources/agtermCore/SidebarDrop.swift` — `resolveSession(...)` (lines
  33–64): the "after this row" math (`sessionIndex + 1` on `onItemIndex`), the
  same-workspace post-removal off-by-one (`dropChildIndex - 1`), and no-op detection.
  Add a thin host-free `resolveRelative(...)` wrapper so the anchor→index mapping is
  unit-testable.
- `agtermCore/Sources/agtermCore/AppStore.swift` — `moveSession(_:toWorkspace:at:)`
  (lines 376–385, already clamps `at index:`); `addSession(...)` (lines 220–231,
  currently always appends — add an optional `at index:`); `sessionLocation(ofSession:)`
  (lines 420–424) turns an anchor id into `(workspace, index, count)`.
- `agtermCore/Sources/agtermCore/ControlResolve.swift` — `resolve(_:candidates:active:)`
  (lines 22–41): id / unique-prefix / `active` sugar. Reused to resolve the anchor sid
  against the store's full session-id set.
- `agterm/Control/ControlServer+SessionActions.swift` — `createSession` (lines 95–119)
  and `moveSession(_:window:move:)` (lines 417–435): the app-side `ControlActions`
  side effects. Thread the resolved anchor index into `store.addSession(...at:)` /
  `store.moveSession(...at:)`.
- `agterm/Control/ControlServer.swift` — `makeSessionResponse(in:workspaceID:options:)`
  (lines 413–422): the create-session helper.
- `agtermCore/Sources/agtermctlKit/SessionCommands.swift` — `Session.New` (lines 26–51)
  and `Session.Move` (lines 95–116): add `--after`/`--before` options, extend
  `validate()` (currently a two-way switch) and `makeRequest()` (currently a binary
  map) to the new mode.

Related patterns found:

- `session.move` is already MODE-BEARING: `--to <dir>` reorders in-workspace,
  positional `workspace` relocates. The place mode is a third exclusive branch.
- The anchor sid is a **session** address, sugar-eligible (`active` = the selected
  session, exact uuid, or unique prefix) — resolved exactly like `--target`.
- Existing test harnesses to mirror: round-trip in `ControlProtocolTests.swift`
  (`sessionMoveReorderRoundTripsWithDirection`, lines 483–490); CLI parse/validate in
  `agtermctlKitTests/CommandsTests.swift` (`sessionMove*`, lines 115–133; `sessionNew*`,
  lines 75–100); dispatcher guards in `ControlDispatcherTests.swift`; e2e in
  `agtermUITests/ControlAPIUITests.swift` (`testSessionMoveReorderWithinWorkspace`,
  lines 808–838, seeds ordered sessions via `relaunch(withSnapshot:)` and asserts with
  `pollSessionOrder`; `testSessionMoveToAnotherWorkspace`, lines 754–767, for
  cross-workspace + `pollSessionCounts`).

Dependencies identified: `swift-argument-parser` (CLI only); no new deps. All
host-free logic stays in `agtermCore` (no GhosttyKit/AppKit/CoreGraphics).

## Development Approach

- **Testing approach: Regular (code first, then tests)** — implement each layer, then
  add its tests in the SAME task before moving on (chosen by the maintainer).
- Complete each task fully before the next. Small, focused changes.
- **CRITICAL: every task with code changes includes new/updated tests** (success +
  error/edge cases), listed as separate checklist items.
- **CRITICAL: all tests pass before starting the next task.** `cd agtermCore && swift
  test` must stay green; the app must build; `make lint` must pass (swiftlint
  `--strict`, zero findings) after every change.
- Keep this plan file in sync if scope shifts (`➕` new task, `⚠️` blocker).
- Backward compatible: `after`/`before` are new OPTIONAL args — old clients/JSON and
  the existing `--to`/workspace forms are unaffected.

## Testing Strategy

- **Unit tests (agtermCore, `swift test`, no app host):**
  - Protocol round-trip (`ControlProtocolTests`) for `session.new`/`session.move`
    carrying `after`/`before`.
  - `SidebarDrop.resolveRelative` placement math (same-workspace before/after, the
    off-by-one, cross-workspace, anchor==self no-op).
  - `AppStore.addSession(...at:)` insertion + clamping.
  - Dispatcher validation/routing (`ControlDispatcherTests`) — the new mutual-exclusion
    guards and that the correct `ControlSessionMove`/`ControlSessionCreateOptions` is
    handed to the mock `ControlActions`.
  - CLI parse/validate (`agtermctlKitTests/CommandsTests`) — `--after`/`--before`
    mapping to `ControlArgs`, and `validate()` rejections.
- **E2E (XCUITest, `agtermUITests/ControlAPIUITests.swift`):** raw JSON over the socket,
  poll persisted state. Move after/before same-workspace (order), move after/before
  cross-workspace (counts + order), new after/before, and the error guards. Same rigor
  as unit tests — must pass before the plan is done. (Note: the app-side `ControlActions`
  side effects in Task 4 are `@MainActor` glue with no host-free unit seam; they are
  verified by these e2e tests, per the repo's established pattern.)

## Progress Tracking

- Mark completed items `[x]` immediately.
- `➕` newly discovered tasks, `⚠️` blockers.
- Update the plan if scope changes.

## What Goes Where

- **Implementation Steps** (`[ ]`): code, unit tests, e2e tests, docs — all
  automatable in this repo.
- **Post-Completion** (no checkboxes): manual dev-instance smoke test, PR/keep-in-sync
  human review.

## Implementation Steps

### Task 1: Wire model — `after`/`before` on the protocol + modes
- [x] `ControlProtocol.swift`: add `public var after: String?` and `public var before:
      String?` to `ControlArgs` (near `to`/`workspace`), and add both to the `init`
      parameter list (all optional, default nil — keeps every existing call site and
      old-JSON decode working).
- [x] `ControlModes.swift`: add a placement case to `ControlSessionMove`, e.g.
      `case place(anchor: String, after: Bool)` (a single Bool distinguishes
      after/before; keep the enum small and `Equatable, Sendable`).
- [x] `ControlModes.swift`: add `public let after: String?` / `public let before:
      String?` to `ControlSessionCreateOptions` and its `init`.
- [x] `ControlProtocolTests.swift`: add round-trip tests — `session.new` with
      `after`/`before`, and `session.move` with `after`/`before` — asserting the fields
      survive encode/decode and other fields stay nil (mirror
      `sessionMoveReorderRoundTripsWithDirection`).
- [x] `cd agtermCore && swift test` — must pass before Task 2.

### Task 2: Host-free placement math — `SidebarDrop.resolveRelative` + `AppStore.addSession(at:)`
- [x] `SidebarDrop.swift`: add
      `public static func resolveRelative(source: (workspace: UUID, index: Int),
      anchor: (workspace: UUID, index: Int, count: Int), placeAfter: Bool) ->
      SessionResolution?` — a thin wrapper that builds
      `SessionDropTarget.sessionRow(workspace: anchor.workspace, sessionIndex:
      anchor.index, sessionCount: anchor.count)`, picks `childIndex = placeAfter ?
      onItemIndex : anchor.index`, and delegates to `resolveSession(...)`. This reuses
      the tested after-this-row + post-removal off-by-one + no-op logic; no new
      arithmetic. (Tuple params instead of six scalars to satisfy swiftlint's 5-param
      cap; the tuples mirror `AppStore.sessionLocation`'s return shape.)
- [x] `AppStore.swift`: add an optional `at index: Int? = nil` to `addSession(...)`;
      when set, `insert(at:)` at the clamped index (`max(0, min(index, count))`) instead
      of `append`. `nil` keeps today's append behavior (all existing callers unchanged).
- [x] Add unit tests for `resolveRelative`: same-workspace before/after (incl. the
      downward off-by-one), cross-workspace before/after (no off-by-one), and
      anchor==source → nil (no-op). Place alongside the existing `SidebarDrop` tests.
- [x] Add unit tests for `addSession(...at:)`: insert at head/middle/tail, and
      out-of-range index clamps to `0...count`.
- [x] `cd agtermCore && swift test` — must pass before Task 3.

### Task 3: Dispatcher — validation + routing for the place mode
- [x] `ControlDispatcher.swift` `.sessionMove` arm: extend the guards so exactly one
      placement intent is set among {positional workspace, `--to`, `--after`/`--before`}.
      Emit clear errors:
      - `--after` + `--before` → `"use either --after or --before, not both"`.
      - `--after`/`--before` + `--to` → `"session.move takes --after/--before or --to,
        not both"`.
      - `--after`/`--before` + a workspace → `"session.move takes --after/--before or a
        workspace, not both"` (the anchor already names the workspace).
      Then route to `actions.moveSession(request.target, window:, move: .place(anchor:,
      after:))`. Leave the existing `--to`/workspace/neither branches intact.
- [x] `ControlDispatcher.swift` `.sessionNew` arm: reject `--after`/`--before` combined
      with each other or with `--workspace`/`--workspace-name` (the anchor names the
      workspace), then pass `after`/`before` through into `ControlSessionCreateOptions`.
- [x] `ControlDispatcherTests.swift`: add tests using the existing mock `ControlActions`
      — assert each new error string, and that a valid `--after`/`--before` produces the
      right `ControlSessionMove.place`/`ControlSessionCreateOptions` handed to the mock.
- [x] `cd agtermCore && swift test` — must pass before Task 4.

### Task 4: App-side ControlActions — resolve the anchor and place
- [x] `ControlServer+SessionActions.swift` `moveSession(...)`: handle the new
      `.place(anchor:, after:)` case. Resolve the `--target` session to `(store,
      sessionID)`; look up its `sessionLocation`; resolve the anchor sid against the
      store's full session set (`store.workspaces.flatMap(\.sessions).map(\.id)`, active
      = `store.selectedSessionID`) via `resolver.resolve(..., noun: "session")`; get the
      anchor `sessionLocation`; call `SidebarDrop.resolveRelative(...)`; on a non-nil
      resolution call `store.moveSession(sessionID, toWorkspace: resolution.workspace,
      at: resolution.destination)`; on nil treat as a successful no-op. Return
      `result.id = sessionID`.
- [x] `ControlServer+SessionActions.swift` `createSession(...)`: when `after`/`before`
      is set, resolve the anchor sid across the store, take its `(workspace, index)`,
      create via `store.addSession(toWorkspace: anchorWS, cwd:, command:, name:, at:
      before ? index : index + 1)` (clamped in `AppStore`), then focus if in the active
      store. Bypass the `--workspace`/`--workspace-name` resolution path for this branch.
- [x] Build the app (`make build`) — must compile; `make lint` clean.
- [x] (Behavior verified by the e2e tests in Task 6 — no host-free unit seam for this
      `@MainActor` glue.)

### Task 5: CLI — `--after`/`--before` on `session new` and `session move`
- [x] `SessionCommands.swift` `Session.New`: add `@Option(name: .long) var after:
      String?` and `var before: String?`. In `validate()`, reject after+before together
      and either combined with `--workspace`/`--workspace-name`. In `makeRequest()`,
      thread `after`/`before` into the `ControlArgs(...)`.
- [x] `SessionCommands.swift` `Session.Move`: add `--after`/`--before` options. Rework
      `validate()` from the two-way switch to enforce exactly one of {positional
      workspace, `--to`, after/before} with matching usage errors, and after+before not
      both. Rework `makeRequest()` to build the right `ControlArgs` for the place mode.
      Update the `configuration.abstract`/help to mention placement.
- [x] `CommandsTests.swift`: add parse tests — `session new --after <sid>` /
      `--before`, `session move --after <sid> --target <sid>` / `--before` map to the
      expected `ControlRequest`; and `validate()` rejection tests for the new
      mutual-exclusion messages (mirror `sessionMoveRejectsWorkspaceAndTo`).
- [x] `cd agtermCore && swift test` — must pass before Task 6.

### Task 6: E2E — XCUITest over the socket
- [x] `ControlAPIUITests.swift`: `session.move` `--after`/`--before` within one
      workspace — seed three ordered sessions (`relaunch(withSnapshot:)`), move one and
      assert the new order with `pollSessionOrder`.
      (`testSessionMovePlaceWithinWorkspace`.)
- [x] `session.move` `--after`/`--before` cross-workspace — anchor in another workspace;
      assert with `pollSessionCounts` + `pollSessionOrder` that the session relocated to
      the anchor's workspace at the right slot. (`testSessionMovePlaceCrossWorkspace`;
      added the `pollSessionOrder(inWorkspace:equals:timeout:)` base-class oracle for the
      non-first destination workspace.)
- [x] `session.new` `--after`/`--before` — create relative to a seeded session; assert
      placement/order and that the returned `result.id` is the new session.
      (`testSessionNewPlaceRelativeToAnchor`.)
- [x] Error-guard e2e: after+before together, after/before + `--to`, after/before + a
      workspace — assert the dispatcher error strings (mirror
      `testSessionMoveBothToAndWorkspaceErrors`). (`testSessionMovePlaceRejectsAfterAndBefore`,
      `testSessionMovePlaceRejectsAfterAndTo`, `testSessionMovePlaceRejectsAfterAndWorkspace`,
      `testSessionNewPlaceRejectsConflicts`.)
- [x] Run the XCUITest scheme — the new e2e tests must pass (deployed app untouched;
      tests use the `.debug` bundle id + isolated `AGTERM_STATE_DIR`/socket).
      (All 7 new tests pass; deployed daily-driver untouched.)

### Task 7: Keep-in-sync docs (HARD)
- [x] `agterm/Resources/agent-skill/reference.md`: document `--after`/`--before` on
      `session.new` and `session.move` (args, semantics, cross-workspace behavior,
      mutual exclusion with `--to`/workspace).
- [x] `agterm/Resources/agent-skill/SKILL.md`: update the `session.new`/`session.move`
      summary lines; keep the command count at 50 (no new command).
- [x] `agterm/Resources/agent-skill/examples.md`: add the headline recipe
      (`agtermctl session new --after active`) and a `session move --after <sid>` recipe.
- [x] `.claude/rules/control-api.md`: update the `session.move` catalog note (it is now
      place-bearing too — `--after`/`--before` anchor-relative placement, anchor carries
      the workspace) and the `session.new` line.
- [x] `README.md` / `site/docs.html` enumerate `session` flags — added `--after`/`--before`
      example lines to the `agtermctl` recipe block in both.

### Task 8: Verify acceptance criteria
- [x] `agtermctl session new --after active` creates right after the current session in
      one round-trip (functional path verified by e2e
      `testSessionNewPlaceRelativeToAnchor`; the "watch it land visually" smoke is manual
      — Post-Completion).
- [x] `agtermctl session move --after <sid> --target <sid>` positions with no visible
      step-by-step shuffle; cross-workspace anchor relocates + positions (functional path
      verified by e2e `testSessionMovePlaceWithinWorkspace` /
      `testSessionMovePlaceCrossWorkspace`; the "no visible shuffle" visual is manual —
      Post-Completion).
- [x] All error guards (after+before, after/before vs `--to`, after/before vs workspace,
      anchor not-found/ambiguous) return clear messages (dispatcher unit tests +
      `testSessionMovePlaceRejects*` / `testSessionNewPlaceRejectsConflicts` e2e).
- [x] `cd agtermCore && swift test` green (1159 tests); `make build` succeeds; `make
      lint` passes (`--strict`, zero findings).
- [x] XCUITest e2e suite passes (the 7 new tests added in Task 6).
- [x] Verify no source file crossed 1000 lines from these edits — clean; only three
      files exceed 900 lines and all are tests (2000-line budget):
      `ControlDispatcherTests.swift` (1392), `WindowLibraryTests.swift` (953),
      `CommandsTests.swift` (938). No source file bump needed.

## Technical Details

- **`ControlSessionMove.place(anchor: String, after: Bool)`** — `after == false` means
  place before. Chosen over two cases to keep the enum minimal.
- **Anchor resolution:** the anchor is a session address resolved against the store's
  full session set (all workspaces), so it self-identifies the destination workspace;
  `--after`/`--before` therefore never read the workspace parameter. `active` = the
  selected session.
- **Index math (reused from `SidebarDrop`):**
  - before → `childIndex = anchorIndex`; after → `childIndex = onItemIndex` (maps to
    `anchorIndex + 1`).
  - same-workspace move: `AppStore.moveSession` removes the source first, so the fed
    slot is pre-removal and `at:` is post-removal → subtract 1 when `sourceIndex <
    dropChildIndex`; `resolveSession` already does this. anchor==source ⇒ nil no-op.
  - cross-workspace move: no removal shift in the target → `destination = dropChildIndex`.
  - create: no removal → insert at `before ? anchorIndex : anchorIndex + 1`, clamped.
- **Wire (unchanged shape):** `{"cmd":"session.move","target":"<sid>","args":{"after":"<sid>"}}`
  and `{"cmd":"session.new","args":{"after":"active"}}`. Response `result.id` = the
  moved/created session id, as today.
- **Backward compatibility:** `after`/`before` optional; absent = today's behavior.

## Post-Completion
*Items requiring manual intervention or external systems — informational only*

**Manual verification:**
- Launch an ISOLATED dev instance (`open -n --env AGTERM_STATE_DIR=<tmp> --env
  AGTERM_CONTROL_SOCKET=/tmp/agterm-dev.sock .../Debug/agterm.app`) and drive
  `agtermctl --socket /tmp/agterm-dev.sock session new --after active` /
  `session move --after <sid> --target <sid>` to watch placement land in one shot with
  no row-hopping. Do NOT touch the deployed daily-driver app.

**External / process:**
- Open the PR referencing discussion #123; the maintainer (umputun) offered to review.
  Keep the description prose, short, goal-first (per repo conventions). No changelog
  edit (release-only). Confirm the four keep-in-sync surfaces (protocol/CLI/e2e/skill
  docs) are all covered before requesting review.
