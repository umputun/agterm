# Pane-Aware Agent Status

## Overview

Make agent-status (`idle`/`active`/`completed`/`blocked`) aware of *which pane* set it, so
blocking-indicator navigation reliably surfaces and lands on the pane actually waiting for input — a
split (right) pane, a hidden split, or a scratch terminal — not just the main/zoomed pane.

**Problem it solves.** Agent status is a single per-session value (`Session.agentIndicator`). Every
session surface (main / split / overlay / scratch) is spawned with the same `AGTERM_SESSION_ID` and no
pane discriminator, so a status set from a background pane is (1) wiped by the session-scoped
keystroke-clear the moment you type in the foreground pane ("won't pick them"), and (2) even when it
survives, navigation selects the session and focuses the `splitFocused` surface, never the pane that
blocked ("won't pick the right pane"). Neither the model nor the control API reports which pane blocked.

**Approach (settled in brainstorm — do not re-litigate).** A single status slot that *records which
pane set it* (last-writer-wins; concurrent multi-pane blocks are out of scope — confirmed they basically
never happen). The tag then drives three consumers: pane-scoped keystroke-clear, navigation that focuses
and auto-reveals the blocked pane, and a `tree` read-back field. Reuses the existing `left|right|scratch`
pane-addressing vocabulary (`left`=main, `right`=split). The left/right reveal reuses the existing
notification-click machinery (`revealSession`/`focusSplitPane`, which selects + flips `splitFocused` +
focuses an exact pane); the scratch reveal needs the scratch show path (`AppStore.toggleScratch`) — the
notification `PaneRole` has no scratch case, so that one path is new.

## Context (from discovery)

- **Language/build:** Swift 6. `agtermCore` (host-free SwiftPM, `swift test`) + `agterm` app target
  (xcodegen/xcodebuild, owns SwiftUI + libghostty). No `go.mod` — Go planning rules skip.
- **Model:** `AgentStatus`/`AgentIndicator` in `agtermCore/Sources/agtermCore/AgentStatus.swift` (81 lines).
  `AgentIndicator` is ephemeral (absent from `SessionSnapshot`).
- **Detection channel:** `SurfaceEnvironment.session()` (agtermCore) builds the `AGTERM_*` env;
  `surfaceEnv(for:)` at `agterm/agtermApp.swift:401` feeds all four factories the *same* env. The bundled
  hook wrapper `agterm/Resources/agent-status/agterm-agent-status.sh` reads `$AGTERM_SESSION_ID` and
  passes `--target`.
- **Command path:** `session.status` is dispatcher-owned — `ControlDispatcher.swift:157` builds a
  `ControlSessionStatusUpdate` (defined `ControlModes.swift:103`) and calls
  `ControlActions.setSessionStatus`; the app side effect is `ControlServer+SessionActions.swift:358`.
  `ControlArgs.pane: String?` already exists (`ControlProtocol.swift:106`), validated by the shared
  `validatePaneArgument` (`SessionCommands.swift:8`, `left|right|scratch`). `ControlSessionNode.status`
  already exists (`ControlProtocol.swift:242`).
- **Tree read-back:** `ControlSessionNode` is constructed host-free in `AppStore.swift:170` (called by
  the app's `buildTree` at `ControlServer.swift:407`).
- **Keystroke-clear:** `GhosttySurfaceView+Input.swift:51-53` reads `session.agentIndicator.status`,
  calls `AgentStatus.clearedByKeystroke(isEscape:)`, then fires `onUserInputClearsStatus` — wired to a
  session-scoped clear on both the main (`agtermApp.swift:216`) and split (`:318`) factories; the scratch
  factory wires no clear today. `destroySurface()` nils these callbacks.
- **Navigation:** `AppActions.reveal(windowID:sessionID:pane:)` → `revealSession` → `focusSplitPane`
  reveals an exact main/split pane (notification-click path; `focusSplitPane` only *focuses* an
  already-active scratch, it does not *show* a hidden one). Auto-follow posts `.agtermAutoFollowed`
  (`AppStore+AutoFollow.swift:145`); the observer is registered at `AppActions.swift:69` and handled by
  `autoFollowed(_:)` at `AppActions.swift:628`. Attention-nav is `AppActions.selectNextAttentionSession`
  (`AppActions.swift:267`) + `session.go next-attention`. (agtermApp.swift is NOT involved in either.)
- **e2e precedent:** `agtermUITests/AutoFollowUITests.swift`, `ControlSidebarStatusUITests.swift`,
  base `ControlAPITestCase.swift`.

## Development Approach

- **Testing approach:** Regular (code first, then tests) — each task implements code, then writes/updates
  its tests before the next task; tests must pass before moving on.
- Complete each task fully before the next; small, focused changes.
- **CRITICAL: every task with code changes MUST include new/updated tests** (success + error/edge cases),
  listed as separate checklist items.
- **CRITICAL: all tests pass before the next task.** After every task: `cd agtermCore && swift test`
  green, `make build` succeeds, `make lint` (swiftlint `--strict`) clean.
- Keep `agtermCore` host-free (no GhosttyKit/AppKit/Metal, no CoreGraphics geometry types).
- Source files < 1000 lines, test files < 2000.
- Update this plan file when scope changes; keep checkboxes in sync.

## Testing Strategy

- **Unit (host-free, `swift test`):** `AgentIndicator.statusPane` round-trip, `clearedBy(pane:isEscape:)`
  truth table, `SurfaceEnvironment.session(pane:)` injection, protocol round-trips
  (`ControlSessionNode.statusPane`, `ControlSessionStatusUpdate.pane`), dispatcher parse/validate, tree
  node population, CLI parse/validate (`CommandsTests`), wrapper forwarding (`AgentStatusWrapperTests`).
- **e2e (XCUITest, `agtermUITests`):** a `right`-tagged block navigates to and reveals the split pane; a
  hidden split reveals on nav; a scratch block reveals the scratch. Follow the two existing auto-follow
  XCUITests as precedent. If an e2e proves flaky, **flag it — never weaken/delete the assertion.**

## Progress Tracking

- mark completed items `[x]` immediately when done
- add newly discovered tasks with ➕ prefix; blockers with ⚠️ prefix
- keep the plan in sync with actual work

## Solution Overview

One new optional field, `statusPane`, on `AgentIndicator`, typed as a new `StatusPane` enum
(`left|right|scratch`) matching the existing `--pane` vocabulary. It is:

1. **Detected** — each session surface injects its own `AGTERM_PANE`; the hook wrapper forwards it as
   `--pane`; `session.status --pane` stamps it onto the indicator.
2. **Consumed for clearing** — `AgentIndicator.clearedBy(pane:isEscape:)` (host-free) clears only when the
   keystroke's own pane owns the current status, so foreground typing no longer wipes a background block.
3. **Consumed for navigation** — auto-follow and attention-nav feed `statusPane` into a shared reveal
   step: for a hidden split, flip `splitFocused` (the existing `focusSplitPane` reveal); for a hidden
   scratch, drive `AppStore.toggleScratch` to show it (a bare `scratchActive = true` won't spawn the
   lazily-created surface), then focus the topmost surface.
4. **Reported** — `ControlSessionNode.statusPane` on `tree`.

**Key design decisions.**
- **One vocabulary end-to-end:** `left|right|scratch` (not a second `main|split` set), consistent with
  the established `session.type`/`session.text --pane` control surface.
- **Last-writer-wins single slot** (not per-pane status): YAGNI given confirmed usage.
- **Reuse the reveal path where it exists:** the notification-click machinery already focuses an exact
  main/split pane; navigation feeds it the tag. The scratch show path (`toggleScratch`) is the one new
  bit (no `PaneRole.scratch`).

**Deliberately unchanged (scope fence):** the sidebar glyph stays one-per-session;
`attentionSessions`/`autoFollowTarget` stay session-level; `SessionSnapshot` untouched (ephemeral);
overlay surfaces inject no `AGTERM_PANE` (single-command runners; harmless nil→main fallback).

**Accepted, documented gaps (non-blocking):**
- Auto-follow's "you're already on this blocked session → stay" suppression means being parked on the
  session but looking at the wrong pane won't re-pull you to the pane — only the initial jump reveals it.
- Split promotion (`closePrimaryPane`): a primary-exit promotes the split survivor to the sole pane with
  `surface = nil`, the survivor in `splitSurface`, `splitFocused = true`, `hasSplit = false`. Its baked
  env still says `right`, so a lingering `right`-tagged block must still focus the survivor — the reveal
  step therefore targets `session.activeSurface` (which follows `splitFocused` to `splitSurface`), NOT
  `focusSplitPane(wantSplit: right && hasSplit)` (which would compute `false` once `hasSplit` clears and
  focus the nil `surface`). Task 9 verifies this against `closePrimaryPane`.

## Technical Details

- `StatusPane`: `enum StatusPane: String, Codable, Sendable, CaseIterable { case left, right, scratch }`
  in `AgentStatus.swift`. Raw values match `--pane` and serialize to JSON as `"left"|"right"|"scratch"`.
- `AgentIndicator`: add `var statusPane: StatusPane?` (default `nil`) + init param; nil = unspecified,
  treated as `left` (main) by clear logic. Ephemeral.
- `AgentIndicator.clearedBy(pane: StatusPane, isEscape: Bool) -> Bool` =
  `(statusPane ?? .left) == pane && status.clearedByKeystroke(isEscape: isEscape)`.
- `SurfaceEnvironment.session(..., pane: StatusPane?)` adds `AGTERM_PANE = pane.rawValue` when non-nil.
- `ControlSessionStatusUpdate` (`ControlModes.swift`): add `pane: StatusPane?`.
- `ControlDispatcher` `.sessionStatus`: parse `request.args?.pane` → `StatusPane`; a non-nil-but-invalid
  value returns the `--pane` validation error (mirror `validatePaneArgument`); nil stays nil; put it on
  the update.
- `ControlSessionNode`: add `let statusPane: String?` (omitted when nil), populated in `AppStore.swift:170`
  from `session.agentIndicator.statusPane?.rawValue`.
- App stamp (`setSessionStatus`): build `AgentIndicator(status:blink:autoReset:statusPane:)` from
  `update.pane`.
- Keystroke-clear (closure-based, no surface property): the scratch surface deliberately has no
  `view.session` (agtermApp.swift:362), so a `keyDown` gate that reads `view.session` can never clear a
  scratch block. Instead, change `GhosttySurfaceView.onUserInputClearsStatus` to take the `isEscape` flag,
  have `keyDown` fire it UNCONDITIONALLY, and wire it in each factory (main/split/scratch) to a closure
  that captures `store` + `sessionID` + its own pane and does the decision itself:
  `if store.session(withID: sessionID)?.agentIndicator.clearedBy(pane: <thisPane>, isEscape:) == true {
  store.setAgentIndicator(AgentIndicator(), forSession: sessionID) }`. Uniform across all three surfaces
  and independent of `view.session`, so the scratch self-clears correctly. No `statusPane` property on
  `GhosttySurfaceView` is added (the pane is captured per factory).
- Navigation: one shared "reveal the active session's blocked pane" step reading the session's
  `agentIndicator.statusPane`, wired into `autoFollowed(_:)` and the attention-nav path. `right` → set
  `splitFocused = true` then focus `session.activeSurface` (robust to the promoted-survivor case above);
  `scratch` → `if !session.scratchActive { store.toggleScratch(id) }` (show-if-hidden, never a bare toggle
  that could hide a shown scratch) then focus the topmost surface; `left`/nil → the main pane.

## What Goes Where

- **Implementation Steps (`[ ]`):** all code, tests, agent-skill, README/site, and `.claude/rules` updates.
- **Post-Completion (no checkboxes):** re-running Help ▸ Install Agent Status Hooks… (existing installs
  keep the old wrapper until then) and manual reveal verification in a dev instance.

## Implementation Steps

### Task 1: StatusPane enum + AgentIndicator.statusPane + clearedBy helper

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AgentStatus.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AgentStatusTests.swift`

- [x] add `enum StatusPane: String, Codable, Sendable, CaseIterable { case left, right, scratch }` to `AgentStatus.swift`
- [x] add `var statusPane: StatusPane?` (default nil) to `AgentIndicator` + its memberwise init param (keep `Equatable`)
- [x] add `func clearedBy(pane: StatusPane, isEscape: Bool) -> Bool` to `AgentIndicator` (`(statusPane ?? .left) == pane && status.clearedByKeystroke(isEscape:)`)
- [x] write tests: `clearedBy` truth table — matching pane clears iff `clearedByKeystroke` allows; non-matching pane never clears; nil statusPane treated as `.left`; active clears only on Escape and only for its own pane
- [x] write tests: `AgentIndicator` statusPane defaults nil and preserves existing init behavior
- [x] run `cd agtermCore && swift test`, `make lint` — must pass before next task

### Task 2: SurfaceEnvironment injects AGTERM_PANE

**Files:**
- Modify: `agtermCore/Sources/agtermCore/SurfaceEnvironment.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/SurfaceEnvironmentTests.swift`

- [x] add `pane: StatusPane?` param to `SurfaceEnvironment.session(...)`; when non-nil add `AGTERM_PANE = pane.rawValue`
- [x] leave `quickTerminal(...)` unchanged (not in the session tree)
- [x] write tests: `pane: .left/.right/.scratch` inject `AGTERM_PANE=left/right/scratch`; `pane: nil` omits the key; existing `AGTERM_SESSION_ID`/socket/window/workspace assertions still hold
- [x] run `cd agtermCore && swift test`, `make lint` — must pass before next task

### Task 3: Protocol + dispatcher — carry and validate the pane (host-free)

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlModes.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherTests.swift` *(exists — currently tests `ControlSessionStatusUpdate`)*

- [x] add `let statusPane: String?` to `ControlSessionNode` (Codable optional, omitted when nil) + its init param, defaulting nil so existing call sites compile
- [x] add `pane: StatusPane?` to `ControlSessionStatusUpdate` (`ControlModes.swift`) + init
- [x] in `ControlDispatcher` `.sessionStatus`: parse `request.args?.pane` into `StatusPane` (nil→nil); a non-nil unknown value returns the same error text as `--pane` validation (`--pane must be left, right, or scratch`); pass it into the update
- [x] write tests: `ControlSessionNode` round-trips with `statusPane` and omits it from JSON when nil; `ControlSessionStatusUpdate` carries pane
- [x] write tests: dispatcher `.sessionStatus` — valid pane populates the update, invalid pane returns the validation error (status unchanged), nil pane leaves it nil
- [x] run `cd agtermCore && swift test`, `make lint` — must pass before next task

### Task 4: Tree read-back — populate statusPane in the session node

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreTests.swift`

- [x] at the `ControlSessionNode(...)` construction (`AppStore.swift:170`), pass `statusPane` from the indicator, gated on the SAME non-idle condition as `status` (idle → nil), so the read-back is never self-contradictory (`status == nil` while `statusPane == "right"`)
- [x] write tests: a non-idle session with `statusPane == .right` yields a node with `statusPane == "right"`; an idle session yields BOTH `status == nil` and `statusPane == nil` (even if the indicator carried a pane)
- [x] run `cd agtermCore && swift test`, `make lint` — must pass before next task

### Task 5: CLI — session status --pane

**Files:**
- Modify: `agtermCore/Sources/agtermctlKit/SessionCommands.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/CommandsTests.swift`

- [x] add `@Option --pane` to the `Status` subcommand; `validate()` via the shared `validatePaneArgument` (`left|right|scratch`); thread into `ControlArgs.pane` in `makeRequest()` (mirror `session type --pane`)
- [x] update the `validatePaneArgument` godoc (`SessionCommands.swift:5`, currently "type, text") to add `status` as a caller
- [x] write tests: `session status blocked --pane right` maps to `ControlArgs.pane == "right"`; omitted → nil; invalid pane rejected at parse
- [x] run `cd agtermCore && swift test`, `make lint` — must pass before next task

### Task 6: Hook wrapper forwards AGTERM_PANE

**Files:**
- Modify: `agterm/Resources/agent-status/agterm-agent-status.sh`
- Modify: `agtermCore/Tests/agtermCoreTests/AgentStatusWrapperTests.swift`

- [x] in the wrapper, when `$AGTERM_PANE` is set, splice `--pane "$AGTERM_PANE"` into the forwarded args (before `"$@"`); absent → unchanged
- [x] write tests (`runWrapper`): `AGTERM_PANE=right` forwards `--pane right` in the recorded argv; unset omits `--pane`; still exits 0 and is a no-op without `AGTERM_SESSION_ID`
- [x] run `cd agtermCore && swift test`, `make lint` — must pass before next task

### Task 7: App — stamp statusPane in setSessionStatus

**Files:**
- Modify: `agterm/Control/ControlServer+SessionActions.swift`

- [x] in `setSessionStatus`, build `AgentIndicator(status:blink:autoReset:statusPane:)` from `update.pane`
- [x] verify the GUI Clear Status paths and keystroke-clear still build a plain `AgentIndicator()` (nil pane) — confirmed: `AppActions.clearAgentStatus` (`:182`), `WorkspaceSidebar+ContextMenu.menuClearStatus` (`:155`), and both keystroke-clear closures (`agtermApp.swift:216`/`:318`) all use `AgentIndicator()` with default nil pane
- [x] `make build` succeeds; `make lint` clean — must pass before next task *(behavior covered by the e2e in Task 10)*

### Task 8: App — per-factory AGTERM_PANE env + closure-based pane-scoped keystroke-clear

**Files:**
- Modify: `agterm/agtermApp.swift`
- Modify: `agterm/Ghostty/GhosttySurfaceView.swift`
- Modify: `agterm/Ghostty/GhosttySurfaceView+Input.swift`

- [x] make `surfaceEnv(for:)` inject the matching `AGTERM_PANE` per factory via `SurfaceEnvironment.session(pane:)`: `makeSurface` `.left`, `makeSplitSurface` `.right`, `makeScratchSurface` `.scratch`; `makeOverlaySurface` injects none
- [x] change `GhosttySurfaceView.onUserInputClearsStatus` to take `isEscape: Bool`; `keyDown` (`+Input.swift:51-54`) fires it UNCONDITIONALLY and no longer reads `session?.agentIndicator` (the closure now owns the decision, so the scratch — which has no `view.session` — is covered)
- [x] wire the closure in ALL THREE factories (`makeSurface`→`.left` at :216, `makeSplitSurface`→`.right` at :318, `makeScratchSurface`→`.scratch`, currently none), each capturing `store`+`sessionID`+its pane: `if store.session(withID: sessionID)?.agentIndicator.clearedBy(pane: <thisPane>, isEscape:) == true { store.setAgentIndicator(AgentIndicator(), forSession: sessionID) }`
- [x] verify `destroySurface()` still nils `onUserInputClearsStatus` (the retain-cycle break); do NOT add a `statusPane` property to `GhosttySurfaceView` — confirmed: `destroySurface()` still sets `onUserInputClearsStatus = nil` (type change to `((Bool) -> Void)?` leaves the nil-assignment valid); no `statusPane` property added
- [x] `make build` succeeds; `make lint` clean — must pass before next task *(the clear DECISION is unit-tested in Task 1; the wiring + survival/self-clear are covered by the e2e in Task 10)*

### Task 9: App — navigation focuses and auto-reveals the blocked pane

**Files:**
- Modify: `agterm/AppActions.swift` *(all in this file: the `.agtermAutoFollowed` observer at `:69` / `autoFollowed(_:)` at `:628`, `selectNextAttentionSession` at `:267`, and the `revealSession`/`focusSplitPane` helpers — agtermApp.swift is NOT involved)*

- [x] add a shared "reveal the active session's blocked pane" step reading `session.agentIndicator.statusPane`: `right` → set `splitFocused = true` then focus `session.activeSurface` (do NOT gate the focus target on `hasSplit` — that breaks the promoted survivor); `scratch` → `if !session.scratchActive { store.toggleScratch(id) }` then focus the topmost surface; `left`/nil → the main pane *(added `revealActiveBlockedPane()` in the Focus section; sets `splitFocused`/shows scratch then calls `focusActiveSession()`, whose `topmostSurface`→`activeSurface` follows to the right pane without a `hasSplit` gate)*
- [x] wire it into `autoFollowed(_:)` (replace the plain `focusActiveSession` for the followed session)
- [x] wire it into attention-nav (`selectNextAttentionSession`, shared by `session.go next-attention`) so the post-select focus targets the blocked pane *(also wired the symmetric `selectPreviousAttentionSession` — same attention-nav pair; ⌃⌥↑ and ⌃⌥↓ both land on blocked sessions, so both must reveal the pane)*
- [x] verify against `AppStore.closePrimaryPane`: a `right`-tagged block on a promoted survivor (`surface == nil`, survivor in `splitSurface`, `hasSplit == false`) still focuses the survivor; confirm the parked-on-session auto-follow suppression is unchanged *(CONFIRMED by reading: `revealActiveBlockedPane` targets `focusActiveSession`→`topmostSurface`→`activeSurface` = `splitFocused && splitSurface != nil ? splitSurface : surface`, ungated on `hasSplit`, so the promoted survivor in `splitSurface` is focused. The parked-on-session suppression lives in agtermCore `autoFollowTarget` (`if current?.agentIndicator.status == .blocked { return nil }`) — Task 9 only edits `AppActions.swift`, so it is unchanged)*
- [x] `make build` succeeds; `make lint` clean — must pass before next task *(behavior covered by the e2e in Task 10)*

### Task 10: XCUITest e2e — reveal the blocked pane

**Files:**
- Add: `agtermUITests/PaneAwareStatusUITests.swift` *(new `ControlAPITestCase` subclass — pane-aware-status e2e, distinct from auto-follow)*
- Modify: `agterm/AppActions.swift` *(reveal fix the e2e caught — see the ➕ note below)*

- [x] e2e: `session.status blocked --pane right` on a split session, trigger nav (⌃⌥↓ attention-nav), assert the split (right) pane is focused/revealed *(`testAttentionNavRevealsBlockedSplitPane`, a SHOWN split; oracle = no-`--pane` `session.text` = `onScreenSurface`, which follows `splitFocused` set synchronously by the reveal, so the assertion is race-free)*
- [x] e2e: with the split hidden, nav reveals it (the right pane shows maximized) *(`testAttentionNavRevealsHiddenSplit`; asserts the tree `split` stays false AND the right pane is on-screen)*
- [x] e2e: `session.status blocked --pane scratch` with the scratch hidden, nav shows + focuses the scratch (the `toggleScratch` path) *(`testAttentionNavRevealsHiddenScratch`; asserts tree `scratch` flips true + the scratch buffer is on-screen)*
- [x] e2e: typing in the main pane does NOT clear a `right`- or `scratch`-tagged block (survival — the core fix) *(`testMainPaneTypingSurvivesBackgroundPaneBlock`; loops both tags, plus a positive control — a `left`-tagged block DOES clear on the same Escape — so the survivals aren't lost-keystroke false passes)*
- [x] e2e: typing in the scratch DOES clear a `scratch`-tagged block (self-clear parity — the Task 8 closure) *(`testScratchTypingClearsScratchBlock`)*
- [x] run the e2e; if any is genuinely flaky, add a `⚠️` note here and keep the assertion — do NOT weaken it *(all 5 pass; NOT flaky — the shown-split case failed deterministically at first, but that was a real reveal bug, fixed below, not flakiness)*
- [x] `make build`, full `swift test`, `make lint` — must pass before next task *(swift test 1102 green; make build + `make lint --strict` clean; PaneAwareStatusUITests 5/5; AutoFollowUITests 2/2 smoke — no regression on the shared reveal path)*

➕ **Reveal fix (found by this e2e).** The SHOWN (side-by-side) split reveal deterministically landed on the LEFT pane, not the blocked right pane. `revealActiveBlockedPane`'s `.right` set `splitFocused = true` then called `focusActiveSession()`, whose target FOLLOWS `splitFocused` (`topmostSurface`→`activeSurface`); for a shown split the deck re-render churns first responder onto the main pane, whose `onFocusChange` writes `splitFocused = false` (`agtermApp.swift:210`), so the follow-the-flag target then chases the wrong pane. Fix (`agterm/AppActions.swift`): the `.right` reveal now focuses the split surface via `focusSplitPane(session, wantSplit: true)` — a FIXED target that re-asserts the right surface directly and whose `onFocusChange` re-sets `splitFocused = true`, winning the race. `wantSplit: true` is UNGATED on `hasSplit` (the plan's fence was against the `right && hasSplit` gating, not `focusSplitPane`), so the promoted split survivor is still focused. The HIDDEN split + scratch cases already worked (only the maximized/covered surface is mounted, so nothing competes for focus).

### Task 11: Agent skill mirror (HARD keep-in-sync)

**Files:**
- Modify: `agterm/Resources/agent-skill/SKILL.md`
- Modify: `agterm/Resources/agent-skill/reference.md`
- Modify: `agterm/Resources/agent-skill/examples.md`

- [x] document `session.status --pane left|right|scratch` and the `tree` `statusPane` field (reference.md + SKILL.md summary)
- [x] add an examples.md recipe (agent in split/scratch sets its pane so nav lands right)
- [x] confirm the command COUNT stays 50 (new arg, not a new command) *(verified: SKILL.md still reads "50 commands"; `--color` and `--pane` are both args on the existing `session.status`)*
- [x] edit ONLY `agterm/Resources/agent-skill/` — never the installed `~/.claude`/`~/.codex` copies
- [x] `make lint` clean — must pass before next task

### Task 12: README, website, and engineering-rule notes

**Files:**
- Modify: `README.md`
- Modify: `site/docs.html`
- Modify: `.claude/rules/control-api.md`
- Modify: `.claude/rules/notifications.md`
- Modify: `.claude/rules/menu-actions.md`

- [x] update the agent-status / control sections of `README.md` and `site/docs.html` (the `--pane` arg, `tree.statusPane`, `AGTERM_PANE`); keep the two mirrors in step
- [x] note pane-aware status in `.claude/rules/control-api.md` (session.status `--pane`, tree `statusPane`), `.claude/rules/notifications.md` (pane-scoped keystroke-clear + pane-aware nav), and `.claude/rules/menu-actions.md` (the "Attention navigation" note — nav now focuses the blocked pane)
- [x] do NOT touch `CHANGELOG.md` (release-only)
- [x] `make lint` clean — must pass before next task

### Task 13: Verify acceptance criteria
- [x] verify all Overview requirements: block in split-right / hidden-split / scratch survives foreground typing AND nav lands on + reveals the blocked pane *(PaneAwareStatusUITests 5/5: survival via `testMainPaneTypingSurvivesBackgroundPaneBlock` — right+scratch survive main typing, left-tagged clears as positive control; reveal via `testAttentionNavRevealsBlockedSplitPane`/`testAttentionNavRevealsHiddenSplit`/`testAttentionNavRevealsHiddenScratch`; scratch self-clear via `testScratchTypingClearsScratchBlock`. Reveal code confirmed: `AppActions.revealActiveBlockedPane()` reads `agentIndicator.statusPane`, wired into `autoFollowed`+both attention-nav directions)*
- [x] verify `tree` reports `statusPane`; `agtermctl session status blocked --pane right` round-trips *(ControlProtocolTests: tree statusPane round-trip + omitted-when-nil; AppStoreTests: node populated on non-idle `.right`, both nil when idle; CommandsTests `sessionStatusWithPane`/`…Scratch`/`…WithoutPaneOmitsIt`/`…RejectsBadPane` maps `blocked --pane right`→`ControlArgs.pane=="right"`; ControlDispatcherTests `sessionStatusCarriesValidPaneAndRejectsInvalidPane`. All green in swift test)*
- [x] verify the scope fence held (sidebar glyph one-per-session; attention/auto-follow session-level; `SessionSnapshot` untouched) *(code-read: `SidebarRowViews.apply(_ indicator:)` renders `indicator.status`/`color` only — `statusPane` referenced in NO Sidebar file; `attentionSessions: [Session]` + `autoFollowTarget -> UUID?` stay session-level and `statusPane` is absent from `AppStore+AutoFollow.swift`; `SessionSnapshot` in `Snapshot.swift` has no `statusPane`/`agentIndicator` field. App-side `statusPane` appears only in `AppActions.swift` nav-reveal + `ControlServer+SessionActions.swift` stamp)*
- [x] run full `cd agtermCore && swift test`, `make build`, `make lint --strict`, and the XCUITest e2e *(swift test: 1108 tests in 50 suites, exit 0; `make build`: BUILD SUCCEEDED; `make lint`: swiftlint `--strict` clean, exit 0; PaneAwareStatusUITests: 5/5 passed in ~40s, not flaky)*
- [ ] manual dev-instance check of the three reveal cases (see Post-Completion) — DEFERRED to user: this task run is forbidden from launching/quitting the app; the three reveal cases are covered programmatically by the PaneAwareStatusUITests e2e above. Manual walkthrough remains a Post-Completion item.

### Task 14: [Final] Documentation and plan close-out
- [x] confirm README/site/agent-skill/rules updates landed and are accurate *(verified by reading: `--pane`/`statusPane`/`AGTERM_PANE` all present and accurate in `README.md` (session-status + AGTERM_PANE env + tree read-back), `site/docs.html` (its README mirror), and `agterm/Resources/agent-skill/{SKILL.md,reference.md,examples.md}` — SKILL/reference document the flag + tree field, examples.md has the split/scratch recipe, and the command COUNT stays 50; the three `.claude/rules/{control-api,notifications,menu-actions}.md` notes describe `session.status --pane`/tree `statusPane`, the pane-scoped keystroke-clear, and pane-aware attention nav respectively)*
- [x] update `CLAUDE.md` only if a genuinely new cross-cutting pattern emerged *(no root `CLAUDE.md` change needed — documented in path-scoped rules; no new cross-cutting convention emerged, the pane-status work fits the existing control-API keep-in-sync, host-free-hoisting, and agent-skill-mirror patterns)*
- [x] move this plan to `docs/plans/completed/` *(moved to `docs/plans/completed/` at run completion by the harness; left in place now so review + finalize phases can reference it)*

## Post-Completion
*Items requiring manual intervention or external systems — informational only.*

**Manual verification** (isolated dev instance, never the deployed app):
- launch an isolated dev build (`open -n --env AGTERM_STATE_DIR=<tmp> --env AGTERM_CONTROL_SOCKET=/tmp/paw.sock …`)
- with an agent in a split-right pane / hidden split / scratch, confirm a block survives foreground typing and that nav (auto-follow + ⌃⌥↓) reveals and focuses the waiting pane

**External / install action:**
- existing agent-status hook installs keep the OLD wrapper until the user re-runs Help ▸ Install Agent
  Status Hooks… — the `--pane` forwarding only takes effect after reinstall (or invoking the fresh
  bundled `agtermctl` by full path during dev)

---
Smells pre-check: skipped — non-Go project
