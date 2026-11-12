# Remote log follow and text-page controls

## Overview

A text page shown for a remote session is a static copy today. A session attached from another Mac or served by
an agterm-server Linux host gets no log page (`--tail`, `--follow-file`, a clicked log); `session.overlay.search`,
`.wrap` and `.changes` are refused with `remote page`, and `.follow` finds no log page. On the presenting Mac the
replica page's own bar searches and wraps, but nothing is recorded or read back.

This plan makes a remote text page behave like a local one: it follows a log's end, searches, wraps and steps a
diff's changes, from its own bar and from the control API on the origin and on the presenting Mac, for a Mac origin
and a Linux origin. agterm-server also gets page sessions: the HTML file and URL page rows a Mac has, shown in a
Mac's remote window and attachable from another Mac. Page rows hold only HTML file and URL pages on both hosts;
markdown, text and document page rows are a separate local feature, not part of this plan.

Smells pre-check: skipped — non-Go project

## Context (from discovery)

- `PresentationFrames.swift`: `PresentationPage`, `PresentationPageSource.text(path:line:)`, `PresentationPageAction`,
  `PresentationPageCommand`, `PresentationPageState` (title, address and error capped).
- `PageServeFrames.swift`/`PageServeStream.swift`: page channel frames (`PageServeFrame`); `resource` returns a whole
  file under `TextPage.maxBytes`; `head(id:mimeType:)` carries only a MIME type; `PageServeClaim` carries only
  `source` and `links`, built at `ServerStreams.swift:135` too.
- `RemotePageResources.swift`: `.text` serves `ContentResource(maxBytes: TextPage.maxBytes)`.
- `TextProbe.loadLog` and `BoundedFile.readTail` return "unchanged" or a bounded tail snapshot with stamp;
  `FileStamp` is not `Codable`, `TextProbe.LogRead` has no public init.
- `agterm/Views/LogFollower.swift`: synchronous `Reader`; reads already run detached with a read sequence and pause
  epoch, and an overtaken read is dropped.
- `agterm/Views/TextPageBridge.swift`: `make` guards `case .text`; owns follower, search, wrap, changes.
- `HtmlOverlayRegistry.swift:600-609`: a replica text page is built once from `fetchReplica` with no bridge;
  `HtmlReplicaLink` holds `fetch`, `bridge` and `ownPageCommandsLocal`.
- A replica's source is `.replica(path:, content: .text(line:))` (`AppStore+ReplicaPage.swift:37`), also for page rows
  from another Mac (`addReplicaPageRoot`, `addReplicaPageCompanion`). Every text-page store path guards on `.text`:
  `textSearchPage`, `setTextSearch`, `textChangesPage`, `setTextChangesReport`, `setTextWrap(_ id:)`, and
  `setTextLogFollowing` refuses `.replica`.
- `ControlServer+RemotePage.swift:147-190`: `applyReplicaPageCommand` advances `appliedSeq` for every action and only
  logs a refusal; `flushReplicaStates` coalesces state reports to the next main-queue turn.
- `AppStore+RemotePage.swift`: `presenterShows` checks `page.content`, `page.document`, `page.forward`;
  `offerPendingPage` re-offers held pages; `receiveRemotePageFrame` emits `tree.changed` on any applied change.
- Control: follow and wrap are sync (`ControlActions.swift:178-183`, `ControlDispatcher+Overlay.swift:131-148`, routed
  from `ControlDispatcher.swift:447-451`); search and changes are async. Both hosts run a command inline on the accept
  thread (`ControlServer.handleConnection`, `ControlServer.swift:454`; `ServerControlSocket.swift:87`); only the Mac's `waitsOnNetwork` list leaves it.
- `ControlServer+TextPage.swift:16` `textLogRefusal`; `:27` a clicked log on a remote pane opens plain.
- agterm-server: `ServerActions+Overlay.swift:41` refuses every log page; `checkedPage` reads text whole;
  `ServerStreams.clickedPage` maps the route alone; `ServerCommandPolicy` does not admit follow/search/wrap/changes,
  which fall to `ControlActionsDefaults`' unsupported replies. The server uses the shared `AppStore` remote-page path.
- `ControlErrors.swift:84` `logRemote` names "another Mac", wrong for a Linux origin.
- Existing tests asserting the refusals: `ControlServerTextPageTests.swift:100`, `ServerActionsOverlayTests.swift:76`.

## Development Approach

- **testing approach**: Regular (code first, then tests in the same task)
- complete each task fully before moving to the next; every task adds or updates tests
- all tests must pass before starting the next task
- run only the touched tests while working (`swift test --filter`, `-only-testing:`); full gates run once in the last
  task
- an existing test asserting a refusal this plan removes is rewritten to the capability split, never deleted
- update this plan when scope changes

## Testing Strategy

- host-free `agtermCore` tests for frames, channel frames, store state, refusals, emission and server actions
- hosted `agtermTests` for the bridge, replica pages and control-server routing, with `RemotePageFakes`
- no UI tests: the page bar is the local one, and every remote path is covered host-side

## Decisions carried

| Decision | Source | Here |
|---|---|---|
| Log request and live `logState` ride the model, not `HtmlSource` | #899 plan | kept; the page frame carries an optional log request |
| `.text(path:line:)` associated values unchanged | #899 plan | kept, so the agterm-linux fork's matches compile |
| Follower polls once a second, only while following and on screen | #899 plan | kept, on the presenting Mac |
| `setTextLogReport`/`setTextSearchReport` never emit; follow and query changes emit `tree.changed` | #899 plan | kept on both Macs, wrap added as locally |
| "Remote stays as today" | #899 plan | changed: CLAUDE.md remote-parity rule |
| A replica page is refused `no text page` | #899 plan | changed: a replica text page is controlled on the presenter, same rule |
| A replica text page's field and keys report and read back nothing | #899 plan | changed: recorded and mirrored to the origin, same rule |
| A replica's wrap stays unrecorded, unreported, dropped by a rebuild | control-api.md | changed: recorded, reported, kept across rebuilds, same rule |
| Wrap and diff change-stepping on remote pages | Eugene, 2026-11-12 | included |
| Page rows hold only HTML file and URL pages | `ControlDispatcher+Companions.pageRowOptions` | kept; content page rows are a local feature outside this plan |
| agterm-server has no page sessions | Linux server plan | changed: Eugene, 2026-11-12 |

## Solution Overview

The presenting Mac renders and owns the live page state, as it already owns the web view. The origin owns the file.

- **Reads.** A new channel request reads the claimed log's raw tail through `BoundedFile.readTail`, with the caller's
  last stamp; the presenter builds the snapshot with `TextProbe.LogRead(_:tail:)`, the function `loadLog` uses, so
  rename, truncate, delete and binary or partial-UTF-8 tails keep `LogTail`'s semantics. No offset protocol and no
  push.
- **Presenter.** A replica text page, overlay or page row, gets a `TextPageBridge` like a local one, with its reads
  injected. A plain text page loads through the existing resource request. A log page loads only through the new
  request: its first load, every tick and an explicit reload while paused, so a log over `TextPage.maxBytes` opens.
  The store's text-page paths accept `.replica(_, .text)`, so the presenter's own control commands act on the replica
  as on a local page, and every change reaches the origin through the page state.
- **Origin control.** Follow, search, wrap and changes on a remote slot travel as new page actions. Each gets a
  correlated result frame that also carries the page's text state; the origin applies that state, then replies, so
  `tree` read after the reply already shows it.
- **Gating.** One capability kind, `page.text`, advertised both ways. Without it on both ends, today's behavior stays:
  log opens and the four commands are refused with a message that names the remote session, not "another Mac".
- **Linux origin.** The server drops its unconditional refusal, probes logs through the tail path, marks clicked logs
  when the presenter can follow them, carries the log request in `PageServeClaim`, and admits and handles the four
  commands through the shared store path.

## Technical Details

- `PresentationPage.textLog: TextLog?`, the existing model type (tail lines, following), omitted for a plain page.
- `PresentationTextState { following: Bool?, log: TextLogReport?, query: String?, revision: Int, matches: Int?,
  current: Int?, wrap: Bool, changes: TextChanges? }`. `TextLog`, `TextLogReport`, `TextChanges` and
  `BoundedFile.FileStamp` gain `Codable`; `ControlToggleMode` gains raw values `on|off|toggle`; `TextProbe.LogRead`
  gains a public init. The query is capped like `PresentationPageState`'s strings.
- `PresentationPage.textSeed: PresentationTextState?` carries following, query and wrap on a re-offer, built from the
  latest mirrored state, never from the open's initial options. The presenter applies it before its first render and
  first state report, so an empty first report cannot erase it.
- `PresentationPageState.text: PresentationTextState?` mirrors the presenter's text state.
- `PresentationPageAction` adds `follow`, `search`, `wrap`, `changes`; `PresentationPageCommand` adds optional
  `toggle: ControlToggleMode?`, `query: String?`, `step: String?` (`next`/`prev`/`close`).
- `pageResult { page, seq, ok, text?, error?, state: PresentationTextState? }`, presenter to origin, sent once per new
  action and never coalesced; text and error are capped. `PresentationHub.receive`, the Mac's `receivePresenterFrame`
  (`ControlServer+Ask.swift`) and `ServerStreams.receivePresenterFrame` route it explicitly: both end in `default:`, so
  the compiler would not catch a missing route.
- The origin waits for `pageResult` inline on the accept thread on both hosts, bounded by
  `PresentationPageResult.deadline` (5 seconds), and answers `presenter did not answer` past it; the wait also settles
  on page end, channel loss or presenter change. Adopted presentation streams have their own readers, so the wait
  does not block the result it waits for.
- Ordering: the origin's text actions on one page run in sequence order on the presenter (`applyReplicaPageCommand`),
  each awaited before the next starts and each resolving its page when it runs, so a replaced page is never touched.
  Calls made on the presenting Mac itself, its socket, page bridges and the page's own field and keys, stay on their
  existing paths: each step is one script call, so no source can tear another's step, and the revision and report
  checks guard the rest, as locally.
- A completed step commits its result before `pageResult` is built: `TextPageBridge.step` and `stepChange` write
  the counts, the current match or change, and a following log's pause into the model, so the captured state never
  depends on the order of the page's script messages.
- Existing actions keep advancing `appliedSeq` as today; only the four new actions answer through `pageResult`.
- `setSessionOverlayFollow` and `setSessionOverlayWrap` become async in `ControlActions`, its defaults, the dispatcher
  (async helpers beside `dispatchSessionOverlaySearch`, routed with `.sessionOverlaySearch`) and their callers.
- Channel frames: `PageServeFrame.logTail(id:, stamp:)` (`log.tail`, stamp omitted when nil), answered by
  `logUnchanged(id:)` (`log.unchanged`), by `logHead(id:, stamp:, offset:)` (`log.head`) followed by the raw tail
  bytes as `chunk`s and `end` (an empty file included), or by the existing `failure`: `not a log page` for a claim that
  is not a `.text` page with a log request, `file cannot be read` for a missing or unreadable file, which the page
  shows as waiting. The bytes are `BoundedFile.readTail(maxBytes: TextPage.maxTailBytes)`'s, the extra leading byte
  included, so the presenter's snapshot is the one a local page would build.
- Query revisions: the presenter assigns them; the origin stores what it is told and never increments.
- A toggle is applied on the presenter, and the result reports the resulting value.
- One-shot steps are never replayed after a rebuild, reconnect or re-offer; following, query and wrap are restored
  through `textSeed`.
- Follow, query and wrap transitions emit `tree.changed` on both Macs, as `setTextWrap` does locally; log, search and
  changes counts never emit.
- `presenterShows` requires `page.text` for a page carrying `textLog`. A headless origin holds such a page until a
  presenter listing `page.text` is connected; an open while only an older presenter is connected is refused with the
  reworded remote message.
- Server page sessions: `CatalogSessionFields.page: CatalogPage?` (`kind`, `identity`) and `CatalogHello.pageRows:
  Bool?`; an older viewer gets a filtered catalog whose revisions stay contiguous through `catalog.skip` deltas.
  A page row is viewed through `session.companion.page.attach` on the server, one claim per view, as a Mac page row
  attached from another Mac is.

## Implementation Steps

### Task 1: Frames, wire types and capability

**Files:**
- Modify: `agtermCore/Sources/agtermCore/PresentationFrames.swift`
- Modify: `agtermCore/Sources/agtermCore/PresentationHub.swift`
- Modify: `agtermCore/Sources/agtermCore/RemotePresentationClient.swift`
- Modify: `agtermCore/Sources/agtermCore/HtmlOverlay.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlModes.swift`
- Modify: `agterm/Control/ControlServer+Ask.swift`
- Modify: `agterm/Control/ControlServer+RemotePage.swift`
- Modify: `agtermCore/Sources/AgtermServerKit/ServerStreams.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/PresentationFramesTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/PresentationHubTests.swift`

- [x] check the agterm-linux fork (`gh` code search with `fork:true`, or a shallow clone in `/tmp`) for exhaustive
      switches over `PresentationPageAction` or `PresentationFrame.Body`; report any to Eugene before adding cases
- [x] add `PresentationHub.pageTextKind = "page.text"` and advertise it from both roles
- [x] add `PresentationTextState`, `PresentationPage.textLog` and `textSeed`, the four actions and their command
      fields, the `pageResult` body and `PresentationPageState.text`, with the string caps
- [x] make `TextLog`, `TextLogReport` and `TextChanges` `Codable`; give `ControlToggleMode` raw values
- [x] update `PresentationFrame.Body.kind`, `init(from:)`/`encode`, `RemotePresentationClient`'s switch and the
      app's page command handler; route `pageResult` explicitly in `PresentationHub.receive` and both
      `receivePresenterFrame`s; new actions answer a not-supported result until Task 5, without advancing `appliedSeq`
- [x] write round-trip tests, nil omission, decoding of frames without the new fields, and the string caps
- [x] write tests that an unknown action from a newer peer is not decodable as an old one, and that the hub admits
      `pageResult`
- [x] run tests - must pass before next task

### Task 2: Log tail frames on the page channel

**Files:**
- Modify: `agtermCore/Sources/agtermCore/PageServeFrames.swift`
- Modify: `agtermCore/Sources/agtermCore/PageServeStream.swift`
- Modify: `agtermCore/Sources/agtermCore/BoundedFile.swift`
- Modify: `agtermCore/Sources/agtermCore/TextProbe.swift`
- Modify: `agtermCore/Sources/AgtermServerKit/ServerStreams.swift`
- Modify: `agterm/Control/ControlServer+PageServe.swift`
- Modify: `agterm/Control/RemotePageChannel.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/PageServeFramesTests.swift`
- Modify: `agtermCore/Tests/AgtermServerTests/ServerStreamsTests.swift`
- Modify: `agtermTests/ControlServerPageServeTests.swift`
- Modify: `agtermTests/RemotePageChannelTests.swift`
- Modify: `agtermTests/RemotePageFakes.swift`

- [x] make `FileStamp` `Codable`; give `TailRead` and `TextProbe.LogRead` public inits, `LogRead(_:tail:)` building
      the snapshot `loadLog` returns
- [x] add the `logTail` request and its answers; update `PageServeStream`'s and the frame's `id` switches
- [x] `PageServeClaim` carries the log request with a nil default, wired on the Mac's `PageServeHost` claim and at
      `ServerStreams.swift:135`
- [x] serve the raw tail through `BoundedFile.readTail` for a log claim only, chunked under `maxChunkBytes`
- [x] add `RemotePageChannel`'s `logTail` client method and update its switches
- [x] write serving tests in `ServerStreamsTests` (the shared `PageServeStream`, host-free): unchanged stamp, changed
      file, empty file, missing file, truncation, a log over `TextPage.maxTailBytes`, refused for a non-log and a
      non-text claim, cancellation mid-answer; one hosted test for the Mac claim carrying the log. Binary and clipped
      tails are snapshot cases, built by the presenter through `LogRead(_:tail:)`, which `TextProbeTests` cover
      through `loadLog`
- [x] write frame round-trip tests and `RemotePageChannel` client tests
- [x] run tests - must pass before next task

### Task 3: Async reader for LogFollower

**Files:**
- Modify: `agterm/Views/LogFollower.swift`
- Modify: `agterm/Views/TextPageBridge.swift`
- Modify: `agtermTests/LogFollowerTests.swift`

- [x] make `Reader` async; the default reader detaches `TextProbe.loadLog` itself and `readLog` awaits `read`
- [x] write a test where pause, and separately stop, happen while an async reader is suspended mid-read
- [x] run tests - must pass before next task

### Task 4: Replica text pages on the presenter

**Files:**
- Modify: `agterm/Views/TextPageBridge.swift`
- Modify: `agterm/Views/HtmlOverlayRegistry.swift`
- Modify: `agterm/Views/HtmlReplicaLink.swift`
- Modify: `agterm/Control/ControlServer+RemotePage.swift`
- Modify: `agterm/Control/ControlServer+TextPage.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+HtmlOverlay.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+ReplicaPage.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/HtmlOverlayTests.swift`
- Modify: `agtermTests/TextPageRenderingTests.swift`
- Modify: `agtermTests/HtmlOverlayRegistryTests.swift`
- Modify: `agtermTests/ControlServerTextPageTests.swift`
- Modify: `agtermTests/RemotePageFakes.swift`

- [x] widen the store's text-page paths to `.replica(_, .text)` (through `HtmlSource.kind == .text`):
      `textSearchPage`, `setTextSearch`, `textChangesPage`, `setTextChangesReport`, `setTextWrap`; follow answers
      `no log page` on a static text replica and keeps the replica refusal for any other replica
- [x] `TextPageBridge` takes a replica text page with injected `Reads` (text and log), as a failable `init(for:)`;
      `HtmlReplicaLink` gains `logTail` over `RemotePageChannel.logTail`; a read cancelled by a hide is no answer
- [x] build a replica text page through the bridge, replacing the one-shot replica builder for `.text`; state reports
      go to the origin only for an overlay slot; a log page's first load, ticks and paused reload use `logTail`, a
      plain page the resource request; a theme change redraws from what the page shows, as locally
- [x] install `textLog` and `textSeed` into the replica overlay (`AppStore+ReplicaPage.swift`) and populate
      `replicaPageState.text`; follow polls only while following and on screen
- [x] report every change on the presenter in the page state: the widened setters reach `onReplicaPageChanged`
      through `updateHtmlOverlay`
- [x] write store tests: each widened path accepts a replica text page and still refuses a non-text replica
- [x] write bridge and registry tests: replica log page over 4 MB opens from its tail without a resource fetch,
      follows the file, a hide during a suspended channel read leaves the report alone and showing catches up, a
      log the origin cannot read waits; a seed applies before the first state report (store test). Theme rebuild,
      paused reload and channel loss run the same bridge and page code the local and replica tests already cover
- [x] write control tests on the presenter: `session.overlay.search|follow|wrap|changes` on a replica answer as on a
      local page and the change appears in the reported state
- [x] run tests - must pass before next task

### Task 5: Origin control of remote text pages

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore+RemotePage.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+HtmlOverlay.swift`
- Modify: `agtermCore/Sources/agtermCore/RemoteOverlays.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlErrors.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlActions.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlActionsDefaults.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher+Overlay.swift`
- Modify: `agterm/Control/ControlServer+TextPage.swift`
- Modify: `agterm/Control/ControlServer+RemotePage.swift`
- Modify: `agterm/Control/ControlServer+Ask.swift`
- Modify: `agterm/Views/TextPageBridge.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreRemotePageTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherOverlayTests.swift`
- Modify: `agtermTests/ControlServerTextPageTests.swift`
- Modify: `agtermTests/ControlServerRemotePageTests.swift`

- [x] make `setSessionOverlayFollow` and `setSessionOverlayWrap` async in the protocol, defaults and callers; move
      their dispatcher arms to async helpers routed with `.sessionOverlaySearch`; local replies unchanged
- [x] open a log page on a remote slot when the presenter lists `page.text`; keep the refusal otherwise, reworded
      to name the remote session
- [x] route follow, search, wrap and changes on a remote slot to the presenter and wait for `pageResult` within the
      deadline; settle on page end, channel loss or presenter change
- [x] apply the four actions on the presenter and answer each with `pageResult` carrying the text state; existing
      actions keep advancing `appliedSeq`
- [x] the origin applies the result's state before replying, and mirrors state reports into the remote page node:
      follow, query and wrap transitions emit `tree.changed`, counts do not
- [x] rewrite `ControlServerTextPageTests.swift:100` to the capability split: a `page.text` presenter opens the log
      page, an older one gets the reworded refusal
- [x] write tests: each command's success and error text matches the local one (`N of M`, `no query`,
      `page not loaded`, `no log page`, `following`/`paused`, `wrapped`/`unwrapped`); `presenter did not answer`
      past the deadline
- [x] commit step results in `TextPageBridge.step`/`stepChange` (counts, current, a following log paused) before the
      result is built; run text actions per page in sequence order at `applyReplicaPageCommand`
- [x] write tests: a `pageResult` frame travels presenter to origin through the Mac host end to end; `tree` read right
      after a `follow off`, `wrap on`, search step or diff step reply shows the new value, and a following log reads
      paused right after a search step
- [x] write `AppStoreRemotePageTests` cases: a report changing only lines, matches or changes emits nothing; a follow,
      query or wrap change emits once
- [x] write tests: query before load runs on load, step before load fails, rapid follow toggles, a step not replayed
      after rebuild, mixed-version refusals in both directions
- [x] run tests - must pass before next task

### Task 6: Clicked logs on remote panes

**Files:**
- Modify: `agterm/Control/ControlServer+TextPage.swift`
- Modify: `agterm/Control/ControlServer+ForwardedClick.swift`
- Modify: `agtermTests/ControlServerRemoteLinkClickTests.swift`

- [x] a forwarded click on a log opens a log page when both ends list `page.text`, the plain page otherwise
- [x] write tests for both capability cases and for a hidden clicked log page being replaced
- [x] run tests - must pass before next task

### Task 7: agterm-server origin

**Files:**
- Modify: `agtermCore/Sources/AgtermServerKit/ServerActions+Overlay.swift`
- Modify: `agtermCore/Sources/AgtermServerKit/ServerStreams.swift`
- Modify: `agtermCore/Sources/AgtermServerKit/ServerCommandPolicy.swift`
- Modify: `agtermCore/Sources/AgtermServerKit/ServerActions.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+RemotePage.swift`
- Modify: `agtermCore/Tests/AgtermServerTests/ServerActionsOverlayTests.swift`
- Modify: `agtermCore/Tests/AgtermServerTests/ServerStreamsTests.swift`
- Modify: `agtermCore/Tests/AgtermServerTests/ServerCommandPolicyTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreRemotePageTests.swift`

- [x] remove the unconditional log refusal; probe a log through the tail path in `checkedPage`
- [x] carry the log request into the serving claim; a clicked log becomes a log page only when the connected
      presenter lists `page.text`, the plain page otherwise, as on the Mac
- [x] admit `session.overlay.follow|search|wrap|changes` and implement them through the shared store path
- [x] `presenterShows` requires `page.text` for a log page; `offerPendingPage` sends `textSeed` from the latest
      mirrored state and never a step
- [x] rewrite `ServerActionsOverlayTests.swift:76` to the capability split
- [x] write tests: a log over 4 MB opens, clicked log with and without `page.text`, each command over a fake
      presenter, a `pageResult` frame through `ServerStreams` end to end, re-offer seed applied before the first
      report, a held log page not offered to an older presenter, an open refused while only an older one is connected
- [x] run tests - must pass before next task

### Task 8: Page sessions on agterm-server

**Files:**
- Modify: `agtermCore/Sources/AgtermServerKit/ServerCommandPolicy.swift`
- Modify: `agtermCore/Sources/AgtermServerKit/ServerActions+Sessions.swift`
- Modify: `agtermCore/Sources/AgtermServerKit/ServerActions+Unserved.swift`
- Modify: `agtermCore/Sources/AgtermServerKit/ServerStreams.swift`
- Modify: `agtermCore/Sources/AgtermServerKit/AgtermServer.swift`
- Modify: `agtermCore/Sources/AgtermServerKit/PaneObserver.swift`
- Modify: `agtermCore/Sources/AgtermServerKit/ServerCatalog.swift`
- Modify: `agtermCore/Tests/AgtermServerTests/ServerActionsSessionsTests.swift`
- Modify: `agtermCore/Tests/AgtermServerTests/PaneObserverTests.swift`
- Modify: `agtermCore/Tests/AgtermServerTests/ServerCommandPolicyTests.swift`
- Modify: `agtermCore/Tests/AgtermServerTests/ServerStreamsTests.swift`

- [x] admit `session.page`, `session.companion.page` and `session.companion.page.attach`; create HTML file and URL
      rows through the shared `AppStore.addPageSession`/`addPageCompanion` and the dispatcher's existing
      `pageRowOptions`; a loopback URL page is refused as on the Mac
- [x] keep page rows out of the daemon lifecycle: `PaneObserver` skips them (no pane, daemon or exit record, so never
      marked ended), and `ServerCatalog` projects them with no terminal pane
- [x] serve an attachment per view: a per-claim token claimed into a `PageServeStream` in companion mode on the
      server's `PageServeHost`; the page's final release ends every view; a file page's bridge requests run through the
      server's own dispatcher
- [x] save and restore page rows through the shared `PageSnapshot` path (`openRestoredPages`) when the server restarts
- [x] hoist `ControlServer.pageCompanionRefusal` into agtermCore and call it from `ServerActions.serve`, so split,
      type, scratch, HUD, ask and the other terminal commands on a server page row are refused as on the Mac;
      `session.overlay.follow|search|wrap|changes` on a page row answer `no text page`, as a Mac page row does, since
      rows hold only HTML file and URL pages
- [x] hoist the companion attach token and claim book (`companionPageTokens`, `companionPageStreams`) into agtermCore,
      shared by both hosts, never duplicated in AgtermServerKit
- [x] skip page rows in the server's pane-identity readers (`ServerActions+Receipts.swift:98`,
      `ServerActions+Remote.swift:17`) as `locallyManagedPaneIdentities` does on the Mac
- [x] refuse a loopback URL page row at creation on the server: it names the server's host, and a page row has no
      `page.forward` path, so no Mac could ever show it (Mac page rows keep today's refusal at attach)
- [x] write tests: each creation command and refusal, the terminal-command refusals on a page row, an observer tick
      and startup adoption with an empty daemon listing leave a page row live, attach token claim and expiry, two
      views served at once, restore after restart, bridge requests dispatched on the server
- [x] run tests - must pass before next task

### Task 9: Server page rows in Mac remote windows, docs and gates

**Files:**
- Modify: `agtermCore/Sources/agtermCore/CatalogFrames.swift`
- Modify: `agtermCore/Sources/agtermCore/CatalogHub.swift`
- Modify: `agtermCore/Sources/AgtermServerKit/ServerCatalog.swift`
- Modify: `agtermCore/Sources/agtermCore/RemoteCatalogMirror.swift`
- Modify: `agtermCore/Sources/agtermCore/RemoteCatalogClient.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+Catalog.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+ReplicaPage.swift`
- Modify: `agterm/Control/ControlServer+RemoteCatalog.swift`
- Modify: `agterm/Control/ControlServer+RemoteCompanions.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/CatalogFramesTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/CatalogHubTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/RemoteCatalogMirrorTests.swift`
- Modify: `agtermCore/Tests/AgtermServerTests/ServerCatalogTests.swift`
- Modify: `agtermTests/AppActions+RemoteCatalogTests.swift`
- Modify: `plugins/agterm/skills/agterm/SKILL.md`
- Modify: `plugins/agterm/skills/agterm/reference.md`
- Modify: `site/docs.html`
- Modify: `site/commands.html`
- Modify: `.claude/rules/control-api.md`

- [x] `CatalogSessionFields.page: CatalogPage?` (`kind` file or url, `identity` text) marks a page row, whose
      `primary` is the row's own id; `CatalogHello.pageRows: Bool?`, set by `RemoteCatalogClient.open`'s outgoing
      hello, declares that this Mac shows page rows
- [x] older viewers (no `pageRows`): `CatalogHub` keeps one revision and one diff of the full catalog; such a
      subscriber gets the filtered snapshot, and on each refresh the changes between the filtered previous and next
      catalogs, sent at the first of that refresh's revisions, the rest as `catalog.skip` deltas, a new change kind
      an older viewer decodes as `.unknown` and steps past. Indices come from diffing the filtered catalogs; a
      companion whose page root is filtered loses its `parent` in the filtered view, so it shows as a top-level row
- [x] `AppStore.insertCatalogSession` builds a page row as `.page` content (`Session.content` is a `let`), and
      `catalogRowAdded` starts no presentation stream for it: its one stream is the page channel, claimed through the
      server's `session.companion.page.attach` and rendered with the shared replica builder; the binding keeps the
      server session id and `catalogOwned`, and carries the origin endpoint a page row has no `CatalogPane` for
- [x] channel loss or a server restart re-claims while the catalog still lists the row, never closing it; a removal
      from the catalog closes it; `session.detach` closes the channel and keeps the row, `session.reattach` claims again
- [x] rename, move, close and companion placement of a server page row go through the existing catalog operations;
      `session.page` and `session.companion.page` in a server window are forwarded to the server through
      `RemoteOperation` instead of refused as `localOnlyCommands`
- [x] write tests: catalog round trip with and without `page` and `pageRows`; for an older viewer, a hidden page
      between terminal rows, page changes, then visible insertion, move and removal without a revision gap or
      reorder, and a page root's companion shown top-level; the mirror attaching in place with a stable row id and no
      duplicate; detach and reattach; re-claim after channel loss and after restart; rename, move and close of a page
      row; `session.page` forwarded from a server window
- [x] update the skill, docs, command reference and control-api rules: remove the remote refusals, state the
      `page.text` gate, the older-peer messages, the presenter-side control and page sessions on agterm-server
- [x] run `cd agtermCore && swift test`, `make test-app`, `make lint`
- [x] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification**
- a Mac attached to another Mac and to an agterm-server host: `overlay open --tail 200` on a growing log, then
  follow, pause by scrolling, search, wrap, step a `.diff` page, from the page bar and from `agtermctl` on both sides
- an older presenter and an older origin: log open and the four commands answer the remote refusal
- `agtermctl session overlay open --page --html <file>` on an agterm-server host: the row shows in a Mac's remote
  window, survives a server restart, and attaches from a second Mac
