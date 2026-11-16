# Remote window on a Mac origin

## Overview
- File ▸ Open Remote Window… and `agtermctl window remote open HOST` accept a host that is a Mac running agterm,
  not only an agterm-server host. A Mac with one open window opens it at once; with more, the same picker
  asks which window.
- The remote window behaves like a server window for structure: its sidebar follows that Mac window live, and
  creating, renaming, moving, splitting, closing and terminating sessions, companions and workspaces, flags, tints and
  Recent Closed act on the origin Mac's window, in front of whoever sits there.
- Dialogs (asks, picks, page questions) follow today's Attach Remote presentation rules, unchanged. Eugene chose this
  scope on 2026-11-15; moving dialogs to the viewer on takeover is a separate follow-up.
- Today picking a Mac host ends in "a Mac app rather than agterm-server; a remote window needs agterm-server"
  (`agtermCore/Sources/agtermCore/RemoteCatalogMirror.swift:104`).

## Context (from discovery)
- Server catalog: `AgtermServerKit/ServerCatalog.swift` (projection, `CatalogStream` sink, heartbeat, hello
  deadline, adoption at :6-123), `ServerStreams.swift` (`CatalogHub`), `ServerActions+Receipts.swift` (op serving on
  `ServerActions` state); shared already in agtermCore: `CatalogHub.swift`, `CatalogFrames.swift`,
  `CatalogOperations.swift` (`adopt` at :79-86). The app target links agtermCore only (`project.yml:188-190`), not
  AgtermServerKit. Stream-host precedent: `PresentationStreamHost` (`PresentationStream.swift:8`),
  `OverlayJobStreamHost` (`OverlayJobStream.swift:8`).
- Mac attachability: `ControlServer+Zmx.swift:140-169` `localAttachableSessions`, `RemoteTree.swift:93-180`
  `RemoteTreeMerger`; window identity `WindowInfo.id` (durable, `WindowLibrary.swift:6-16, 613-618`); `window list`
  already reports `open` and `remote` (`ControlProjection.swift:884,910`).
- Viewer: `RemoteCatalogClient.swift` (version check, subscribe, retry, 35 s silence limit), `RemoteCatalogMirror.swift`
  (states, `versionRefusal`, hello check :186-190, reconcile :286), `RemoteCatalogActions.swift` (`prepare`/`send`/
  `request`, `RemoteOperation.words` :213-257), `AppStore+Catalog.swift` (`catalogBinding` hardcodes
  `originHeadless: true` at :293-300), `WindowLibrary+Remote.swift` (raise-existing by host at :19-33, `bindCatalog`
  at :36-47, `WindowSource{host, catalogID}` at :184-192), picker `agterm/AppActions+RemoteAttach.swift:71-93`,
  `ControlServer+RemoteCatalog.swift`, `HtmlBridge.swift:61-96` (fills `args.window` with the page's window).
- Mac dispatch: hand-off arm for `zmx.present` `ControlServer.swift:504-511`; remote/attached forwarding before
  dispatch `ControlServer.swift:543` (`remoteRoute`, `ControlServer+RemoteActions.swift:23-46`); receipt gate
  `ControlDispatcher.swift:16-19`; creation selects `ControlServer.swift:927-936`; workspace reveal
  `ControlServer+WorkspaceCommands.swift:14-22`; app-global Recent Closed `ControlServer+Recent.swift:5-35`; restore
  destination `WindowLibrary+RecentClosed.swift:69-86,112-124`; undo searches every store
  `WindowLibrary+RecentClosed.swift:41-43`; `RecentClosedItem` `RecentClosed.swift:25-45`.
- Refresh gaps on the Mac: cwd/title (`GhosttySurfaceView.swift:504-540`), split layout (`AppStore+Panes.swift:48-90`),
  scratch toggle (`AppStore+Panes.swift:671-676`) emit no tree event; surfaces are `ObservationIgnored`
  (`Session.swift:169,198,574`); mail relay publishes presentation mail only (`ControlServer+Presentation.swift:60-65`).
  `Session.ended` is set for a local row only by the headless `markSessionEnded` (`AppStore+Panes.swift:403-410`).
- Rules to read first: `.claude/rules/control-api.md`, `windows.md`, `menu-actions.md`, `sidebar.md`, `tests.md`.

## Decisions carried from the design draft
The design was reviewed with codex over three revisions and the plan by the plan-review agent; this plan carries both.

| Decision | Status | Reason |
|---|---|---|
| Only a headless server serves the catalog (`docs/plans/20261106-linux-remote-server.md:196-198`) | changed | Eugene asked for server parity on a Mac origin; that plan file stays unedited |
| Follow-only mirror, no structural writes | dropped | Eugene: an asymmetric window would confuse users |
| One menu item for both kinds of host, window picker step | kept | no new item; picker skips the question for one window |
| Old viewers kept out by `versions` nil in the `version` reply, new optional `macCatalog` advertisement | kept | an old viewer keeps today's final refusal instead of a retry loop |
| New `refused(reason, final)` frame; "window closed" retryable | kept | a socket close reads as a lost connection and retries forever |
| Every command carries the origin window; targets and destinations validated in it | kept | the hello does not scope later ssh commands |
| No incidental selection or reveal on the origin | kept | narrowed: closing the selected row still reconciles selection |
| Per-window Recent Closed with the existing restore-destination rule | kept | the Mac list is app-global; a moved workspace must not be recreated |
| Dirty seam: Observation for observed fields, explicit marks for backing, inventory, mail, history | kept | surfaces and zmx inventory are not observable |
| Receipt book shared in agtermCore; hub never evicted; receipts durable per window | changed | the catalog stream plumbing moves too, since the app does not link AgtermServerKit |
| Presenter transfer and pending-dialog migration on takeover | dropped | Eugene: separate follow-up; Attach Remote rules apply |
| Rows attached from a third Mac are left out of the catalog | kept | no chains |
| `zmx present` on the Mac accepts ended rows | dropped | a local Mac row is never ended |

## Development Approach
- **testing approach**: TDD - each task writes the failing tests for its contracts first, then the code.
- complete each task fully before moving to the next; make small, focused changes.
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task, success and error paths.
- **CRITICAL: all tests must pass before starting the next task** - no exceptions.
- **CRITICAL: update this plan file when scope changes during implementation.**
- run only the tests a change touches while working; the full gates run once at the end.
- keep existing server-window and Attach Remote behavior unchanged; a new viewer against an agterm-server host and an
  old viewer against a new Mac must behave as today.
- every task that changes a `public` agtermCore symbol keeps the `agterm-linux` downstream consumer building:
  defaulted parameters or overloads for protocol requirements, and a check of exhaustive switches over a new enum case.

## Testing Strategy
- **host-free**: `cd agtermCore && swift test --filter <Suite>`; suites live in `agtermCore/Tests/agtermCoreTests/`
  (protocol, projection, receipts, scope, Recent Closed, viewer state), `agtermCore/Tests/AgtermServerTests/`
  (server switched to shared code), `agtermCore/Tests/agtermctlKitTests/` (CLI parsing and requests).
- **hosted AppKit** in `agtermTests/`: `scripts/test-app.sh` takes no arguments, so a scoped run calls xcodebuild
  directly with its flags: `xcodebuild test -project agterm.xcodeproj -scheme agtermTests -destination 'platform=macOS'
  -derivedDataPath build/DerivedData -only-testing:agtermTests/<Class>/<test>` (after `scripts/setup.sh` and
  `xcodegen generate`).
- **gates at the end**: `swift test`, `make test-app`, `make lint`, each once.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix

## Solution Overview
- The origin Mac serves a catalog per window, with the window's durable id as `catalogID`, reusing the hub, frames,
  stream plumbing and receipt book from agtermCore. Its projection reuses the `zmx tree` attachability rule for one
  window.
- The viewer's existing remote window, mirror, client and actions serve both origins; the differences are the
  advertisement it reads, the origin window it saves and names on every command, and the origin kind it binds with.
- Presentation (pane lead, takeover cover, presenter grant, follower gate) stays as Attach Remote has it.

## Technical Details
- **Advertisement**: the Mac's `version` reply keeps `versions` nil and adds optional
  `macCatalog: {catalog, protocol}`. A new viewer accepts either `versions` (server) or `macCatalog` (Mac); an old
  viewer sees only nil `versions` and refuses as today, before subscribing. The Mac's hello and snapshot carry a real
  `CatalogVersions` (app version, `PresentationCodec.version`, `CatalogCodec.version`), which `CatalogHub.subscribe`
  and the mirror's hello check need; the `CatalogFrames.swift:3-4` doc changes to match.
- **Refusal texts**: a new viewer facing an old Mac says HOST runs an agterm without remote windows and needs this
  version or later; the strings saying a remote window needs agterm-server change wherever they now mislead:
  `RemoteCatalogMirror.swift:104`, `ControlActionsDefaults.swift:181`, `ControlDispatcher.swift:18`,
  `CatalogCommands.swift:8,50-53,61`, `WindowCommands.swift:142-148`, the picker prompt
  `AppActions+RemoteAttach.swift:73` ("Open a window for which host?"), `.claude/rules/control-api.md:199`; pinned
  tests `ControlDispatcherZmxTests.swift:296-299` and `CatalogOperationsTests.swift:130` follow.
- **Hello**: `CatalogHello` gains optional `window: String`. The Mac refuses a hello without one, or naming a window
  that is unknown, closed or remote, with `refused`.
- **Refusal frame**: `CatalogFrame.refused(reason: String, final: Bool)`. Final: Live sessions not active (judged by
  `ControlRestoreStatus` active), unknown window, version mismatch. Not final: window closed on the origin, which ends
  the stream with that reason; the viewer shows it in `RemoteConnectionStrip` and keeps its backoff.
- **Stream plumbing**: `CatalogStream` (sink, 10 s heartbeat, stale drop, no-hello deadline, inbound backpressure,
  adoption) moves from `ServerCatalog.swift:6-123` into agtermCore behind a `CatalogStreamHost` protocol, as
  `PresentationStreamHost` does; the server switches to it. The Mac's `handleConnection` gains a `catalog.subscribe`
  hand-off arm after the `zmx.present` arm (`ControlServer.swift:504-511`).
- **Receipt book**: op serving moves into agtermCore behind a host seam that supplies session resolution, page-row
  and scratch refusal and a checked save; the server and the Mac each implement it.
- **Window discovery**: the picker reads the origin's `window list --json` (`open`, `remote` exist) and lists open
  local windows, empty ones included.
- **Command scope**: for a Mac origin, `RemoteCatalogActions.run`/`send`/`request` and the `catalog op` lookup add
  `--window <origin window id>` (on the origin that names its own local window). The Mac intercepts an op-bearing
  request ahead of the `remoteRoute` forwarding at `ControlServer.swift:543`, keeping the `waitsOnNetwork` worker
  hand-off for restart and companion creation; it resolves the store from `--window` and refuses anything outside it:
  every batch target (not only the first), destinations, move anchors, companion parents, undo ids (scoped to that
  window's pending closes, not `undoPendingClose`'s search of every store), `session flag clear` (that window only),
  and ids of rows the catalog hides (rows attached from a third Mac) when used as a target or anchor. A workspace
  delete from a mirror is refused while the workspace holds rows the catalog hides, with a reason naming how many and
  saying to delete it on that Mac (Eugene, 2026-11-15); workspace flag and tint act on the workspace as the same command
  does locally there. An op or lookup naming a window that is closed now is refused with the non-final reason.
- **Origin read-back**: the origin window's tree node reports how many Macs mirror it (`catalogViewers`, omitted when
  zero); nothing is shown on screen (Eugene, 2026-11-15).
- **Origin selection**: catalog ops create with no select and no workspace reveal, and undo and Recent Closed reopen
  without selecting or reporting a selection (`AppStore.preservingSelection` around them); close/terminate of the selected row
  runs the normal reconciliation. A creation op that executed answers ok with the created id, never a refusal. A
  terminal creation waits, bounded, for the new row's panes to be eligible so its receipt is `applied` at a revision
  that includes the row; if the row is still starting at the bound, or its command exited and the row closed first,
  no revision moved and the receipt is `noop`, and the row appears later or not at all, as the same create behaves
  locally.
- **Targets**: a targeted catalog op names its target; only `session.new`, `workspace.new`, `session flag clear`,
  undo and Recent Closed take none, since an omitted target resolves the origin's own selection.  Page and workspace creation have no panes and answer at once.
- **Recent Closed**: `RecentClosedItem` gains an optional window id (`decodeIfPresent`) recorded at close. The
  catalog's `recent` lists that window's own items, never the merged remote ones; remote open restores into that
  window through the existing destination rule and refuses an entry whose workspace or parent now lives in another
  window ("reopen it from that window"); remote clear clears only that window's items. Entries saved before this
  change carry no window: they appear in no catalog list and stay in the Mac's own File ▸ Open Recent, which remains
  app-global.
- **Projection**: workspaces (id, order, name, tint) and session fields from the window's model; panes and scratch
  joined from the zmx inventory (claimed and running, as `zmx tree`) and the Mac's zmx endpoint. Rows with
  `remoteHost` are left out. A terminal row is left out until its primary first runs (deferred spawn, first attach),
  never listed paneless, which the viewer would read as ended. A listed row keeps every pane it has on the origin, in
  origin order, never compacted: a pane whose daemon is not running and not restarting carries `CatalogPane.held`
  (optional, set only by a Mac origin), and the row is `.ended` only when every pane is held. A pane being restarted
  by `session restart` stays listed through the kill and rebuild. The per-window listed set drops a row that leaves
  the store, so a Recent Closed reopen waits for its new daemon. A restored hidden split is listed from the inventory
  without a local attach. Page rows are listed. Shared shape-building code in agtermCore where the server and the Mac
  agree.
- **Inventory reads**: `zmx list` runs off the main actor only when the window's evidence can change: at subscribe,
  before and after a receipt op, when the window's pane identity set changes, at a surface slot replacement, a lead
  role change, a held exit, and a restart's begin and end; cached otherwise, never per publish and never on a poll.
  Known limitation: a hidden split nobody attaches on the origin, whose shell exits on its own, stays listed as
  running until the next trigger, indefinitely; `zmx tree` has no such gap because it rereads per request.
- **`zmx present`**: the Mac's handler also accepts page rows, as the server's does; presentation ownership is
  unchanged.
- **Publication**: one coalesced per-window dirty mark, separate from persistence. Producers: Observation tracking
  over the projection's observed fields (tree, split layout, scratch, cwd, title); explicit marks at surface backing
  changes, inventory reads (above) that change a claimed/running entry of the window, the mail relay, and Recent Closed
  changes. A receipt-bearing op refreshes synchronously before and after it applies.
- **Hub lifetime**: the epoch is `ControlServer.originEpoch`. A window's hub is created on first use (a subscribe, an
  op or a lookup, none of which needs a subscriber) and kept until the app quits. Receipts are saved with the window's
  store file, bounded like the server's op table, and adopted into the epoch when the hub is created
  (`CatalogOperations.swift:79-86`).
- **Window close and reopen on the origin**: closing the window drops its `AppStore`; the retained hub, dirty tracking
  and receipt persistence detach from it, the stream ends with the non-final "window closed" refusal, and reopening
  the window rebinds all three to the recreated store with receipts adopted from its file.
- **Viewer binding**: `catalogBinding` takes `originHeadless` from the advertisement. `WindowSource` gains
  `originWindow` (`decodeIfPresent`), saved at open and sent in every hello, so a restored window reconnects to the
  same origin window after the viewer relaunches. `newRemoteWindow` takes the origin window and raises an existing
  window by host plus origin window before any snapshot; a Mac-origin window is named "HOST · origin window name".
  The tree's window node reads back origin kind and origin window, omitted when nil.
- **Selector**: `window remote open HOST [--origin-window W]`, wire field `originWindow`, distinct from the
  local-window `window` field the HTML bridge fills. Against a Mac with one open local window it opens it; with
  several it fails with an ambiguity error listing them and asking for `--origin-window` (the menu asks through its
  picker instead); with none, "HOST has no open window"; an unknown or remote one fails naming it. A server host
  rejects `--origin-window`. An older app that drops the field answers as today, which the read-back tells apart.
- **`catalog op` lookup**: `CatalogCommands.swift` `Operation` takes `BasicOptions` only (:77), so it gains
  `--window`, with its `ControlArgs`, dispatcher arm and `ControlActions` signature (defaulted for downstream).
- **Security**: the new input is catalog frames and op-bearing commands on the origin's control socket, reachable
  only over ssh as the same user, who can already run every `agtermctl` command there. New: one window's tree as a
  stream, and receipts. Bound: every op is scoped to the window it names; no incidental selection change.

## What Goes Where
- **Implementation Steps**: code, tests and documentation in this repository.
- **Post-Completion**: manual two-Mac verification.

## Implementation Steps

### Task 1: Shared catalog protocol, stream, receipts and per-window Recent Closed in agtermCore

**Files:**
- Modify: `agtermCore/Sources/agtermCore/CatalogFrames.swift`, `CatalogHub.swift`, `CatalogOperations.swift`,
  `ControlProtocol.swift`, `ControlDispatcher.swift`, `ControlActions.swift`, `ControlActionsDefaults.swift`,
  `RemoteCatalogMirror.swift`, `RecentClosed.swift`, `WindowLibrary+RecentClosed.swift`
- Modify: `agtermCore/Sources/agtermctlKit/CatalogCommands.swift`, `WindowCommands.swift` (texts)
- Move: `CatalogStream` and op serving out of `agtermCore/Sources/AgtermServerKit/ServerCatalog.swift`,
  `ServerActions+Receipts.swift` into agtermCore; the server implements the new host seams
- Tests: `agtermCore/Tests/agtermCoreTests/` (frames, hub, mirror, receipts, Recent Closed),
  `agtermCore/Tests/AgtermServerTests/` (server on shared code), `agtermCore/Tests/agtermctlKitTests/` (catalog op)

- [x] write failing tests: `macCatalog` advertisement round-trip and old-decoder tolerance; hello `window`; `refused`
      frame encode/decode and an old decoder stepping past it; mirror accepts a Mac hello with real `CatalogVersions`;
      new refusal texts (pinned tests updated)
- [x] write failing tests: shared `CatalogStream` heartbeat, stale drop and no-hello deadline with an injected clock;
      shared receipt book (applied, noop, refused, repeated op id, fencing, adoption into a new epoch)
- [x] write failing tests: Recent Closed window ownership (recorded at close, legacy entry decodes with no window and
      is in no catalog list, per-window list excludes merged remote items, per-window clear, cross-window
      workspace/parent refusal); `catalog op --window` parser, request and dispatcher arm
- [x] implement the protocol fields and frame, advertisement check and texts, shared stream and receipt book with
      host seams (server switched, behavior unchanged), Recent Closed ownership, `catalog op --window`
- [x] downstream check for every changed `public` symbol and the new `CatalogFrame` case
- [x] `cd agtermCore && swift test` for the touched suites passes, the server's catalog suites included
- ⚠️ the `catalog` CLI help (`CatalogCommands.swift`, `WindowCommands.swift`) and the docs quoting the old receipt
  refusal still say only agterm-server serves a catalog; they change with Task 2 and Task 4, once a Mac does

### Task 2: The origin Mac serves one window's catalog

**Files:**
- Modify: `agterm/Control/ControlServer.swift`, `ControlServer+Zmx.swift`, `ControlServer+Presentation.swift`,
  `ControlServer+Recent.swift`, `ControlServer+WorkspaceCommands.swift`, `ControlServer+RemoteActions.swift`,
  `agterm/Ghostty/GhosttySurfaceView.swift`, `agtermCore/Sources/agtermCore/WindowLibrary.swift`, `ControlActions.swift`,
  `ControlActionsDefaults.swift`, the AppStore dirty-mark sites
- Create: `agterm/Control/ControlServer+MacCatalog.swift` (serving), the one-window projection in agtermCore
- Tests: `agtermCore/Tests/agtermCoreTests/` (projection, dirty seam, scope rules), `agtermTests/` hosted
  (`ControlServerMacCatalogTests.swift`: socket-level subscribe and op end to end, close/reopen)

- [x] write failing tests: one-window projection on an injected inventory (deferred startup omitted, running lists,
      restart keeps it listed, held primary with a live split keeps both in origin order, held split with a live
      primary, both held is `.ended` with both panes, Recent Closed reopen waits for its new daemon, restored hidden
      split listed, empty window, empty workspace, page and scratch rows, `remoteHost` rows left out, non-Live refusal
      by active eligibility)
- [x] write failing tests: dirty seam fires for tree edits, split layout, scratch toggle, cwd, title, backing change,
      inventory change, mail count, Recent Closed change; coalesced per window; receipt ops refresh synchronously;
      creation op's receipt revision includes the new row once eligible; a row still starting at the bound and a row
      whose command exited before eligibility both answer ok with the id (`noop`, no revision moved); page and
      workspace creation answer at once
      ⚠️ hosted tests run no zmx, so a creation whose row becomes eligible (`applied` at the row's revision) is checked
      in the two-Mac run under Post-Completion
- [x] write failing tests: op scope table (every batch target, destination, anchor, companion parent, undo id,
      flag clear, hidden third-Mac row as target or anchor, workspace delete refused while it holds hidden rows with
      the count in the reason, workspace flag and tint applied, closed window), `catalogViewers` read-back counts
      subscribers and is omitted at zero, ops
      never reach `remoteRoute` forwarding; every `RemoteOperation.words` plus `--window <id>` parses in agtermctlKit;
      no incidental selection or reveal, selected-row close still reconciles; an op before any subscribe
- [x] write failing hosted tests: `catalog.subscribe` and `catalog.op` over the socket end to end; close the origin
      window (stream ends with non-final "window closed", receipts kept on disk), reopen it (hub, dirty tracking and
      receipt persistence rebound to the new store; a repeated op id answers its recorded outcome; a later edit
      publishes)
- [x] implement the hand-off arm, `catalogSubscribe` and `catalogOperation` on the Mac, per-window hubs on
      `originEpoch` kept until quit, durable per-window receipts, op interception before :543, the dirty seam,
      no-select creation with the bounded eligibility wait, window-scoped Recent Closed and undo, window-closed stream
      end, `zmx present` accepting page rows, `version` with `macCatalog`
- [x] downstream check for changed `public` symbols (`ControlActions`, `catalogOperation` signature)
- [x] focused agtermCore and hosted tests pass

### Task 3: The viewer opens and drives a Mac-origin remote window

**Files:**
- Modify: `agtermCore/Sources/agtermCore/RemoteCatalogClient.swift`, `RemoteCatalogActions.swift`,
  `AppStore+Catalog.swift`, `RemotePresentationState.swift`, `WindowLibrary+Remote.swift`, `ControlProtocol.swift`
  (`originWindow` arg), `ControlDispatcher.swift`, `ControlActions.swift`, `ControlProjection.swift` (read-back),
  `HtmlBridge.swift`
- Modify: `agterm/AppActions+RemoteAttach.swift` (picker), `agterm/Control/ControlServer+RemoteCatalog.swift`,
  `agterm/Views/RemoteConnectionStrip.swift`, `agtermCore/Sources/agtermctlKit/WindowCommands.swift`
- Tests: `agtermCore/Tests/agtermCoreTests/` (client, actions, binding, library, bridge),
  `agtermCore/Tests/agtermctlKitTests/` (`--origin-window`), `agtermTests/` (`AppActions+RemoteCatalogTests.swift`,
  remote window open end to end)

- [x] show the picker's window step and the strip's non-final reason in an isolated Debug instance before their tests
- [x] write failing tests: client accepts a Mac advertisement, sends the saved origin window in the hello, stops on a
      final `refused`, keeps backoff with the reason shown on a non-final one; every Mac-origin command and lookup
      carries `--window`; `originHeadless` follows the advertisement (scratch daemon naming, ask and pick waits)
- [x] write failing tests: `WindowSource.originWindow` saved and restored (old index decodes; relaunch reconnect sends
      the saved window); raise-existing by host plus origin window before any snapshot, two windows of one Mac side
      by side with distinct names; picker skips the window step for one window and lists all open local windows
      otherwise
- [x] write failing tests: `window remote open HOST --origin-window W` through protocol, dispatcher, CLI and end to
      end; ambiguity error, "no open window", unknown or remote selector, server host rejecting the option; the HTML
      bridge leaves `originWindow` alone; an older app dropping the field; read-back of origin kind and origin window,
      omitted when nil
- [x] ➕ write failing tests: held panes. A held pane gets `RemoteSession.endedCommand` in its own slot with no
      attach, roles unchanged; an `.ended` row carrying held panes keeps both slots on a cold snapshot and on reconnect
      (`insertCatalogSession` adds the split only for `.live` today, and the ended update branch returns before pane
      reconciliation); a pane whose `held` clears gets a fresh attach; `handlePaneExit`, respawn and reconnect never
      attach a held pane, in a mixed live/held row included (a Mac lists a scratch only while it runs, so none is held)
- [x] ➕ refuse at open (Eugene, after the demo): a Mac's `version` carries `macCatalog.live`; with it false the window
      step and `window remote open` refuse with the hello's notLive reason and create no window
- [x] ➕ lead on open (Eugene, after the demo): a Mac window's rows take the zmx lead on a user's open (first snapshot
      after `newRemoteWindow` created or reopened it) and for rows this Mac creates (convert's new parent included);
      never on reconnect, relaunch restore, origin-created rows or a server window. The origin's `catalog.subscribe`
      reads the panes first and refuses a failed read, so that first snapshot is complete; a pane whose attach started
      unclaimed takes the lead on its first role report
- [x] implement the client, actions, binding, `WindowSource.originWindow`, library keying and naming, picker step,
      `originWindow` arg and `--origin-window`, read-back, per-pane held handling
- [x] confirm a server host takes exactly today's path (no window step, no `--window`)
- [x] downstream check for changed `public` symbols (`windowRemoteOpen` overload with a default, `WindowSource`,
      `ControlRemoteWindow.init`, client and actions)
- [x] focused agtermCore and hosted tests pass

### Task 4: Docs, skill and gates

**Files:**
- Modify: `site/docs.html`, `site/commands.html`, `plugins/agterm/skills/agterm/` (SKILL.md, reference),
  `.claude/rules/control-api.md`, `.claude/rules/windows.md` (rule at :33), `.claude/rules/menu-actions.md`,
  `ARCHITECTURE.md`, `agtermCore/Sources/agtermCore/EventFormatter.swift` (if events change)

- [ ] ➕ `site/docs.html` "Who leads a pane": a Mac remote window takes the lead when opened and for rows this Mac
      creates; a reconnect does not
- [ ] `site/docs.html` remote window section: Mac hosts, the window step, Live sessions requirement, dialogs follow
      Attach Remote rules, rows attached from a third Mac not shown, Recent Closed per window
- [ ] `site/commands.html` and the bundled skill updated for `--origin-window`, `catalog op --window` and the read-back
- [ ] mechanism (advertisement, refusal frame, stream and receipt seams, dirty seam, op scope, reversed server-plan
      decision) recorded in `control-api.md`, `windows.md` and `ARCHITECTURE.md`
- [ ] verify requirements in Overview are met; server-window and Attach Remote behavior unchanged
- [ ] gates once: `cd agtermCore && swift test`, `make test-app`, `make lint`; `lsappinfo list | grep -A4 agterm.debug`
      after the hosted run
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification**
- Two real Macs, both on this build, origin in Live sessions mode: open a one-window and a two-window origin, create,
  rename, move, split, close and terminate from the mirror and watch the origin window follow, then edit on the origin
  and watch the mirror follow; close the origin window and reopen it; quit the origin app; relaunch the viewer.
- An `ssh localhost` origin reaches the default socket of whatever agterm runs there, which is the live terminal; a
  same-Mac check needs an origin instance whose state directory the ssh command resolves, never the live one.
- An old viewer against a new Mac and a new viewer against an old Mac both show a final refusal.

**Follow-up**
- Dialog ownership handoff between Macs (presenter transfer with revocation, moving open asks and picks), which also
  closes the same gap in plain Attach Remote.
