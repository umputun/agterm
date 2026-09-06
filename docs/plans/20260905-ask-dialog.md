# Ask dialog: control-driven modal question

## Overview

A caller (agent hook, script, recipe) needs to put a question to the user and learn which button was
pressed. Today the control API offers a searchable list (`pick`), one-way panels (`session.hud.*`,
`notify`), and a full program surface (`session.overlay.*`). None returns a chosen button, and a two-row
`pick` shows a search field and a list where a dialog is wanted.

`ask` adds a theme-styled, terminal-looking modal dialog: a title, an optional message, and one to six
caller-named buttons. It resolves with the pressed button's id, label, and caller index, or `escaped`
or `cancelled`.
The command family, blocking CLI, result retention, and tree read-back copy `pick` one to one.

## Context (from discovery)

- `pick` family is the template: `agtermCore/Sources/agtermCore/{Pick,ControlPick}.swift`,
  `ControlDispatcher+Pick.swift`, `agterm/Control/ControlServer+Pick.swift`,
  `agtermctlKit/MiscCommands.swift` (`Pick` command, poll loop, `abandon`), `SocketClient.pickExitCode`.
- Modal gates that read the pending picker today: `AppActions+Focus.swift` `pickActive`,
  `GhosttySurfaceView.pickOwnsFocus`, `WindowContentView.swift` auto-follow suppression and frontmost
  handling (`pick.pending`), `agtermApp.swift:482,729,736` (search cleanup, quick terminal summon),
  `AppActions.swift` `cancelPendingPick`/`cancelAllPendingPicks` (⌘W, termination), tree
  `pickPending` in `ControlServer.swift:747` and `ControlProjection.swift`.
- Pane anchoring exists for the HUD, but inside one session's own layer: `HudPaneAnchors` is published
  and consumed within `sessionDetail` (`WindowContentView+Detail.swift`), and the cached
  `Session.hudPaneFrames` is observation-ignored and stale for hidden panes. Neither can feed a window-level
  host, hence the dedicated preference in Technical Details. `ControlServer+Hud.swift`
  `resolveHudPlacement` resolves `--pane`/pane id against a session with `requireVisible` and is reused.
- Theme colors for SwiftUI views come from `GhosttyApp.shared.terminalBackgroundColor` /
  `terminalForegroundColor` (used by the sidebar, rename field, watermark); font family and size from
  `settingsModel.settings`. The HUD is a terminal helper program (`hud.sh`), not a SwiftUI view, so its
  transport is not reused; only its look is.
- Keyboard capture pattern for a SwiftUI modal without a text field: `DashboardKeyCatcher`
  (`NSViewRepresentable` owning first responder) in `agterm/Views/DashboardView.swift`.
- Docs surfaces: `.claude/rules/control-api.md`, `site/commands.html`, `site/docs.html`,
  `plugins/agterm/skills/agterm/{SKILL,reference,examples}.md`, `.claude/rules/menu-actions.md` (modal
  cover list).
- No command count is stated on any surface, and stays that way.

## Development Approach

- **testing approach**: Regular (code first, then tests in the same task)
- one task at a time; every task ends with its tests green before the next starts
- gates run once at the end: `cd agtermCore && swift test`, `make test-app`, `make lint`; targeted
  runs during work (`-only-testing:agtermUITests/ControlAskUITests`)
- host-free logic (model, validation, result shaping, CLI parsing) lives in `agtermCore`; the app target
  resolves windows, sessions, geometry, and draws
- update this plan when scope changes

## Testing Strategy

- **unit tests** (Swift Testing, `agtermCore/Tests`): model and controller, protocol round trip,
  dispatcher validation, projection, CLI parsing and exit codes. One test file per source file.
- **hosted UI tests** (`agtermUITests/ControlAskUITests.swift`, XCTest on `ControlAPITestCase`):
  render, click, keyboard, dismissal semantics, tree read-back, shared modal slot, pane anchoring. Keep
  the count small; each hosted test costs seconds.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix

## Solution Overview

Decisions settled in design review (Eugene, with codex as second reader):

- **Modality: window-wide, like pick.** One shared pending slot per window for ask and pick; a second
  open of either is rejected. Every focus, zoom, auto-follow, search-cleanup, and quick-terminal gate
  that reads "is a picker pending" reads "is a modal pending" instead.
- **Placement: session-wide by default.** With a session target the dialog draws over that session's
  whole area, both halves of a split; `--pane left|right` narrows it to one half. With no session it
  centers over the terminal area, right of the sidebar and below the titlebar, exactly where the pick
  palette centers (`terminalAreaInset`). A supplied session or pane that is missing or not visible rejects the open;
  `--pane` without a session is rejected.
- **Anchor identity is captured at open**; its geometry follows resizes. The anchor is lost, and the ask
  resolves `cancelled`, when the anchored session is closed or deselected in its window, or when an
  anchored pane stops being rendered (`Session.rendersPane` false, or its pane identity gone). A
  session-wide anchor survives a split collapse, and a pane anchor survives while that pane stays on
  screen, maximized included. The dialog never relocates.
- **Zoom and dashboard**: an anchored open while terminal zoom or the dashboard covers the owning window
  is rejected with `session not visible`, since the deck under them is not on screen. An unanchored ask
  draws at terminal-area center above zoom and dashboard, exactly as pick does. Opening zoom, dashboard, quick
  terminal, or search while an ask is pending is refused by the shared modal gates.
- **Rendering has two styles**, selected by `style` (`terminal` default, `gui`), identical in every
  behavior. `terminal` is drawn over the pane in the theme's background and foreground with the terminal
  font: every button is a padded monospace label on a dim fill (foreground at low opacity),
  the active one solid foreground with background-colored text, hotkeys underlined. `gui` reuses the
  picker's material panel, corner radius and appearance handling with system fonts: headline title,
  secondary message, native push buttons in a trailing row, the current highlight prominent in the accent color,
  the destructive one tinted red and prominent red when highlighted, no hard-coded colors. Clicking outside the panel does nothing in either.
  `style` is decoration, so it has no read-back; an unknown value is rejected.
- Buttons in a row share the widest button's width. In a column they share its width, with long labels
  wrapping within it, in both styles.
- **Button block alignment** is `align` (`left`, `center`, `right`; default `right`), CLI `--align`, in
  both styles. It places the whole button block within the panel; the vertical fallback aligns its column
  the same way. Decoration like `style`: no read-back, unknown value rejected.
- **Panel width** is automatic in both styles: natural content width capped at 90 percent of the anchor
  and 72 cells. Optional `width`, CLI `--width N`, replaces that rule with a fixed integer percentage of
  the anchor from 10 to 100. Invalid values return `width must be 10 to 100`. It is decoration, with no
  read-back, and is carried on `PendingAsk`.
- **Dismissal is two kinds.** User dismissal (Esc, ⌘W) returns `escaped`, CLI exit 3. Administrative
  cancellation (`ask.cancel`, window teardown, app termination, CLI abandon, anchor loss) returns
  `cancelled`, exit 2. Neither synthesizes a button, and there is no cancel button role: a caller's
  "Cancel" button is an ordinary button answered by id. ⌘W dismisses the ask for consistency with pick.
- **Keyboard contract**: exactly one button is highlighted at every moment and Return activates it.
  `default` names the initial highlight; without it the first button that is not `destructive` is
  highlighted, or the first button when it is the only one. Tab, Right, Down move forward; Shift-Tab,
  Left, Up move back; movement wraps. A hotkey activates its button directly. A `destructive` button is
  reachable by navigation and hotkey but may not be `default`; that is a validation error, never
  silently ignored. The active button is visibly distinct from the others in both styles.
- **Result shape** copies pick: `{"result":"answered","id":"yes","label":"Yes","index":0}`,
  `{"result":"escaped"}` or `{"result":"cancelled"}`; `index` is the caller's button order regardless
  of vertical layout.
  `ask.result` over the socket also reports `pending`; the blocking CLI prints only the terminal answer.
- **Tree** exposes `askPending` (the id) on the window node next to `pickPending`.
- **Naming**: `ask.open` / `ask.result` / `ask.cancel`; CLI `agtermctl ask`.

Rejected alternatives: `NSAlert` sheet (not theme-styled, ugly past three buttons); folding buttons into
`pick.open` (muddles a contract of 1..1000 searchable rows); session-scoped modality that leaves the other
pane usable (needs a pending indicator, hidden-focus rules, and move/close rules; can come later if a real
caller needs it); a rename of `PickController`/`PickRegistry` to a modal-neutral name (mechanical churn
across ten files for no behavior; the shared-slot predicate is named `modalPending` instead).

## Technical Details

### Protocol (`ControlProtocol.swift`)

- `Command`: `askOpen = "ask.open"`, `askResult = "ask.result"`, `askCancel = "ask.cancel"`.
- `ControlArgs` additions: `buttons: [ControlAskButton]?`, `defaultButton: String?`,
  `destructiveButton: String?`, `style: String?`, `align: String?`. Reused: `title` (notify's field), `message`
  (dialog body), `pane`, `paneID`, `window`, `follow`. `target` is the session for `ask.open` (optional)
  and the ask id for `ask.result`/`ask.cancel`. `ControlArgs` is synthesized `Codable` with no coding
  keys, so the additions are plain optional fields.
- `ControlResult.ask: ControlAskResult?`; `ask.open` answers `ControlResult(id:)` like pick, plus
  `result.pane` when a pane anchor was resolved: `--pane` changes where the dialog lands, and
  control-api.md requires a read-back for such a field, as `session.restore` does.
- `ControlAskButton { id, label, hotkey: String? }`, `ControlAskOutcome { pending, answered, escaped,
  cancelled }`, `ControlAskResult { result, id?, label?, index? }`, `ControlAskStyle { terminal, gui }`,
  `ControlAskAlignment { left, center, right }``
  in `ControlAsk.swift`.

### Validation (`ControlDispatcher+Ask.swift`, host-free)

- `ControlAskPlacement` carries parsed `pane` and unresolved `paneID` together in the host action.
- `title` required and non-blank; `title`, `message`, and every label free of control characters.
- 1...6 buttons (`ControlAskButton.maxButtons = 6`), unique ids, non-empty labels.
- `default` and `destructive` must each name an existing button; `default == destructive` is rejected
  with an explicit message.
- `style`, when present, is `terminal` or `gui`; anything else is `unknown style`.
- `hotkey` is one ASCII letter, stored lowercased, unique across buttons. Return, Tab, Esc, arrows,
  digits and punctuation are rejected so a hotkey can never collide with navigation or dismissal. A key
  event carrying Command, Control, or Option never activates a hotkey.
- `pane` parses through `parsePane` with `OverlayPane`; `pane` or `paneID` without a session target is
  rejected (`--pane requires a session`).
- `ask.result`/`ask.cancel` require a target id.
- Errors keep pick's phrasing: `ask.open requires a title`, `ask.open requires buttons`,
  `too many buttons (max 6)`, `ask button ids must be unique`, `unknown default button: X`, and so on.

### Model (`Ask.swift`, agtermCore)

- `PendingAsk { id, title, message?, buttons, defaultID?, destructiveID?, style, align, width?, anchor: AskAnchor? }`
  with `AskAnchor { sessionID: UUID, pane: OverlayPane?, paneIdentity: UUID? }`.
- `PickController` gains `pendingAsk: PendingAsk?`, `recentAskResults: [ResolvedAsk]`,
  `openAsk(_:) -> Bool`, `resolveAsk(_:)`, `cancelAsk()`, `askResult(for:)`, and the shared predicate
  `modalPending: Bool` (`pending != nil || pendingAsk != nil`). `open`/`openAsk` both refuse while
  `modalPending`. Each family retains its own history using pick's existing 8/32 caps, so ask traffic
  does not evict unread pick answers. The resolution sequence is shared with pick.
- `PickRegistry.unregister` cancels the pending ask and retains its results; `liveAsk(for:)` and
  `retainedAskResult(for:)` mirror the pick lookups.
- `AskNavigation` (host-free, in `Ask.swift`) holds the highlight state machine: `highlighted: Int?`
  seeded from `defaultID`, otherwise the first non-destructive button or first available button.
  `moveForward()` and `moveBackward()` wrap; `activate() -> Int?` is nil only for an empty list, `hotkey(_ letter:) -> Int?`. The app-side key
  catcher only maps key events onto these calls, so the whole keyboard contract is unit-tested in
  `agtermCore`.

### App host (`ControlServer+Ask.swift`)

- `openAsk`: with a session target, `resolver.resolveSession` finds the store and session, the window
  owning it is the modal owner, the session must be selected in that window (`session not visible`), and
  pane placement resolves through the HUD placement resolver moved to a shared file
  (`resolvePanePlacement(_:paneID:in:requireVisible:invalidPaneError:)`), capturing `paneIdentity`. Terminal zoom or an open
  dashboard in that window rejects an anchored open (`session not visible`). Without a target,
  `resolveOpenPlacementStore(window)` picks the window and the anchor is nil. `follow` raises the window.
- `askResult`/`cancelAsk` copy `pickResult`/`cancelPick` including window-mismatch and retained lookups.
- Tree: `askPending` is a top-level `ControlTree` field beside `pickPending` (`ControlProjection.swift`),
  populated through the same closure path: `AppStore.swift` tree builder (`pickPending:` parameter and
  call), the agterm-linux shim `ControlProtocolCompatibility.swift`, and the server closure in
  `ControlServer.swift`. Nil is omitted from JSON like `pickPending`.

### Modal gates

Every site that reads the pending pick switches to `modalPending`. The grep
`pick\.pending|PickRegistry\.shared|pickerActive|pickActive` over `agterm` and `agtermCore/Sources` finds
about 48 hits in 20 files, and the task is complete only when that grep shows no `pending != nil` read
left outside the pick host itself. Sites by kind:

- host-free: `PaletteCatalog.swift` `PaletteContext.pickerActive`, the input to `modalActive`, which
  `menu-actions.md` names as the single owner of menu enablement (rename to `modalPickerActive` or feed it
  from `modalPending`; `PaletteCatalogTests` covers it)
- menus and actions: `agtermApp+Menus.swift:68,330`, `AppActions.swift:48` (`uiActionsEnabled`),
  `AppActions+Focus.pickActive`, `agtermApp.swift:482,729,736`
- views: `GhosttySurfaceView.pickOwnsFocus`, `WindowContentView` frontmost/auto-follow handling and
  palette-close-on-open, `WindowContentView+Dashboard.swift:110`, `+Zoom.swift:177`,
  `+Titlebar.swift:192`, `+RecentSessions.swift` (six reads)
- control entry points refusing `pick pending` today: `ControlServer.swift:646` (dashboard),
  `ControlServer+AppCommands.swift:240` (quick terminal), `ControlServer+SurfaceIO.swift:404` (search),
  `ControlServer+SessionActions.swift:699,724` (zoom); their message comes from one
  `PickController.pendingModalError` (`pick pending` or `ask pending`) so the pick message and its tests
  stay unchanged

⌘W and Esc: `escapeAsk()` resolves `escaped`; termination and teardown call `cancelAsk()`.

### View (`agterm/Views/AskDialogView.swift`)

- Colors: `GhosttyApp.shared.terminalBackgroundColor` / `terminalForegroundColor` with the standard
  fallbacks; a one-cell border in the foreground at reduced opacity; font from
  `settingsModel.settings.fontFamily`/`fontSize` (the HUD's `cellSize` lookup).
- Layout: title (bold), message (wrapped), then buttons in one row when the widest layout fits the anchor
  frame minus padding, else one per row; caller order preserved either way. Width is clamped to the anchor.
  Content that exceeds the anchor height scrolls; keyboard navigation brings the selected button into view.
  A button is a filled block with a plain label; the highlighted one is drawn in inverse video (foreground and background
  swapped); the hotkey letter is underlined; the `destructive` button carries a leading `!` marker
  (`! Delete`) and bold weight, since the app has no access to the theme's ANSI red.
  A hotkey absent from its label appears as an underlined parenthesized hint.
- Input: `AskKeyCatcher` (`NSViewRepresentable`, modelled on `DashboardKeyCatcher`) owns first responder
  while mounted and maps Tab/Shift-Tab/arrows/Return/Esc/letters onto `AskNavigation` calls, dropping any
  event with Command, Control, or Option; mouse click on a button activates it; the scrim consumes clicks
  and does nothing.
- Placement: mounted beside `pickPaletteOverlay` at the top of `WindowContentView`'s stack (zIndex 20),
  not inside `windowOverlayLayer`, which is absent while zoomed. Geometry is live, not the HUD cache:
  `Session.hudPaneFrames` is observation-ignored, merges only non-nil frames, and keeps stale frames for
  hidden panes and deselected sessions, so it can neither drive resize nor prove visibility. Only the
  SELECTED session's detail (`isActive`) publishes an `AskAnchorPreferenceKey` with the session container
  bounds and each rendered pane's bounds, so the preference `reduce` never merges frames from the other
  deck sessions the `ForEach` keeps mounted at opacity zero; the ask host resolves the anchors in its own
  coordinate space (sidebar and titlebar offsets included). Session-wide uses the container bounds, `--pane` the named pane's bounds, no anchor
  the terminal area center below the titlebar and right of the sidebar. Validity is derived from state, not from the preference:
  `store.selectedSessionID == anchor.sessionID`, and for a pane anchor the captured pane IDENTITY is
  resolved to its CURRENT role first (`Session.askTargetPane`, the same identity-to-role lookup as
  `hudTargetPane`), then `session.rendersPane(role)`; a nil role or a false `rendersPane` cancels. Both
  geometry and validity use that resolved role, never the pane name given at open: when the primary
  shell exits, `closePrimaryPane` promotes the right survivor and its identity to `left`, so a
  right-anchored ask follows its pane into the left slot. Following one identity through a role change
  is geometry movement, allowed; only a different anchor would be relocation, which never happens.
- Accessibility ids: `ask-dialog`, `ask-title`, `ask-message`, `ask-button-<id>`.

### CLI (`agtermctlKit/AskCommands.swift`, `Ask` command)

```
agtermctl ask TITLE [--message TEXT] --button ID=LABEL [--button ...] [--hotkey ID=K ...]
             [--default ID] [--destructive ID] [--style terminal|gui]
             [--target SESSION] [--pane left|right] [--pane-id TOKEN] [--window W] [--follow] [--no-block]
agtermctl ask result ID
agtermctl ask cancel ID
```

- `--button ID=LABEL` splits on the first `=`; a missing `=` uses the token as both. `--hotkey ID=K`
  attaches a hotkey to a declared button.
- `--target` is `ask`'s own optional option, not `TargetOptions`, whose default of `active` would turn
  every no-target call into an anchored one and break terminal-area placement.
- `--pane-id` exposes the existing stable-token wire field, with the same target requirement as `--pane`.
- `Ask.self` is registered in `Agtermctl.configuration.subcommands` (`agtermctlKit/Commands.swift`).
- Default subcommand is open. Blocking poll, delays, abandon-on-transport-failure, and exit codes (0
  answered, 3 escaped, 2 cancelled, 1 failure) reuse the pick helpers, generalized to take the outcome kind.
- `--no-block` prints `{"id":...}`. The one-shot `ask result ID` prints whatever the socket reports,
  `pending` included, and exits 1 for pending like `pick result`.

### Events

No events: pick emits none either. Recorded here as the deliberate exemption from the
event-arguments rule.

## Implementation Steps

### Task 1: Wire types and protocol round trip

**Files:**
- Create: `agtermCore/Sources/agtermCore/ControlAsk.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift` (nil fallthrough until Task 3)
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`

- [x] add `ControlAskButton`, `ControlAskOutcome`, `ControlAskResult`, `ResolvedAsk` (with sequence)
- [x] add the three `Command` cases and the `ControlArgs`/`ControlResult` fields
- [x] extend `ControlArgs`/`ControlResult` initializers
- [x] round-trip tests for `ask.open` with every argument, `ask.result`, `ask.cancel`
- [x] round-trip tests for every `ControlAskResult` shape (pending, answered, cancelled)
- [x] run `swift test --filter ControlProtocolTests` (196 tests passed)

### Task 2: Pending ask model on the shared modal slot

**Files:**
- Create: `agtermCore/Sources/agtermCore/Ask.swift`
- Modify: `agtermCore/Sources/agtermCore/Pick.swift`
- Create: `agtermCore/Tests/agtermCoreTests/AskTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/PickTests.swift`

- [x] add `PendingAsk` and `AskAnchor`
- [x] add `pendingAsk`, `recentAskResults`, `openAsk`, `resolveAsk`, `cancelAsk`, `askResult(for:)`, and
      `modalPending` to `PickController`; `open` and `openAsk` refuse while `modalPending`
- [x] `PickRegistry`: cancel and retain asks on `unregister`; add `liveAsk(for:)`, `retainedAskResult(for:)`
- [x] `AskNavigation` state machine (seeded highlight, forward/backward with first/last entry and wrap,
      inert activate with no highlight, hotkey lookup)
- [x] tests: open/resolve/retain, cancel, result-by-id, retention cap, registry retention across unregister
- [x] tests: ask refuses while a pick is pending and pick refuses while an ask is pending
- [x] tests: the whole keyboard contract on `AskNavigation`, with and without `default`, one and six
      buttons, hotkey case folding
- [x] run `swift test --filter 'agtermCoreTests\.(AskTests|PickTests)/'` (35 tests passed)

### Task 3: Host-free validation and dispatch

**Files:**
- Create: `agtermCore/Sources/agtermCore/ControlDispatcher+Ask.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift` (`ControlActions` + routing)
- Modify: `agtermCore/Sources/agtermCore/ControlActionsDefaults.swift` (unsupported-host defaults)
- Modify: `agtermCore/Tests/agtermCoreTests/MockControlActions.swift`
- Create: `agtermCore/Tests/agtermCoreTests/ControlDispatcherAskTests.swift`

- [x] add `openAsk`, `askResult`, `cancelAsk` to `ControlActions`; route the three commands
- [x] implement every validation rule from Technical Details with pick-style messages
- [x] mock records the calls
- [x] table-driven tests: each rejection (title, buttons count, ids, labels, control chars, unknown role
      ids, default==destructive, cancel==destructive, hotkey length and collision, pane without session,
      invalid pane, missing result/cancel target)
- [x] tests: a valid open reaches the mock with the parsed `PendingAsk` fields intact
- [x] run `swift test --filter 'agtermCoreTests\.ControlDispatcher(Ask|Pick|Hud)Tests/'` (51 tests passed)

### Task 4: App-side host and tree read-back

**Files:**
- Create: `agterm/Control/ControlServer+Ask.swift`
- Create: `agterm/Control/ControlServer+PanePlacement.swift`
- Create: `agtermTests/ControlServerAskTests.swift`
- Modify: `agterm/Control/ControlServer+Hud.swift` (move `resolveHudPlacement` to a shared pane
  placement resolver)
- Modify: `agterm/Control/ControlServer.swift` (tree `askPending` closure)
- Modify: `agtermCore/Sources/agtermCore/ControlProjection.swift`, `AppStore.swift` (tree builder
  parameter and call), `ControlProtocolCompatibility.swift` (agterm-linux shim)
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift` (`result.pane` documentation)
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreTreeProjectionTests.swift`,
  `ControlProtocolTests.swift`

- [x] `openAsk` resolves the session or placement window, requires a visible session and pane, rejects
      an anchored open while zoom or dashboard covers the window, captures the anchor, opens on the
      window's controller, handles `follow`, closes the palette, returns `result.pane` for a pane anchor
- [x] `askResult` and `cancelAsk` with the pick lookup order (live by id, retained, explicit window)
- [x] add top-level `askPending` through projection, store builder, shim, and server closure
- [x] projection test for `askPending` presence and absence; nil-omission test beside the `pickPending`
      one in `ControlProtocolTests`
- [x] build the app target through the isolated `agtermTests` scheme; 18 hosted tests passed

### Task 5: Shared modal gates and ⌘W/termination paths

**Files:**
- Modify: `agtermCore/Sources/agtermCore/PaletteCatalog.swift`,
  `agtermCore/Tests/agtermCoreTests/PaletteCatalogTests.swift`
- Modify: `agtermCore/Sources/agtermCore/Pick.swift`, `agtermCore/Tests/agtermCoreTests/PickTests.swift`
- Modify: `agtermTests/ControlServerAskTests.swift`
- Modify: `agterm/AppActions+Focus.swift`, `agterm/AppActions.swift`, `agterm/agtermApp.swift`,
  `agterm/AppDelegate.swift`, `agterm/Ghostty/GhosttySurfaceView.swift`
- Modify: `agterm/Views/WindowContentView.swift`, `WindowContentView+Dashboard.swift`,
  `WindowContentView+Zoom.swift`, `WindowContentView+Titlebar.swift`, `WindowContentView+RecentSessions.swift`
- Modify: `agterm/Control/ControlServer.swift`, `ControlServer+AppCommands.swift`,
  `ControlServer+SurfaceIO.swift`, `ControlServer+SessionActions.swift`, `ControlServer+Ask.swift`

- [x] switch every pending-pick predicate to `modalPending`, the five control entry points included,
      with `pendingModalError` supplying the message; finish with the grep from Technical Details showing
      no read left outside the pick host
- [x] `PaletteContext` takes the modal predicate; `modalActive` covers an ask
- [x] `dismissPendingAsk(userInitiated:)` for ⌘W; `cancelAllPendingModals` for termination
- [x] auto-follow suppression and quick-terminal hide pair with the ask exactly as with the pick
- [x] tests: `PaletteCatalogTests` case for `modalActive` under a pending ask
- [x] build the app target and attempt `ControlPickUITests` once; UI verification skipped because the
      runner timed out enabling automation mode before any test methods ran. Core and hosted checks passed.

### Task 6: Dialog view, keyboard, and placement

**Files:**
- Create: `agterm/Views/AskDialogView.swift`
- Create: `agtermTests/AskDialogViewTests.swift` (native keyboard/scrolling and render attachments)
- Modify: `agtermCore/Sources/agtermCore/Session.swift` (`askTargetPane`),
  `agtermCore/Tests/agtermCoreTests/SessionTests.swift`
- Modify: `agterm/Views/WindowContentView.swift` (mount at zIndex 20 beside `pickPaletteOverlay`),
  `agterm/Views/WindowContentView+Detail.swift` (publish `AskAnchorPreferenceKey` from the selected
  session's container and rendered panes)

- [x] panel with theme colors, terminal font, title/message/buttons, horizontal-or-vertical layout
- [x] `AskKeyCatcher` maps key events onto `AskNavigation` (letters without modifiers, Esc, Return, Tab,
      arrows) and nothing else
- [x] mouse activation on buttons; scrim swallows clicks; destructive marker and inverse-video highlight
- [x] live anchor geometry from the preference in the host's coordinate space (session container, one
      pane, or whole-window center); the frame follows resize and sidebar changes
- [x] `Session.askTargetPane` resolves the captured identity to its current role; validity from state
      (selected session, resolved role, `rendersPane`); the host cancels the ask when it fails
- [x] test in `SessionTests`: a right-anchored identity resolves to `left` after `closePrimaryPane`
      promotes the survivor, and to nil once the pane is gone
- [x] accessibility identifiers
- [x] launch isolated Debug with a short explicit socket and fresh-shell state; socket checks passed for
      resize, hidden-pane cancellation, session collapse, deselection, and pane promotion. Stopped its
      exact PID with SIGTERM. Live keyboard/click/screen capture skipped: macOS denied the helper those
      permissions. Native-host keyboard/scrolling tests passed and test-generated renders were inspected.

### Task 7: CLI command

**Files:**
- Create: `agtermCore/Sources/agtermctlKit/AskCommands.swift` (`MiscCommands.swift` is 741 lines and
  the pick family alone is about 200; the package already splits per family)
- Modify: `agtermCore/Sources/agtermctlKit/MiscCommands.swift` (share the poll loop with pick)
- Modify: `agtermCore/Sources/agtermctlKit/Commands.swift` (register `Ask.self`)
- Modify: `agtermCore/Sources/agtermctlKit/SocketClient.swift` (exit code and format helpers)
- Create: `agtermCore/Tests/agtermctlKitTests/AskCommandsTests.swift` (the existing CommandsTests is at its line limit)
- Modify: `agtermCore/Tests/agtermctlKitTests/SocketClientTests.swift`

- [x] `Ask` command with `Open` (default), `Result`, `Cancel`; button and hotkey parsing; its own
      optional `--target`
- [x] register `Ask.self` in the root subcommand list
- [x] blocking poll and abandon reuse the pick loop, generalized over the outcome kind
- [x] tests through `Agtermctl.parseAsRoot`: every option, `ID=LABEL` split, default subcommand, no
      target means no `target` in the request, request shaping
- [x] tests: exit codes and result formatting
- [x] run `swift test --filter agtermctlKitTests` (463 tests passed, using the existing clean scratch path)

### Task 8: Hosted UI tests

**Files:**
- Create: `agtermUITests/ControlAskUITests.swift`
- Modify: `agtermUITests/ControlAPITestCase.swift` (ask helpers next to the pick helpers)

- [x] render, click a button, `askPending` in tree, result id/label/index, dialog dismissed
- [x] keyboard: no default leaves Return inert, Tab then Return answers the first button; hotkey answers
- [x] Esc with a cancel button answers it; Esc without returns `cancelled`
- [x] `ask.open` while a pick is pending is rejected, and the reverse
- [x] `dashboard`, `quick`, `session.search`, and zoom commands are refused while an ask is pending
- [x] `ask.cancel` on a dialog with a named cancel button returns `cancelled`, not the button; closing
      the window while pending returns `cancelled` and the result stays readable afterwards
- [x] `--pane right` on a split session draws within the right pane frame; a hidden session rejects open;
      selecting another session by control while anchored resolves `cancelled`; collapsing the split under
      a session-wide anchor keeps the dialog up
- [x] an unanchored ask opened while zoom is active renders above it; an anchored one is rejected
- [x] run only `ControlAskUITests`: 13 of 14 passed initially; corrected the render test to read macOS
      static text `value`, then that method passed on its targeted rerun. No other UI suite ran.

### Task 9: Documentation

**Files:**
- Modify: `.claude/rules/control-api.md`, `.claude/rules/menu-actions.md`, `site/commands.html`,
  `site/docs.html`, `plugins/agterm/skills/agterm/SKILL.md`, `reference.md`, `examples.md`;
  `ARCHITECTURE.md` does not list control widgets and `cookbook/` stays untouched

- [x] control-api.md: ask section (validation, shared slot, dismissal kinds, anchor rules, events
      exemption) beside pick
- [x] menu-actions.md modal cover list names the pending ask
- [x] commands.html: `ask` section with arguments and read-back; docs.html mention in the control widgets
      list
- [x] skill reference and examples: the command, one hook example (a yes/no before a destructive step)
- [x] no surface states a command count

### ➕ Task 10: Escaped result, filled buttons, and the gui style

Eugene's review of the built dialog changed the contract after Task 9 documented it. This task moves the
code to what the docs already say; the Solution Overview above is the authority.

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlAsk.swift` (`escaped`, `ControlAskStyle`),
  `ControlProtocol.swift` (drop `cancelButton`, add `style` and `align`),
  `Ask.swift` (drop `cancelID`, add `style` and `align`),
  `Pick.swift` (`escapeAsk()`), `ControlDispatcher+Ask.swift` (drop the cancel role, validate `style`)
- Modify: `agtermCore/Sources/agtermctlKit/AskCommands.swift` (drop `--cancel`, add `--style`),
  `SocketClient.swift` (`escaped` exits 3)
- Modify: `agterm/AppActions+Focus.swift` (`dismissPendingAsk` becomes escape, no button lookup),
  `agterm/Views/AskDialogView.swift` (filled buttons, `gui` rendering), `agterm/Views/WindowContentView.swift`
  (Esc resolves `escaped`)
- Modify: every test that named the cancel role: `ControlProtocolTests`, `AskTests`,
  `ControlDispatcherAskTests`, `AskCommandsTests`, `SocketClientTests`, `ControlServerAskTests`,
  `AskDialogViewTests`, `ControlAskUITests`

- [x] `ControlAskOutcome.escaped`; `escapeAsk()` on the controller; Esc and ⌘W resolve it
- [x] remove `cancelButton`/`cancelID`/`--cancel` and the cancel-versus-destructive rule everywhere
- [x] `style` on the wire, validated host-free, carried on `PendingAsk`; CLI `--style`, default `terminal`
- [x] `align` on the wire (`ControlAskAlignment { left, center, right }`), validated host-free, carried
      on `PendingAsk`; CLI `--align`, default `right`; both styles and the vertical fallback honor it
- [x] docs: add `style` and `align` to control-api.md, commands.html, docs.html and the skill reference
      where Task 9 described `style`
- [x] unanchored placement centers over the terminal area: `askAnchorFrame` with no anchor starts at
      `terminalAreaInset`, not x 0, so the sidebar is excluded like the pick palette; UI test asserts
      the dialog's minX is at or right of the sidebar's maxX with the sidebar visible
- [x] long labels never clip: in the vertical fallback a button's label wraps within the panel width
      (the width clamp applies to the text, not only the panel), and the panel never exceeds the anchor;
      hosted render check with a label longer than the anchor is wide
- [x] terminal style: every button on a dim fill (foreground at low opacity), the active one solid
      foreground with background-colored text, filled block and hotkey underline kept
- [x] gui style: picker's `PalettePanelBackground`, corner radius and appearance handling, system font,
      headline title, secondary message, native push buttons in a trailing row, `.borderedProminent`
      highlight, red-tinted destructive; same `AskKeyCatcher` and `AskNavigation`
- [x] CLI exit 3 for `escaped`; `ask result` one-shot maps it the same way
- [x] update unit, hosted and UI tests to the new contract; Esc and ⌘W cases assert `escaped`
- [x] UI tests: `--default` then Return answers the default; Right arrow then Return answers the second
      button; a `--style gui` open renders `ask-dialog` with native buttons and answers by click
- [x] hosted render check of both styles in light and dark appearance
- [x] run `-only-testing:agtermUITests/ControlAskUITests` and the affected core suites
- [x] one button is always highlighted: `AskNavigation` seeds from `default`, else the first
      non-destructive button, else the first; `activate()` never returns nil for a non-empty list; the
      inert-Return unit and UI cases become "Return without default answers the first non-destructive
      button"; the terminal active style must read as active at a glance against the dim fills

### ➕ Task 11: Demo fixes

From Eugene's case-by-case review of the Debug build on 2026-09-05. Terminal style only; the gui
style passed as is.

**Files:**
- Modify: `agterm/Views/AskDialogView.swift`, `agtermTests/AskDialogViewTests.swift`
- Modify: `.claude/rules/control-api.md` and the skill reference only where they state the panel width

- [x] message text is drawn in a muted foreground (foreground at reduced opacity), the title stays full
- [x] the frame border is dimmer than today's 60 percent foreground; pick a value that reads as a
      quiet outline against both light and dark themes
- [x] the panel takes its content's natural width instead of filling the anchor, capped at 90 percent
      of the anchor width and the 72-cell maximum; a short question gets a short panel, a long one
      keeps a margin on both sides; the column fallback and wrapping still apply within the cap
- [x] hosted render checks: short question in a narrow pane, long label in a narrow pane, light and dark
- [x] targeted `AskDialogViewTests` and `-only-testing:agtermUITests/ControlAskUITests`
- [x] terminal buttons drop the `[ ` and ` ]` brackets; the filled block is the button. The destructive
      button keeps its `! ` prefix. Update `buttonLabel`, its tests, the Solution Overview rendering
      bullet, and every doc line that shows a bracketed button; re-run the targeted render and UI checks
- [x] gui uses the same width rule as terminal: the content's natural width, capped at 90 percent of the
      anchor and the same maximum, so a short question gets a compact gui panel too
- [x] `width` on the wire and `--width N` on the CLI, an integer percent of the anchor width from 10 to
      100, in both styles; when given it fixes the panel width instead of the auto rule (still never
      wider than the anchor); absent means auto; out of range is `width must be 10 to 100`.
      CLI non-integers use that message; malformed wire types use the ordinary decode error.
      Decoration like `style` and `align`: carried on `PendingAsk`, no read-back; validated host-free with
      dispatcher tests, CLI parsing tests, a hosted render at 50 percent in both styles, and docs beside
      `align` in control-api.md, commands.html, docs.html and the skill reference
- [x] equal-width buttons within one dialog: in the row layout every button takes the widest button's
      width; in the column layout every button takes the column's width; both styles; a wrapped long
      label still wraps within that shared width; hosted render with "OK" beside "Cancel everything"

### Task 12: Verify acceptance criteria
- [ ] every decision in Solution Overview is implemented and has a test
- [ ] `cd agtermCore && swift test`
- [ ] `make test-app`
- [ ] `make lint` with zero findings
- [ ] Debug instance: manual pass of the keyboard contract and a theme switch while the dialog is up,
      in both styles

### Task 13: [Final] Update documentation
- [ ] CLAUDE.md if a new constraint surfaced during implementation
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification**:
- run the bundled skill's example hook against a Release build installed with `make deploy`
- confirm `agtermctl ask` from inside a session with no `--target` still draws at terminal-area center

Smells pre-check: skipped — non-Go project
