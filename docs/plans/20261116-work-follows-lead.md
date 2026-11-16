# Open work follows the pane's lead

## Overview
- Fixes #1017. An open ask, pick or page is shown on the Mac that leads its target pane, the origin
  included, and moves when the lead moves. Today (#1012) it stays on the Mac where it opened while that Mac
  is connected, so V1 draws a live dialog over a pane covered "used on another Mac" while V2, where the person
  types, shows nothing. When V1 then leaves, a Mac origin takes the ask back to its own screen and dismisses
  the page.
- One rule for users: a question, picker or page is where you are typing into its pane. A disconnect is one
  case of that rule, not a separate one.
- Applies on a Mac origin and on an agterm-server origin; viewers are Macs running the same replica code.
- What a move costs, accepted by Eugene: unsent ask text and pick query are reset, a page reloads (scroll,
  form and JS state lost). Running program overlays never move.
- Eugene's decisions (2026-11-16):
  - a page whose holder is lost and that no viewer can take is shown on the origin instead of dismissed;
  - a dialog the leading Mac cannot show yet (row off screen, another picker up, split pane hidden) waits
    there and shows when it can, instead of coming back to the origin;
  - a page the leading Mac refuses stays on the old Mac and is retried on the next lead event;
  - page connection loss re-offers the page to whoever leads, the same viewer included;
  - the ask's offer is kept outside `Session.swift`; headless move behavior is tested in core.

## Context (from discovery)
- Routing: `PresentationHub.route` (`PresentationHub.swift:311`) returns the newest lead claimant, else the
  grant holder; `AppStore.remoteRecipient` / `pendingRecipient` (`ZmxLead.swift:200-212`); follower gate
  `Session.followsRemotely` (`ZmxLead.swift:218`).
- Ownership: owner = the subscriber's stream generation (`PresentationHub.swift:173`), never reused.
  Ask/pick replies are keyed by request id + owner; page replies by page id + sender only
  (`PresentationFrames.swift:417-570`).
- Mac loss handling: `ControlServer+Presentation.swift:33-36`; headless: `ServerStreams.swift:61-119`
  (`ownerLost` returns work to pending, `offerPendingInteractions` on lead report, grant and loss).
- Viewer refusals: a pick is refused while the viewer's modal is busy and a GUI ask while its row is off
  screen, unless the origin is headless (`ControlServer+Pick.swift:76`,
  `ControlServer+RemotePresentation.swift:139-142`); an anchored ask is refused when its pane is not rendered
  (`AppStore+RemotePresentation.swift:255-258`); a page when its pane is not rendered or its slot is taken
  (`AppStore+ReplicaPage.swift:14-26`).
- Page channels: `claimRemotePage` marks a page claimed before the claim reply is written;
  `pageClaimUnanswered` is the failed-write path (`ControlServer.swift:559-567`); adoption overwrites
  `pageServeStreams[page]` and `onWithdrawn` shuts down by page id. A queued bridge request resolves its page
  by id only (`PageServeStream.swift:349-357`). Loss paths: `PageServeStream.closed`, `pageClaimUnanswered`,
  the owner's `pageClosed(channelLost)` frame (`ControlServer+RemotePage.swift:133`).
- Local slots: GUI asks and picks live in the window's `PickController` (`Pick.swift`), which can only
  resolve; session picks are booked in `SessionPickBook`. Local pages close through
  `HtmlOverlayReleases.release`, which records the page dismissed (`HtmlOverlay.swift:550`). An image page's
  probed pixels exist only in its open options (`AppStore+RemotePage.swift:62`).
- `PresentationHub.batch` wraps sends in `pending.chunk`/`pending.commit`, which viewers predating #949
  ignore (`PresentationHub.swift:213-222`).
- Lead signals: hub `onLeadReport` / `onPresenterGranted` / `onOwnerLost`; layout publish (`:240`) fires no
  callback; the origin's own role changes arrive through `ZmxLeadBook.onChange`, today set only by the viewer
  side (`ControlServer+RemotePresentation.swift:33`).
- File limits: `Session.swift` 1000 lines (lint warns at 1000), `ServerStreamsTests.swift` 1990 of 2000,
  `PresentationFrames.swift` 938.
- `agtermCore` is consumed by the agterm-linux fork: add public API, do not change existing signatures.

## Development Approach
- **testing approach**: code first within each task, its tests written and passing before the task closes.
  Reproduced defects are written first and run red against today's code: the reporter's three steps, a stale
  page close after a re-offer, a queued bridge request after a move, a GUI ask against an unrelated pick.
  New seams are tested once their shape settles. Tests live in `agtermCore` wherever the logic does; hosted
  AppKit tests for app-side code (viewer replica echo and hold, GUI placement, window controllers).
- run the touched tests after each change (`swift test --filter`, `-only-testing`); the full gates once, at
  the end.
- never delete or weaken a test: tests pinning "open work stays with its owner" or a refusal fallback are
  rewritten to the new contract, keeping a separate case for each fallback that still applies. A behavior
  test moved out of `ServerStreamsTests` keeps every assertion.
- `Session.swift` is not touched; no file is split.

## Testing Strategy
- unit tests in `agtermCore/Tests/agtermCoreTests` with the existing two-viewer fixtures
  (`AppStoreRemotePageTests.origin()/claimant()`, `AppStoreRemoteAskTests`, pick tests), and a new
  `AppStoreOpenWorkTests.swift` for the pass on Mac and headless stores.
- `ServerStreamsTests.swift` holds only the headless wiring, one test per event, and stays under 2000 lines.
- hosted app tests (`make test-app`, targeted `-only-testing`) for the Mac host and the viewer side.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix

## Solution Overview
- **Placement of held work.** A piece whose holder is connected has a *place*:
  - the viewer that newest claims its target pane (primary pane for session-wide work) through `lead.report`,
    when (Mac origin) the origin pane reports `follower`, and that viewer can take it;
  - on a Mac origin, the origin itself when its pane role is `leader`;
  - otherwise *none*, and it stays where it is. The grant holder is never a place for a move.
- **Lost work** is placed as headless places it today: `route` (claimant, else grant holder).
  - Headless keeps `ownerLost` + `offerPendingInteractions` unchanged for lost and pending work, page-row GUI
    asks and legacy viewers included.
  - On a Mac origin with no viewer to take it, lost work comes to the origin: an ask as today, a GUI ask or
    pick through local admission (else today's `presentation-lost` / cancel), a page mounted locally through
    the remote -> local seam with its outcome still pending (dismissed only if the local slot cannot take it).
    If a viewer claims later, the next pass moves it out.
- **Reconcile, never react inline.** Every event that can change a place schedules one reconcile pass for the
  session on a later main turn (a stalled send drops a viewer mid-call). Scheduling coalesces: one queued pass
  per session, reading the latest state. No timer, no dwell.
- **Viewers hold, never refuse, the dialogs they cannot show yet**, for an origin that negotiated `offer.id`:
  a pick waits for the viewer's modal slot, a GUI ask for its row to be shown, an anchored ask for its pane to
  render. This extends what viewers already do for a headless origin, and covers new work as well as moves.
- **Offer identity.** Each hand-over carries a fresh `offer` serial that the viewer echoes in every reply; the
  origin acts on a reply only when owner and offer match.
- **Transfer seams.** Moves never go through close/cancel paths, which record outcomes. Take operations
  release a slot without an outcome and keep the request id, deadline, outcome ledger entry, ask registry
  result and any `--block`/`--wait` caller.
- **Admission before withdrawal.** For asks and picks, a move checks what the origin can know about the
  destination (kinds incl. `pending.snapshot`, frame size, a free local slot, GUI fit) before withdrawing the
  holder. Failed local admission while the holder is connected leaves the piece where it is.
- **Two-phase page moves.** A page keeps one current presentation (owner, token, offer, channel) and at most
  one *candidate* offer to its new place. The old holder keeps showing it and stays owner until the candidate
  is confirmed: its channel adopted successfully (channel pages) or its first `pageState` (URL pages). Then
  ownership, token and channel switch in one step and the exact old stream is retired with a tagged close. A
  refusal, an unanswered claim or a claim expiry discards only the candidate; the page stays working where it
  was, and the next event retries. A candidate is also closed on its viewer and discarded when a pass no
  longer wants that destination (the lead moved again before confirmation) and when the page itself ends
  (close, submit, session end); adoption or state is accepted only for the still-current candidate, so a late
  one can neither move nor resurrect the page.
- **Page connection loss** (all three paths) marks the current presentation dead and schedules the pass,
  which re-offers the page to its place, the same viewer included. The retry is bounded by evidence from the
  current offer: a page that reported `load: loaded` under it gets one re-offer, consuming that evidence; one
  that never loaded ends as today. A channel that fails at once cannot loop.
- **Retired page channels.** A non-attachment bridge request runs only while its stream is still the page's
  registered, non-ending channel. Attachment channels keep their own placement check.

## Technical Details
- **Wire.**
  - new kind `PresentationHub.offerIdentityKind = "offer.id"` in `supportedKinds`. An origin listing it also
    tells the viewer to hold dialogs it cannot show yet.
  - `offer: Int?` added to `PresentationAsk`, `PresentationPick`, `PresentationPage` (requests) and echoed on
    `PresentationAskAnswer`, `PresentationAskRef`, `PresentationPickAnswer`, `PresentationPickRef`,
    `PresentationPageChange`, `PresentationPageState`, `PresentationPageResult`. Optional, so older peers
    decode it as absent.
  - the origin allocates offers from one monotonic counter and stores the current one per piece: the ask's in
    a new `RemoteAskOffers` book keyed by ask id (beside `AppStore+RemoteAsk.swift`, the `SessionPickBook`
    pattern), the pick's on its `SessionPickBook` entry, the page's on `RemotePage` (current and candidate).
  - reply check: `owner == current owner && offer == current offer`; a reply with no offer is accepted only
    from an owner that did not negotiate `offer.id`. A page's candidate accepts only its own refusal, claim,
    adoption and first state.
- **Compatibility.** Work may move away from a viewer without `offer.id` (the owner check refuses its later
  replies). A piece is never re-offered to a viewer without `offer.id` that already held it on the same
  stream. A page whose connection breaks on such a viewer while it stays connected ends as today. A
  destination must list `pending.snapshot` and `job.token` (`pendingRecipient`), so `batch` frames reach it.
  A viewer without `offer.id` keeps refusing what it cannot show, with today's fallback.
- **Core API (public, additive).**
  - `AppStore.reconcileOpenWork(forSession:now:local:) -> OpenWorkMoves`: runs the pass. `local` is the host's
    admission and placement for work coming to the origin (GUI fit, a free window modal slot, a free overlay
    slot). The result says whether claim/job expiry must be scheduled.
  - `AppStore.remotePageLost(_ page: UUID)`: the shared page connection loss transition for all three paths on
    both origins, distinguishing the current presentation from a candidate.
  - page candidate confirmation on adoption: `adoptPageServeStream` confirms a candidate and returns the old
    stream to retire, so the host never shuts down a stream by page id alone.
  - `PickController.takeAsk() -> PendingAsk?` and `PickController.takePick() -> PendingPick?`: release the
    modal slot without a result; refused for app-internal picks with a waiter.
  - a local page transfer seam on `AppStore` that empties the slot without touching `HtmlPageOutcomes`, and
    its counterpart that mounts a remote page's `HtmlOverlay` locally under the same id with its outcome still
    registered. An image page stores its probed pixels on the page at open.
  - the ask registry owner moves with a GUI ask: `.window(windowID)` while local, `.session` while remote.
  - viewer side: a held replica ask/pick/anchored ask shows when its slot frees, its row is shown or its pane
    renders, with no new origin offer.
- **Scope of what moves.** Session-bound work only: the session's ask slot, GUI asks whose `PendingAsk.anchor`
  names the session, session picks booked in `SessionPickBook`, and the session's remote and local pages.
  Remotely a session has one ask slot, so a local GUI ask anchored to the session moves only while that slot
  is free; the slot freeing schedules a pass. Window-only dialogs and app-internal picks never move. Running
  or claimed program jobs never move; headless keeps its pending offer of ownerless program jobs. A moved page
  keeps its hidden state, size and point overrides and text seed, as `offerPendingPage` does
  (`AppStore+RemotePage.swift:149-168`).
- **Events that schedule a pass.** Hub `onLeadReport`, `onPresenterGranted`, `onOwnerLost`; a layout publish
  (a primary pane swap changes session-wide placement); the origin's own `ZmxLeadBook.onChange` for a pane of
  a served session, installed by the Mac control server at start alongside the viewer-side `refreshLeads`; a
  page connection loss; a discarded page candidate is not an event. On a Mac origin, local admission becoming
  possible for a session whose work has the origin as its place: a window modal slot or overlay slot freeing,
  the session's ask slot freeing, the session becoming selected, a terminal zoom or dashboard over it
  closing. A pass for a session that left its store or was soft-closed does nothing.
- **Read-back.** No new fields: `ask.remote`, the session's `interactions`, `remoteOverlays` and
  `overlay result --page` already show where each piece is and how it ended. No new command: moves follow
  the lead, which `session lead` already drives.

## Decisions carried from the draft
The earlier design is `docs/plans/completed/20261115-lead-routed-presentation.md` (#1012). Its own table is
carried row by row first, then its Solution Overview rules this plan touches.

| decision | status | reason |
|---|---|---|
| a viewer sends an explicit acquire after hello; first acquire wins | kept | the grant still routes new and lost work for viewers without a claim |
| no preemption, no manual release | changed | open work moves when its pane's lead moves; still no manual release |
| a refused mirror waits for reconnect / `presenter.vacant` (#1008) | kept | unchanged |
| the grant affects new requests only; open work stays put | kept, narrowed | the grant never moves connected work; the lead does |
| connection existence alone never selects a presenter | kept | a lead claim or the origin's own role selects a place |
| loss of the stream is the revocation | changed | loss re-places what the subscriber held |
| work is bound to the owning subscriber's token | kept, extended | owner token plus a per-hand-over offer serial |
| hub accepts answer frames from any subscriber; the store checks owner | kept, extended | the store checks owner and offer |
| #661: pane-targeted work remote only when that pane is `follower` on the origin | kept | it also decides when work comes back to the origin |
| #661: session-wide work follows the primary pane | kept | the primary pane's lead places it; a swap re-places it |
| headless parks work for the subscriber that routes it, offered on report, grant or owner loss | kept | the pass only adds moves of held work |
| a status sound follows the status pane's route | kept | not open work |
| the holder or any viewer claiming a pane forwards clicks and sends status clear/seen | kept | not open work |
| a page from a forwarded click opens on the Mac that clicked | kept for the open, changed after | the next pass moves it to the pane's leader when that differs |
| `presenters.mirrors` / `presenters.viewers` read-back | kept | unchanged |
| follow-ups (dismiss, close, resize, page commands) go to the stored owner, never through routing | kept | the stored owner changes only by a move |
| every new piece: route once, check capabilities, reserve, then send | kept | moves use the same order, with withdrawal after admission or confirmation |
| Lose (Mac): the lost subscriber's work is taken back | changed | re-placed with `route` first; with no viewer, it comes to the origin, pages included |
| open work never moves while its owner is connected | changed | it moves to its place |
| Mac: losing the presenter ends its overlays for good (#630) | changed | pages are re-placed or shown on the origin; dismissed only when no slot can take them |
| a Mac-origin viewer refuses a GUI ask off screen / a pick with a busy modal | changed | it holds them, as it already does for a headless origin |
| claimed or running jobs are never relaunched | kept | program overlays never move |

## What Goes Where
- **Implementation Steps** (`[ ]` checkboxes): code, tests and docs in this repository.
- **Post-Completion** (no checkboxes): two-Mac manual checks, the agterm-linux fork's build.

## Implementation Steps

### Task 1: Offer identity on the wire, and viewers that hold

**Files:**
- Modify: `agtermCore/Sources/agtermCore/PresentationFrames.swift`, `SessionPick.swift`, `PresentationHub.swift`
- Create: `agtermCore/Sources/agtermCore/RemoteAskOffers.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+RemoteAsk.swift`, `AppStore+RemotePage.swift`,
  `AppStore+RemotePresentation.swift`, `AppStore+ReplicaPage.swift`
- Modify: viewer side `agterm/Control/ControlServer+RemotePresentation.swift`, `ControlServer+RemotePage.swift`,
  `ControlServer+Pick.swift`
- Modify: matching core tests; hosted tests for the app-side echo and hold

- [x] reproduce red first: a page re-offered to the same viewer, then that viewer's old `pageClosed` delivered,
      today withdraws the replacement
- [x] add `offer.id`, the optional fields, the counter and per-piece current offer; check offers in
      `resolveRemoteAsk`, `isPresentingRemotely`, pick resolve/refuse and `receiveRemotePageFrame`
- [x] viewer replicas store the offer they were handed and echo it on every reply
- [x] viewer holds, for an `offer.id` origin, a pick while its modal is busy, a GUI ask while its row is off
      screen and an anchored ask while its pane is hidden, showing each when it can
- [x] tests after: codec round trip with and without `offer`; an old offer from the same owner is refused for
      each kind; a reply without `offer` from an older owner is accepted; the hosted echo on each reply kind;
      a held pick shows when the modal frees, a held GUI ask when its row is selected, an ask for a hidden
      split when that pane is shown, each without another origin offer; an older origin still gets refusals
- [x] run the touched tests - must pass before task 2

### Task 2: Transfer seams and two-phase page moves

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Pick.swift`, `SessionPick.swift`, `AppStore+RemoteAsk.swift`,
  `RemoteAskOffers.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+HtmlOverlay.swift`, `AppStore+RemotePage.swift`,
  `HtmlOverlay.swift`, `AppStore+RemoteOverlay.swift`, `PageServeStream.swift`
- Modify: `agterm/Control/ControlServer+PageServe.swift`, `agtermCore/Sources/AgtermServerKit/ServerStreams.swift`
  (retire the exact old stream on confirmation)
- Modify: tests for each

- [ ] implement the take operations, the remote ask/pick reassign (dismiss to the old owner, offer to the new
      one under a fresh offer), local -> remote and remote -> local transfers for each kind with admission
      checked first, and the ask registry owner moved with the ask
- [ ] implement the page candidate: offer, confirmation on adoption or first state, the one-step switch, the
      exact old stream retired, and refusal / unanswered claim / expiry discarding only the candidate
- [ ] store an image page's probed pixels on the page at open
- [ ] tests after: `takeAsk`/`takePick` free the slot with no retained result and drain queued replicas, and
      refuse a pick with an app-internal waiter; a moved ask/pick keeps id and deadline, and `ask result` /
      `--block` returns its answer after a move each way; a local page (html, markdown, image) hands over to a
      viewer and a remote page mounts locally with outcome `pending` and its `--wait` caller waiting; a moved
      page keeps hidden state, size, points and text seed; a candidate's refusal, claim-reply failure and
      expiry leave the old page working; a confirmed candidate's new stream survives the old one's teardown;
      A owns, B gets a candidate, A retakes the lead before B adopts -> B's candidate is closed and its late
      adoption or state moves nothing; the page closed or submitted before confirmation -> the candidate
      replica is closed too and a late adoption resurrects nothing
- [ ] run the touched tests - must pass before task 3

### Task 3: Reconcile pass and the loss transitions

**Files:**
- Create: `agtermCore/Sources/agtermCore/AppStore+OpenWork.swift`
- Create: `agtermCore/Tests/agtermCoreTests/AppStoreOpenWorkTests.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+RemoteOverlay.swift`, `AppStore+RemotePage.swift`,
  `AppStore+Interactions.swift`, `PageServeStream.swift`
- Modify: the existing remote ask/page/pick tests whose contract changes

- [ ] reproduce red first: the reporter's three steps (V2 takes the lead: ask and page stay on V1; V1 leaves:
      ask comes back to the origin, page dismissed); a bridge submit queued on V1's page channel, drained after
      the page moved (to V2, and to V1 again) and the old stream shut, acts on the replacement
- [ ] implement `reconcileOpenWork`, `remotePageLost` with the loaded-evidence bound, and Mac owner loss through
      the pass (route first, then the origin); the headless pass adds moves of held work only
- [ ] admit a non-attachment bridge request in `PageServeStream.answer` only while its stream is the page's
      registered, non-ending channel
- [ ] tests after (Mac store unless noted):
      - V2 takes the lead -> ask, pick and page move to V2, nothing drawn on the origin, V1 gets dismissals, a
        late answer from V1 is refused;
      - the origin takes the lead -> the work comes back; a viewer takes it from the origin -> it leaves;
      - V2 stops claiming with the origin still `follower` -> nothing moves; V1 takes the lead from the origin
        with the origin's role change seen before V1's report -> one move, to V1;
      - V1 disconnects while V2 leads -> work goes to V2; V1, the only viewer, quits -> the ask and the page
        come to the origin, the page's outcome still pending, then move out if a viewer claims; the local slot
        taken -> the page ends dismissed (rewrite `losingOneViewerEndsOnlyThePageItHeld` to this contract);
      - page connection loss on each path, before and after the stream's loss -> a loaded page is re-offered
        once to its place, the same viewer included; one that never loaded under the current offer ends as
        today; a second loss with no new load ends it;
      - the leading viewer refuses a moved page -> the page stays working on the old holder until the next
        lead event, which retries;
      - a viewer without `offer.id` gives work up to another viewer but is never re-offered the same piece;
        a destination without `pending.snapshot` is never chosen;
      - a terminal ask and an anchored GUI ask together: the slot's ask moves, the GUI ask follows once it frees;
      - a pass for a soft-closed or removed session does nothing;
      - headless: held work moves between viewers; lost and pending work, page-row GUI asks and ownerless
        program jobs still go through the pending offer
- [ ] move `ServerStreamsTests`' owner-loss re-offer behavior tests into `AppStoreOpenWorkTests` with every
      assertion kept
- [ ] run the touched tests - must pass before task 4

### Task 4: Event wiring on both origins, docs and gates

**Files:**
- Modify: `agterm/Control/ControlServer+Presentation.swift`, `ControlServer+PageServe.swift`,
  `ControlServer+RemotePresentation.swift`, `ControlServer+Ask.swift`, `ControlServer+Pick.swift`
- Modify: the selection, terminal zoom and dashboard close seams the Mac origin observes
  (`AppStore.swift` selection, `TerminalZoomRegistry`, `DashboardControllerRegistry` owners)
- Modify: `agtermCore/Sources/AgtermServerKit/ServerStreams.swift`, `agtermCore/Sources/agtermCore/PresentationHub.swift`
- Modify: `agtermCore/Tests/AgtermServerTests/ServerStreamsTests.swift` (wiring only, under 2000 lines),
  hosted tests under `agtermTests/`
- Modify: `.claude/rules/control-api.md`, `site/docs.html`, `plugins/agterm/skills/agterm/` where it states
  where open work shows, `ARCHITECTURE.md` if it describes presentation ownership

- [ ] reproduce red first: origin takes the lead while V1 (connected) holds a GUI ask and the window modal
      holds an unrelated pick -> today the ask is cancelled
- [ ] add the hub's layout signal; install the origin `ZmxLeadBook.onChange` observer at server start with the
      viewer-side `refreshLeads`; coalesce scheduling; wire the three page loss paths, candidate confirmation
      and the admission events on the Mac; schedule claim and job expiry after a pass that offered something
- [ ] tests after: each event schedules exactly one pass per session per turn, never inside hub teardown;
      the Mac `local` admission:
      - the unrelated-pick case leaves the ask on V1 and the pick untouched, and brings the ask back once the
        modal frees;
      - session not on screen -> the ask stays on V1 and comes back once the session is selected; with a
        dashboard over it, once the dashboard closes, the lead unchanged throughout;
      - V1 gone, no viewer, the GUI ask cannot be shown -> `presentation-lost` (today);
      - a returned GUI ask/pick that fits is placed with id, deadline and result intact;
      headless: one wiring test per event in `ServerStreamsTests`
- [ ] update the contract once in `control-api.md` (presentation ownership, loss, offer identity, holding, the
      #630 line), cross-referenced; `site/docs.html` attached sessions: where questions and pages show and that
      they follow the lead; the skill if it states the old behavior
- [ ] verify every Overview requirement against the tests; run `cd agtermCore && swift test`, `make test-app`,
      `make lint`, and the app build, once each
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification:**
- origin O and viewers V1, V2 on isolated state dirs: the reporter's three steps from #1017, the origin taking
  the lead back, a page whose channel breaks on a viewer that stays connected, V1 quitting as the only viewer
  while it leads, and V1 quitting while it leads with V2 holding the presenter role. The reporter offered to
  test on two Macs after a release.

**External system updates:**
- agterm-linux consumes `agtermCore`: the new public API is additive; confirm its build.

Smells pre-check: skipped — non-Go project
