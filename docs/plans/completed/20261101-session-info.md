# Session info line in the sidebar

## Overview

A per-session line of styled text that an outside caller sets over the control API/CLI, drawn under the
session's sidebar row. It is the general slot discussion #713 asked for in a narrower form: agent hooks,
recipes and scripts can show "3 subagents running", a CI state or a deploy step next to the session it
belongs to, with no agent-specific knowledge in the app.

It differs from `session context` on purpose. Context is durable purpose shown in the title bar and kept
across relaunch. Info is current activity: runtime-only, optionally timed, and styled. Like context, it is
mirrored to a viewer attached to a remote session.

## Context (from discovery)

- Uncommitted prototype in this worktree, approved visually by Eugene in an isolated Debug instance:
  - `agtermCore/Sources/agtermCore/SessionInfoMarkup.swift` + `SessionInfoMarkupTests.swift` (8 cases):
    plain or inline Foundation markdown to host-free `SessionInfoSpan`s, `^[text](color: "NAME")` and
    `^[text](dim: true)`, link label kept, unknown color and parse errors rejected, blank, line-break and
    control-character visible text rejected after entity decoding.
  - `agterm/Views/SidebarInfoCell.swift`: `SidebarInfoMetrics`, `SidebarInfoCellView` (one tail-truncated
    line under the name, colored fragments keep color on a selected row, uncolored ones follow
    `themeTextColor(selected:)`, color emoji drawn at 0.7 and centered on cap height, tooltip on truncation).
  - `agterm/Views/SidebarInfoProto.swift`: throwaway sample source behind `AGTERM_PROTO_INFO=1`.
  - `WorkspaceSidebar+RowRendering.swift`: `heightOfRowByItem`, `sessionInfo(forSession:)` shared by height
    and cell, `session-info-cell` identifier, title row centered on a band of plain row height.
  - `SidebarRowViews.swift`: `SidebarCellView` no longer `final`, `themeTextColor(selected:)` extracted.
- `session.context` (plan `docs/plans/completed/20260831-session-context.md`, commit 73b63b71) is the
  surface map to mirror: `ControlProtocol.swift:29`, the `mode: set|clear` body in
  `ControlDispatcher+SessionMetadata.swift`, the requirement in `ControlActions.swift` and its default in
  `ControlActionsDefaults.swift`, `ControlSessionNode` + compatibility initializer in
  `ControlProjection.swift`, `AppStore.setContext` in `AppStore+SessionState.swift` (returns whether the value
  changed, calls `scheduleTreeChanged()`, publishes to `presentationHub`), command list at
  `ControlServer.swift:636`, CLI `SessionMetadataCommands.swift:150`.
- HUD `--hide-after` (#613) is the timer to mirror: `ControlServer+Hud.swift:38` `armHudAutoHide`
  (revision, deadline, cancel through `Session.onHudDiscarded`, which `Session.discardHudBody()` fires from
  every teardown site: `AppStore+Panes.swift:487`, `AppStore+PendingClose.swift:575`, `AppStore.swift:614`
  and `:656`, `WindowAccessor.swift:182`), `HudSpec.isValidHideAfter` (`0...86400`) shared by the CLI
  (`SessionHudCommands.swift:54`) and the dispatcher, `closeTimedHud` at `AppStore+PendingClose.swift:387`,
  contract in `.claude/rules/control-api.md:821-838`. `ControlServerHudAutoHideTests` uses a short real
  expiry and a bounded wait.
- Remote presentation (`control-api.md:1792`) mirrors status, context, notifications and the HUD:
  `PresentationFrames.swift` (`case context(String?)`, `PresentationSnapshot.context`; an unknown frame kind
  decodes to `.unknown`, so older viewers skip a new kind), applied in `RemotePresentationClient.swift:214`.
- `InterfaceElement.hiddenByDefault` (`AppSettings.swift:91`) supports an element hidden until shown; labels
  are sentence case ("Session context"); `settingsOrder(in:)` orders the section.
  `SettingsUITests.testInterfaceTabFitsWithTheOverlaysToggle` (`:359`) is the Interface tab-fit check.
- Line caps (1000 source, 2000 tests) already reached: `ControlProtocolTests.swift` 2000,
  `ControlServer+SessionActions.swift` 1000, `AppStorePaneTests.swift` 1982, `CommandsTests.swift` 2000,
  `WorkspaceSidebar.swift` 979. The tasks below place new code and tests in files with room.

## Development Approach

- **testing approach**: Regular - code first, then its tests in the same task.
- Every task ends with its tests written and passing before the next starts.
- Gates run ONCE at the end (`make build`, `cd agtermCore && swift test`, `make test-app`, `make lint`);
  per-task runs are scoped with `--filter` or `-only-testing:` to what changed.
- A file reaching its line cap is a STOP: ask before splitting it; never raise the limit.
- Update this plan when scope changes during implementation.

## Testing Strategy

- **unit tests** (`agtermCore`, swift-testing): parsing, validation, dispatcher, store events, projection,
  presentation frames, settings, CLI.
- **hosted tests** (`agtermTests`, scoped `-only-testing:`): app effect, timer, remote presentation, sidebar
  row height and colors, and one command-to-row integration check through the real dispatcher into a live
  outline.
- **XCUITest**, two targeted cases: the Interface tab-fit check extended in `SettingsUITests`, and one
  socket-level `tree` read-back after `session info`, following `ControlRecentUITests.swift:33`.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix

## Solution Overview

`Session.info: SessionInfo?` holds the caller's source, its markdown flag, the configured hide-after and the
parsed spans. It is set only over the control channel, never persisted, projected on `ControlSessionNode`,
mirrored over remote presentation, and drawn by `SidebarInfoCellView` where the app-wide `SessionInfoDisplay`
setting allows: Always (default), Flagged (the flagged sidebar view only) or Off. The setting gates drawing
only; the line, its expiry, mirroring and read-back are untouched.

Every successful set replaces the whole value, as `hud.update` does: omitting `--markdown` means plain,
omitting `--hide-after` cancels a prior expiry. Each successful set restarts the timer, even with identical
text, so a recipe refreshing "3 subagents running" keeps it alive and a crashed hook lets it expire. A
rejected set changes nothing, value or deadline. `--clear` is the only clearing form.

The store owns the value and the change event (`AppStore.setInfo`, like `setContext`); the app owns the timer
(`ControlServer`, like `armHudAutoHide`). Expiry clears the line through the store, so the row shrinks and
`tree.changed` fires whether or not the line is shown. On an attached viewer the origin owns the timer and
its expiry arrives as a mirrored clear.

Unknown attribute keys (`colour:`) are dropped by Foundation and render unstyled; that is accepted rather
than lexed for, so there is one markdown grammar, Foundation's.

## Technical Details

```swift
public struct SessionInfo: Equatable, Sendable {
    public let source: String
    public let markdown: Bool
    public let hideAfter: Double   // 0 = no expiry
    public let spans: [SessionInfoSpan]
}
```

- Source cap: 512 UTF-8 bytes, checked before parsing; markup syntax counts toward it.
- Hide-after: `HudSpec.isValidHideAfter` (`0...86400`, rejected rather than clamped), in CLI and dispatcher.
- Protocol: `session.info` with `mode: set|clear` like `session.context`; `set` takes `text`, optional
  `markdown` and `hideAfter`; `clear` refuses `text`, `markdown` and `hideAfter`.
- Read-back on `ControlSessionNode`: when info is set, `info` (raw source), `infoMarkdown` and
  `infoHideAfter` (configured seconds, 0 for no expiry, never a countdown) are all present; when unset, all
  three are omitted.
- Remote, following context's split (`Session.swift:92-93`): `Session.info` is the local value,
  `mirroredInfo` the origin's, `effectiveInfo` is `info ?? mirroredInfo`. Projection, `RowContent` and
  rendering read `effectiveInfo`. Origin updates continue under a local override; clearing or expiring the
  override reveals the latest origin value; disconnect drops only the mirror.
- Presentation: a new `info` frame and an optional, defaulted `PresentationSnapshot.info` carrying source,
  markdown flag and configured hideAfter. The viewer parses the source itself and arms no timer: the
  origin's expiry arrives as a mirrored clear. A viewer's `tree` reports the origin's configured hideAfter.
- Sidebar: rows with info grow to `SidebarInfoMetrics.rowHeight`; rows without keep the plain height.

## What Goes Where

- **Implementation Steps**: code, tests and docs in this repo.
- **Post-Completion**: visual check by eye in an isolated Debug instance.

## Implementation Steps

### Task 1: SessionInfo model, validation and store setter

**Files:**
- Modify: `agtermCore/Sources/agtermCore/SessionInfoMarkup.swift`
- Modify: `agtermCore/Sources/agtermCore/Session.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+SessionState.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/SessionInfoMarkupTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreEventTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/SnapshotRoundTripTests.swift`

- [x] add `SessionInfo` and `SessionInfo.make(source:markdown:hideAfter:)` returning the value or a rejection
      message: source cap, `HudSpec.isValidHideAfter`, then `SessionInfoMarkup.spans`
- [x] add runtime-only `public var info: SessionInfo?` to `Session`, with `mirroredInfo` (internal set) and
      `effectiveInfo` mirroring `context`/`mirroredContext`/`effectiveContext`, plus `onInfoDiscarded` and
      `discardInfo()` mirroring `onHudDiscarded`/`discardHudBody()`; `SessionSnapshot` does not gain a field
- [x] add `AppStore.setInfo(_:forSession:) -> Bool` beside `setContext`: no save (runtime-only), returns
      whether the local value changed, calls `scheduleTreeChanged()` only when `effectiveInfo` changed; a nil
      goes through `discardInfo()`
- [x] write tests: the exact 512-byte boundary both sides with a multibyte source measured in bytes, bad
      hide-after, parse errors, plain and markdown success, and the existing parser cases
- [x] write `AppStoreEventTests` cases: set fires `tree.changed`, identical set fires nothing, clear fires and
      runs the discard hook
- [x] write tests: a snapshot round trip carries no info, and a duplicated session has none
- [x] run the three scoped suites - must pass before task 2

### Task 2: session.info protocol, dispatcher and read-back

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher+SessionMetadata.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlActions.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlActionsDefaults.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProjection.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherSessionMetadataTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreTreeProjectionTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/MockControlActions.swift`
- Modify: `agterm/Control/ControlServer.swift`

- [x] ➕ register `.sessionInfo` in `ControlServer.dispatch`'s exhaustive switch beside `.sessionContext`, moved
      here from task 3 because a new command case breaks the app build until it is listed
- [x] add `case sessionInfo = "session.info"` and the `markdown`/`hideAfter` args; dispatch it in
      `ControlDispatcher+SessionMetadata.swift` with `mode: set|clear`, building the value through
      `SessionInfo.make` and rejecting every bad combination before any action runs
- [x] add `setSessionInfo` to `ControlActions` with the unimplemented default
- [x] add optional `info`, `infoMarkdown`, `infoHideAfter` to `ControlSessionNode` with defaults in the
      compatibility initializer (agtermCore is consumed by the agterm-linux fork), populated in `AppStore`
      from `effectiveInfo` per the read-back rule in Technical Details
- [x] write dispatcher tests in `ControlDispatcherSessionMetadataTests` (`ControlProtocolTests.swift` is at
      its cap): set, clear, the encoded request shape, and every rejection path calling NO action
- [x] write projection tests: all three fields present with `infoMarkdown: false` and `infoHideAfter: 0` for a
      plain untimed line, all omitted when unset
- [x] run `swift test --filter "ControlDispatcherSessionMetadataTests|AppStoreTreeProjectionTests"` - must pass
      before task 3

### Task 3: App effect, expiry timer and close/undo

**Files:**
- Create: `agterm/Control/ControlServer+SessionInfo.swift`
- Modify: `agterm/Control/ControlServer.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+PendingClose.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`
- Modify: `agterm/Views/WindowAccessor.swift`
- Create: `agtermTests/ControlServerSessionInfoTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStorePendingCloseTests.swift`

- [x] implement `setSessionInfo` in the new file through `AppStore.setInfo` (`ControlServer+SessionActions.swift`
      is at its cap; the switch registration landed in task 2)
- [x] add `armInfoAutoHide` mirroring `armHudAutoHide`: a per-session revision, restart on every successful
      set including identical text, cancel through `Session.onInfoDiscarded` and on a set without
      `--hide-after`; expiry clears through `AppStore.setInfo(nil, ...)`
- [x] call `discardInfo()` only where the SESSION or its window is torn down (`AppStore+PendingClose.swift:575`,
      `AppStore.swift:614` and `:656`, `WindowAccessor.swift:182`), never from `closeOverlay`
      (`AppStore+Panes.swift:487`), which runs on every overlay, program or HUD close while the session lives
- [x] clear a timed info line at soft close (beside `closeTimedHud`) so undo never restores one whose time
      was up; an untimed line keeps the ordinary undo behavior
- [x] write hosted tests in the `ControlServerHudAutoHideTests` style, a short real expiry and a bounded
      wait (a Date clock stamps deadlines but does not drive `Task.sleep`): set reaches the store; identical
      set restarts the deadline; expiry clears and fires the event; a superseded timer is inert
- [x] write hosted tests: a rejected write keeps the armed deadline and value; a set without `--hide-after`
      over a timed line cancels its expiry; closing the session cancels an armed timer; closing an overlay
      or HUD keeps the info line and its armed timer
- [x] write `AppStorePendingCloseTests` cases: soft close drops a timed line and keeps an untimed one
      through undo
- [x] run the scoped hosted tests and `swift test --filter AppStorePendingCloseTests` - must pass before task 4

### Task 4: Remote presentation of the info line

**Files:**
- Modify: `agtermCore/Sources/agtermCore/PresentationFrames.swift`
- Modify: `agtermCore/Sources/agtermCore/PresentationHub.swift` (➕ `info` joins `supportedKinds`, which advertises
  it; `publish` does not filter by negotiated kinds, so an older viewer still receives the frames and stays safe by
  decoding them as `.unknown` and ignoring the snapshot's extra key)
- Modify: `agtermCore/Sources/agtermCore/RemotePresentationClient.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+SessionState.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+Presentation.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+RemotePresentation.swift`
- Modify: `agterm/Control/ControlServer+RemotePresentation.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/PresentationFramesTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/RemotePresentationStateTests.swift`
- Modify: `agtermTests/ControlServerRemotePresentationTests.swift`

- [x] add an `info` frame and an optional, defaulted `PresentationSnapshot.info` carrying source, markdown
      flag and configured hideAfter; `AppStore.setInfo` publishes the local value to `presentationHub` as
      `setContext` does, and `AppStore+Presentation.swift` puts it in the initial snapshot
- [x] the viewer applies a frame or snapshot into `mirroredInfo` (`AppStore+RemotePresentation.swift`, wired
      through `ControlServer+RemotePresentation.swift`), parsing the source and dropping an unparseable one,
      arms no timer, and clears only the mirror on stream end, exactly as `mirroredContext` does
- [x] write frame tests: encode/decode round trip including hideAfter, a snapshot without the key decodes
      to nil
- [x] write state and hosted tests: set, clear and origin expiry reach the viewer row; the viewer's `tree`
      reports the origin's configured hideAfter; stream end clears the mirror
- [x] write override tests: local set over a mirror -> origin update stays hidden -> local clear or expiry
      reveals the latest origin value; disconnect while a local override remains keeps the local line
- [x] run the scoped suites - must pass before task 5

### Task 5: Sidebar rendering from the store, and the Interface toggle

**Files:**
- Delete: `agterm/Views/SidebarInfoProto.swift`
- Modify: `agterm/Views/WorkspaceSidebar+RowRendering.swift`
- Modify: `agterm/Views/WorkspaceSidebar.swift`
- Modify: `agterm/Views/SidebarInfoCell.swift`
- Modify: `agtermCore/Sources/agtermCore/AppSettings.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppSettingsTests.swift`
- Create: `agtermTests/SidebarInfoRowTests.swift`
- Modify: `agtermUITests/SettingsUITests.swift`

- [x] add `case sessionInfo` to `InterfaceElement` in the sidebar section, `hiddenByDefault`, label
      "Session info", a nil `symbolName`, placed by `settingsOrder(in:)`
- [x] `sessionInfo(forSession:)` reads `Session.effectiveInfo?.spans`, nil while the element is hidden;
      delete the sample source and its environment flag
- [x] add the shown effective info to `RowContent` so a change reloads that row and re-asks its height
      (`noteHeightOfRows`); a toggle flip arrives through `appearanceChanged` and takes the same path.
      ⚠️ `WorkspaceSidebar.swift` is at 979/1000 lines: if the change crosses the limit, STOP and ask
- [x] write `AppSettingsTests` cases: section, hidden by default, shown-set round trip
- [x] write hosted tests: row height grows with info and returns to plain on clear and when hidden; a
      selected row keeps colored fragments in their tint color and draws uncolored ones in the selection
      foreground; a row tint never reaches the info line
- [x] write one hosted integration test: a `session.info` request through the real dispatcher and
      `ControlServer` refreshes the live outline row and changes its height, then `--clear` restores it
- [x] extend `testInterfaceTabFitsWithTheOverlaysToggle` with the new toggle: the tab still fits, and showing
      it saves into `shownInterfaceElements`
- [x] run `swift test --filter AppSettingsTests`, the scoped hosted tests and the scoped XCUITest - must pass
      before task 6

### Task 6: agtermctl session info

**Files:**
- Modify: `agtermCore/Sources/agtermctlKit/SessionMetadataCommands.swift`
- Modify: `agtermCore/Sources/agtermctlKit/SessionCommands.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/SessionMetadataCommandsTests.swift`
- Create: `agtermUITests/ControlSessionInfoUITests.swift`

- [x] add `session info [TEXT] [--clear] [--markdown] [--hide-after N]` beside `session context`, with
      target/window options and help showing the quoted color form `^[text](color: "green")`
- [x] reject at parse time: `TEXT` with `--clear`, neither, `--markdown`/`--hide-after` with `--clear`, and an
      out-of-range `--hide-after` through `HudSpec.isValidHideAfter`
- [x] write tests: parsing, each rejection, and the request shape sent to the socket
- [x] write one XCUITest following `ControlRecentUITests.swift:33`: `session info` over the real socket, then
      `tree` reads `info`, `infoMarkdown` and `infoHideAfter` back
- [x] run `swift test --filter SessionMetadataCommandsTests` and the scoped XCUITest - must pass before task 7

### Task 7: ➕ Three-way info display setting

Eugene replaced task 5's on/off Interface toggle with a three-way choice after seeing it; codex agreed.

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppSettings.swift`
- Modify: `agterm/Ghostty/GhosttyApp.swift`
- Modify: `agterm/SettingsModel.swift`
- Modify: `agterm/Views/SettingsView.swift`
- Modify: `agterm/Views/WorkspaceSidebar+RowRendering.swift`
- Modify: `agtermCore/Sources/agtermctlKit/SessionMetadataCommands.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppSettingsTests.swift`
- Modify: `agtermTests/SidebarInfoRowTests.swift`
- Modify: `agtermUITests/SettingsUITests.swift`

- [x] drop `InterfaceElement.sessionInfo` (never shipped) and restore the settings tests that enumerate it
- [x] add `SessionInfoDisplay` (`always`|`flagged`|`off`, labels Always/Flagged/Off) and raw
      `AppSettings.sessionInfoDisplay`, nil and unknown resolving to `always`, persisted nil for Always,
      mirrored to `GhosttyApp` and set through `SettingsModel.setSessionInfoDisplay` like the flagged layout
- [x] gate `sessionInfo(forSession:)`: Off draws nothing, Flagged draws only while `store.sidebarMode` is
      flagged; the line, timer, mirroring and read-back are never touched
- [x] put a menu Picker "Session info" in the Interface Sidebar grid's empty half-cell; checked by eye that
      the label and the selected value fit and the tab does not scroll
- [x] update the CLI help to the three-way rule
- [x] write tests: settings default, resolution, round trip and labels; hosted rows for Off keeping the line and
      timer, Flagged hiding in the tree and showing after a mode flip, and a setting change redrawing through
      `.agtermAppearanceChanged`; the Interface tab UI test picks Flagged, checks it persists and the tab fits
- [x] run the settings tests, the scoped hosted tests and the scoped UI test - must pass before task 8

### Task 8: Cross-surface documentation

**Files:**
- Modify: `.claude/rules/control-api.md`
- Modify: `.claude/rules/sidebar.md`
- Modify: `plugins/agterm/skills/agterm/SKILL.md`
- Modify: `plugins/agterm/skills/agterm/reference.md`
- Modify: `site/commands.html`
- Modify: `site/docs.html`

- [x] `control-api.md`: the command, its whole-value replacement, renew-on-identical timer, runtime-only
      storage, read-back fields, that markup syntax counts toward the 512-byte source cap, why unknown
      attribute keys are not rejected, and info joining the mirrored presentation set with the
      local/mirrored/effective split and origin-owned expiry
- [x] `sidebar.md`: the info row's height, title band, selection colors and emoji scaling, owned once
- [x] bundled skill: a `SKILL.md` trigger ("show status or activity under a session in the sidebar") and the
      full contract in `reference.md`, including that a recipe reporting activity must pass `--hide-after`
      and refresh it
- [x] `site/commands.html` mirrors the command, arguments and read-back fields; `site/docs.html` describes the
      feature, the markup with an example, the Session info display setting, and that attached sessions show it
- [x] state no command total anywhere

### Task 9: Verify acceptance criteria

- [x] a caller can set, restyle, renew and clear a line, and `tree` reads back source, markdown and hide-after
- [x] a rejected set leaves value and deadline untouched; `--clear` is the only clearing form
- [x] expiry clears the line and shrinks the row while hidden too; relaunch starts with no info
- [x] an attached viewer shows the origin's line with its configured hideAfter, loses it on origin expiry
      and on stream end, and a local override hides and then reveals the origin's line
- [x] run `make build`, `cd agtermCore && swift test`, `make test-app`, `make lint` - all clean
- [x] ➕ lint caught two `twoColumnSection` calls passing two closures by trailing syntax; fixed
- [x] ➕ `watchdogFiresWhileTheGlobalQueueIsExhausted` (unrelated `session wait` test) timed out once in the
      gate and passed in 26 later runs; it now records stage and process diagnostics on a timeout with
      bounded cleanup, and `docs/backlog/session-wait-watchdog-probe-times-out-once.md` holds the evidence

### Task 10: [Final] Wrap up

- [x] update `ARCHITECTURE.md` if the surface split changed
- [x] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification:**
- Launch an isolated Debug instance, set lines from
  `agtermctl --socket` (plain, markdown with colors, emoji, a long one, one with `--hide-after 5`), and check
  by eye: row height, truncation and tooltip, selection colors, a tinted row, and the line disappearing on
  expiry.
- Look at Settings > Interface with the Session info picker on each value, and switch the sidebar to the flagged view under Flagged.

Smells pre-check: skipped — non-Go project.
