# Lead-routed remote presentation

## Overview
- A remote session's new asks, picks, program overlays, pages and status sounds go to the attached Mac that
  leads the target pane, instead of to the one session-wide presenter that asked first.
- Problem (#1007, second ask): with two viewer Macs attached, work reaches the Mac holding the presenter role
  even while the person types on the other one. #661 recorded this as a known limit; #1008 fixed only the case
  where the presenter left.
- One rule for users: a question or page opens on the Mac where you are leading that pane. A session-wide one
  opens where you lead the primary (left) pane. A page from a link you click opens on the Mac you clicked on.
  One already open stays where it opened.
- Works the same for a Mac origin and an agterm-server origin, which share `PresentationHub` in `agtermCore`.
- Older Macs keep today's behavior: they never report a lead, so the presenter grant and `presenter.vacant`
  remain the fallback.
- Security: the new untrusted input is a `lead.report` (and the clicks and clears it now allows) from any
  subscriber of the origin's presentation stream. It can steer new work for a session to that subscriber. That
  is bounded: every subscriber already reaches the stream through ssh as the origin's user, who can run
  `agtermctl` there directly, and a frame line stays capped as today. No new file, network or command
  capability is added.

## Context (from discovery)
- Hub and grant: `agtermCore/Sources/agtermCore/PresentationHub.swift` (`sendToPresenter`, `batchToPresenter`,
  `receive` drops answer frames from any viewer but the holder, `release` → `onPresenterLost`,
  `announceVacancy`), `PresenterGrant.swift` (one holder per session, generation per session).
- Frames: `PresentationFrames.swift`, `PresentationFrame+Codable.swift`; `PresentationLayout.panes`/`primary`
  are origin pane identities. The viewer's exhaustive frame switch is in `RemotePresentationClient.swift`.
- Lead: `ZmxLead.swift` (`ZmxLeadBook.states`, `role(pane:)`; `Session.followsRemotely`, the #661 gate, requires
  every pane to follow for session-wide work; `AppStore.presentsRemotely`, always true when headless).
- Viewer pane mapping: `RemotePresentationState.swift` (`RemoteBinding.localPane(forRemote:)`,
  `remotePane(forLocal:)`, :61-79); layout application `AppStore+RemoteLayout.swift`; viewer client
  `RemotePresentationClient.swift`; app side `agterm/Control/ControlServer+RemotePresentation.swift`.
- Viewer gates: `AppStore+LinkClickRequest.swift:11-12` and `AppStore+RemotePresentation.swift:82-84`
  (`sendToOrigin`) refuse unless `mode == .presenter`.
- Work bound to the presenter generation (`owner`): `AppStore+RemoteAsk.swift`, `SessionPick.swift`,
  `AppStore+RemoteOverlay.swift`, `AppStore+RemotePage.swift`, `AppStore+RemoteTextPage.swift`,
  `AppStore+Interactions.swift`, `AppStore+Presentation.swift` (sound), `AppStore+Status.swift` (clear/seen),
  `agterm/Control/ControlServer+Ask.swift`, `+Pick.swift`, `+ForwardedClick.swift`, `+ImagePage.swift`,
  `+MarkdownPage.swift`, `+DocumentPage.swift`, `+TextPage.swift`, `+PageServe.swift`, `+Detach.swift`,
  `RemotePageChannel.swift`, `AgtermServerKit/ServerStreams.swift`, `ServerActions+Overlay.swift`.
- Read-back: `ControlProjection.swift` (`ControlPresentersNode { mirrors, presenter }`, per-surface `lead`),
  `AppStore+RemotePresentation.swift` (`presentersNode`), CLI `agtermctlKit/SocketClient.swift:591`
  ("mirrored by: N").
- Contracts: `.claude/rules/control-api.md` (58 "presenter" mentions), `site/docs.html#remote-sessions-present`,
  `site/commands.html` (19), `plugins/agterm/skills/agterm/reference.md` (37) and `SKILL.md`, `ARCHITECTURE.md`.
- Downstream: `agtermCore` is a library consumed by the agterm-linux fork, so a changed `public` symbol may break
  that build.

## Development Approach
- **testing approach**: TDD (tests first). Every behavior bullet in a task has its failing test written and run
  before the code that makes it pass.
- complete each task fully before moving to the next
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
- run tests after each change: targeted `swift test --filter` and `-only-testing:` while working; the full
  gates (`swift test`, `make test-app`, `make lint`) once, in the last task
- maintain backward compatibility with viewers and origins that predate the lead report

## Testing Strategy
- **unit tests**: host-free `agtermCore` tests for the claims and routing, the frame codec, ownership and loss
  per owner, the viewer's report and gates; `AgtermServerTests` for the headless origin with two real streams.
- **hosted tests**: `agtermTests` presenter fixtures for the Mac origin's ask, overlay, page, click and sound
  routing, the gate, and fallback to the grant.
- no UI e2e suite covers this; two-Mac behavior stays a manual check (Post-Completion).

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview
- **Report.** A viewer listing the new `lead.report` kind sends the origin, over its presentation stream, the
  set of the session's origin panes it leads, computed in one place from `ZmxLeadBook.states` and the layout
  binding. It sends the set on connect and whenever the computed set changes, whatever changed it: a role
  report, a pane closing or being forgotten, a fresh attach, a binding change.
- **Claim.** The hub keeps each subscriber's latest set intact. A pane's claimant is the subscriber with the
  newest report among those still claiming it, so a stale claim never evicts a live one, an empty set clears a
  subscriber's claims, and a dropped subscriber's claims vanish.
- **Route.** Which subscriber gets new work for `(session, pane?)`:
  1. pane-targeted: that pane's claimant;
  2. session-wide (no pane): the claimant of `layout.primary`;
  3. nobody claims it: the grant holder, exactly as today (older viewers, unowned panes, a scratch pane, which
     the binding does not cover).
- **Gate.** The Mac origin's #661 gate still decides local vs remote and runs first. For pane-targeted work it is
  unchanged (that pane must be `follower` on the origin). For session-wide work it becomes "the primary pane is
  `follower` on the origin", matching where the work is routed. A headless origin has no gate.
- **Own.** Work handed out is owned by the subscriber it went to. The `owner` already on the wire becomes that
  subscriber's connection generation, so viewers echo it unchanged. Every new piece of work follows one
  sequence: route once, check that recipient's capabilities, reserve the work with its token, then send to that
  owner. Reserving first matters because a send can synchronously drop a stalled subscriber, and loss cleanup
  must already see the work.
- **Follow up to the owner.** Dismissals, closes, resizes, page commands, text-page actions and withdrawals go to
  the stored owner, never through routing again, so a lead change cannot redirect work already open.
- **Answer.** The hub accepts answer frames from any subscriber of the session and passes the sender's token;
  the store accepts an answer only from the owner. Frames with no owner:
  - `status.clear` and `status.seen` are accepted from the grant holder or from any subscriber claiming at least
    one of the session's panes;
  - `link.click` is accepted from the same set, and its page and any refusal go back to the sender.
- **Lose.** When a subscriber's stream ends, only the work it owned is taken back (Mac origin) or returned to
  pending (headless). Open work never moves while its owner is connected: a lead change affects new work only.
- **Offer pending.** A headless origin offers pending work per recipient on a lead report, on a grant, and after
  an owner's loss returns work to pending while another route exists. Each recipient gets its own capability
  check and its own batch. Claimed or running jobs are still never relaunched.

## Technical Details
- Frame: `lead.report`, viewer → origin, body `PresentationLeadReport { leaders: [UUID] }`, the origin pane
  identities this viewer leads; a full replacement each time. Negotiated kind `lead.report` in
  `PresentationHub.supportedKinds`; the viewer sends it only when the hello answer lists the kind.
- Hub state: `Subscriber.leads: Set<UUID>` and `Subscriber.leadsAt` (a hub-wide counter bumped per accepted
  report). `claimant(session:pane:)` picks the highest `leadsAt` among subscribers whose `leads` contains the pane.
- Ownership token: `Int`, the subscriber's `SubscriberID.generation`, unique per hub. The hub's surface for work:
  - `route(session:pane:) -> Int?` — the recipient's token (claimant, else grant holder), nil when none;
  - `supports(_ kind:, owner:) -> Bool` — replaces `presenterSupports`, checked on the chosen recipient (also
    behind `presenterShows`, `presentablePoints`, `remoteTextAction`, and the pending `pending.snapshot`/
    `job.token` checks);
  - `send(_:toOwner:) -> Bool` — for the first send and every follow-up; false when that owner is gone;
  - `isConnected(owner:) -> Bool` — replaces `presenterGeneration(session:) == owner && hasPresenter` in page
    claims and `remotePagePlace`;
  - `batch(toOwner:_:)` — replaces `batchToPresenter`, keyed by owner, chunks and commit to that owner;
  - `hasPresenter(session:)` keeps meaning "a grant holder exists" and serves only the fallback; callers that
    ask "does anything remote take this" use `route(...) != nil`.
  `sendToPresenter`, `presenterGeneration(session:)`, `presenterSupports` and `batchToPresenter` go.
- Callbacks: `onPresenterFrame(session, body)` gains the sender's token; `onPresenterLost(session)` becomes
  `onOwnerLost(session, owner)`, fired for every subscriber that drops; loss handlers (`takeBackRemoteAsk`,
  `takeBackRemotePick`, `remoteOverlayPresenterLost`, `returnAskToPending`, `returnToPending`) filter by owner.
- Viewer-side gates: `linkClickRequest` and `sendToOrigin` also pass when the origin negotiated `lead.report` and
  this Mac claims a pane of the session (the clicked pane for a click). An older origin keeps the presenter-only
  rule.
- Read-back:
  - each origin surface in the tree gains `remote: true` when its pane's next work goes to an attached Mac
    (the gate passes and `route` returns a token), absent otherwise;
  - `presenters` gains an optional `viewers`, the count of attached streams; `mirrors` (viewers without the
    fallback grant) and `presenter` (a grant holder exists) stay on the wire unchanged, so a CLI or client of
    either version reads the other's `tree`; the CLI line reads "viewed by: N", from `viewers` or, when absent,
    `mirrors` plus one for a presenter;
  - no viewer-side field is added: the per-surface `lead` already shows what a viewer leads.

## Decisions carried from the draft
The earlier design is `docs/plans/completed/20260918-remote-presentation.md` ("Presenter (slice 2)") plus the
later changes in #661 and #1008.

| decision | status | reason |
|---|---|---|
| a viewer sends an explicit acquire after hello; first acquire wins | kept | it is the fallback for older viewers and unowned panes |
| no preemption, no manual release | kept | a lead change routes new work only; nothing open moves |
| a refused mirror waits for reconnect | changed earlier (#1008) | `presenter.vacant` lets it ask again; unchanged here |
| the grant affects new requests only; open work stays put | kept | same rule now applies per owner |
| connection existence alone never selects a presenter | kept | a lead report selects the target, a connection does not |
| loss of the stream is the revocation | changed | loss revokes only the work that subscriber owned |
| work is bound to the presenter generation | changed | bound to the owning subscriber's token; wire field unchanged |
| hub ignores answer frames from non-holders | changed | accepts from any subscriber; the store checks owner, the hub checks clear/seen/click senders |
| #661: pane-targeted work remote only when that pane is `follower` on the origin | kept | it decides local vs remote; routing decides which remote |
| #661: session-wide work remote only when every pane is `follower` | changed | primary pane only, matching the session-wide route |
| headless parks work for the next presenter | changed | parks for the subscriber that routes it, offered on report, grant or owner loss |
| a status sound goes to the presenter, not the pane leader | changed | it follows the status pane's route like other work |
| only the presenter forwards link clicks and sends status clear/seen | changed | the holder or any viewer claiming a pane, when the origin negotiated `lead.report` |
| a page from a forwarded click opens on the presenter | changed | it goes back to the Mac that clicked |
| `presenters.mirrors` counts non-presenting viewers | kept, redefined | stays on the wire for version compatibility, now "viewers without the fallback grant"; optional `presenters.viewers` counts all |

## What Goes Where
- **Implementation Steps** (`[ ]` checkboxes): code, tests and docs in this repository.
- **Post-Completion** (no checkboxes): manual two-Mac checks.

## Implementation Steps

### Task 1: Lead report frame, claims and routing in the hub

**Files:**
- Modify: `agtermCore/Sources/agtermCore/PresentationFrames.swift`, `PresentationFrame+Codable.swift`,
  `PresentationHub.swift`, `RemotePresentationClient.swift` (switch case only, ignored until Task 3)
- Modify: `agtermCore/Tests/agtermCoreTests/PresentationFramesTests.swift`, `PresentationHubTests.swift`,
  `PresenterGrantTests.swift`

- [x] check the agterm-linux fork for uses of `PresentationFrame.Body` exhaustive switches and of every public
      hub symbol this plan changes (GitHub code search with `fork:true`, or a shallow clone under `/tmp`); record
      the result here
      - melonamin/agterm-linux (pushed 2026-11-08), `agterm-linux/` consumes `../agtermCore` by path. Its one
        `Body` switch has a `default`, so the new case is safe. It calls `onPresenterLost`, the two-argument
        `onPresenterFrame`, `presenterGeneration(session:)`, `hasPresenter`, and the store's
        `takeBackRemoteAsk(forSession:)`, `remoteOverlayPresenterLost(forSession:)`,
        `resolveRemoteAsk(_:forSession:)`, `isPresentingRemotely`, `rejectRemoteOverlay`,
        `remoteOverlaySurfaceClosed`, `receiveRemotePageFrame`; Task 2 changes most of these
- [x] write failing tests: codec round trip of `lead.report`; a report without the negotiated kind is ignored;
      `route` returns the pane's claimant, the primary's claimant for session-wide work, and the grant holder
      when nobody claims; an empty report clears claims; a dropped subscriber's claims vanish; the stale-claim
      sequence (B claims P, A claims P, A reports `[]`) leaves P with B
- [x] add the `leadReport` body, its codec entries and the kind; add the case to the viewer's exhaustive switch
      as a no-op so the package compiles
- [x] store per-subscriber leads with their report order and implement `claimant` and `route`
- [x] run `swift test --filter 'PresentationFramesTests|PresentationHubTests|PresenterGrantTests|RemotePresentationClientTests'`

### Task 2: Per-owner booking, follow-ups, answers, loss and the session-wide gate

**Files:**
- Modify: `agtermCore/Sources/agtermCore/PresentationHub.swift`, `ZmxLead.swift` (`followsRemotely`)
- Modify: `agtermCore/Sources/agtermCore/AppStore+RemoteAsk.swift`, `SessionPick.swift`,
  `AppStore+RemoteOverlay.swift`, `AppStore+RemotePage.swift`, `AppStore+RemoteTextPage.swift`,
  `AppStore+Interactions.swift`, `AppStore+Presentation.swift`, `AppStore+Status.swift`
- Modify: `agterm/Control/ControlServer+Presentation.swift`, `ControlServer+Ask.swift`, `ControlServer+Pick.swift`,
  `ControlServer+ForwardedClick.swift`, `ControlServer+ImagePage.swift`, `ControlServer+MarkdownPage.swift`,
  `ControlServer+DocumentPage.swift`, `ControlServer+TextPage.swift`, `ControlServer+PageServe.swift`,
  `ControlServer+Detach.swift`
- Modify: `agtermCore/Sources/AgtermServerKit/ServerStreams.swift`, `ServerActions+Overlay.swift`
- Modify tests: `agtermCore/Tests/agtermCoreTests/AppStoreRemoteAskTests.swift`, `SessionPickTests.swift`,
  `AppStoreRemotePageTests.swift`, `AppStoreRemoteOverlayTests.swift`, `PresentationHubTests.swift`,
  `agtermCore/Tests/AgtermServerTests/ServerStreamsTests.swift`, `agtermTests/ControlServerPresentationTests.swift`,
  `ControlServerRemotePresentationTests.swift`, `ControlServerForwardedClickTests.swift`,
  `ControlServerPageServeTests.swift`, `ControlServerStatusSoundTests.swift`

- [x] write failing tests, each run red before its code:
      - concurrent left and right overlays and pages owned by two viewers; each answer accepted only from its owner;
      - an ask and a pick routed to the pane's claimant (one slot each, separate cases), and to the grant holder
        when nobody claims;
      - after a lead change, dismiss, resize, page command and withdrawal (`withdrawnFrom`) still reach the
        original owner;
      - dropping one viewer takes back (Mac) or returns to pending (headless) only its work; a subscriber that
        stalls during its own initial offer has that work cleaned up;
      - the status sound routes by its status pane;
      - clear/seen and clicks are accepted from the holder and from a claiming viewer, refused from others;
      - a clicked page and a refusal return to the clicking viewer on both origins;
      - the Mac origin's gate runs first: pane-targeted unchanged, session-wide passes when only the primary
        follows and stays local when the primary leads
- [x] add `route`/`supports`/`send(_:toOwner:)`/`isConnected(owner:)`/`batch(toOwner:)` and remove the old
      presenter-wide calls; book every new piece of work route → supports → reserve with token → send to owner,
      and send every follow-up to the stored owner
- [x] replace grant-generation liveness checks (page claims, `remotePagePlace`) with `isConnected(owner:)`
- [x] let `receive` forward answer frames from any subscriber with the sender's token; accept owner-less frames
      by the Answer rule; fire `onOwnerLost(session, owner)` for every dropped subscriber and filter every loss
      handler by owner
- [x] carry the clicking subscriber's token through the async page helpers and `ServerStreams.clickedPage`
- [x] change `followsRemotely` for session-wide work to check the primary pane; update the #661 tests that pinned
      the every-pane rule
- [x] run the targeted core, server and hosted tests (`-only-testing:` for the hosted ones)

### Task 3: Viewer reports its leads; viewer-side gates

**Files:**
- Modify: `agtermCore/Sources/agtermCore/RemotePresentationClient.swift`, `RemotePresentationState.swift`,
  `AppStore+RemoteLayout.swift`, `AppStore+LinkClickRequest.swift`, `AppStore+RemotePresentation.swift`
  (`sendToOrigin`)
- Modify: `agterm/Control/ControlServer+RemotePresentation.swift`
- Modify tests: `agtermCore/Tests/agtermCoreTests/RemotePresentationClientTests.swift`,
  `AppStoreRemoteLayoutTests.swift`, `RemotePresentationStateTests.swift`, `AppStoreForwardedClickTests.swift`,
  `agtermTests/ControlServerRemoteLinkClickTests.swift`

- [ ] write failing tests: the client sends a report only after a hello answer listing `lead.report`; the
      computed set maps local panes to origin pane ids and skips panes with no binding; the set re-sends on a
      role report, `forget`, a fresh `begin`, a binding change and a remote-window catalog row, and is not
      re-sent when unchanged; an empty set is sent when the Mac leads nothing
- [ ] write failing tests: a claiming mirror may forward a click and send clear/seen to an origin that negotiated
      `lead.report`; the same mirror is refused by an older origin; a non-claiming mirror is refused
- [ ] add the single computation seam and the client's report path, wired from the app side
- [ ] relax `linkClickRequest` and `sendToOrigin` by the Viewer-side gates rule
- [ ] run the targeted tests

### Task 4: Headless pending per recipient, read-back, docs and gates

**Files:**
- Modify: `agtermCore/Sources/AgtermServerKit/ServerStreams.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+Interactions.swift`, `AppStore+RemoteAsk.swift`,
  `AppStore+RemotePage.swift`, `AppStore+RemoteOverlay.swift`, `SessionPick.swift` (the offer functions),
  `ControlProjection.swift`, `AppStore+RemotePresentation.swift` (`presentersNode`, surface `remote`)
- Modify: `agtermCore/Sources/agtermctlKit/SocketClient.swift`
- Modify tests: `agtermCore/Tests/AgtermServerTests/ServerStreamsTests.swift`, `RemotePresentationStateTests.swift`,
  `agtermCore/Tests/agtermctlKitTests/SocketClientTests.swift`
- Modify docs: `.claude/rules/control-api.md`, `site/docs.html`, `site/commands.html`,
  `plugins/agterm/skills/agterm/reference.md`, `plugins/agterm/skills/agterm/SKILL.md`, `ARCHITECTURE.md`

- [ ] write failing tests: a pending ask on pane A reaches the viewer that claims A once its report arrives, not
      the viewer claiming B; pending left and right overlays/pages go to two viewers in separate batches, each
      after its own capability check; a non-grant owner's disconnect while the grant holder stays idle re-offers
      its returned work to the holder; claimed or running jobs are not relaunched; the tree marks a surface
      `remote` exactly when its next work goes to a viewer; `presenters.viewers` and the CLI "viewed by" line;
      a tree without `viewers` (older app) decodes and the CLI derives the total from `mirrors` and `presenter`;
      a tree with `viewers` decodes into a struct that has only `mirrors` and `presenter` (older client)
- [ ] offer pending work per recipient on a lead report, a grant and after owner loss
- [ ] add the surface `remote` field and the optional `presenters.viewers`, keep `mirrors` and `presenter`, and
      update the CLI line
- [ ] sweep every "presenter" statement in `control-api.md`, `commands.html`, `reference.md`, `SKILL.md`,
      `docs.html` and `ARCHITECTURE.md`: state the routing rule, the session-wide gate, click and clear rules, the
      new read-back and the older-Mac fallback once each, in their owning surface
- [ ] verify every Overview requirement on both origins and with an older viewer beside a current one
- [ ] run the gates once: `cd agtermCore && swift test`, `make test-app`, `make lint`
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification**:
- two viewer Macs on one origin Mac: lead the pane on viewer B while A attached first; an `ask open` and a
  `session overlay open --markdown` open on B; take the lead on A and the next one opens on A; the one open on
  B stays there and answers normally.
- split session with the left pane led by A and the right by B: a pane-targeted ask opens on that pane's Mac,
  a session-wide one on A; with the origin leading the right pane, a session-wide one still opens on A.
- click a file link on B while A holds the grant: the page opens on B.
- the same cases against an agterm-server origin.
- one viewer on an older agterm next to a current one: work for panes the older Mac leads goes to the grant
  holder as today.

Smells pre-check: skipped — non-Go project
