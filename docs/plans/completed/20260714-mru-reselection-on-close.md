# Return to the previously-active session when the current one is closed

## Overview

Closing the ACTIVE session currently reselects by **position** (the session that shifted into the removed
slot, else the previous one), which produces unintuitive jumps: starting on session `1`, opening a new
session after it (`1 4 2 3`, focused on `4`) and closing `4` lands on `2`, not on `1` — the session you
actually came from. Same for a new session at the end (`1 2 3 4` → close `4` → lands on `3`).

Make the close of the ACTIVE session return to the **most-recently-active surviving session** instead.
This is the same "go back to where I came from" model Ctrl-Tab already uses, and the navigation history it
needs (`AppStore.sessionRecency`) is already tracked and persisted.

**No setting** — this becomes the behavior (agreed by the maintainer on the discussion).

Source: GitHub Discussion [#147](https://github.com/umputun/agterm/discussions/147), raised by olomix,
approved by umputun on 2026-07-13 with the exact shape below. The PR was invited; it targets
`umputun/agterm` `master`.

### The agreed algorithm (from umputun's comment)

1. The recency stack Ctrl-Tab uses is the right source. `closeSession` already prunes the closing session
   from it before it reselects, so the most-recently-active survivor is already at the front.
2. **Scope the MRU pick to the current workspace** and the active focus filter when one is on. An unscoped
   "most recent survivor" could pull the user into another workspace, or silently drop a focus filter on
   close — more disorienting than the positional neighbor.
3. **An empty scoped MRU falls straight back to the existing positional `reselectionTarget`.** That covers
   a fresh restore before anything is activated, sessions that were never focused, and the case where the
   only recent entry was the one just closed. Nothing regresses: the worst case is exactly today's neighbor
   behavior, never an empty selection.
4. Shape it as `RecencyStack.top(1, in:)` over the surviving in-scope ids, else `reselectionTarget` — a
   small change in `agtermCore` with the logic unit-testable.

## Context (from discovery)

Everything the change needs already exists; this is a new ~10-line helper plus three call-site swaps.

**Files involved**

- `agtermCore/Sources/agtermCore/AppStore.swift`
  - `closeSession(_:)` (~line 401) — hard close. Already calls `sessionRecency.remove(sessionID)` **before**
    reselecting, then `selectedSessionID = reselectionTarget(after: location)`.
  - `reselectionTarget(after:)` (~line 948) — the existing positional pick. **Keep it, unchanged**; it
    becomes the fallback.
  - `navigableSessions` (~line 791) — already the "visible/filtered set": `flaggedSessions` in `.flagged`
    sidebar mode, else `visibleWorkspaces.flatMap(\.sessions)` (which collapses to the focused workspace
    when `focusedWorkspaceID` is set and still valid). This is exactly the "active focus filter" scope
    umputun asked for; the per-workspace restriction is the one extra constraint to add.
  - `autoUnfocusIfOutsideFocus(_:)` (~line 328) — the safety net that clears the focus filter when the new
    selection lands outside it. With a workspace-scoped MRU it should never need to fire on close, but it
    stays where it is.
- `agtermCore/Sources/agtermCore/AppStore+PendingClose.swift`
  - `softCloseSession(_:grace:)` (line 77) — the undoable single close.
  - `softCloseSessions(_:grace:)` (line 134) — the undoable multi close; it passes an index **adjusted** by
    the count of sessions removed before the active one (`removedBeforeActive`). That adjustment feeds the
    positional fallback and must be preserved verbatim.
- `agtermCore/Sources/agtermCore/RecencyStack.swift`
  - `top(_ n: Int, in valid: Set<ID>)` (line 32) — already skips ids not in `valid`, so a session absent
    from the tree can never be returned even if it is still in the stack.

**Key behavioral note to verify in Task 1**

Unlike `closeSession`, the soft-close paths do **not** prune `sessionRecency` at close time — only
`hardFinalizePendingSession` calls `removeFromRecency`, at grace expiry. That is fine and must stay that
way (undo needs the entry back): the closing session is already removed from the **tree**, and the scope
set is built from the tree, so `top(1, in: scope)` cannot return it. This is worth an explicit test, not
just an assumption.

**Out of scope (decided)**

`removeWorkspace` / `softRemoveWorkspace` keep their existing cross-workspace positional reselection. The
"stay in the current workspace" constraint is meaningless when the workspace itself is what's being removed,
and the discussion only agreed to the session-close case. Do not touch them.

**Control API / keep-in-sync audit** (per CLAUDE.md — stated explicitly, not silently skipped)

- No new user action, so the four-point audit (`Command` case / `ControlServer` arm / `agtermctl` subcommand
  / round-trip tests) is **already satisfied**: `session.close` exists and drives the same `AppStore` seam,
  so it picks up the new behavior for free.
- No new per-session state is introduced, so **no `tree` read-back field is owed**. The resulting selection
  is already readable — `selectedSessionID` surfaces on the tree as the selected session.
- The bundled agent skill (`agterm/Resources/agent-skill/`) documents commands/args/returns and the
  window/workspace/session model, none of which change. No update needed.
- `site/docs.html` / `site/commands.html` / `README.md` do not document close-reselection behavior (verified:
  no mention of the positional neighbor rule anywhere user-facing), so no website change was planned. The
  behavior IS described in `.claude/rules/menu-actions.md`, which does need updating. **As shipped, this
  changed**: review asked for a user-facing sentence, so `README.md` and its `site/docs.html` mirror each
  gained a short note on the new close-reselection rule; `site/commands.html` stays untouched (no command
  changed).
- `CHANGELOG.md` is release-only — **do not touch it** in this PR.

## Development Approach

- **Testing approach**: TDD (tests first)
- Complete each task fully before moving to the next
- Make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
- **CRITICAL: all tests must pass before starting the next task** — no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- Run `cd agtermCore && swift test` after each change
- Maintain backward compatibility: the positional fallback guarantees the worst case is today's behavior

## Testing Strategy

- **Unit tests** (`agtermCore`, host-free, the primary safety net): all new selection logic is exercised
  here via `swift test`. Extend `AppStoreTests.swift` (which already covers `closeSession` and the
  soft-close paths) rather than adding a new file, and reuse `AppStoreTestFixtures.swift`.
- **XCUITest e2e**: NOT required. The behavior is pure model logic with no new UI surface, and the existing
  close/session-nav UI tests already assert that closing the active session leaves a valid selection — they
  must keep passing (a regression there would mean the fallback is broken).
- **Manual acceptance**: reproduce the two examples from the discussion body in a dev instance (see
  Post-Completion).

## Progress Tracking

- Mark completed items with `[x]` immediately when done
- Add newly discovered tasks with ➕ prefix
- Document issues/blockers with ⚠️ prefix
- Keep this plan in sync with the actual work done

## Implementation Steps

### Task 1: Set up the isolated worktree and pin down current behavior

- [x] create an isolated git worktree for this work — ⚠️ **not applicable**: the work is already isolated on
      the `mru-reselection-on-close` branch in the main checkout (`git worktree list` shows a single
      checkout, already on that branch), and the ralphex loop drives that working directory. Moving to a
      separate worktree mid-loop would strand the loop's cwd. No worktree created.
- [x] symlink the three gitignored build artifacts — **not needed** for the same reason: `GhosttyKit.xcframework`,
      `agterm/Resources/ghostty`, and `agterm/Resources/terminfo` are all present in this checkout.
      `scripts/setup.sh` was not run.
- [x] confirm the baseline is green: `cd agtermCore && swift test` → **1528 tests in 62 suites passed**
- [x] read `AppStore.closeSession`, `reselectionTarget(after:)`, `navigableSessions`, `RecencyStack.top(_:in:)`,
      and both soft-close paths — **all four Context claims confirmed verbatim, nothing differs** (findings below)
- [x] run `make lint` to confirm a clean starting tree → **swiftlint --strict clean, zero findings**

**Findings (Task 1 code read — the Context section is accurate, no plan changes needed)**

- `closeSession` (`AppStore.swift:401`): removes the session from the tree (line 405), then calls
  `sessionRecency.remove(sessionID)` (line 413) **before** `selectedSessionID = reselectionTarget(after: location)`
  (line 415). Confirmed.
- `softCloseSession` (`AppStore+PendingClose.swift:54`): removes the session from the tree (line 58) and calls
  `reselectionTarget(after: location)` (line 77). It does **not** touch `sessionRecency`. Confirmed.
- `softCloseSessions` (`AppStore+PendingClose.swift:93`): removes the group from the tree (line 121) and calls
  `reselectionTarget` with the `removedBeforeActive`-adjusted index (lines 131-135). It does **not** touch
  `sessionRecency` either. Confirmed.
- The **only** recency prune on a soft close is `hardFinalizePendingSession` → `removeFromRecency`
  (`AppStore+PendingClose.swift:376`), which runs at grace expiry. So the key behavioral note holds: a
  soft-closed session stays in `sessionRecency` (undo needs it) but is gone from the tree, and since the
  scope set is built from the tree, `top(1, in: scope)` cannot return it. This gets an explicit test in Task 4.
- ➕ **Plan correction for Task 3 — later SUPERSEDED, the shipped helper has no stale-index branch at all
  (see the Task 3 note and "Deviations from the planned shape"): no caller removes a workspace before
  reselecting, so the defensive guard this bullet proposed was never needed.** `reselectionTarget(after:)`
  (`AppStore.swift:948`) force-indexes
  `workspaces[location.workspaceIndex]` with no bounds check — it traps on a stale index. So the defensive
  guard the plan specifies ("if the workspace index is no longer valid, fall back to `reselectionTarget`")
  cannot call `reselectionTarget` in that branch; it would crash on exactly the input it is meant to defend
  against. In the stale-index branch, return the first session of any remaining workspace instead (the same
  last-resort `reselectionTarget` itself uses), which also preserves the "never nil while sessions survive"
  criterion. The Technical Details pseudo-code below is updated to match.
- `navigableSessions` (`AppStore.swift:791`) and `RecencyStack.top(_:in:)` (`RecencyStack.swift:32`) are exactly
  as described — `top` already skips ids absent from `valid`.

### Task 2: Write the failing tests for MRU reselection on close (TDD)

➕ **Plan deviation — the tests went into a NEW file, `AppStoreCloseReselectionTests.swift`, not
`AppStoreTests.swift`.** The plan called for extending `AppStoreTests.swift`, but that file is already
1979 lines against the HARD 2000-line test budget (`agtermCore/Tests/.swiftlint.yml`), so the ~140 new lines
would have pushed it over and failed `make lint --strict`. Per CLAUDE.md the limit is not to be bumped to
fit new code, so the new suite (`AppStoreCloseReselectionTests`, `@MainActor struct`) lives in its own file
and reuses `AppStoreTestFixtures.swift` (`makeStore()`) exactly as the plan intended. Task 4's soft-close
tests should go in the same new file.

- [x] test: the first discussion example — sessions `1 2 3`, select `1`, insert `4` **after** the current one
      (`1 4 2 3`) and select it, close `4` → selection is **`1`** (today it would be `2`)
- [x] test: the second discussion example — sessions `1 2 3`, select `1`, append `4` at the end (`1 2 3 4`)
      and select it, close `4` → selection is **`1`** (today it would be `3`)
- [x] test: the MRU survivor is preferred over the positional neighbor in general (a session touched more
      recently but positionally distant wins)
- [x] test: a more-recent MRU entry in **another workspace** is NOT picked — closing the active session falls
      back to the positional neighbor within its own workspace, and `focusedWorkspaceID` is untouched
- [x] test: with a focus filter on (`focusedWorkspaceID` set), the pick stays inside the focused workspace
- [x] test: in `.flagged` sidebar mode, the pick stays within the flagged set of the closing session's
      workspace
- [x] test: an empty scoped MRU (nothing ever activated — e.g. a fresh restore, or the only recent entry was
      the session just closed) falls back to `reselectionTarget`, reproducing today's positional pick exactly
      (driven through `restore(from:)`, since `sessionRecency` is `private(set)` and cannot be cleared directly)
- [x] test: closing the last session in the tree yields a nil selection (unchanged), but closing any session
      while others survive NEVER yields nil
- [x] run `swift test` — the new tests must fail for the right reason (wrong session selected), not compile
      errors or crashes → **exactly as expected: 5 of the 8 fail on a wrong-session `#expect`** (the
      positional neighbor is picked), zero compile errors or crashes. The other 3 PASS already and are
      no-regression guardrails: the cross-workspace, empty-recency-fallback, and never-nil cases must hold
      both before and after Task 3. Full suite: 1536 tests, the ONLY failures are these 5 — no existing test
      regressed. `make lint` is clean.

### Task 3: Add the scoped-MRU reselection helper and wire the hard close

➕ **Plan deviation — the helper lives in a NEW file, `AppStore+CloseReselection.swift`, not inside
`AppStore.swift`.** Added in place, it pushed `AppStore.swift` to 1016 lines and broke the 1000-line
`file_length` limit (`make lint --strict`). Per CLAUDE.md the limit is not to be bumped to fit new code, so
the helper sits in a small `extension AppStore` file of its own. It is `internal`, so `closeSession` and
both soft-close paths (Task 4) reach it exactly as planned.

- [x] add `closeReselectionTarget(after location:)` — in `AppStore+CloseReselection.swift` (see the deviation
      above). ⚠️ **Shipped differently from this bullet's original wording in three ways** (all four points are
      spelled out under "Deviations from the planned shape"; the code's doc comment and
      `.claude/rules/menu-actions.md` are the authority):
      (a) the scope is the closing workspace's surviving ids ∩ the FLAGGED set in `.flagged` mode only — NOT
      ∩ `navigableSessions`, since that folds the FOCUS filter in and breaks two reachable states;
      (b) when the close leaves that workspace with nothing in scope the workspace term is DROPPED and the
      scope widens, rather than falling straight to the positional pick; in `.flagged` mode the fallback is
      itself scoped-and-positional (`nearestInScopeTarget`), with the unfiltered `reselectionTarget(after:)`
      standing only once the scope is empty (the last flagged session anywhere was closed);
      (c) there is NO stale-index branch — `reselectionTarget` force-indexes `workspaces[location.workspaceIndex]`
      with no guard of its own and no caller removes a workspace before reselecting, so the helper adds no new
      trap risk and the Task 1 "plan correction" turned out to be unnecessary
- [x] document the helper with a doc comment stating **why** the scope is restricted (an unscoped survivor
      could pull the user into another workspace), plus why the scope is built from the tree rather than the
      recency stack. ⚠️ **The "silently drop a focus filter" half of this bullet is SUPERSEDED**: as shipped,
      the focus filter deliberately does NOT scope the pick, and the doc comment says so explicitly — see
      deviation (a) above and "Deviations from the planned shape"
- [x] swap `closeSession` (AppStore.swift line 415) to call `closeReselectionTarget(after: location)`, and
      update its doc comment (it no longer just "reselects a neighbor")
- [x] leave `reselectionTarget(after:)` itself unchanged — it is now the fallback, and its ONLY caller (Task 5
      verified `removeWorkspace` / `softRemoveWorkspace` never called it; both keep their own inline positional
      pick, untouched by this branch)
- [x] run `swift test` — the 5 failing hard-close tests from Task 2 now pass; full suite **1536 tests in 63
      suites passed**, `make lint` clean

### Task 4: Wire the two soft-close (undoable) paths

➕ **One EXISTING test had to be rewritten: `softCloseSessionsAdjustsReselectionForEarlierBatchRemovals`
(`AppStoreTests.swift:474`).** It built its four sessions with `addSession` (which auto-selects each one), so
the last-added `/d` was the most-recently-activated survivor — under the new behavior the scoped MRU
legitimately picks `/d`, not the positional neighbor `/c` the test asserted. This is the intended change, not
a regression: the `removedBeforeActive` adjustment now feeds only the **fallback**. To keep that adjustment
covered, the test now drives the fallback path through `restore(from:)` (empty scoped recency once the
restored selection is the session being closed) and still asserts the neighbor — without the adjustment the
stale index would pick the last session instead. The `removedBeforeActive` code itself is unchanged, verbatim.

- [x] swap `softCloseSession` (AppStore+PendingClose.swift line 77) to `closeReselectionTarget(after:)`
- [x] swap `softCloseSessions` (AppStore+PendingClose.swift line 134) to `closeReselectionTarget(after:)`,
      **preserving** the existing `removedBeforeActive` index adjustment that feeds the positional fallback
- [x] write tests: soft-closing the active session picks the MRU survivor, same as the hard close
      (`softCloseActiveSessionPicksTheRecentSurvivorLikeTheHardClose` — the one new test that FAILED before the
      swap, for the right reason: the positional neighbor was picked)
- [x] write tests: multi-soft-close of several sessions (including the active one) picks the most-recent
      survivor that is NOT part of the closing group — the closed group is out of the tree, so it can never
      be selected even though it is still in `sessionRecency` (`softCloseSessionsNeverPicksAMemberOfTheClosingGroup`
      asserts both legs: the survivor is selected AND both closed ids are still in `sessionRecency.items`)
- [x] write tests: **undo** of a soft close still restores the previously-selected session (the existing
      `restorePendingSessions` behavior must not regress)
- [x] write tests: grace-expiry finalization after a soft close leaves the selection alone (finalize must not
      re-run reselection) — polls the teardown rather than a flat sleep, per the existing suite's convention
- [x] run `swift test` — all tests must pass before the next task → **1540 tests in 63 suites passed**,
      `make lint` clean

### Task 5: Verify acceptance criteria

- [x] verify both examples from the discussion body produce session `1`, exactly as the maintainer expects —
      covered by the two named unit tests `closeActiveSessionInsertedAfterCurrentReturnsToTheSessionItCameFrom`
      and `closeActiveSessionAppendedAtTheEndReturnsToTheSessionItCameFrom`, both green
- [x] verify no call site can produce a nil selection while sessions survive (grep every `reselectionTarget`
      and `closeReselectionTarget` caller) — exactly three callers of `closeReselectionTarget` (`closeSession`,
      `softCloseSession`, `softCloseSessions`), and `closeReselectionTarget` is in turn the ONLY caller of
      `reselectionTarget`; every branch of the helper returns a live tree id while any session survives (MRU
      hit → an id from the tree scope; `.flagged` fallback → an in-scope id from `nearestInScopeTarget`;
      otherwise `reselectionTarget`, which is nil only when no session remains anywhere). Guarded by
      `closeActiveSessionNeverClearsTheSelectionWhileSessionsSurvive`
- [x] verify `removeWorkspace` / `softRemoveWorkspace` are untouched and still positional — neither ever
      called `reselectionTarget`; both keep their own inline positional pick (`AppStore.swift:450-456`,
      `AppStore+PendingClose.swift:165-171`), unmodified by this branch
- [x] run the full `swift test` suite — must pass → **1540 tests in 63 suites passed**
- [x] build the app (`make build`) — must succeed → **BUILD SUCCEEDED**
- [x] run `make lint` (`swiftlint --strict`, zero findings) — must pass → **clean**
- [x] run the existing XCUITest suites that close sessions to confirm no regression in the e2e selection
      assertions — ran the five suites that exercise `session.close`/Close Session/undo-close
      (`ControlAPIUITests`, `NewSessionDirectoryUITests`, `DashboardUITests`, `SplitUITests`,
      `SidebarUITests`). All close/selection assertions passed. ⚠️ One unrelated flake:
      `SidebarUITests.testDragSessionToWorkspace` failed once (a drag test, no close path involved) and
      **passes on re-run in isolation** — not a regression from this change.

### Task 6: [Final] Update documentation

- [x] update `.claude/rules/menu-actions.md`: added a dedicated bullet right after `Close Session` recording
      that closing the ACTIVE session now returns to the most-recently-active surviving session via
      `closeReselectionTarget(after:)` (scoped to the closing session's own workspace, further ∩ the FLAGGED
      set in `.flagged` sidebar mode only — the focus filter deliberately does not scope it; the workspace
      term is dropped when the close leaves that workspace with nothing in scope), why the scope set is built
      from the tree rather than the recency stack (soft close must NOT prune `sessionRecency` — undo needs the
      entry), and that the positional `reselectionTarget` stays as the fallback (its only caller is now the
      helper — `removeWorkspace`/`softRemoveWorkspace` keep their own inline positional pick and were never
      callers). Semantic line breaks throughout
- [x] confirm — and state in the PR — that no control-API or agent-skill change is owed: re-verified
      the keep-in-sync audit holds. No new user action (`session.close` already drives the same `AppStore`
      seam and picks the behavior up for free), so the four-point control audit is already satisfied; no new
      per-session state, so no `tree` read-back field is owed (`selectedSessionID` already surfaces the result);
      the agent skill documents commands/args/returns and the window/workspace/session model, none of which
      change. The website claim did NOT hold: `README.md` and its `site/docs.html` mirror gained a short note
      on the new close-reselection rule (`site/commands.html` unchanged — no command changed). This goes in
      the PR body
- [x] do NOT touch `CHANGELOG.md` (release-only) — untouched, confirmed via `git status`
- [x] full suite green after the doc change: **1540 tests in 63 suites passed**, `make lint` clean

## Technical Details

**The helper — AS SHIPPED** (`agtermCore/Sources/agtermCore/AppStore+CloseReselection.swift`; this block
was revised during implementation, see "Deviations from the planned shape" below):

```
closeReselectionTarget(after location: (workspaceIndex: Int, sessionIndex: Int)) -> UUID?
    filtered      = sidebarMode == .flagged ? flagged ids : all tree ids
    sameWorkspace = ids of workspaces[location.workspaceIndex].sessions ∩ filtered
    scope         = sameWorkspace.isEmpty ? filtered : sameWorkspace   // widen when the workspace is spent
    if let recent = sessionRecency.top(1, in: scope).first { return recent }
    if sidebarMode == .flagged, let inScope = nearest in-scope session to the removed slot, walking the
      tree FLATTENED in sidebar order (forward first, then backward)
      { return inScope }                                               // keep the fallback in the filter,
                                                                       // and keep it POSITIONAL
    return reselectionTarget(after: location)                          // scope empty: last flagged closed
```

**Why the scope set is built from the tree, not from the recency stack:** the closing session is removed
from `workspaces` *before* reselection at every call site, so it is absent from `scope` by construction.
That is what makes the soft-close paths correct without pruning `sessionRecency` at close time (which they
must not do — undo needs the entry).

**Deviations from the planned shape** (all four landed as follow-up commits after review; the code's doc
comment and `.claude/rules/menu-actions.md` are the authority):

- **The FOCUS filter does not scope the pick** — the plan called for `∩ navigableSessions`, which folds
  focus in. That breaks two reachable states: closing a session while ANOTHER workspace is focused would
  jump the user INTO the focused workspace, and closing the focused workspace's last session would widen
  into an EMPTY set and fall through to a positional first-workspace jump. Focus is a property of the TREE,
  not of the selection (`setFocusedWorkspace` never moves the active session), and every caller already runs
  `autoUnfocusIfOutsideFocus` to reveal a pick landing outside it. Only the FLAGGED filter scopes.
- **The workspace term is dropped when the close leaves the workspace with nothing in scope**, rather than
  falling straight to the positional pick — "stay in this workspace" has nothing left to mean, and the
  positional alternative is a jump into the first workspace, the disorientation this feature removes.
- **The `.flagged` fallback is scoped AND positional** — the plan had the unfiltered `reselectionTarget` as
  the only fallback, which walks the tree positionally and so could land on an unflagged sibling the flagged
  sidebar renders no row for. `nearestInScopeTarget` repeats that walk restricted to the scope, over the tree
  flattened in sidebar order: the in-scope session that shifted into the removed slot, else the nearest
  in-scope one before it — cross-workspace once the scope has widened, since the flagged sidebar is one flat
  list. Only when the close took the LAST flagged session anywhere (empty scope) does the unfiltered
  positional pick stand.
- **No stale-index guard** — `reselectionTarget` itself force-indexes `workspaces[location.workspaceIndex]`
  with no guard, so the helper adds no new trap risk, and no caller removes a workspace before reselecting.

**Call sites after the change** (all three pass the same `location` they pass today):

| Call site | File | Behavior |
| --- | --- | --- |
| `closeSession` | `AppStore.swift` | scoped MRU → positional fallback |
| `softCloseSession` | `AppStore+PendingClose.swift` | scoped MRU → positional fallback |
| `softCloseSessions` | `AppStore+PendingClose.swift` | scoped MRU → positional fallback, with the existing `removedBeforeActive` index adjustment feeding the fallback |
| `removeWorkspace`, `softRemoveWorkspace` | both | unchanged — still positional/cross-workspace |

## Post-Completion

*Items requiring manual intervention or external systems — informational only*

**Manual verification** (in an isolated dev instance, per CLAUDE.md — `open -n --env AGTERM_STATE_DIR=/tmp/…`
so the deployed daily-driver app and its real `workspaces.json` are never touched; never kill or relaunch
the deployed app):

- Reproduce discussion example 1: from `1 2 3` on session `1`, open a new session after the current one
  (`1 4 2 3`), close `4` → should land back on `1`.
- Reproduce discussion example 2: from `1 2 3` on session `1`, open a new session at the end (`1 2 3 4`),
  close `4` → should land back on `1`.
- Close a session with a focus filter active → the pick is NOT scoped by focus (see the deviation above);
  when it lands outside the focused workspace, `autoUnfocusIfOutsideFocus` drops the filter to reveal it.
- Close a session in flagged sidebar mode → the selection stays within the flagged set, unless that close
  took the LAST flagged session anywhere, where the scope is empty and the unfiltered positional pick stands.
- Close a session right after a cold restore (nothing activated yet) → the old positional neighbor, no
  empty selection.
- Soft-close then undo within the grace window → the closed session comes back and is reselected.

**PR**

- Target `umputun/agterm` `master`; reference Discussion #147 in the PR body, note that the shape follows
  umputun's comment (scoped MRU with a positional fallback, no setting), and state that no control-API or
  agent-skill change is owed. The user-facing behavior note DOES land in `README.md` and its `site/docs.html`
  mirror.
- Write the PR description as prose, no test plan section, no AI attribution.
- After merge: remove the worktree, merging/branch-deleting from the **main checkout**, never from the
  worktree (it would switch the main checkout's branch).
