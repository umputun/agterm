# Ask dialog: session ownership for the terminal style

## Overview

- The terminal-style ask (`--style terminal`, the default) moves from the per-window modal slot to the
  session, one per session with optional pane placement, the same ownership shape as the HUD.
- The GUI style keeps today's window-level slot on `PickController`, exclusive with picks, with its
  existing session or pane anchoring.
- Motivating flow: the left pane decides codex in the right pane must exit, opens a terminal ask anchored
  on the right pane, the dialog draws over codex, and the left pane keeps working while it waits.
- Decisions settled in the brainstorm (all approved): one terminal ask per session; a terminal ask blocks
  only the pane or session it covers; an untargeted terminal ask goes to the window's selected session;
  the ask draws above program overlays, pane overlays and the HUD inside its region; a session-wide ask
  draws above the scratch while a pane-anchored one hides under it; a pending ask is cancelled the moment
  its session is soft-closed and undo restores the session without the dialog.

## Context (from discovery)

- Current implementation: PR #556 (`32ec288d`), plan `docs/plans/20260905-ask-dialog.md`.
- Model: `agtermCore/Sources/agtermCore/Ask.swift` (`PendingAsk`, `AskAnchor`, `AskNavigation`),
  `Pick.swift` (`PickController.pendingAsk`, `modalPending`, `PickRegistry` ask retention).
- HUD ownership to mirror: `Session.swift` `hudSpec`, `hudPaneIdentity`, `hudTargetPane`,
  `paneRole(forIdentity:)`; HUD pane-close hooks in `AppStore+Panes.swift:175-178, 223-235`.
- Validation and host: `ControlDispatcher+Ask.swift` (rejects `--pane` without a target at :93),
  `agterm/Control/ControlServer+Ask.swift` (builds `AskAnchor` for both styles at :26-41, refuses under
  zoom or dashboard, enforces `--window` for either style including retained results at :70-105; shipped
  errors are `ask already pending` and `session not visible`). GUI tree read-back: `ControlServer.swift:750`
  supplies `askPending` into `store.controlTree`; session nodes are built once in `AppStore.swift:296`.
- View: `agterm/Views/AskDialogView.swift`; the backdrop fills its host (:66-91) and `AskKeyCatcher`
  re-grabs first responder on every update and never relinquishes (:292-327). Mounted from
  `WindowContentView.swift:606` with `askAnchorFrame` (:650) and the anchor-invalid cancel (:627). The
  session layer it joins is the HUD panel in `WindowContentView+Detail.swift:284-300`.
- Existing focus guard to extend: `GhosttySurfaceView.pickOwnsFocus(in:)` (:833), consulted by
  `restoreAutoFocus` (:778). Paths that grab first responder and must consult the extended guard inside
  their retries: `retryReparentFocus` (`GhosttySurfaceView.swift:810`, no deck-active guard),
  `GhosttySurfaceView+Input.swift:155` `mouseDown`, `TerminalView.swift:69-94` attachment grab,
  `AppActions+Focus.swift:128-197` retry loops, `WindowContentView+Detail.swift:168-189` overlay-close and
  scratch-toggle refocus, `agtermApp.swift:483`, `WorkspaceSidebar.swift:730-735` direct grab.
  Cmd-W dismissal ladder: `AppActions.swift:218-264` (`escapePendingAsk`).
- Close paths that drop ownership: `AppStore.closeSession`, `removeWorkspace`;
  `AppStore+PendingClose.swift` `softCloseSession` (:86), `softCloseSessions` (:131-153),
  `softRemoveWorkspace` (:200-209), none delegating through one path; `WindowLibrary.swift`
  `closeWindow` (:453, early-returns while terminating) and `removeWindow` (:495-523) drop stores without
  closing sessions; the AppKit teardown that cancels window modals today is
  `PickRegistry.shared.unregister` from `WindowAccessor.swift:150` (willClose) and
  `WindowContentView.swift:244` (onDisappear); quit cancels before `ControlServer.stop` in
  `AppDelegate.swift:317-321`.
- CLI: `agtermCore/Sources/agtermctlKit/AskCommands.swift`; `ModalCommandRunner` polls by id only.
- Docs stating one pick or ask per window: `.claude/rules/control-api.md:557`,
  `.claude/rules/menu-actions.md:31`, `site/commands.html:2270`, `plugins/agterm/skills/agterm/SKILL.md:522`,
  `plugins/agterm/skills/agterm/reference.md:1003,1037` (plus `askPending` and style semantics at
  :251,258,1051,1090).

## Development Approach

- **testing approach**: Regular (code first, then tests in the same task)
- one task at a time; every task ends with its tests green before the next starts, and the app target
  builds after every task (`make test-app` scoped with `-only-testing` where a task touches `agterm/`)
- gates run once at the end: `cd agtermCore && swift test`, `make test-app`, `make lint`
- host-free logic stays in `agtermCore`; the app target resolves geometry, focus and drawing
- existing hosted GUI tests stay GUI fixtures; they are not rewritten to the terminal contract
- update this plan when scope changes

## Testing Strategy

- unit tests in `agtermCore` in the existing test file of each source file touched
- hosted tests (`agtermTests`) for mounting, clipping and input ownership
- UI tests (`agtermUITests/ControlAskUITests`) for the acceptance list in Task 6

## Progress Tracking

- mark completed items with `[x]` immediately when done; add discovered tasks with ➕, blockers with ⚠️

## Solution Overview

- **Ownership by style.** `ask.open` with `style: terminal` stores the request on the target `Session`
  (`askPending`, `askPaneIdentity`), independent of the overlay slot HUD and programs share, so an ask never
  refuses or destroys overlay work. `style: gui` keeps `PickController.pendingAsk` with its `AskAnchor`
  unchanged. Style therefore decides ownership and default placement, not only rendering.
- **One registry for lookup.** `AskRegistry` in `agtermCore` indexes each live ask id to its owner at open
  (the window id for GUI, the session id plus owning window id for terminal) and retains finished outcomes
  with their owning window in a bounded cache, replacing the ask half of `PickRegistry`. Pending state is
  owned once, by `Session` or `PickController`; the registry points at it. `ask.result` and `ask.cancel`
  resolve by exact id for either style and keep the `--window` mismatch refusal for both, so a stale
  callback cannot dismiss a later ask and a wrong window cannot read another window's ask.
- **Synchronous cancellation.** Every path that removes an owner cancels its ask in the store before the
  owner leaves the tree, never from a view disappearing: session close, soft close (single and batch),
  workspace removal (hard and soft), the exact anchored pane closing, window close and remove, the AppKit
  window teardown hooks, quit. A session-wide ask survives its sibling pane closing; pane identity follows
  swaps and right-to-left promotion; a pane that is merely not laid out keeps its ask pending.
- **Input scoped to the covered region.** The dialog and its backdrop are clipped to the anchored pane or
  the session area. `GhosttySurfaceView.pickOwnsFocus(in:)` grows into the single input-ownership decision
  and every focus path consults it inside its retries. A terminal ask owns input only when its session is
  the window's selected session, the window may take input, the covered region is laid out (missing pane
  geometry means hidden, never a session-frame fallback), the covered pane is the focused pane, and no GUI
  ask, pick, palette, sidebar rename or quick terminal holds input. Clicking the dialog selects and focuses
  that pane; answering an unfocused ask does not pull focus. Zoom and dashboard hide the ask, keep it pending
  and release input. Escape and Cmd-W act only on the interactive ask.
- **Layer order.** In its region the terminal ask draws above program overlays, pane overlays and the HUD
  and takes their keys. A session-wide ask draws above the scratch; a pane-anchored ask hides while the
  scratch covers its pane and returns on dismiss.
- **Read-back.** `ControlSessionNode` gains `ask` (pending id plus pane placement). Top-level
  `askPending` stays GUI-only.

## Technical Details

- `Session`: `askPending: PendingAsk?`, `askPaneIdentity: UUID?`, `askTargetPane` derived through
  `paneRole(forIdentity:)`, `openAsk(_:) -> Bool`, `resolveAsk(id:_:)`, `cancelAsk(id:)` matching the
  exact id. `PendingAsk` and `AskAnchor` keep their shape; the GUI path keeps building the anchor.
- `AskRegistry` (`@MainActor`, shared): `register(id:owner:)` with
  `enum Owner { case window(WindowInfo.ID); case session(UUID, window: WindowInfo.ID) }`, a resolver
  closure supplied by the app to reach the live `Session` or `PickController`, `retain(id:result:window:)`,
  `result(for:) -> (ControlAskResult, WindowInfo.ID)?`, cache limit 32 ordered by resolution sequence.
- Task order is chosen so the app target builds and no terminal ask is unanswerable at any task boundary:
  the session-owned dialog mounts (Task 3) before the host routes terminal asks to sessions (Task 4).

## Implementation Steps

### Task 1: Session ask slot and the shared id registry

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Ask.swift`, `Session.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AskTests.swift`, `SessionTests.swift`

- [x] add `askPending`, `askPaneIdentity`, `askTargetPane`, `openAsk`, `resolveAsk(id:)`, `cancelAsk(id:)`
      to `Session`; a second open is refused; a stale id is ignored
- [x] add `AskRegistry` (owner index, resolver, bounded finished cache with owning window); `PickRegistry`
      ask retention stays until Task 4 removes it
- [x] update `PendingAsk.style` doc comment: style decides ownership and default placement
- [x] tests in `SessionTests`: slot exclusion, exact-id resolve and cancel, `askTargetPane` after swap and
      promotion; tests in `AskTests`: registry pending and finished lookup for both owners, window
      recorded with a finished result, cache bound and ordering
- [x] `swift test --filter` on both files; must pass before Task 2

### Task 2: Cancel on every owner-removal path in the store

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`, `AppStore+PendingClose.swift`,
  `AppStore+Panes.swift`, `WindowLibrary.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreTests.swift`, `AppStorePendingCloseTests.swift`,
  `AppStorePaneTests.swift`, `AppStorePaneSwapTests.swift`, `WindowLibraryTests.swift`

- [x] cancel the session ask in `closeSession`, `softCloseSession`, `softCloseSessions`, `removeWorkspace`,
      `softRemoveWorkspace`, before the session leaves the tree; undo never restores a cancelled ask
- [x] on pane close, cancel only when the closed pane's identity equals `askPaneIdentity`, next to the HUD
      hooks; swap and promotion leave the identity alone
- [x] `WindowLibrary.closeWindow` and `removeWindow` cancel every session ask in the dropped store
- [x] tests: each path yields `cancelled` from `AskRegistry.result` immediately after the call, batch and
      soft variants included; sibling pane close keeps a session-wide ask; swap and promotion keep the ask
- [x] `swift test --filter` on the touched files; must pass before Task 3

### Task 3: Session-owned dialog mount and input ownership

**Files:**
- Modify: `agterm/Views/AskDialogView.swift`, `WindowContentView+Detail.swift`,
  `Ghostty/GhosttySurfaceView.swift`, `Ghostty/GhosttySurfaceView+Input.swift`, `TerminalView.swift`,
  `AppActions.swift`, `AppActions+Focus.swift`, `agtermApp.swift`, `Views/WorkspaceSidebar.swift`
- Modify: `agtermTests/AskDialogViewTests.swift`, `PickFocusGuardTests.swift`,
  `GhosttySurfaceViewInputTests.swift`

- [ ] mount `Session.askPending` in the session detail layer above the HUD panel, framed and hit-tested to
      the pane frame from `HudPaneAnchorsPreferenceKey` or the detail frame; hidden under zoom, dashboard
      and, for a pane ask, the scratch; the GUI mount in `WindowContentView.swift` is untouched
- [ ] extend `pickOwnsFocus(in:)` into the input-ownership decision described in Solution Overview; it
      takes the candidate session and pane alongside the window, since a window-only answer cannot block
      the covered right pane while allowing a left-pane refocus; `AskKeyCatcher` grabs when it becomes
      true for its pane and resigns first responder when it turns false; clicking the dialog selects and
      focuses its pane; answering does not refocus
- [ ] hosted fixtures seed the ask through `Session.openAsk` plus `AskRegistry.register` with a test
      resolver and mount the session view directly; `ControlServer` still routes terminal asks to
      `PickController` until Task 4, and the existing GUI fixtures stay untouched
- [ ] consult the decision inside every focus path listed in Context, including `retryReparentFocus`,
      `mouseDown`, overlay-close and scratch-toggle refocus, and the sidebar's direct grab
- [ ] Escape and the Cmd-W ladder in `AppActions.swift` dismiss the session ask only when it owns input
- [ ] tests: backdrop frame equals the covered pane; ownership truth table over selected session, window
      eligibility, laid-out region, focused pane, GUI modal, palette, rename, quick terminal, zoom,
      dashboard, scratch by anchor kind; catcher resigns when ownership turns false; `mouseDown` and
      reparent retry skip the grab while the ask owns the pane
- [ ] `make test-app` scoped to the three test classes; must pass before Task 4

### Task 4: Host, dispatcher and read-back switch over by style

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher+Ask.swift`, `ControlProjection.swift`,
  `AppStore.swift`, `Pick.swift`, `ControlActions*.swift`
- Modify: `agterm/Control/ControlServer+Ask.swift`, `ControlServer.swift`, `AppDelegate.swift`,
  `Views/WindowAccessor.swift`, `Views/WindowContentView.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherAskTests.swift`, `PickTests.swift`,
  `AppStoreTreeProjectionTests.swift`; `agtermTests/ControlServerAskTests.swift`

- [ ] dispatcher: accept `--pane`/`--pane-id` without a target for terminal style only; GUI keeps the
      rejection and its target-anchored placement
- [ ] host: terminal open resolves the target or the window's selected session, captures pane identity,
      refuses `ask already pending` and `session not visible`, drops the zoom and dashboard refusal, and
      registers the owner; result and cancel locate either owner through `AskRegistry` and keep the
      `--window` mismatch refusal for both styles
- [ ] remove ask retention from `PickController` and `PickRegistry`; `modalPending` covers GUI asks and
      picks only; the `unregister` hooks in `WindowAccessor` and `WindowContentView` and the quit path in
      `AppDelegate` cancel session asks too, before `ControlServer.stop`
- [ ] `ControlSessionNode.ask` (id, pane) in the `AppStore.swift:296` projection; `askPending` at
      `ControlServer.swift:750` stays GUI-only
- [ ] tests: untargeted terminal `--pane` resolves to the selected session, GUI rejection kept, second
      terminal ask refused, wrong `--window` refused for a terminal id, result by id for both styles,
      `ask` on the session node with `askPending` nil for a terminal ask, existing GUI anchor tests still
      pass unchanged
- [ ] `swift test --filter` plus `make test-app` scoped to `ControlServerAskTests`; must pass before Task 5

### Task 5: CLI accepts pane placement without a target

**Files:**
- Modify: `agtermCore/Sources/agtermctlKit/AskCommands.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/AskCommandsTests.swift`

- [ ] drop the target requirement for `--pane`/`--pane-id` when the style is terminal; help text names
      the selected-session default
- [ ] tests: pane without target for terminal builds the request, GUI without target still refused, exit
      mapping unchanged
- [ ] `swift test --filter AskCommandsTests`; must pass before Task 6

### Task 6: UI acceptance tests

**Files:**
- Modify: `agtermUITests/ControlAskUITests.swift`

- [ ] left pane keeps typing while a right-pane ask is pending; answering it sends no bytes to the right
      shell
- [ ] two sessions hold terminal asks at once; a GUI ask opens over a session with a terminal ask and takes
      the keys until answered
- [ ] a pick opened over a pending terminal ask takes keys; closing it returns them to the ask
- [ ] overlay exit and sibling pane close while an ask is pending do not steal its keys; the anchored pane
      closing cancels it
- [ ] zoom hides the ask and typing reaches the zoomed terminal; scratch over a session-wide ask leaves the
      ask on top, scratch over a pane ask hides it until dismissed
- [ ] soft close then immediate `ask result` returns `cancelled`; undo brings the session back without the
      dialog
- [ ] `-only-testing:agtermUITests/ControlAskUITests`; must pass before Task 7

### Task 7: Documentation

**Files:**
- Modify: `.claude/rules/control-api.md`, `.claude/rules/menu-actions.md`, `CLAUDE.md`,
  `site/commands.html`, `site/docs.html`, `plugins/agterm/skills/agterm/SKILL.md`,
  `plugins/agterm/skills/agterm/reference.md`

- [ ] `control-api.md` owns the contract: ownership by style, cancel paths, input priority order, scratch
      rule; `menu-actions.md` modal-cover line names GUI asks only; `CLAUDE.md` overlay-slot note gains one
      line that the ask slot is separate
- [ ] `commands.html`, `SKILL.md`, `reference.md`: `ask` on the session node, `askPending` GUI-only,
      terminal default placement, `--pane` without a target, every "one pick or ask per window" sentence
- [ ] `docs.html`: the terminal ask covers one session or pane and leaves the rest of the window usable

### Task 8: Verify acceptance criteria and close the plan

- [ ] in a Debug instance with isolated state: the motivating flow (left asks over right, keeps working,
      reads the answer); a script inside a program overlay asks and is answered; a GUI ask and a terminal
      ask in one window with the GUI one taking keys
- [ ] run `cd agtermCore && swift test`, `make test-app`, `make lint` once; zero findings
- [ ] move this plan to `docs/plans/completed/`
