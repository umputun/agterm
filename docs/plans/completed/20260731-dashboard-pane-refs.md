# Dashboard pane refs in the `ids` argument

Resolves #331.

## Overview

`agtermctl dashboard` takes session ids, and a split session always contributes both of its panes as grid
cells. There is no way to put one pane of a split session on the grid.

This accepts a per-id pane ref in the positional `ids` argument:

```
agtermctl dashboard A1B2C3D4                      # unchanged: every pane of the session
agtermctl dashboard A1B2C3D4:left                 # main pane only
agtermctl dashboard A1B2C3D4:left E5F6A7B8:right  # mixed, per id
```

A bare id keeps its current meaning, so nothing breaks.

Why it matters: the 9-cell cap counts panes, and the cap is `prefix(limit)` over the ordered expansion
(`AppStore+Dashboard.swift:22-26`). With nine sessions of which three are split, sessions 7-9 never reach
the grid at all — unwatched shell panes evict watched agent panes, and `--auto-size` shrinks fonts to fit
them.

There is no workaround today. `session.split off` only flips `isSplit`; `hasSplit` survives a hide
(`AppStore+Panes.swift:15-19`) and expansion keys on `hasSplit` explicitly "shown OR hidden". Only the
pane's own shell exiting clears it, which destroys a layout the user built.

## Context (from discovery)

- Write side resolves against session ids only: `ControlServer.swift:437` builds
  `candidates = store.workspaces.flatMap { $0.sessions.map(\.id) }`, and `ControlResolve.resolve` matches
  `active`, a full UUID, or a UUID prefix — none can contain `:`.
- Read side already emits this vocabulary: `DashboardMember.controlRef` renders `<uuid>:left` / `<uuid>:right`
  (`DashboardController.swift:45-47`), used by the `dashboardMembers` and `dashboardHighlighted` read-backs.
  So the tree read-back contract is pre-satisfied and a single-pane request round-trips exactly.
- A lone `.split` member is already a fully supported runtime state — nothing in `DashboardView`,
  the deck exclusion, the font apply, reconcile, or Enter-routing pairs `.primary` with `.split`.
  It simply cannot be requested.
- Expansion is shared with the GUI: `dashboardPaneCells(for: [UUID])` also backs `dashboardMRUMembers`
  and `AppActions.toggleDashboard`, so the UUID-taking form must stay.
- Command count stays 71 — no new command, so no `SkillInstallTests` count update and no
  four-count-mention churn in `site/commands.html`.

## Development Approach

- Regular (code first, then tests) — this is a feature, not a bug fix.
- Complete each task fully before moving to the next; all tests pass before starting the next task.
- Every task that changes code adds or updates tests in the same task.
- Follow `.claude/rules/control-api.md`: dispatcher-first, never add validation to the fallback switch.

## Testing Strategy

- Unit tests in `agtermCore/Tests/agtermCoreTests/` per changed source file, one test file per source file.
- CLI tests in `agtermCore/Tests/agtermctlKitTests/CommandsTests.swift`.
- One XCUITest in `agtermUITests/DashboardUITests.swift`, near-cloned from
  `testSplitSessionOpensTwoCellsAndEnterFocusesSplitPane`.
- Gates: `cd agtermCore && swift test`, `make test-app`, `make lint`. Zero lint findings required.

## Solution Overview

One host-free parser turns each raw target into `(head, pane?)`. The dispatcher validates the grammar
host-free; `ControlServer` resolves the head through the existing `ControlResolve` path and expands
according to the pane. Dedup moves from `Set<UUID>` to a member-level key.

Grammar, deliberately narrow:

- `<target>` — bare, unchanged. Expands to every pane of the session.
- `<target>:left` / `<target>:right` — that pane only.
- `<target>` is anything `ControlResolve.resolve` already accepts: `active`, a full UUID, or a unique
  prefix. So `active:left` and `A1B2:right` both work.
- The pane half is lowercased before matching, so the whole token is case-insensitive — the id half
  already is (`ControlResolve.swift:30`).
- Only `left` and `right` are accepted. `primary`/`split` are rejected even though
  `TerminalZoomSurface(controlName:)` accepts them: the read-back emits `left`/`right`, and one spelling
  per pane keeps the write form identical to the read form.
- `:scratch` and `:overlay` are rejected — `DashboardMember` excludes them by contract
  (`DashboardController.swift:33`).
- Empty head (`:left`) and empty pane (`A:`) are rejected.

Split on the **first** colon, and hard-reject any suffix that is not `left`/`right`. This is safe because a
valid head can never contain a colon — `ControlResolve.resolve` accepts only `active`, a full UUID, or a
UUID prefix (`ControlResolve.swift:22-41`), none of which can. So `surface:<uuid>:left` (the `surface.zoom`
form) is a hard reject rather than something that half-resolves, and a typo like `A:lft` gets a real error
instead of becoming a mystery entry in the `unresolved` note.

**Grammar errors are hard; resolution misses are soft.** An unparseable token (`A:lft`, `A:primary`,
`A:scratch`) fails the command in the dispatcher — the caller wrote something meaningless. A well-formed
token that points at nothing (`A:right` where A has no split, or an unknown id) joins the `unresolved`
note and the rest of the grid still opens. That is the same split `ControlResolve` already draws between a
malformed target and a target that simply is not there.

### Decisions taken (maintainer-approved)

| case | behavior |
|---|---|
| `dashboard A A:left` | Dedup by `(id, pane)`. `A` yields primary+split, `A:left` adds primary, dedup collapses it. No new validation. |
| `A:right` on a session with no split | Joins the existing `unresolved: A:right` note, same as an unknown id, and fails the command outright when nothing else resolved. Consistent with the command's skip-and-report model. |
| Main pane exits, split promoted | An `A:right` member is **rewritten to `A:left`** so the watched agent stays on the grid. |

The promotion rewrite cannot live in `reconcile(existing:)` — that takes a set of currently-valid members
and cannot distinguish `closeSplit` (split shell died; the cell should go) from `closePrimaryPane` (split
promoted into primary; the cell should follow). It must be driven from the promotion path.

### Rejected alternatives

- **Global `--panes primary|split|both` flag.** One value for the whole id list; cannot express a mixed
  grid, which is the issue's third example and the real fleet case.
- **Reusing `surface:<uuid>:<pane>` (the `surface.zoom` form).** It demands a full UUID
  (`TerminalZoom.swift:86` calls `UUID(uuidString:)`), so it would silently drop prefix and `active`
  support inside an argument list that has both today. It also admits `scratch`/`overlay`, which are not
  valid members.

## Technical Details

New host-free type in `agtermCore`, used by both the dispatcher (validation) and `ControlServer`
(resolution), so the grammar has exactly one implementation:

```swift
/// One `dashboard` target: a resolvable head plus an optional pane selector. A nil `pane` means the
/// bare form — every pane of the session.
public struct DashboardTarget: Equatable, Sendable {
    public let head: String
    public let pane: TerminalZoomSurface?   // .primary or .split only, never .scratch/.overlay
}
```

`ControlArgs.targets` stays `[String]`, so there is no wire type change and
`ControlActions.setDashboard`'s signature is unchanged — no `MockControlActions` churn.

Backward compatibility is total: a bare id behaves exactly as today, and a new CLI against an old server
yields `unresolved: A:left`, which is today's behavior.

## Progress Tracking

- Mark completed items `[x]` immediately when done.
- New tasks get a ➕ prefix; blockers get ⚠️.
- Update this file when scope changes.

## Implementation Steps

### Task 1: Host-free `DashboardTarget` parser

**Files:**
- Create: `agtermCore/Sources/agtermCore/DashboardTarget.swift`
- Create: `agtermCore/Tests/agtermCoreTests/DashboardTargetTests.swift`

- [x] add `DashboardTarget` with a failable parse from a raw target string
- [x] no colon → bare target, `pane == nil`, always valid
- [x] split on the FIRST colon; the suffix must lowercase to exactly `left` or `right`, else the parse fails
- [x] reject empty head, empty pane, and every other suffix — including `primary`/`split` (accepted by
      `TerminalZoomSurface(controlName:)` but not a spelling this command emits) and `scratch`/`overlay`
- [x] write tests: bare id, `active:left`, prefix+suffix (`A1B2:right`), uppercase `:LEFT`, full-UUID forms
- [x] write tests for rejects: `:left`, `A:`, `A:lft`, `A:scratch`, `A:overlay`, `A:primary`, `A:split`,
      and `surface:<uuid>:left` (head `surface`, suffix `<uuid>:left` — a hard reject, not a half-resolve)
- [x] run `cd agtermCore && swift test` — 16 tests pass

### Task 2: Dispatcher-side grammar validation

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherDashboardTests.swift`

- [x] in `dispatchDashboard`, parse every target through `DashboardTarget` and reject an invalid suffix
      with a clear error naming the offending token
- [x] keep the existing flag-combination checks and their messages unchanged
- [x] confirm the fallback switch gains no validation (`.claude/rules/control-api.md`)
- [x] write tests: valid suffixed targets pass through; each reject form produces the error
- [x] write tests: bare-id requests are byte-identical to today
- [x] run `cd agtermCore && swift test` — 22 tests pass across both suites

### Task 3: Pane-aware expansion in `agtermCore`

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore+Dashboard.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStore+DashboardTests.swift`

- [x] add a `DashboardMember`-yielding expansion that takes resolved `(UUID, TerminalZoomSurface?)` pairs
      — modelled as `ResolvedDashboardTarget` beside `DashboardTarget`, so the pair is named and Equatable
- [x] keep `dashboardPaneCells(for: [UUID])` for the MRU and GUI paths — it now delegates to the
      resolved-target form, so there is still exactly one expansion
- [x] a nil pane expands to primary + split as today; an explicit pane yields that cell only
- [x] dedup at member level, preserving first-seen order
- [x] keep the expansion pure — it never receives an impossible pair, because task 4 checks pane
      availability before calling it (avoids splitting the availability rule across two layers, where the
      expansion drops silently and `ControlServer` has to re-derive which token vanished)
- [x] write tests: mixed bare/suffixed input, `A A:left` dedup, explicit-pane expansion, cap and
      dropped-pane count still correct
- [x] run `cd agtermCore && swift test` — full suite green, 2088 tests

### Task 4: Resolution in `ControlServer.setDashboard`

**Files:**
- Modify: `agterm/Control/ControlServer.swift`

- [x] parse each target into `DashboardTarget`, resolve the head via `ControlResolve.resolve`
- [x] check the requested pane exists; a resolved head whose pane does not exist joins `unresolved` with
      the original token. ➕ used `session.hasSplit` rather than the planned
      `TerminalZoomSurface.isAvailable(in:)` — `isAvailable` rejects `.primary` when the primary surface is
      nil, which `dashboardValidMembers` still counts as a valid cell, so the two would disagree and admit
      or refuse cells reconcile then contradicts. `hasSplit` is exactly what reconcile tests
- [x] replace the `Set<UUID>` dedup with the member-level dedup from task 3
- [x] **change the empty guard from `sessionIDs` to the expanded members.** `ControlServer.swift:448`
      currently guards `!sessionIDs.isEmpty`. Today that is equivalent to a non-empty grid, because every
      resolved session yields at least a `.primary` cell — with pane refs it is not. `dashboard A:right`
      on a non-split A resolves A but expands to zero members, and the current guard would let it through
      to `TerminalZoomRegistry…clear()` (`:454`) and `controller.open(members: [])`, which leaves
      `isOpen == false` (`DashboardController.swift:78`). Net effect: silently closes an already-open
      dashboard, drops that window's zoom, and reports `ok:true`. The GUI path already guards this
      (`AppActions.swift:737`)
- [x] leave the `--mru` branch on the UUID path unchanged
- [x] keep the existing `unresolved` / dropped-pane note format and its `;` join
- [x] run `make test-app` — TEST SUCCEEDED, 87 hosted tests (behavioral coverage for this task lands in task 7)

### Task 5: Keep a promoted pane on the grid

**Files:**
- Modify: `agtermCore/Sources/agtermCore/DashboardController.swift`
- Modify: `agterm/agtermApp.swift`
- Modify: `agterm/Views/DashboardView.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/DashboardControllerTests.swift`

- [x] add a controller method that rewrites a session's `.split` member to `.primary`, deduping if the
      session already has a `.primary` member, and moves the highlight with it
- [x] drive it from `handlePaneExit` in `agterm/agtermApp.swift`, immediately after the
      `store.closePrimaryPane(sessionID)` call, reusing the "session still exists ⇒ it promoted" test the
      adjacent line already performs. This is the only place that knows a promotion happened:
      `closeSplit` and `closePrimaryPane` both end with `hasSplit == false`, so `dashboardValidMembers`
      looks identical for both and `reconcile(existing:)` cannot tell them apart
- [x] thread `library` into `handlePaneExit` to reach the window's controller —
      `DashboardControllerRegistry` exposes only `controller(for:)` with no enumeration, so it needs
      `library.windowID(for: store)`. Both call sites already hold `library`, so this is a one-parameter change
- [x] verify the rewrite lands before the prune: `closePrimaryPane` is synchronous and reconcile is a
      SwiftUI `.onChange(of: dashboardValidMembers)`, so a synchronous rewrite runs first
- [x] verify `closeSplit` (split shell exits) still prunes rather than rewrites
- [x] update the `DashboardView.swift:155-165` comment, whose premise this changes
- [x] write tests: `A:split`-only member survives promotion as `A:primary`; both-member case dedups;
      highlight follows; `closeSplit` still prunes
- [x] ⚠️ unit tests reach the controller method only, not the `agtermApp.swift` wiring — the end-to-end
      assertion for that lives in task 7 and must not be skipped
- [x] run `cd agtermCore && swift test` and `make test-app` — must pass before task 6

### Task 6: CLI surface

**Files:**
- Modify: `agtermCore/Sources/agtermctlKit/MiscCommands.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/CommandsTests.swift`

- [x] extend the `ids` argument help and the discussion block with the pane-ref forms
- [x] add a discussion line for the mixed example `dashboard A:left B:right`
- [x] keep parse-time `validate()` rejecting the same flag combinations as today
- [x] write tests: suffixed ids reach `ControlArgs.targets` verbatim; `--mru` with suffixed ids still rejected
- [x] run `cd agtermCore && swift test` — must pass before task 7

### Task 7: End-to-end coverage

**Files:**
- Modify: `agtermUITests/DashboardUITests.swift`

`openDashboard(members: [String])` (`DashboardUITests.swift:456`) already takes raw strings, so every
assertion below is a string change rather than new harness.

- [x] add a test opening a split session by `<id>:right` and asserting exactly one cell
- [x] assert `dashboardMembers` reads back `["<id>:right"]`
- [x] assert Enter focuses that exact pane (`splitFocused` flips)
- [x] assert the issue's headline case: `A:left B:right` yields a two-cell mixed grid in that order
- [x] assert `active:left` resolves, so the suffix composes with non-UUID heads
- [x] assert `A:right` on a non-split session reports the token in `unresolved` and leaves any open
      dashboard untouched (covers the task 4 empty-guard bug)
- [x] assert the task 5 wiring end to end: hold a session on the grid by `:right`, exit its primary
      shell, and confirm `dashboardMembers` becomes `["<id>:left"]` rather than dropping the cell
- [x] run the five tests — **all pass**, 34.6s (`Executed 5 tests, with 0 failures`).
      `testPromotedSplitKeepsItsCellOnTheGrid` is the executed coverage for task 5's `agtermApp` wiring,
      which the controller unit tests cannot reach.
- ➕ The first two attempts died before any test body ran: `Failed to initialize for UI testing: Timed out
      while enabling automation mode`, reproduced on the untouched
      `testDashboardOpensWithMemberCellsAndClosesClean` as a control. It cleared on retry — the runner
      binary under a fresh worktree's `build/DerivedData` needs a macOS automation grant on first use.
      Retry before investigating; do NOT reach for `tccutil`.

### Task 8: Documentation mirrors

**Files:**
- Modify: `README.md`, `site/docs.html`, `site/commands.html`
- Modify: `plugins/agterm/skills/agterm/SKILL.md`, `plugins/agterm/skills/agterm/reference.md`,
  `plugins/agterm/skills/agterm/examples.md`
- Modify: `.claude/rules/control-api.md`

- [x] README dashboard section and cheat sheet: document the pane-ref form
- [x] `site/docs.html` mirrors README; `site/commands.html` dashboard usage line and argument prose
- [x] bundled skill: `SKILL.md` dashboard entry, `reference.md` dashboard block (the `ids` argument and
      the `unresolved:` note both live there), and `examples.md` dashboard examples
- [x] `.claude/rules/control-api.md` dashboard bullets: pane refs, dedup key, promotion rewrite
- [x] verify the command count stays 71 everywhere it appears
- [x] run `make lint` — zero findings

### Task 9: Verify acceptance criteria

- [x] `dashboard A1B2C3D4:left E5F6A7B8:right` produces a two-cell mixed grid
- [x] a bare id still yields every pane of the session
- [x] `A A:left` dedups; `A:right` on a non-split session lands in the `unresolved` note, or errors when it is the sole target
- [x] promoting a split survivor keeps the cell on the grid
- [x] full suite: `cd agtermCore && swift test`, `make test-app`, `make lint`

### Task 10: [Final] Close out

- [x] confirm README, site, skill, and rules all describe the shipped grammar
- [x] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification:**
- Build a real mixed grid from a `tree --json | jq` filter against an isolated Debug instance and confirm
  cell contents, `--auto-size` font, and Enter-routing per cell.
- Exit the main pane of a session held on the grid by `:right` and confirm the promoted pane stays visible.

**External:**
- The PR closes #331 with `Fix #331`. pkoptilin gets the shape he proposed; no interim comment is needed.
