# Show HTML overlays on a presenting Mac

## Overview
- A page opened with `session overlay open --html` or `--url` on a session that another Mac presents shows on
  that Mac, the way program overlays and asks already do. From the user's side there is no difference between
  a program overlay and a page; today a page is refused while a presenter owns the session
  (`OverlayHtmlError.presenter`, `AppStore+HtmlOverlay.swift:20`) and nobody sees it.
- The case that exposed it: webrev opens a chromeless `--js` file page whose bridge submits annotations,
  read back with `overlay result --page`; watched from another Mac, the page is invisible.
- Scope is NEW pages only. A page already open on the origin stays where it is when a presenter attaches,
  matching asks and program overlays. Moving a live page would need its DOM and unsent edits carried over,
  which is a separate requirement.
- The design was argued out with codex in the session that produced this plan; the decisions below are the
  agreed result, revised after an automated plan review.

## Context (from discovery)
- Program overlay handoff, the model to mirror: `AppStore+RemoteOverlay.swift` (origin reservation, placement
  rule, presenter loss), `AppStore+RemotePresentation.swift` and `OverlayReplica.swift` (viewer replica slots in
  agtermCore: present, close, resize, orphan on stream loss), `ControlServer+OverlayJobs.swift` (claim, stream
  adoption), `ControlServer.swift:460-471` (claim handoff with the failed-reply-write guard), `OverlayJobs.swift`,
  `agtermctlKit/OverlayRunJob.swift` and `StreamBridge.swift` (CLI side), `RemoteSession.swift`
  (`presentCommand` uses `ssh -T`, `runJobCommand` uses `-tt`).
- `job.run` plumbing to copy for the new claim command: `ControlDispatcher.swift` (command arm, `ControlActions`
  requirement), `ControlDispatcher+Overlay.swift`, `ControlActionsDefaults.swift` (public unsupported default for
  the `agterm-linux` conformer), `HtmlBridge.swift` (`refused`, `notSessionTargeted`), `ControlServer.swift`
  fallback list.
- Presentation stream: `PresentationFrames.swift` (256 KiB frame cap, frame kinds, hello `kinds`),
  `PresentationHub.swift` (`supportedKinds`, `sendToPresenter` gates by body kind, `receive` forwards only
  ask/program replies, `send` drops a subscriber whose queue rejects a frame), `RemotePresentationClient.swift`
  (viewer, exhaustive frame switch, hello sends `supportedKinds` wholesale), `RemotePresentationProcess.swift`
  (one nonblocking write, stops on a short write), `ControlServer+Presentation.swift` (presenter-loss and
  presenter-frame hooks), `ControlServer+Ask.swift` (`receivePresenterFrame`),
  `ControlServer+RemotePresentation.swift` (viewer effects).
- Pages: `HtmlOverlay.swift` (`HtmlSource`, `isLoopback`, `contains`, `HtmlNavigationPolicy`; `identity` is display
  text only), `AppStore+HtmlOverlay.swift` (`htmlOverlayNodes`; `setHtmlPage`/`setHtmlLoadState` emit no
  `tree.changed`), `Session+HtmlOverlay.swift`, `Session+OverlayVisibility.swift` (hide/show/toggle; a remote
  reservation answers `shownElsewhere`), `HtmlPageOutcomes.swift` (outcomes keyed by page id, a process-wide
  singleton), `HtmlBridge.swift` (fills defaults, not a sandbox), app `ControlServer+SessionActions.swift`
  (`openHtmlOverlay` adapter: persistent store check, eager page build, local `--follow`; bare `overlay.result`),
  `ControlServer+SurfaceIO.swift` (`overlay.text`/`copy`), `Views/HtmlOverlayRegistry.swift`,
  `HtmlOverlayBridge.swift`, `HtmlOverlayView.swift`. About 15 app sites switch on `HtmlSource`. No custom URL
  scheme handler exists yet.
- Exhaustive switches over the protocol: `ControlDispatcher.swift` (`Command`), `ControlServer.swift`
  (app fallback), `RemotePresentationClient.swift` (`PresentationFrame.Body`).
- Tree: `ControlHtmlOverlayNode` and `ControlRemoteOverlayNode` in `ControlProjection.swift`.
- Test seam: `ControlServerRemotePresentationTests.bridgedPair()` replaces ssh with `server.remoteTransport` and
  runs both roles in one process.
- Rules: `.claude/rules/control-api.md` (Overlay and Remote sessions sections), `libghostty.md` (overlays),
  `ui-tests.md`. `agtermCore` is consumed by `agterm-linux`: add public API, never narrow existing fields; a new
  case on a public enum breaks its exhaustive switches, the cost already accepted for a new `Command` case
  (control-api.md, `sidebar.width` bullet).

## Development Approach
- **testing approach**: Regular (code first, then tests in the same task)
- complete each task fully before moving to the next; every task builds and passes on its own, with no test
  that depends on a later task
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional - they are a required part of the checklist
  - write unit tests for new functions/methods
  - write unit tests for modified functions/methods
  - add new test cases for new code paths
  - update existing test cases if behavior changes
  - tests cover both success and error scenarios
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- model, routing, validation and response shaping go in agtermCore with host-free tests; the app target stays
  the side-effect adapter (CLAUDE.md)
- per task, run only the tests that cover it: `cd agtermCore && swift test --filter <Suite>` and
  `-only-testing:<Target>/<Class>` for hosted tests. The full gates (`swift test`, `make test-app`,
  `make lint`) run once, in the acceptance task, per CLAUDE.md
- maintain backward compatibility: an older presenter or origin keeps today's behavior

## Testing Strategy
- **unit tests**: `agtermCore` tests for frames, codecs, reservation and replica state, placement, refusal rules
  and grant resolution
- **hosted tests**: `agtermTests` for the app adapters, the claimed stream, the scheme handler and the bridge
  relay. The end-to-end page cases follow `ControlServerRemotePresentationTests`, with an injected page-serve
  launcher in place of ssh
- **XCUITest exemption**: like `zmx.present`, the remote path needs a second app as its peer. The viewer's page
  is the ordinary page view, which the existing HTML overlay UI tests cover

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview
- **Handoff.** A new page whose target pane follows remotely on the origin (or every existing pane does, for
  session-wide placement; the program overlay rule in `openRemoteOverlay`) goes to the granted presenter, gated by
  the page frame kinds in the presenter's hello. An older presenter keeps today's refusal. The origin reserves the
  slot, registers the page in `HtmlPageOutcomes` as pending, and replies with the page id, so
  `overlay result --page` and `--html --block` are unchanged. Persistent storage, rendering and `--follow` happen on
  the viewer, never on the origin.
- **File pages use a dedicated channel.** The presenter's open frame carries a single-use claim token. The viewer
  starts `ssh -T <origin> agtermctl session overlay page-serve <token>`, a thin byte bridge into an app stream the
  origin adopts after the claim (the job claim/adopt shape, with its own lifecycle). Through it the origin app
  serves the document and, only with `--cwd`, files inside the grant, off the main actor, in bounded
  demand-driven chunks. It also dispatches relayed bridge requests after checking the live page association and
  presenter generation; a relayed `overlay.submit` lands in the origin's ledger. Bulk bytes never enter the shared
  presentation queue.
- **Viewer replica page.** The viewer shows a page of a third source kind, `HtmlSource.replica`, carrying the
  origin page id, the origin's logical path and whether a grant exists. The compiler then finds every site that
  switches on the source. The navigation policy allows only `agterm-page://<this replica's id>/` for it and opens
  web links externally, as for a file page. The replica has its OWN local page id, mapped to the origin id, so a
  submit on the viewer can reach the origin's ledger only through the page channel. The viewer's `htmlOverlays`
  reports it with `replica: true` and the origin's logical path as `file`.
- **URL pages load on the viewer.** A non-loopback `--url` page needs no helper: it loads its full URL directly
  with viewer networking and viewer-local `--persistent` storage, as an ordinary URL page marked `replica: true`.
  A loopback URL (`HtmlSource.isLoopback`) is refused on a presenter, since it names a server on the origin.
- **Actions on the origin, per command, for a remote page:**
  - `overlay.close`, `resize`, `reload [--current]`, `navigate back|forward` reach the viewer.
  - `navigate browser` reaches the viewer for a URL page; `navigate finder` and `navigate browser` on a remote file
    page are refused `page is shown on another Mac`; Copy Link stays viewer-local.
  - `hide|show|toggle` reach a remote PAGE (bare scope includes it, toggle hides all when any is shown); a remote
    PROGRAM reservation keeps answering `overlay is shown on another Mac`. For a remote page the reply is
    request-only: the origin records the REQUESTED visibility with a sequence number, `result.text` and the
    toggle decision use it while the request is unacknowledged. A mirrored `pageState` echoing the latest sequence
    clears the pending request, and from then on toggles use the reported visibility until another request is sent;
    an older sequence never overwrites a pending request. So two toggles before the mirror arrives hide then show,
    and a hide made on the viewer after an applied show makes the next origin toggle a show.
  - on the VIEWER, `overlay.submit` on a replica is refused without closing it (`submit on the Mac that opened the
    page`); the replica's own submit goes through the bridge and the page channel.
  - bare `overlay.result` answers `OverlayHtmlError.noResult`, as for a local page; `--page` reads the ledger.
  - `overlay.text` and `overlay.copy` answer the local page's `noRead`.
  - `overlay.submit` records into the origin ledger.
- **Read-back.** The origin lists a remote page in its `htmlOverlays` with `remote: true`: the fields it owns
  (`id`, `pane`, `file`, `cwd`, `url`, the flags) from its own record, the live ones (`state`, `error`, `page`,
  `title`, `canGoBack`, `canGoForward`, `hidden`) from the viewer's mirrored state. `remoteOverlays[]` gains
  `pageID`, and `hiddenOverlays` includes a remote page the viewer reports hidden, so the two agree. Projection
  only: no local `HtmlOverlay` and no origin coverage for a remote page. `tree.changed` fires on a slot change or a
  hidden transition only, never on a title, address or load-state update, as for a local page.
- **Failure.** Claim timeout or helper loss ends only that page; presenter loss ends the page and its helper.
  A pending page finishes `dismissed`, an accepted submission is kept, and bridge calls are never replayed. A
  viewer that refuses the page (slot taken, persistent store failure) answers `pageRejected` with a reason; the
  origin's open already answered ok, so the page ends `dismissed` and the reason is logged on the origin. That
  is an accepted difference from a local open, which fails with the error.

## Technical Details
- **Shared-stream frames** (presentation kinds, small and bounded): `pageRequest` (page id, claim token, typed
  full source: the origin's logical file path with its grant root, or the complete URL with path and query;
  display identity separately; chromeless, javascript, navigation, browse, persistent, background color, pane
  identity, size, follow), `pageRejected` (page id, reason), `pageClose`, `pageClosed`, `pageCommand` (hide, show,
  reload original/current, back, forward, browser, resize; each carries a sequence number), `pageState` (title,
  logical address, load state, error, history availability, hidden, load revision, last applied command sequence). `pageState` is coalesced per page and its strings bounded before
  sending; a replaceable update overwrites a queued one.
- **Negotiation**: every page kind joins `PresentationHub.supportedKinds`, and the open path requires all of them
  in the presenter's hello before allocating anything. `receive` forwards page frames only from the session's
  current presenter. Until the viewer side exists (Task 6), the client answers every `pageRequest` with
  `pageRejected`, so an origin never waits out the claim deadline.
- **Claim command**: `session.overlay.page.serve` takes the token, is refused by `HtmlBridge` and absent from
  its session-targeted set, has a `ControlActions` requirement with a public unsupported default, and leaves the
  accept thread through a `handleConnection` branch mirroring `job.run`'s, where a claim whose reply write fails
  ends the page.
- **Claim token**: random, single-use, bound on the origin to page id, presenter generation and a deadline. Never
  in `tree`. A failed or late claim starts no service and leaves no reservation.
- **Page channel frames** (newline-delimited JSON with base64 chunk bodies): `resource` (request id, load
  revision, logical path) answered by `chunk`/`end`/`error`; `cancel` (request id); `bridge` (request id, raw
  control request) answered by `reply`. Chunk size is bounded well under the frame cap; the origin produces the
  next chunk only when the writer drained the last, and a bridge reply is never queued behind a whole asset.
  Oversize requests and replies are refused with an error frame, never by dropping the channel.
- **Grant resolution** is host-free in agtermCore beside `HtmlOverlay.contains`: decode, standardize, resolve
  symlinks, refuse a path that escapes the grant; a request is the absolute origin path the scheme URL carries,
  decoded at the scheme boundary; no grant serves the page's own file alone.
- **Custom scheme**: `agterm-page://<replica page id>/<path>` through a `WKURLSchemeHandler`; `<path>` maps to an
  origin logical path. The scheme URL never reaches read-back, which reports the origin's logical path.
- **Tree**: `ControlHtmlOverlayNode` gains optional `remote` and `replica` (true only when set); `zoom` is omitted
  for a remote page. `ControlRemoteOverlayNode` gains optional `pageID`. New init parameters are trailing and
  defaulted, so existing callers compile unchanged.
- **Resize read-back**: as for remote programs, `remoteOverlays[].sizePercent` reports the requested size; what the
  viewer applied is not read back.

## What Goes Where
- **Implementation Steps** (`[ ]` checkboxes): code, tests and documentation in this repository
- **Post-Completion** (no checkboxes): manual two-Mac verification

## Implementation Steps

### Task 1: Prove WebKit custom-scheme loading for pages

**Files:**
- Create: `agterm/Views/HtmlPageSchemeHandler.swift`
- Create: `agtermTests/HtmlPageSchemeHandlerTests.swift`

- [x] add a `WKURLSchemeHandler` serving `agterm-page://<page-id>/<path>` from an injected async byte source,
      with request cancellation when WebKit stops a task
- [x] hosted test: a page with a relative stylesheet, image and ES module loads fully through the handler
- [x] hosted test: `fetch` of a relative path, `history.pushState` and back/forward behave as on a file page
- [x] hosted test: a stopped task cancels its source, and a slow source does not block other requests
- [x] module, fetch and history loading all pass, so the transport stands
- [x] run the new hosted tests - must pass before task 2

### Task 2: Protocol types, the claim command and the replica source

**Files:**
- Modify: `agtermCore/Sources/agtermCore/PresentationFrames.swift`
- Create: `agtermCore/Sources/agtermCore/PageServeFrames.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher+Overlay.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlActionsDefaults.swift`
- Modify: `agtermCore/Sources/agtermCore/RemotePresentationClient.swift`
- Modify: `agtermCore/Sources/agtermCore/HtmlBridge.swift`
- Modify: `agtermCore/Sources/agtermCore/HtmlOverlay.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+HtmlOverlay.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProjection.swift`
- Modify: `agterm/Control/ControlServer.swift`
- Modify: `agterm/Views/HtmlOverlayRegistry.swift`
- Modify: `agterm/Views/HtmlOverlayView.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/PresentationFramesTests.swift`
- Create: `agtermCore/Tests/agtermCoreTests/PageServeFramesTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/HtmlBridgeTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherOverlayTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/HtmlOverlayTests.swift`

- [x] add the shared-stream page kinds with the typed full source and background color; unknown kinds stay skippable
- [x] add page channel frames with bounded chunk and request/reply sizes, and the load revision field
- [x] add `session.overlay.page.serve`: catalog entry, dispatcher arm validating the token format, a
      `ControlActions` requirement with a public unsupported default, `HtmlBridge` refusal
- [x] add `HtmlSource.replica` (origin page id, logical path, grant flag); the navigation policy allows only its own
      `agterm-page://` origin and opens web links externally; every switch on the source handles it
      (`AppStore+HtmlOverlay` node builder, `HtmlOverlayRegistry`, `HtmlOverlayView`), with replica loading left to
      Task 6
- [x] update the remaining exhaustive consumers (`RemotePresentationClient`, `ControlServer`'s fallback); the client
      answers `pageRequest` with `pageRejected` until Task 6
- [x] add `ControlHtmlOverlayNode.remote`/`replica` and `ControlRemoteOverlayNode.pageID` as trailing defaulted
      init parameters, omitted when nil; reword the `htmlOverlays` and `hiddenOverlays` comments
      (`ControlProjection.swift:337-341`) so only LOCAL entries also occupy `overlay`/`paneOverlays`
- [x] tests: round trips including a URL with path and query and a file source with its grant, oversize refusal,
      an older decoder skipping the new kinds, the dispatcher arm and its unsupported default, bridge refusal,
      the replica navigation policy (own origin allowed, another page id and `file` refused, web link external),
      nil omission of the new tree fields
- [x] run `swift test --filter` for the touched suites and `-only-testing:agtermTests/HtmlOverlayRegistryTests`
      - must pass before task 3

### Task 3: Origin reservation, routing and lifecycle for remote pages

**Files:**
- Create: `agtermCore/Sources/agtermCore/AppStore+RemotePage.swift`
- Create: `agtermCore/Sources/agtermCore/RemotePageResources.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+HtmlOverlay.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+RemoteOverlay.swift`
- Modify: `agtermCore/Sources/agtermCore/RemoteOverlays.swift`
- Modify: `agtermCore/Sources/agtermCore/Session+OverlayVisibility.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+OverlayVisibility.swift`
- Modify: `agtermCore/Sources/agtermCore/PresentationHub.swift`
- Create: `agtermCore/Tests/agtermCoreTests/AppStoreRemotePageTests.swift`
- Create: `agtermCore/Tests/agtermCoreTests/RemotePageResourcesTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/HtmlOverlayTests.swift`

- [x] route a page open through the program overlay placement rule; refuse a loopback URL and keep the old refusal
      for a presenter whose hello lacks the page kinds, preserving missing-pane and slot-taken errors
- [x] reserve the slot, register the page pending in `HtmlPageOutcomes`, mint the claim token, send `pageRequest`
- [x] add the page kinds to `supportedKinds`; `receive` forwards `pageState`, `pageClosed` and `pageRejected` only
      from the current presenter
- [x] apply mirrored `pageState`; project a remote page into `htmlOverlayNodes` with `remote: true`, into
      `remoteOverlays[].pageID`, and into `hiddenOverlays` when reported hidden
- [x] hide/show/toggle include a remote page slot (bare scope and toggle rule as for local pages) with the
      request-only contract: a pending requested visibility with its sequence number decides the reply and the next
      toggle; a `pageState` echoing that sequence clears it, after which toggles use the reported visibility; an older
      sequence never overwrites a pending request; a remote program reservation keeps `shownElsewhere`
- [x] close, resize, presenter loss, session/pane removal (soft close included) and rejection end or update the
      reservation; a pending page finishes `dismissed`, an accepted submission is kept
- [x] `submitHtmlOverlay` resolves a remote page reservation into the origin ledger
- [x] `tree.changed` fires on slot changes and hidden transitions only
- [x] `RemotePageResources` resolves a requested logical path inside the grant (decode, standardize, symlinks,
      a path escaping the grant refused, absolute origin paths inside it allowed; no grant: the page file only)
- [x] tests for each path above, including placement with mixed lead roles, the older-presenter refusal, a frame
      from a non-presenter ignored, read-back projection, hidden agreement between the two fields, no
      `tree.changed` on a title change, remote submit, grant escape cases, and a delayed `pageState`: two toggles
      before any mirror hide then show, a stale report does not overwrite the newer request, and a viewer-local hide
      after an applied show makes the next origin toggle a show
- [x] run `swift test --filter` for the new and existing remote overlay suites - must pass before task 4

### Task 4: Origin app wiring and page service over a claimed stream

**Files:**
- Create: `agterm/Control/ControlServer+PageServe.swift`
- Modify: `agterm/Control/ControlServer.swift`
- Modify: `agterm/Control/ControlServer+SessionActions.swift`
- Modify: `agterm/Control/ControlServer+Presentation.swift`
- Modify: `agterm/Control/ControlServer+Ask.swift`
- Modify: `agterm/Control/ControlStreamOwner.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+RemotePage.swift`
- Create: `agtermTests/ControlServerPageServeTests.swift`

- [x] `openHtmlOverlay` tries the remote route first; a remote page skips the persistent store check, the eager
      page build and local `--follow`, which happen on the viewer
- [x] wire `receivePresenterFrame` and the presenter-loss hook to the store's page handlers, logging a `page.rejected` reason
- [x] answer `session.overlay.page.serve` through the `ControlActions` requirement: validate the token against page,
      presenter generation and deadline; a `handleConnection` branch adopts the connection, and a claim whose reply
      write fails ends the page
- [x] serve resources off the main actor through `RemotePageResources`, in demand-driven chunks, honoring `cancel`
      and the load revision
- [x] dispatch relayed bridge requests through `HtmlBridge` and the normal dispatch after checking the live page
      association; refuse after close even when bytes were already queued; never replay
- [x] helper EOF or claim timeout ends only that page; presenter loss shuts the page stream
- [x] tests: remote open skips local persistent and follow effects, loopback refused, grant escape refused on the
      channel, a large file in chunks, cancel, a relayed submit recorded (its channel closes with the page), bridge
      for an ended page refused, token reuse refused, failed claim reply ends the page, helper loss keeps the
      presenter, presenter loss ends the page
- [x] run `-only-testing:agtermTests/ControlServerPageServeTests` - must pass before task 5

### Task 5: `agtermctl session overlay page-serve` bridge and its ssh command

**Files:**
- Create: `agtermCore/Sources/agtermctlKit/OverlayPageServe.swift`
- Modify: `agtermCore/Sources/agtermctlKit/SessionCommands.swift`
- Modify: `agtermCore/Sources/agtermCore/RemoteSession.swift`
- Create: `agtermCore/Tests/agtermctlKitTests/OverlayPageServeTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/RemoteSessionTests.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/SocketClientTests.swift`

- [x] the CLI subcommand claims with the token and pumps bytes both ways with `StreamBridge`, handling partial
      writes; it reads no files and interprets no frames
- [x] `RemoteSession.pageServeCommand(host:token:)` builds the `ssh -T` argv with the PATH chain
      `presentCommand` uses
- [x] tests: argv shape and quoting, refused host, a refused claim exits nonzero, EOF on either side ends the pump
- [x] run the touched `swift test --filter` suites - must pass before task 6

### Task 6: Viewer replica page

**Files:**
- Create: `agtermCore/Sources/agtermCore/AppStore+ReplicaPage.swift`
- Create: `agtermCore/Tests/agtermCoreTests/AppStoreReplicaPageTests.swift`
- Create: `agterm/Control/ControlServer+RemotePage.swift`
- Create: `agterm/Control/RemotePageChannel.swift`
- Modify: `agterm/Control/ControlServer+RemotePresentation.swift`
- Modify: `agtermCore/Sources/agtermCore/RemotePresentationClient.swift`
- Modify: `agterm/Views/HtmlOverlayRegistry.swift`
- Modify: `agterm/Views/HtmlOverlayBridge.swift`
- Modify: `agtermCore/Sources/agtermCore/HtmlOverlay.swift` (replica release signal)
- Modify: `agtermCore/Sources/agtermCore/AppStore+HtmlOverlay.swift`, `AppStore+OverlayVisibility.swift`,
  `AppStore+RemoteOverlay.swift`, `AppStore+RemotePresentation.swift`, `AppStore.swift`, `ControlProtocol.swift`
- Modify: `agterm/Control/ControlServer.swift`, `agterm/Control/ControlServer+Presentation.swift`
- Create: `agtermTests/ControlServerRemotePageTests.swift`, `agtermTests/RemotePageChannelTests.swift`,
  `agtermTests/RemotePageFakes.swift` (one test file per source file, so the plan's single
  `RemotePageReplicaTests.swift` became the first two)

- [x] agtermCore: present a replica page into the target slot with its own local page id mapped to the origin id
      (pane mapping as `presentReplicaOverlay`), close it, apply resize and hide/show, and orphan it on stream loss;
      a refused present answers `pageRejected` with the reason
- [x] app: a file replica starts the page-serve helper through an injectable launcher (ssh by default, like
      `remoteTransport`) and loads through the Task 1 scheme handler; a URL page loads its full URL directly with no
      helper and viewer-local persistent storage
- [x] the channel writer is bounded and off the main actor, drains partial writes, and stops reading when
      WebKit is not consuming; scheme tasks map to `resource`/`cancel`; answers for a request of a superseded load
      revision are dropped; at most `pageServeResourceLimit` resource requests are in flight, the rest wait
      locally, and a request's slot is freed only by its terminal frame (`end` or `failure`, which a cancel
      also produces), while bridge calls do not share those slots
- [x] relay the `data-agterm` adapter and `agterm.request` through `bridge` frames with correlation ids; keep the
      main-frame restriction and URL pages bridge-free
- [x] audit every `if case .file`/`.url` predicate and early return in the page code (`drawsBackground`, `themed`,
      which gates the bridge handler and the adapter scripts, `textLoaded`, `pageURL`'s raw `webView.url` return)
      so a file replica is themed, bridged and reports its logical path, never the `agterm-page://` URL
- [x] mirror coalesced `pageState` with the last applied command sequence; apply `pageCommand`; refuse Finder and
      Open in Browser for a file replica; Copy Link stays local; the viewer's `htmlOverlays` reports `replica: true`
      with the origin's logical path
- [x] the viewer's socket `overlay.submit` on a replica is refused and leaves it open
- [x] presenter loss, helper exit, `pageClose` and local close tear the page down once and report `pageClosed`
- [x] tests: host-free present/close/orphan/refusal and id mapping; hosted file replica loading an asset over an
      injected channel, bridge relay correlation through an injected dispatch for both `agterm.request` and a JS-off
      `data-agterm` tag, logical-path read-back, URL page without helper, refused Finder/browser on a file replica,
      browser on a URL replica, a refused socket submit leaving the replica and the origin pending, teardown on each
      trigger, state coalescing
- [x] run `swift test --filter AppStoreReplicaPage` and `-only-testing:agtermTests/ControlServerRemotePageTests`, `RemotePageChannelTests` - must
      pass before task 7

### Task 7: Origin control actions on a remote page

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore+RemotePage.swift` (routing: `navigateRemotePage`, `reloadRemotePage`)
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift` (`OverlayHtmlError.remotePage`)
- Modify: `agterm/Control/ControlServer+SessionActions.swift`
- Modify: `agterm/Control/ControlServer+SurfaceIO.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreRemotePageTests.swift`
- Modify: `agtermTests/ControlServerPageServeTests.swift` (`ControlServerSessionActionsTests.swift` is at the 2000-line
  test cap, and parsing is unchanged, so the dispatcher and its tests need no edit)

- [x] implement the per-command answers in Solution Overview: close, resize, reload, back/forward and hide/show/toggle
      reach the viewer; browser reaches it for a URL page; finder and browser on a remote file page are refused;
      bare `overlay.result` answers `noResult`; `overlay.text`/`copy` answer `noRead`; submit and `result --page`
      use the origin ledger
- [x] tests for each command against a remote file page and a remote URL page, including a gone presenter and a
      remote program reservation still answering `shownElsewhere` for hide
- [x] run the touched suites - must pass before task 8

### Task 8: End-to-end page handoff over the real bridge

**Files:**
- Modify: `agtermTests/ControlServerRemotePresentationTests.swift`

- [x] both roles in one process with the page-serve launcher set to
      `[cli, "session", "overlay", "page-serve", <token>, "--socket", path]`: a `--js --cwd` file page with a relative
      asset opens on the presenter, its bridge submits a value, and `overlay result --page` on the origin returns it
- [x] assert the submit crossed the page channel: a recording launcher wrapper observes the `bridge` frame carrying
      `session.overlay.submit`, and the viewer's ledger has no entry under the replica's local id
- [x] the origin's `htmlOverlays` lists the page with `remote: true` and the viewer's live `page` and `title`
- [x] an older presenter (hello without the page kinds) gets today's refusal
- [x] presenter loss mid-page finishes the page `dismissed`
- [x] run `-only-testing:agtermTests/ControlServerRemotePresentationTests` - must pass before task 9

### Task 9: Verify acceptance criteria
- [x] verify every Overview and Solution Overview point is implemented
- [x] verify edge cases: placement with mixed roles, loopback refusal, grant escape, helper loss, token reuse
- [x] run the full gates once: `cd agtermCore && swift test`, `make test-app`, `make lint`
- [x] after the hosted run, check `lsappinfo list | grep -A4 agterm.debug` for leaked test processes

### Task 10: [Final] Update documentation
- [x] `.claude/rules/control-api.md`: replace the "a page never takes the remote program-job path" bullet; add the
      page handoff contract to Remote sessions; add `.overlay.page.serve` to the Public catalog; "Four commands
      leave the accept thread" becomes five; add it to the HtmlBridge refused list; update the hide contract and the
      remote-overlay commands bullet with the per-command answers
- [x] `site/docs.html` and `site/commands.html`: remote page behavior, `page-serve`, `htmlOverlays[].remote` and
      `.replica`, `remoteOverlays[].pageID`, the per-command answers, the `pageRejected` difference
- [x] bundled skill `plugins/agterm/skills/agterm/`: reference (including the HtmlBridge refused list mirror) and a
      SKILL.md pointer
- [x] `ARCHITECTURE.md`: name the new modules beside the remote-presentation ones
- [x] move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification**:
- two Macs, both on this build: attach a Live session, run webrev on the origin, annotate and submit on the
  presenting Mac, and confirm the origin receives the annotations
- a URL page and a chromeless loopback URL page (refused) on a presented session
- an older agterm on the presenting Mac keeps the refusal

Smells pre-check: skipped — non-Go project
