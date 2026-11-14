# Remote Session Parity

## Overview
- A session on agterm-server (Linux) or attached from another Mac should behave like a local one. A static audit
  (2026-11-14, Claude, codex and Fable reading master `180d0c89`) found basic capabilities that work locally and
  are refused, lost or run on the wrong host for remote sessions.
- Three actors are in scope throughout: an agent on the Linux host calling its server (A), a Mac user or CLI on a
  row of a server window (B), and a Mac user or CLI on a row attached from another Mac or attached alone from a
  Linux host (C).
- Already filed and out of this plan: local-to-server messaging (`docs/backlog/local-to-server-messaging.md`),
  pending mail counts on attached rows (`docs/backlog/pending-counts-on-attached-rows.md`), user event hooks on the
  server (`docs/backlog/server-user-event-hooks.md`, Eugene's call).

## Context (from discovery)
- Server: `agtermCore/Sources/AgtermServerKit/` (`ServerCommandPolicy.served` is default-deny,
  `ServerActions+Unserved.swift` lists refusals, `AgtermServer.start` builds the store with no event sink,
  `PaneObserver`, `ServerStreams`, `ServerCatalog`); `HeadlessCommandPolicy` lives in
  `agtermCore/Sources/agtermCore/CatalogRoot.swift`; the policy test is
  `agtermCore/Tests/AgtermServerTests/ServerCommandPolicyTests.swift` (`undecided` set, pinned refusals).
- Mac routing for server rows: `agterm/Control/ControlServer+RemoteActions.swift` (`remoteRoute`,
  `localOnlyCommands`), `agtermCore/Sources/agtermCore/RemoteOperation+Request.swift` (`structuralCommands`,
  `unsupportedField`, `singleTarget`), `RemoteCatalogActions`, `RemoteCatalogMirror`, `RemoteWindowViewState`.
- Mac routing for attached rows: `ControlServer+RemoteCompanions.swift:createRemoteCompanion` (a separate ssh control
  call via `RemoteSession.controlCommand` + `remoteRunner`), `AppStore+RemotePresentation.swift`,
  `AppStore+RemoteLayout.swift:applyRemoteLayout`, `AppStore+Catalog.swift:catalogBinding`, `agtermApp.makeScratchSurface`
  (a plain local shell today, no daemon). An attached row has no ssh pool: `catalogPool` answers only for
  catalog-owned rows.
- `Session.isPersistable` has five callers: quit capture (`AppDelegate.swift`), local Recent Closed
  (`AppStore+RecentClosed.swift`), pending-close and close companion recording (`AppStore+PendingClose.swift`,
  `AppStore.swift`), and the snapshot filter (`AppStore+Snapshot.swift`).
- Recent Closed: `RecentClosed.swift` (`RecentClosedKind`, `RecentClosedStore.load` drops the whole list on a decode
  failure), `ControlServer+Recent.swift` (no window argument), `PaletteCatalog.swift:PaletteContext.hasRecentClosed`.
- Menu enablement: `PaletteCommand.isEnabled(in:)` in `agtermCore/Sources/agtermCore/PaletteCatalog.swift` is its
  single owner (`.claude/rules/menu-actions.md`).
- Presentation stream: viewers advertise the frame kinds they speak (`PresentationHub`, e.g. `pageForwardKind`); an
  origin closes the stream on a frame it cannot decode.
- Forwards: `PooledForward` (agtermCore, on a server window's pool), `agterm/Control/RemotePortForward.swift`
  (standalone `ssh -L`), both used by `ControlServer+RemotePage.swift:showForwardedPage`.
- Prune: `agtermCore/Sources/agtermCore/ZmxInventory.swift` (`ZmxInventory`, `ZmxPrunePolicy`); the Mac's claim walk
  counts pending-close members (`WindowLibrary`).
- Contracts: `.claude/rules/control-api.md`, `sidebar.md`, `menu-actions.md`, `site/docs.html#remote-server`,
  `site/commands.html`, `plugins/agterm/skills/agterm/`.
- Earlier plan this one amends: `docs/plans/20261106-linux-remote-server.md`.

## Development Approach
- **testing approach**: TDD for the defects (task 1's `session text --lines`, task 2's status and unseen, task 9's
  link clicks): a failing test first, then the fix. Tests-after, in the same task, for new capabilities.
- complete each task fully before moving to the next; every task ends with its tests passing
- **CRITICAL: every task MUST include new/updated tests** for its code, success and error paths
- **CRITICAL: update this plan file when scope changes during implementation**
- every new or changed command lands with protocol, dispatcher, `agtermctl`, read-back and tests, per CLAUDE.md
  "Cross-surface contracts"; a command served on the server is also reachable from a server window row and from
  an attached row, or task 10's table names why not
- a task that serves a command or adds one updates `ServerCommandPolicyTests` in the same task: it leaves
  `undecided`, and pinned refusal arguments that name it change; the suite passes at the end of every task
- menu and palette enablement changes go through `PaletteCommand.isEnabled(in:)` and `PaletteContext`, with
  `PaletteCatalogTests`, never through a context-menu check of its own
- every new presentation frame or `link.click` mode is sent only to a peer that advertises its kind; each such task
  tests the older-peer path (frame withheld, behavior as today, stream stays open)
- the worktree needs the six artifact symlinks from the main checkout before the first build (CLAUDE.md
  "Worktrees and local builds"), after checking the stamps match
- no experimental `agtermctl` against the default socket; manual checks use an isolated Debug instance

## Testing Strategy
- **unit tests**: `cd agtermCore && swift test --filter <Suite>`: `AgtermServerTests` for server behavior,
  `agtermCoreTests` for routing, mirror, catalog, snapshot, palette and policy, `agtermctlKitTests` for CLI parsing
- **hosted tests**: `agtermTests` (`scripts/test-app.sh`, scoped with `-only-testing:`) for `ControlServer` routing,
  scratch daemons, link clicks and attached-row lifecycle
- **e2e**: `agtermUITests/ControlAPIUITests` only for a command whose end-to-end Mac path changes, scoped to the new
  methods
- each task names its test files; a new source file gets a test file of the same name
- gates once, at the end: `cd agtermCore && swift test`, `make test-app`, `make lint`

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope

## Solution Overview
- **The host that runs a pane owns every operation on it.** A viewer never imitates an operation locally: it
  routes it to the origin (server catalog operation for B, ssh control call for C) and shows the origin's result.
  The two existing routes are reused; no new transport.
- **A server serves what a headless host can do.** Everything that needs no GUI joins `ServerCommandPolicy.served`.
  What needs a Mac screen or the Mac app is refused by design, as Eugene approved (task 10's table).
- **Per-Mac view choices stay per-Mac but become durable.** Background watermark, companion fold, the context
  override, workspace focus/filter and flagged order are saved. The info line stays runtime-only, as locally.
  Flag and tint become server catalog fields (Eugene's call), so a server agent can set them and every Mac sees the
  same.
- **Attached rows behave like a server window's rows.** They survive relaunch, their new split, scratch and
  duplicate run on the origin, panes the origin adds later attach, and an explicit terminate ends the session at
  the origin while plain close stays a detach.
- **Clears and undo belong to the origin.** A status clear or a seen made on the viewing Mac travels to the origin
  with its reason; undo and Reopen Closed of a remote session act on the origin's own record.
- **Security.** Untrusted inputs: frames from an origin (already decoded by the presentation and catalog decoders)
  and, new here, frames and routed requests from a viewer. New capabilities: a viewer can ask its origin to
  restart, terminate, kill a pane, convert, undo, reopen, or clear status; it does so over the user's own ssh
  authority, which can already run `agtermctl` there, so no privilege is added. The origin accepts a clear or seen
  frame only for a session that viewer is presenting and only for that session's panes, and applies its own rules
  to it. Clicked loopback URLs open the origin's loopback through an ssh forward, so a remote program printing a
  URL reaches only what that host already serves. `/proc/<pid>/cmdline` reads and the event ring stay inside the
  user's own processes and the 0600 control socket. Restoring attached rows starts ssh only to hosts the user
  attached before.
- **TCC.** The Mac scratch daemon starts through the same `agterm-session-host` path the pane daemons use, so its
  attribution matches a pane's (#574: host responsible, `com.umputun.agterm` the subject). Task 5 checks each
  service a scratch commonly uses (microphone, screen recording, Accessibility) the way #574 did; the other tasks
  start no new kind of process on the Mac (ssh only).

## Decisions changed from the earlier server plan and current docs

| Decision | Here | Reason |
|---|---|---|
| Terminate has no undo grace and no Reopen Closed entry | changed: both added, owned by the origin host | Eugene's call; it was "out of this release" |
| Flag/tint are Mac view state | changed: server catalog fields; watermark, fold and context override stay Mac view state, now saved | Eugene's call |
| Attached rows are not saved | changed: restored on relaunch by origin session id | Eugene's call |
| An attached row's new split, scratch and Duplicate start on the viewing Mac | changed: they start on the origin | Eugene's call |
| A Mac scratch is a plain local shell that ends with the app | changed: daemon-backed in Live sessions mode and kept across an app restart, restored hidden | Eugene's call (the option he chose named restart survival) |
| A viewer's status clear is local; the next snapshot restores the origin's status | changed: the clear reaches the origin | Eugene's call |
| `session.restore` on a remote row answers ok and is ignored | changed: refused on a server row, forwarded to a Mac origin | Eugene's call |
| A clicked `http://localhost` URL in a remote pane opens the Mac's own loopback | changed: it opens the origin's loopback through an ssh forward; Mac-origin loopback pages forward too | Eugene approved "link clicks go to the right machine" in the gap list |
| Close detaches by default; Terminate ends on the server | kept, extended to attached rows as an explicit terminate | the gap was only the attached row |
| Attached-row context: a local override over the mirrored origin context | kept, and the override is now saved | documented design |
| Status reset policy is a Mac setting | kept: a Mac origin applies its own; the server applies the Mac defaults (`firstKey`), no server setting | no request for a server setting |
| Settings, keymap, custom command bodies stay on the Mac | kept | approved exception |
| Several Macs on one catalog: first-stream-wins presenter | kept | not in scope |

## Technical Details
- **Events on the server**: `AgtermServer.start` gives its store a `controlEventSink` into a server-owned
  `ControlEventRing`; `ServerActions.readEvents` serves `events.read` through the agtermCore read path
  (`WindowLibrary.readEvents`'s logic). `session wait` needs nothing new.
- **Foreground read-back on Linux**: `ProcCwd.foregroundGroup` (`PaneObserver`) also reads `/proc/<pid>/cmdline`
  and the shell name; `ServerActions.controlTree` and `ServerActions+Remote.swift:remoteTree` pass it as
  `paneForeground`.
- **Catalog fields**: `CatalogSessionFields` gains `flagged` and `tint`; `CatalogWorkspace` gains `tint`. A server
  carrying this code always sends them, `false` and `""` for none, as `customName` does; nil means an older server,
  for which the viewer keeps local flag/tint.
- **Status clear and seen**: a presenter-to-origin frame `clear {session, pane, reason}` where `reason` is the
  keystroke class the local rule already distinguishes (plain text, Return, Escape/interrupt, scripted input) or
  `select` for a selection-driven auto-reset, and `seen {session}`. `PresentationStatus` carries `autoReset` so the
  viewer knows a selection should clear. The origin applies its own policy to the reason (owning pane only; typed
  text never clears `active`; scripted input is submit/other): a Mac origin its own settings, the server the Mac
  defaults through `effectiveStatusReset`/`effectiveBadgeReset`. `ServerActions.typeSession` applies the same input
  clear the Mac's `injectAsUserInput` does. Sent only to an origin advertising the kind.
- **Mac scratch daemon**: in Live sessions mode a Mac scratch is a zmx daemon whose identity is the existing
  `Session.ScratchDaemon`, now saved in the snapshot. Lifetime as today: hide keeps it, close ends it, its shell
  exiting closes and hides it and the next show starts a fresh one (`closeScratch`); an app restart adopts a
  surviving daemon and restores the scratch hidden. Lead follows the pane rules: the origin's own client attaches
  without a claim, a viewer's attach claims, a non-leading scratch is covered (`PaneLeadCover`), and
  `session.lead --pane scratch` takes it back. `PresentationLayout` and `zmx.tree` describe the scratch. Outside
  Live mode it stays a plain shell and an attached row's scratch is refused with a reason.
- **Snapshot of attached rows**: a new predicate `isSnapshotted` (local persistable, or any attached row: terminal,
  page root or page companion) replaces `isPersistable` only in `AppStore+Snapshot.swift`; the other four callers
  keep `isPersistable`, so quit capture and local Recent Closed never see an attached row. An attached row is saved
  as a remote reference `{host, originSessionID, content}`, never as a replica's page source; on relaunch a terminal
  re-attaches through `attachRemoteSession` and a page through its page-attachment path
  (`attachRemotePageRow`, `addReplicaPageRoot`/`addReplicaPageCompanion`).
- **Terminate**: CLI `session close --terminate` sends a distinct wire command `session.terminate`, so an older
  viewer refuses it as unknown instead of detaching and answering ok. On a local row and on a server window row it
  is the same as `session.close` (both already end the session); the server serves it the same way. On an attached
  row the viewer runs the origin's `session close --target <remoteSessionID>`, passing `--undoable` through; a lost
  reply is `unknown`, never a local close, never resent.
- **Recent id in the close reply**: a single-target `session.close` gains `recentID` in its result, the id of the
  Recent Closed entry the close wrote, an undoable close's included, since that entry is written at close time; a
  batch and a row Recent Closed does not keep carry none.
- **Remote Recent Closed entries**: `RecentClosedState` gains an optional `remoteItems` array, which an older build's
  decoder ignores instead of dropping the list. An entry is `{id, closedAt, host, originSessionID, originRecentID?,
  name, placement}`, deduped by `(host, originSessionID)`. A detached attached row records one without
  `originRecentID`; a terminated one records the origin's `recentID`. Reopen: origin session alive → re-attach;
  else the origin reopens its record and the viewer attaches the result; neither → refused with a reason. Undo
  inside the grace calls the origin's undo. The entry ages out with the list like any other.
- **Server undo and Reopen Closed**: the server keeps its own `RecentClosedStore` and pending-close records in its
  state directory, and an undo grace for `session.close --undoable`. Pending closes count as daemon claims, so prune
  never kills them. A clean stop finalizes them first (`finalizeAllPendingCloses`); a start finalizes any it finds
  left by a crash (daemons killed, entries written). `recent.list/open/clear` are served; reopen recreates shells
  and pages in their directories, never revives killed programs.
- **Recent Closed addressing**: `recent.list`, `recent.open` and `recent.clear` take `--window` (default: the active
  window); in a server window they route to its server, `recent.open` and `session.close --undoable` with operation
  receipts and the existing unknown-outcome rules. `PaletteContext` gains the active window's list source, so the
  menu and palette Reopen Closed items read the server's list there.
- **Server prune**: built on `ZmxInventory`/`ZmxPrunePolicy` over the server's daemon namespace, with catalog panes,
  scratches and pending closes as claims.
- **Loopback forward for clicks**: `ControlServer+LinkForward.swift` owns forwards keyed by `(host, port)`: on a
  server window row a `PooledForward` on the window's pool, ending with the pool; on an attached row a
  `RemotePortForward`, ending when the row closes or its attachment ends. The local end is a free local port; the
  URL opened keeps scheme, path and query with host and port rewritten to the local end. A click waits until the
  forward listens before opening the browser or overlay; a failure shows the existing link-refused panel.

## What Goes Where
- **Implementation Steps**: code, tests and docs in this repo
- **Post-Completion**: manual checks against a real Linux host and a second Mac

## Implementation Steps

### Task 1: Host-agent reads on agterm-server

**Files:**
- Modify: `agtermCore/Sources/AgtermServerKit/AgtermServer.swift`, `ServerActions.swift`, `ServerActions+Remote.swift`,
  `ServerActions+Unserved.swift`, `ServerActions+Sessions.swift`, `ServerCommandPolicy.swift`, `PaneObserver.swift`,
  `ServerTestSupport.swift` (test support)
- Modify: `agtermCore/Sources/agtermCore/CatalogRoot.swift` (`HeadlessCommandPolicy` drops `surface.cursor`)
- Tests: `AgtermServerTests/ServerActionsSessionsTests.swift`, `ServerActionsTests.swift`, `ServerActionsRemoteTests.swift`,
  `PaneObserverTests.swift`, `AgtermServerTests.swift`, `ServerCommandPolicyTests.swift`, `agtermCoreTests/CatalogRootTests.swift`

- [x] failing test: server `session text --lines N` returns lines from scrollback beyond the viewport; fix
      `readSessionText` to request the full buffer when `lines` is set, as the Mac's `coveredText` does; make the
      server test stub honor `all`
- [x] events: event sink and ring on the server store, serve `events.read`; `session wait` works on the host
- [x] serve `session.info` with its auto-hide timer on the server
- [x] serve `surface.cursor` from `ZmxScreen`'s cursor position
- [x] foreground argv and shell name in the server `tree` and in the remote tree a viewer reads
- [x] serve `zmx.list` and `zmx.screen` over the server's daemon namespace
- [x] policy test: these commands leave `undecided`, pinned refusal arguments updated
- [x] tests for each command, success and refusal paths; `swift test --filter AgtermServerTests` passes

### Task 2: Status and unseen clear at the origin

**Files:**
- Modify: `agtermCore/Sources/agtermCore/PresentationFrames.swift`, `PresentationHub.swift`, `AppStore+RemotePresentation.swift`,
  `AppStore+Status.swift`, `agtermCore/Sources/AgtermServerKit/ServerStreams.swift`, `ServerActions+Sessions.swift`,
  `ServerActions+Effects.swift`, `ServerCommandPolicy.swift`, `agterm/agtermApp*.swift` (`wireStatusClear`),
  `agterm/Control/ControlServer+Presentation.swift`
- Tests: `agtermCoreTests/PresentationFramesTests.swift`, `PresentationHubTests.swift`, `RemotePresentationStateTests.swift`,
  `AgtermServerTests/ServerStreamsTests.swift`, `ServerActionsSessionsTests.swift`, `ServerActionsEffectsTests.swift`,
  `ServerCommandPolicyTests.swift`, `agtermTests/ControlServerRemotePresentationTests.swift`

- [x] failing tests: a status a viewer cleared returns on reconnect (B and C); server `session type` never clears
      status; server `unseenCount` never resets
- [x] `clear` and `seen` frames with the reason, advertised as a kind; `autoReset` in `PresentationStatus`
- [x] the origin applies them under its own rules, only for a session that presenter shows and its panes; a Mac
      origin with its settings, the server with the Mac defaults
- [x] server `typeSession` applies the local input-driven clear; serve `session.seen`; policy test updated
- [x] tests: each reason against each policy, owning pane, selection clear, reconnect, refusal of a frame for a
      session the viewer does not present and for a pane outside it, older origin (frame withheld)

### Task 3: Flag, tint and saved view state for server rows; remote-window option parity

**Files:**
- Modify: `agtermCore/Sources/agtermCore/CatalogFrames.swift`, `CatalogDiff`/`CatalogHub` as needed,
  `RemoteCatalogMirror.swift`, `RemoteWindowViewState.swift`, `RemoteOperation+Request.swift`,
  `RemoteCatalogActions.swift`, `PaletteCatalog.swift`, `agtermCore/Sources/AgtermServerKit/ServerCatalog.swift`,
  `ServerActions+Sessions.swift`, `ServerActions+Workspaces.swift`, `ServerCommandPolicy.swift`,
  `agterm/Control/ControlServer+RemoteActions.swift`, `agterm/AppActions+Palette.swift`
- Tests: `agtermCoreTests/CatalogFramesTests.swift`, `RemoteCatalogMirrorTests.swift`, `RemoteCatalogMirror+DetachTests.swift`,
  `RemoteOperationRequestTests.swift`, `RemoteCatalogActionsTests.swift`, `PaletteCatalogTests.swift`,
  `AgtermServerTests/ServerCatalogTests.swift`, `ServerActionsSessionsTests.swift`, `ServerActionsWorkspacesTests.swift`,
  `ServerActionsMovesTests.swift`, `ServerCommandPolicyTests.swift`, `agtermTests/ControlServerRemoteActionsTests.swift`

- [x] flag and session/workspace tint as catalog fields (`false`/`""` for none, nil only from an older server);
      server serves `session.flag`, `session.tint`, `workspace.flag`, `workspace.tint`; its `session new --tint`
      shows on every viewer
- [x] a server window routes flag/tint on its rows to the server, reads them back from the catalog, and disables
      them while disconnected through `PaletteContext`
- [x] `RemoteWindowViewState` saves watermark, companion fold, context override, workspace focus/filter and flagged
      order, restored on window reopen and on detach/reattach; the info line is not saved
- [x] remote operations carry `session new --workspace-name/--create-workspace/--tint`, `session new --parent
      --tint`, `workspace new --collapsed/--tint`, and multi-target `session close`/`session move`
- [x] serve `session.duplicate` on the server (fresh shell after the row, as locally); policy test updated
- [x] tests: catalog encode/decode with new fields, explicit none and an older server, a cleared tint, mirror apply,
      view-state round trip (info absent), each routed option, batch receipts, palette enablement

### Task 4: Pane lifecycle on agterm-server

**Files:**
- Modify: `agtermCore/Sources/AgtermServerKit/ServerActions+Sessions.swift`, `ServerPanes.swift`, `PaneObserver.swift`,
  `ServerActions+Receipts.swift`, `ServerCommandPolicy.swift`, `agtermCore/Sources/agtermCore/RemoteOperation+Request.swift`,
  `ZmxInventory.swift`, `PaletteCatalog.swift`, `agterm/Control/ControlServer+RemoteActions.swift`,
  `agterm/AppActions+Companions.swift`, `agterm/AppActions+Palette.swift`, `agterm/Views/WorkspaceSidebar+ContextMenu.swift`
- Tests: `AgtermServerTests/ServerActionsSessionsTests.swift`, `ServerActionsReceiptsTests.swift`, `ServerPanesTests.swift`,
  `PaneObserverTests.swift`, `ServerCommandPolicyTests.swift`, `agtermCoreTests/RemoteOperationRequestTests.swift`,
  `PaletteCatalogTests.swift`, `agtermTests/ControlServerRemoteActionsTests.swift`

- [x] `session.restart` on the server: `--command` and foreground replay (task 1's reader), pane identity and
      placement kept, Ended rows restartable; a server window routes it
- [x] `session.companion.duplicate` and `session.companion.convert` on the server with operation receipts; a server
      window routes them and `PaletteCommand.isEnabled(in:)` enables them there (the context menu follows it)
- [x] `zmx.kill` (one pane; a live split promoted by `PaneObserver.settle`) and `zmx.prune` on `ZmxInventory`/
      `ZmxPrunePolicy` with catalog panes and scratches as claims; `zmx.kill` on a server window row routes there
- [x] `--wait` output hold for `session new` and `companion new` on the server, routed from a server window and
      presented after reconnect
- [x] policy test updated; tests for each operation, receipt replay and refusal paths

### Task 5: Daemon-backed Mac scratch

**Files:**
- Modify: `agterm/agtermApp*.swift` (`makeScratchSurface`), `agtermCore/Sources/agtermCore/Session.swift`
  (`ScratchDaemon`), `Snapshot.swift`, `AppStore+Snapshot.swift`, `AppStore+Panes.swift`, `PresentationFrames.swift`
  (`PresentationLayout`), zmx discovery (`zmx.tree` projection), Live reap/claim paths, `ZmxLeadBook`,
  `agterm/Control/ControlServer+PaneLead.swift`, `PaneLeadCover`
- Tests: `agtermCoreTests/SessionTests.swift`, `SnapshotRoundTripTests.swift`, `PresentationLayoutTests.swift`,
  `agtermTests/ControlServerScratchTests.swift`, `ControlServerPaneLeadTests.swift` (or the existing lead suite)

- [x] in Live sessions mode a Mac scratch runs in a zmx daemon identified by `Session.ScratchDaemon`, started
      through `agterm-session-host` like a pane
- [x] hide, close and shell exit keep today's visible behavior (exit closes and hides it, the next show starts a
      fresh shell); an app restart adopts the daemon and restores the scratch hidden
- [x] reap, claim and Live reset treat scratch daemons like pane daemons
- [x] lead and cover follow the pane rules; `session.lead --pane scratch` takes the lead back
- [x] layout and discovery describe the scratch so a viewer can attach it
- [x] tests: daemon created, hidden and shown, closed, exit then next show starts a fresh daemon, adopted after app
      restart, reaped by reset, lead taken and covered, outside Live mode a plain shell
- [ ] TCC: check microphone, screen recording and Accessibility from a daemon scratch against a pane, as #574 did
      (passive statuses match a pane; the prompt-and-grant check is under Post-Completion)

### Task 6: Lifecycle of rows attached from another host

**Files:**
- Modify: `agterm/Control/ControlServer+RemoteCompanions.swift`, `ControlServer+Restart.swift`, `ControlServer+SessionClose.swift`,
  `ControlServer+Companions.swift`, `ControlServer+Zmx.swift`, `agterm/AppActions.swift`, `agterm/AppActions+Palette.swift`,
  `agterm/agtermApp*.swift` (split/scratch factories), `agtermCore/Sources/agtermCore/AppStore+RemoteLayout.swift`,
  `AppStore+Duplicate.swift`, `ControlProtocol.swift`, `ControlDispatcher.swift`, `PaletteCatalog.swift`,
  `agtermCore/Sources/AgtermServerKit/ServerActions+Sessions.swift`, `ServerCommandPolicy.swift`,
  `agtermCore/Sources/agtermctlKit/` (session close/restart commands)
- Tests: `agtermCoreTests/AppStoreRemoteLayoutTests.swift`, `ControlDispatcherSessionCloseTests.swift`, `PaletteCatalogTests.swift`,
  `agtermctlKitTests` session command suites, `AgtermServerTests/ServerCommandPolicyTests.swift`,
  `agtermTests/ControlServerRemoteCompanionsTests.swift`, `ControlServerRestartTests.swift`, `RemoteLayoutCloseTests.swift`

- [x] `session close --terminate` as `session.terminate`: on an attached row the origin's own close on the original
      session id with `--undoable` passed through, whole companion group, unknown outcome never falls back or
      resends; on a local or server window row the same as `session.close`; served on the server
- [x] `session.close` reports `recentID`
- [x] restart, Convert to Companion and `zmx.kill` on an attached row run on the origin; Convert becomes enabled
      there through `PaletteCommand.isEnabled(in:)`
- [x] ordinary Duplicate, a new split and the scratch of an attached row start on the origin and attach here
- [x] panes the origin creates after the attach (a new or replacement split, the scratch) attach dynamically;
      `applyRemoteLayout` handles additions, not only rearrangement and removal
- [x] `session.restore` forwarded to a Mac origin, refused on a server row with "agterm-server keeps every pane
      running"
- [x] the same paths work for a Linux session attached alone (`zmx attach` outside a server window)
- [ ] policy test classifies `session.terminate`; tests: request shapes sent to the origin, unknown-outcome
      handling, `recentID` read-back, layout additions, scratch attach, hide, show, replace, exit and reconnect
      against a real origin daemon, refusal texts (real-origin hide/show/replace/exit/reconnect is the second-Mac Post-Completion check)

### Task 7: Attached rows survive relaunch

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Session.swift` (`isSnapshotted`), `Snapshot.swift`, `AppStore+Snapshot.swift`,
  `RecentClosed.swift` (`remoteItems`), `AppStore+RecentClosed.swift`, restore/attach path in `agterm/` and
  `agtermCore` (`RemoteSession`, `RemoteReconnect`)
- Tests: `agtermCoreTests/SnapshotRoundTripTests.swift`, `RecentClosedTests.swift`, `RemoteReconnectTests.swift`,
  `agtermTests/ControlServerRemoteReconnectTests.swift`

- [ ] `isSnapshotted` used only by the snapshot filter; attached rows, page roots and page companions included,
      saved as a remote reference (host, origin session id, content kind) with pane bindings, flag, tint, watermark,
      fold and context override, never the info line or a replica page source
- [ ] relaunch re-attaches by origin session id, a page row through the page-attachment path; an unreachable origin
      shows the row disconnected and retrying, as a server window does; an origin session that no longer exists ends
      the row with a stated reason
- [ ] `RecentClosedState.remoteItems`; close of an attached row stays a detach, leaves the snapshot and records a
      remote entry; no local-shell entry and no quit capture ever for an attached row
- [ ] tests: snapshot round trip, restore with origin present, absent and unreachable for a terminal row, an
      attached page root and a group with a page companion, an older-format decoder
      keeping the local list next to `remoteItems`, dedupe by `(host, originSessionID)`, quit capture and local
      Recent Closed skipping attached rows

### Task 8: Undo and Reopen Closed for remote sessions

**Files:**
- Modify: `agtermCore/Sources/AgtermServerKit/` (close path, recent-closed and pending-close stores, `AgtermServer.start`/
  `stop`, prune claims), `agtermCore/Sources/agtermCore/WindowLibrary.swift` (`makeStore` for remote windows),
  `WindowLibrary+RecentClosed.swift`, `AppStore+RecentClosed.swift`, `RemoteOperation+Request.swift`, `PaletteCatalog.swift`,
  `ControlProtocol.swift` (`recent.*` `--window`), `agtermctlKit` recent commands, `agterm/Control/ControlServer+Recent.swift`,
  `ControlServer+RemoteActions.swift`, `ControlServer+RemoteCompanions.swift`, `agterm/AppActions+Palette.swift`
- Tests: `AgtermServerTests/ServerLifecycleTests.swift`, `ServerActionsSessionsTests.swift`, `ServerActionsReceiptsTests.swift`,
  `ServerCommandPolicyTests.swift`, `agtermCoreTests/RecentClosedTests.swift`, `ControlRecentTests.swift`,
  `ControlDispatcherRecentTests.swift`, `PaletteCatalogTests.swift`, `agtermTests/ControlServerRecentTests.swift`,
  `ControlServerRemoteActionsTests.swift`

- [ ] server undo grace for `session.close --undoable`; pending closes saved and counted as claims; a clean stop
      finalizes them, a start finalizes any a crash left; the server window's Terminate offers undo like a local close
- [ ] server Reopen Closed: `recent.list/open/clear` served; `--window` routes them from a server window, with
      receipts for `recent.open` and `session.close --undoable`; the menu and palette read the server's list there
- [ ] remote entries on the viewer: undo inside the origin's grace, reopen by re-attach or by the origin's own
      reopen, refusal when neither exists, for Mac and Linux origins
- [ ] policy test updated; tests: terminate → row gone → undo inside and after the grace; reopen with origin
      session alive, gone but recorded, and gone; a stop and a crash inside the grace kill the daemons and write
      the entry; prune inside the grace keeps them

### Task 9: Link clicks resolve on the pane's host

**Files:**
- Modify: `agterm/Ghostty/GhosttySurfaceView+Input.swift`, `agtermCore/Sources/agtermCore/LinkPolicy.swift`,
  `AppStore+ForwardedClick.swift`, `AppStore+Catalog.swift` (`catalogBinding`), `AppStore+RemotePage.swift`
  (`openRemotePage`), `agtermCore/Sources/AgtermServerKit/ServerStreams.swift` (`clickedPage`), `PaneObserver.swift`
  (scratch cwd), `agterm/Control/ControlServer+ForwardedClick.swift`
- Create: `agterm/Control/ControlServer+LinkForward.swift`
- Tests: `agtermCoreTests/AppStoreLinkClickRequestTests.swift`, `AppStoreRemotePageTests.swift`, the `LinkPolicy` suite,
  `AgtermServerTests/ServerStreamsTests.swift`, `PaneObserverTests.swift`, `agtermTests/ControlServerRemoteLinkClickTests.swift`,
  `ControlServerLinkOverlayTests.swift`, `RemotePortForwardTests.swift`, `ControlServerLinkForwardTests.swift`

- [ ] failing tests: a path clicked in a server scratch resolves on the Mac; a clicked `http://localhost:PORT` in a
      remote pane opens the Mac's loopback
- [ ] remote scratch clicks: pane token in the binding, scratch cwd tracked by `PaneObserver`, click resolved on the
      origin (server scratch and task 5's Mac scratch)
- [ ] loopback http(s) clicks in a remote pane open through `ControlServer+LinkForward`, keeping scheme, path and
      query and the browser or overlay choice; the browser opens only once the forward listens; a viewer-local
      pane's localhost stays local
- [ ] Mac-origin loopback pages forward too (today headless-only)
- [ ] tests: ready-before-open, forward failure panel, reuse and teardown for a server window row and an attached
      row, both origins, older origin without the web click kind

### Task 10: Classification, docs and gates

**Files:**
- Modify: `agtermCore/Tests/AgtermServerTests/ServerCommandPolicyTests.swift`, `.claude/rules/control-api.md`,
  `.claude/rules/sidebar.md`, `.claude/rules/menu-actions.md`, `site/docs.html`, `site/commands.html`,
  `site/llms.txt` if affected, `plugins/agterm/skills/agterm/`

- [ ] `undecided` is gone: each command is served or in an explicit refused-by-design set carrying its reason, per
      the table below
- [ ] docs: remote server and remote sessions sections (status clear, terminate, undo/reopen, restored attached rows,
      scratch daemon and its restart survival, loopback clicks), command reference rows and read-back fields
      (`recentID`, catalog flag/tint, `--window` on `recent.*`), rule files that describe the old behavior (remote
      Convert disabled, scratch override never persisting, remote clear staying local), skill reference and
      SKILL.md triggers for events and wait on the host
- [ ] verify every gap in the table is closed for A, B and C; gates: `cd agtermCore && swift test`,
      `make test-app`, `make lint`
- [ ] move this plan to `docs/plans/completed/`

Disposition of every command that was undecided on the server, plus the new one (A = host agent, B = server window
row, C = attached row):

| Commands | Disposition | Task |
|---|---|---|
| `events.read` | served (A); B and C read their Mac's ring | 1 |
| `session.info` | served (A); B and C set it on the Mac row as today | 1 |
| `zmx.list`, `zmx.screen` | served (A); on B and C they keep reading the Mac's own namespace | 1 |
| `session.seen` | served (A); B and C visits send `seen` | 2 |
| `session.flag`, `session.tint`, `workspace.flag`, `workspace.tint` | served (A), routed (B), saved (C) | 3, 7 |
| `session.background`, `session.collapse`, `session.expand`, `workspace.focus`, `workspace.filter` | refused for A (Mac view state); saved on B and C | 3, 7 |
| `session.duplicate` | served (A), already routed (B), origin (C) | 3, 6 |
| `session.restart`, `session.companion.duplicate`, `session.companion.convert` | served (A), routed (B), origin (C) | 4, 6 |
| `zmx.kill` | served (A), routed (B), origin (C) | 4, 6 |
| `zmx.prune` | served (A); on B and C it keeps pruning the Mac's own namespace | 4 |
| `session new --wait`, `companion new --wait` | served (A), routed (B); C forwards it as today | 4 |
| `session.terminate` (new) | served (A, same as close), same as close on B, origin on C | 6 |
| `recent.list`, `recent.open`, `recent.clear` | served (A), routed with `--window` (B), remote entries (C) | 8 |
| `session.restore` | refused on the server (A and B) with a reason; forwarded to a Mac origin (C) | 6 |
| `hooks.list`, `hooks.reload` | refused for A, deferred to `docs/backlog/server-user-event-hooks.md`; B and C use the Mac's hooks | 10 |
| `session.copy`, `session.paste`, `session.selectall`, `session.search`, `session.overlay.copy`, `session.overlay.text` | refused by design for A (Mac selection and clipboard); work on B and C | 10 |
| `session.focus`, `session.select`, `session.go`, `session.lead`, `session.resize`, `workspace.select`, `workspace.go` | refused by design for A (move what a Mac shows); work on B and C | 10 |
| `session.reveal` | refused by design (Finder on the Mac) | 10 |
| `restore.mode`, `restore.capture`, `restore.clear`, `zmx.reset` | refused by design (Mac app lifecycle) | 10 |
| `session.detach`, `session.reattach`, `workspace.detach`, `workspace.reattach`, `workspace.collapse`, `workspace.expand`, `window.remote.dismiss` | refused for A: Mac view state of a server window, already working on B | 10 |
| `zmx.attach`, `zmx.attach.group` | refused for A: they make a Mac viewer | 10 |
| `debug.appearance` | refused: UI-test seam | 10 |

Approved exceptions (Eugene, 2026-11-14): selection, search, copy and paste; focus, navigation, lead and resize;
Finder reveal and `keymap.run`; Mac app lifecycle commands.

## Post-Completion
**Manual verification**:
- a real Linux host: `session wait` from an agent, restart and pane kill, Terminate then undo and Reopen Closed,
  flag/tint set by a host agent shown on two Macs, a clicked dev-server URL opening the host's server,
  `show-image.sh` from a host pane rendering in its overlay
- a second Mac: attach, relaunch the viewing Mac (rows return), terminate from the viewer then reopen, a new split
  and scratch run on the origin, a cleared status stays cleared after a reconnect
- host reboot behavior of exit records (unsettled in the audit) checked against the restart and Ended paths
- TCC for a Live scratch (Task 5): in an isolated Debug instance a pane and a scratch, each in its own daemon, read the
  same passive statuses (microphone not determined, screen capture false, Accessibility false). Equal statuses do not
  show which process a prompt or grant is attributed to; repeat #574's microphone prompt from a daemon scratch.

Smells pre-check: skipped — non-Go project
