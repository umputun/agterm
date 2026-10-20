# Hide and show overlays without closing them

## Overview
- Let the user hide a session's overlays (HTML pages and program overlays, session-wide and per-pane) without
  closing them, work in the terminal underneath (typically talking to the agent), then bring them back.
- Requested by users who want to collapse an HTML overlay to chat with the agent and return to it; today the
  options are closing it, running it in a separate session, or zooming the pane under it (`surface.zoom`), which
  loses the normal layout.
- A hidden overlay keeps running: its program, web page, size and identity are unchanged. Only its visibility,
  hit testing and input ownership change.
- Shared design brief: https://share.umputun.dev/0ux2QbjZWb1h-RTKLbAo6Q/ (live until 2026-10-27).

## Context (from discovery)
- Overlay state lives on `Session` (`agtermCore/Sources/agtermCore/Session.swift`, `Session+HtmlOverlay.swift`):
  one session-wide slot (`overlayActive`, `htmlOverlay`, HUD) and two pane slots (`leftOverlay`, `rightOverlay`).
- Occupancy predicates today: `overlayActive`, `hudActive`, `programOverlayActive`, `htmlOverlayActive`,
  `coverOverlayActive`, `fullOverlayActive`, `paneOverlay(_:) != nil`, `focusedOverlayPane`.
  Callers mix two questions: "is the slot occupied" (lifecycle, results, `--block`, page lookup, remote
  reservation in `AppStore+RemoteOverlay.swift` `localOverlayHolds`) and "does it cover the session now" (focus,
  zoom, deck gates, scratch focus gate, click catcher, pane hiding). `.claude/rules/control-api.md` lists the
  cover sites.
- Rendering: one always-mounted `overlayPanel` in `agterm/Views/WindowContentView+Detail.swift`; its content is
  built under `if session.overlayActive`, and it picks the HTML host from `htmlOverlayActive`.
- Control: `ControlProtocol.swift` command catalog, `ControlDispatcher+Overlay.swift`, `ControlActions` in
  `ControlDispatcher.swift`, app adapter `agterm/Control/ControlServer+SessionActions.swift`, CLI in
  `agtermCore/Sources/agtermctlKit/SessionCommands.swift`, tree node `ControlSessionNode` in
  `ControlProjection.swift` (built in `AppStore.swift`), `scheduleTreeChanged` in `AppStore+Events.swift`.
- Keymap/menu/palette: `BuiltinAction.swift`, `PaletteCatalog.swift`, `agterm/agtermApp+Menus.swift`,
  `agterm/AppActions+Palette.swift`; a focused HTML page swallows menu chords, so `close_session` is intercepted in
  `agterm/Commands/CustomCommandRunner.swift`.
- ⌘W ladder: `agterm/AppActions.swift` (session slot, scratch, focused pane slot, then close session with the
  opt-in `confirmCloseSession`).
- Title bar: `InterfaceElement` in `AppSettings.swift`, buttons in `agterm/Views/WindowContentView+Titlebar.swift`.
- `agtermCore` is a library consumed by the `agterm-linux` fork: add public API, never narrow or reshape existing
  public fields (`paneOverlays` stays `[String]?`).

## Development Approach
- **testing approach**: Regular (code first, then tests in the same task)
- complete each task fully before moving to the next
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
- **CRITICAL: all tests must pass before starting next task**
- **CRITICAL: update this plan file when scope changes during implementation**
- run only the tests for what changed during a task (`swift test --filter`, `-only-testing:`); run each full gate
  once, in the verification task
- Swift work starts with the `swiftui-expert`, `swift-testing-expert` and `swift-concurrency` skills as relevant

## Testing Strategy
- **unit tests** (`agtermCore`, Swift Testing): model, store, projection, dispatcher, CLI parsing and help
- **hosted app tests** (`agtermTests`): cover-site predicates, ⌘W ladder, palette and menu enablement, title bar
- **UI tests** (`agtermUITests`): one targeted end-to-end per overlay kind (program, HTML, pane) driven over the
  control socket, run with `-only-testing:`

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix

## Solution Overview
- **One hidden bit per slot**: session-wide slot, left pane slot, right pane slot. Only program and HTML occupants
  are eligible; HUD, ask dialogs and origin-only remote reservations are not.
- **Occupancy stays as is.** Existing predicates keep their meaning so lifecycle, `overlay.result`, `--block`,
  page lookup, tree enumeration and remote slot exclusion are unaffected by hiding.
- **A visible-coverage layer is added** (session cover visible, full cover visible, pane cover visible) and every
  site that asks "does a cover own this session's input/pixels now" moves to it, site by site, never by folding
  the bit into an occupancy predicate.
- **The panel stays mounted.** Hiding sets opacity 0, disables hit testing, drops first responder and marks the
  host off-screen; it never tears down or reparents the Ghostty surface or the web view, and the HTML vs terminal
  host choice keeps reading occupant type.
- **Session-scoped toggle**: if any eligible overlay in the session is not hidden (even one behind another
  cover), hide all of them; otherwise show all of them. Showing keeps contents and size; the selected pane does
  not change.
- **Lifecycle**: the bit ends when the slot closes or is replaced; a `--wait` overlay keeps it after its program
  exits until it is closed. A new occupant starts visible. Opening into a hidden slot is refused with
  `overlay hidden`. text/copy/result/navigate/reload/submit work while hidden and never auto-show.
- **Remote**: a replica on the viewing Mac can be hidden there. Session-scoped calls act on eligible LOCAL slots
  and skip origin-only reservations; an explicitly addressed remote pane, or a session whose only overlay is a
  remote reservation, is refused.
- **⌘W** skips hidden slots, keeping the scratch and visible pane-cover rungs in their order. When the opt-in close
  confirmation is shown, it says hidden overlays close with the session.

## Technical Details
- `Session.overlayHidden` for the session-wide slot; `PaneOverlay.hidden` for pane slots, so the bit travels with
  the occupant on promotion and swap. Cleared on removal or replacement of the occupant (`openOverlay`,
  `closeOverlay`, `closePaneOverlay`, `teardownPaneOverlay`, `teardownOverlaySlot`), never on an in-place
  metadata update of the same occupant (`setOverlayReplica`, HTML page updates through `setPaneOverlay`).
- `Session.swift` is at 991 lines: new state is a stored property there, every new computed helper goes in a new
  `Session+OverlayVisibility.swift`; no split of existing code and no lint-limit change.
- Visible predicates, one spelling each, documented in `control-api.md` beside the existing ones.
- `AppStore`: `setOverlaysHidden(_ sessionID:, pane: OverlayPane?, hidden: Bool) -> OverlayVisibilityResult` and
  `toggleOverlaysHidden(_ sessionID:, pane: OverlayPane?) -> OverlayVisibilityResult`; `pane == nil` means every
  eligible local slot of the session. `scheduleTreeChanged()` only on an actual transition.
- Opening into a hidden slot keeps today's public open signatures and adds no case to `PaneOverlayOpenFailure` or
  `HtmlOverlayOpenFailure` (the fork switches over them exhaustively): occupancy already refuses the open, and the
  adapter reads the hidden bit first to answer `overlay hidden`. This covers program, pane, HTML, remote-open
  (`ControlServer+OverlayJobs.swift`) and HUD open (`ControlServer+Hud.swift`) over a hidden occupant; a HUD over
  a hidden program stays refused, with the clearer message.
- Several touched files sit near the 1000-line limit (`Session.swift` 991, `AppActions.swift` 983, `AppStore.swift`
  978, `ControlDispatcher.swift` 974, `SettingsView.swift` 972, `agtermApp.swift` 952,
  `ControlServer+SessionActions.swift` 935). New code goes to new extension files:
  `Session+OverlayVisibility.swift`, `AppStore+OverlayVisibility.swift`, `ControlServer+OverlayVisibility.swift`,
  `AppActions+Overlay.swift`; edits to the listed files stay a few lines, protocol godoc one line.
- Control: `session.overlay.hide`, `session.overlay.show`, `session.overlay.toggle`, each with optional
  `--pane left|right`; without `--pane` they act on every slot of the target session. Help text: "Hide/Show
  overlays in the target session; --pane limits this to one pane's overlay." Toggle help states the hide-first
  rule.
- Read-back: `ControlSessionNode.hiddenOverlays: [String]?` listing `session`, `left`, `right` in that order,
  omitted when none; `ControlHtmlOverlayNode.hidden: Bool?` omitted when false. New initializer arguments default
  to nil, existing public initializer overloads are kept, `ControlHtmlOverlayNode`'s explicit CodingKeys and
  decoder learn the key, and payloads without the keys still decode. `overlay`, `overlaySizePercent` and
  `paneOverlays` stay occupancy.
- Keymap: built-in `toggle_overlay`, default ⌘⇧J, in the View menu and the command palette. Enablement has one
  owner, `PaletteCommand.isEnabled(in:)`, through a new `PaletteContext` term added as a defaulted init parameter
  so the fork still builds; menu and monitor paths read it. `CustomCommandRunner` intercepts the chord while a
  page holds focus, as it does for `close_session`. Check ⌘⇧J against Ghostty's default bindings and the
  conflict rule in `keymap.md` before settling it.
- Title bar: `InterfaceElement.overlayToggle`, hidden by default, in the title-bar group next to scratch and split
  (group set in `titlebarGroupDividers`). When enabled it is always visible, disabled when the session has no
  eligible overlay, highlighted when any is hidden; tooltip and accessibility label `Hide Overlays` /
  `Show Overlays` by the action a press would take.
- Settings > Interface is exactly full at 540x680 and a 13th title-bar toggle adds a row. Decision: fold the
  one-toggle "Multiple Windows" section into the "Sidebar" section (it is a sidebar setting), which frees a
  section header; the tab must pass a fit assertion in `SettingsUITests` like `assertGeneralTabFits`. If it
  still overflows, the next option is a three-per-row title-bar section; never a taller window without asking.
- Human tree output (`SocketClient.swift`) tags a hidden overlay `(overlay hidden)`, as it does `(split hidden)`.

## What Goes Where
- **Implementation Steps**: code, tests and docs in this repository.
- **Post-Completion**: manual checks in an isolated Debug instance.

## Implementation Steps

### Task 1: Core model, store operations and read-back

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Session.swift` (stored state only), `Session+HtmlOverlay.swift`
- Create: `agtermCore/Sources/agtermCore/Session+OverlayVisibility.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+Panes.swift`, `AppStore+HtmlOverlay.swift`,
  `AppStore+RemoteOverlay.swift`, `AppStore.swift`, `ControlProjection.swift`, `ControlProtocolCompatibility.swift`
- Create: `agtermCore/Sources/agtermCore/AppStore+OverlayVisibility.swift`
- Modify tests: `SessionTests.swift`, `AppStorePaneTests.swift`, `AppStorePaneSwapTests.swift`,
  `HtmlOverlayTests.swift`, `AppStoreTreeProjectionTests.swift`, `AppStoreRemoteOverlayTests.swift`,
  `SnapshotRoundTripTests.swift`; new tests for the store operations in `AppStoreOverlayVisibilityTests.swift`

- [x] hidden state: `Session.overlayHidden` and `PaneOverlay.hidden`, eligible only for program and HTML
      occupants; cleared on removal or replacement, kept across in-place metadata updates (replica, HTML page),
      pane promotion and swap, and a `--wait` exit
- [x] visible-coverage predicates in `Session+OverlayVisibility.swift`, occupancy predicates unchanged
- [x] store `setOverlaysHidden` / `toggleOverlaysHidden` with optional pane scope and the hide-first rule;
      session scope acts on eligible local slots and skips origin-only reservations; refusals for no eligible
      overlay and an explicitly addressed remote pane; existing open paths still refuse an occupied hidden slot
- [x] `tree.changed` scheduled only on an actual transition
- [x] tree read-back: `hiddenOverlays` on the session node, `hidden` on HTML overlay nodes, both omitted when
      empty, decoder accepts payloads without them
- [x] tests: visible-predicate truth table per occupant and slot, transitions, idempotent hide/show, mixed-state toggle, eligibility (HUD, ask, remote, mixed local and
      remote panes), clearing on replace/close, survival across metadata update, promotion, swap and `--wait`
      exit, occupied-slot open refusal, projection, old-payload decode and round trip, tree.changed count
- [x] `cd agtermCore && swift test --filter` for the touched suites passes

### Task 2: Control API and CLI

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`, `ControlDispatcher.swift`,
  `ControlDispatcher+Overlay.swift`, `ControlActionsDefaults.swift`
- Create: `agterm/Control/ControlServer+OverlayVisibility.swift` (hide/show/toggle adapter)
- Modify: `agterm/Control/ControlServer+SessionActions.swift`, `ControlServer+OverlayJobs.swift`,
  `ControlServer+Hud.swift` (open refusals answer `overlay hidden`; a few lines each)
- Modify: `agtermCore/Sources/agtermctlKit/SessionCommands.swift`, `SocketClient.swift` (`(overlay hidden)` tag)
- Modify tests: `ControlDispatcherOverlayTests.swift`, `ControlProtocolTests.swift`, `MockControlActions.swift`,
  `OverlayCommandsTests.swift`, `CommandsTests.swift`, `SocketClientTests.swift`,
  `agtermTests/ControlServerSessionActionsTests.swift`, `ControlServerOverlayJobsTests.swift`

- [x] `session.overlay.hide|show|toggle` in the catalog with optional `pane`, dispatched through `ControlActions`
      to the store; app adapter returns the store result
- [x] `agtermctl session overlay hide|show|toggle [--pane left|right]` with help stating session scope and, for
      toggle, the hide-first rule
- [x] responses report the resulting scoped state (`hidden` or `shown`); refusals use stable error strings; opening into a hidden slot
      (session and pane, local and remote-open paths) answers `overlay hidden`
- [x] human tree output tags a hidden overlay `(overlay hidden)`
- [x] tests: dispatch per command and pane, refusals, CLI parsing and help text, adapter round trip, hidden-open
      refusal messages (program, pane, HTML, remote open, HUD), human tree tag
- [x] targeted core and hosted tests pass

### Task 3: Rendering, focus and cover-site migration

**Files:**
- Modify: `agterm/Views/WindowContentView+Detail.swift`, `agterm/Views/WindowContentView.swift` (keep
  `openOverlaySessionIDs` on occupancy: hiding is not closing), `agterm/AppActions.swift`,
  `agterm/AppActions+Focus.swift`, `agterm/agtermApp.swift`, `agtermCore/Sources/agtermCore/DashboardCover.swift`,
  `TerminalZoom.swift`, `PaneBackgrounds.swift`, `Session.swift` (existing `topmostSurface`, `onScreenSurface`
  and focus-target callers), `Session+OverlayVisibility.swift` / `Session+HtmlOverlay.swift` focus and font
  helpers, deck gate and scratch focus sites named in `control-api.md`
- Create: `agterm/AppActions+Overlay.swift` (shared close-confirm text, later the toggle action; `AppActions.swift` is at 983 lines)
- Modify: `agterm/AppActions+Batch.swift` (batch close prompt mentions hidden overlays)
- Modify tests: `agtermTests/SplitToggleCoverTests.swift`, `HudDeckGatesTests.swift`,
  `GhosttySurfaceViewInputTests.swift`, `agtermCore/Tests/agtermCoreTests/TerminalZoomTests.swift`,
  `DashboardCoverTests.swift`, `PaneBackgroundsTests.swift`
- Modify UI tests: `agtermUITests/ControlHtmlOverlayUITests.swift`, `ControlOverlaySplitUITests.swift`

- [x] hidden panel: same host, ids and geometry; opacity 0, no hit testing, no first responder, off-screen for
      drops; HTML vs terminal host choice still by occupant type
- [x] every cover site from `control-api.md`, plus `fullOverlayActive` pane hiding, `deckPane`,
      `focusedOverlayPane`, focus target, zoom pane arms, dashboard cover, HTML font routing and
      `backdropWashRegions` (a hidden colored pane overlay must not tint a visible floating cover's backdrop),
      moved to the visible predicates; lifecycle and read sites stay on occupancy
- [x] show refocuses the shown cover in the selected pane without selecting the sibling; hide refocuses the pane
- [x] ⌘W ladder skips hidden slots; the opt-in close confirmation and the batch close prompt mention hidden
      overlays in any slot
- [x] a program overlay hidden before its surface realizes still realizes (off-screen host, `deckOnScreen`)
- [x] tests: predicate-site behavior with hidden covers, zoom, scratch, backdrop wash with a hidden colored pane
      overlay, ⌘W ladder and confirm text; targeted UI tests that hide and show a program overlay, an HTML page
      and a pane overlay, then use REAL keyboard input and a click in the uncovered pane while hidden and real
      input into the restored overlay after show (socket `session.type` writes under a visible overlay, so it
      proves nothing here), and check the same surface/page identity; unrealized-then-hidden case (model
      side; creation needs only a backing size, which a hidden host keeps). Drop routing rides the existing
      `visible`/`deckVisible` gates, now false for a hidden host; no new UI check
- [x] `cd agtermCore && swift test --filter` for the touched core suites, targeted hosted and UI tests pass

### Task 4: Keymap action, menu, palette and title-bar icon

**Files:**
- Modify: `agtermCore/Sources/agtermCore/BuiltinAction.swift`, `PaletteCatalog.swift`, `AppSettings.swift`
- Modify: `agterm/agtermApp+Menus.swift` (View menu), `agterm/AppActions+Palette.swift`,
  `agterm/Commands/CustomCommandRunner.swift`, `agterm/Views/WindowContentView+Titlebar.swift`,
  `agterm/Views/SettingsView.swift` (Interface tab layout)
- Modify: `agterm/Views/HtmlOverlayView.swift`, `agtermCore/Sources/agtermCore/AppStore+OverlayVisibility.swift`
- Modify tests: `BuiltinActionTests`, `PaletteCatalogTests`, `AppSettingsTests`, `TitlebarCompositionTests` in
  `agtermCoreTests`; `agtermTests/PaletteTests.swift`, `AppActionsPaletteTests.swift`,
  `CustomCommandRunnerTests.swift`, `WindowContentView+TitlebarTests.swift`; `agtermUITests/KeymapUITests.swift`,
  `SettingsUITests.swift`

- [x] built-in `toggle_overlay` with default ⌘⇧J (checked against Ghostty defaults and `keymap.md`), View menu
      item and palette entry; enablement owned by `PaletteCommand.isEnabled(in:)` through a defaulted
      `PaletteContext` term, read by the menu and monitor paths
- [x] page-focus intercept in `CustomCommandRunner` so the chord works from an HTML overlay
- [x] `InterfaceElement.overlayToggle`, hidden by default; when enabled always visible, disabled without an
      eligible overlay, highlighted when any is hidden, tooltip/accessibility `Hide Overlays` / `Show Overlays`
- [x] Settings > Interface fits: "Multiple Windows" folded into "Sidebar"; fit assertion in `SettingsUITests`
- [x] ➕ (Eugene, mid-run) an HTML page's strip gets a Hide button beside Close: `AppStore.hideHtmlOverlay(_:)`
      finds the page's slot like `closeHtmlOverlay` and hides with the page rule (a pane page its pane, a
      session-wide page the session); a chromeless page has no strip and no button
- [x] tests: default chord and rebinding, enablement on all paths, intercept with a focused page, icon states and
      group divider; targeted keymap and settings UI tests
- [x] targeted core, hosted and UI tests pass

### Task 5: Documentation and bundled agent skill

**Files:**
- Modify: `.claude/rules/control-api.md`, `.claude/rules/keymap.md`, `.claude/rules/settings.md`
- Modify: `site/docs.html`, `site/commands.html`, `site/index.html` if the feature list warrants it
- Modify: `plugins/agterm/skills/agterm/SKILL.md`, `reference.md`
- Modify: `README.md` only if it lists overlay controls

- [x] `control-api.md` owns the hidden-state contract once: occupancy vs visible predicates and which sites read
      which, lifecycle, remote rule, scope of the commands
- [x] user guide and command reference document the toggle, icon, shortcut, commands and read-back fields
- [x] skill: SKILL.md `description` trigger within its 1024-character cap (`SkillInstallTests`), by replacing
      "run overlay programs and read their exit status" with "run, hide or show overlays; read exit status";
      `when_to_use` and a body section ("hide the overlay to talk to me, then show it"); reference entries with
      the session scope and hide-first rule; a page's own hide/show/toggle defaults to its own pane, a
      session-wide page's to the session, and an explicit target lifts the pane default
- [x] `swift test --filter SkillInstallTests` passes, with expectations for the new commands
- [x] `keymap.md` and `settings.md` list the new built-in and interface element

### Task 6: Verify acceptance criteria
- [x] every Overview and Solution Overview item implemented
- [x] `make build` (Release) succeeds
- [x] `make lint` clean
- [x] `cd agtermCore && swift test` passes
- [x] `make test-app` passes
- [x] `lsappinfo list | grep -A4 agterm.debug` shows no leaked test instance

### Task 7: [Final] Update documentation
- [x] CLAUDE.md interface-control line committed with this branch
- [x] move this plan to `docs/plans/completed/`

## Post-Completion
*Manual checks in an isolated Debug instance (short `/tmp` state dir, own socket)*

- open an HTML overlay and a program overlay, hide with ⌘⇧J, type in the pane, show again: contents, size and
  scroll position intact
- split session with a pane overlay and a session overlay: one press hides both, next press shows both, selected
  pane unchanged
- `--wait` overlay: program exits while hidden, overlay stays hidden until closed
- title-bar icon enabled: visible and disabled with no overlay, highlighted while hidden, tooltip follows the action

Smells pre-check: skipped — non-Go project
