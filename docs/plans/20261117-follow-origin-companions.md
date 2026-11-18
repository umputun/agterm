# Follow origin companions on attached rows

## Overview
- A session attached from another host into a normal window (File ▸ Attach Remote…, `zmx attach`) follows its
  origin's companions: a companion that joins the session on the origin, created there or moved under it, is
  attached under the local parent row by itself, terminal and page companions alike.
- Problem (discussion #1039): an agent on Mac A opens a log, a shell or a report page as a companion of S, and the
  person watching S on Mac B sees nothing and gets no hint. A page companion cannot be reached from the menu at all.
- Reverses the documented rule from #849 and `site/docs.html:826` ("Companions created over there later are not
  followed"); approved by Eugene.
- Works the same for a Mac origin and an agterm-server origin, and for an attached Mac page root.
- A remote window (Open Remote Window) already follows its origin through the catalog and is untouched.

## Context (from discovery)
- Presentation stream: one per attached row, `ssh agtermctl zmx present`, newline JSON `PresentationFrame`
  (`agtermCore/Sources/agtermCore/PresentationFrames.swift`), hub in `PresentationHub.swift`, shared by the Mac app
  and agterm-server (`AgtermServerKit/ServerStreams.swift:59` sets `store.presentationHub`).
- Pattern to copy: `layout` is a replaceable snapshot field (`AppStore+Presentation.swift:17`) plus a delta
  (`publishLayout`, `PresentationHub.swift:304`); the viewer applies it in `AppStore+RemoteLayout.swift`
  (`applyRemoteLayout`, `attachOriginAdditions`) and never re-attaches a replica closed here (`control-api.md:1969`).
- `PresentationHub.publish` sends to every subscriber without a kind check (`PresentationHub.swift:311`); held replay
  goes through the same path, so a new kind needs filtering there.
- Companion mutations on the origin: `addCompanion`, `addPageCompanion`, `convertToCompanion`
  (`AppStore+Companions.swift`), `moveCompanion` (`AppStore+SessionMoves.swift:35`), close and finalize
  (`AppStore.swift:651`).
- Viewer attach paths: `attach(_:from:host:placement:)` claims the lead on every pane (`ControlServer+Zmx.swift:232`);
  origin-added panes use `claim: false` (`ControlServer+AttachedForward.swift:340`); `attachMember` places under an
  explicit parent (`ControlServer+RemoteGroup.swift:52`); pages via `attachRemotePage` /
  `requestRemotePage` (`ControlServer+RemoteCompanions.swift:196,208`); readiness polling `attachWhenListed`, called
  today by `attachCreatedCompanion` and `attachCreated` (`:353`, `:367`), the latter placing a top-level row.
- `placeRemotePage` refuses a loopback URL page and a persistent page whose profile store failed
  (`ControlServer+RemoteCompanions.swift:237-243`) after `requestRemotePage` already took a per-claim attachment.
- Precedent for a post-mutation publisher: `PresentationMailRelay` (`agtermCore/Sources/agtermCore/
  PresentationMailRelay.swift`), one main-queue turn after a mutation, over `hub.subscribedSessions`, deduped.
- Retry precedent: `RemoteRetryBackoff` (`agtermCore/Sources/agtermCore/RemoteReconnect.swift:6`).
- An observer on a Mac origin counts as a viewer in `presentersNode` (`AppStore+RemotePresentation.swift:312-318`).
- Persistence of attached rows: `AttachedSessionSnapshot` / `AttachedOriginSnapshot` (`AttachedSnapshot.swift`).
- A Mac page root attached directly has no presentation stream (`control-api.md:467`); a headless (agterm-server)
  page root does.
- Soft close removes the row from the tree at once and undo restores and regroups it
  (`AppStore+PendingClose.swift:131-142`, `:538-569`); finalize of a soft-closed row runs on a row already absent
  (`:334-345`).
- Mac-wide identity of an attached row: `Session.showsOriginSession` (`WindowLibrary+SessionLink.swift:5`) over
  `WindowLibrary.allOpenSessions()` (`WindowLibrary.swift:271`); an `AppStore` sees one window only.
- `RemotePresentationClient` sends `presenterAcquire` on a presenter hello and on vacancy
  (`RemotePresentationClient.swift:301-309`).

## Development Approach
- **testing approach**: TDD - tests first for each agtermCore rule, then the app paths
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
- run tests after each change, scoped to what changed (`swift test --filter`, `-only-testing:`); the full
  `swift test`, `make test-app` and `make lint` gates run once, in the last task
- maintain backward compatibility: older origins and older viewers keep today's behavior

## Testing Strategy
- **unit tests** (`cd agtermCore && swift test`): frame codec, hub negotiation and filtered publish, origin
  publishing on every membership change, the viewer's reconcile rule, snapshot persistence and seeding.
- **hosted app tests** (`make test-app`, targeted with `-only-testing:` while working): the viewer's attach of a
  followed terminal and page companion through stubbed remote runners, lead not claimed, no selection change,
  local close not re-attached, two local copies, own New Companion not doubled, Mac page root observer stream.
- **XCUITest**: none planned; the behavior needs two hosts, which UI tests do not have. Manual check under
  Post-Completion.
- One test file per source file; new sources get their matching test file.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview
- **Origin side (shared agtermCore, both origins):** the presentation stream gains a `companions` kind. The snapshot
  carries the session's full ordered companion membership; every membership change publishes the whole list again
  as a replaceable frame, only to viewers whose hello listed the kind. A move publishes for both parents. Publishing
  is a relay in the shape of `PresentationMailRelay`: one main-queue turn after any tree change it reads each
  subscribed session's completed membership and publishes only what differs, so soft close, undo, finalize and
  reorder are covered with no edit at each mutation site, and a batch undo never publishes its temporary grouping.
- **Viewer side:** each local attached parent remembers the origin companion ids it has already handled. On a
  membership list, every id not remembered is attached under that exact local row, unless this Mac already shows
  that origin child anywhere (any window, any parent), in which case it is only remembered. So with two local copies
  of one origin session, a new companion is attached once in total and the other copy only remembers it. Marks are
  shared: an origin child attached here by any path (followed, `zmx attach`, group attach, New Companion) is marked
  in every local row bound to the same origin session (host, endpoint, session id), so a copy whose stream was down
  cannot attach it again after it was closed here; each row still seeds its own baseline. A row closed here stays
  remembered, so it is never attached again by itself. Failures fall into three classes:
  - final, marked as handled and never tried again: an explicit policy refusal, which is a loopback URL page or an
    origin too old for the command;
  - retryable, unmarked and retried on `RemoteRetryBackoff` while the row's stream is up: no answer, a timeout,
    a valid receipt over a failed ssh exit (today classed `.refused` at `ControlServer+RemoteCompanions.swift:223-227`,
    which this change splits off), and a persistent page while this Mac's browser storage is being cleared, whose
    end sends nothing from the origin;
  - current state on the origin, unmarked and parked until the next list or reconnect snapshot, with no backoff: a
    child the membership lists that is not an attach candidate after one bounded readiness wait (an ended row, a
    daemon not up), and a page the origin does not offer now (soft-closed there until undo). Known limit, stated in
    the docs: a parked child restarted on the origin keeps its id, kind and order, so the deduped list does not
    change and it is picked up at the next membership change or reconnect, not at the restart; `zmx attach`
    reaches it before then.
  With two local copies a new child gets one row in total; which copy holds it is not specified.
- **Seeding:** at attach time the remembered set starts as the origin's companions listed in the attach-time
  `zmx tree`, so a plain `zmx attach` of a parent does not pull existing companions; `--companions` and Attach
  Remote's group attach keep attaching them explicitly. A restored row keeps its saved set unchanged and reconciles
  the first list it receives, so a companion created while this Mac was away is attached. A saved row from a build
  without the fields is not baselined: its first list becomes the baseline without attaching anything, and that
  state is saved even when the list is empty. `recent.open` of a closed attached parent is a plain attach and seeds
  the same way. An attach-time tree whose `companions` is nil (an older origin) seeds nothing and leaves the row
  unbaselined, so its first list, if one ever comes, becomes the baseline.
- **No pane-lead or selection change:** terminal panes attach with `claim: false` and nothing is selected. The
  row's presentation client behaves as for an explicit attach, presenter acquisition included, so pending work on a
  headless origin (an ask, a pick) may surface on this Mac exactly as it would after a manual attach. Failures are
  logged, never shown as a panel (no user action to report on).
- **Mac page root:** a membership-only observer stream (`zmx present` with only the `companions` kind, never
  acquiring the presenter, never routing work) so its companions follow too. It closes its stream when the origin's
  hello does not agree `companions`. On the origin it counts as a viewer in `presentersNode`, which is stated in the
  docs and pinned by a test.
- **Security:** the untrusted input is the origin's membership frames, from a host the user already attached. The new
  capability is that this Mac opens ssh attaches and page channels with no user action, URL pages included, which
  may use this Mac's saved browser profile when the origin opened them `--persistent`. The bounds: only the host and
  endpoint already bound to the row, ids parsed as UUIDs and validated before any request is made (terminal
  placement then uses the fresh tree's parent and endpoint, page placement the handover's parent), the
  existing page refusals (loopback, profile store) and the missing-daemon guard, and no attach into a row the user
  did not attach from that host. An origin can add rows to this Mac's sidebar under rows the user attached; it cannot
  reach another host, run a local command or open a page outside what an explicit attach of the same child opens.

## Technical Details
- `PresentationCompanions { members: [Member] }`, `Member { id: UUID, kind: "terminal" | "page" }`; the array order
  is the origin's companion order. `nil` in the snapshot means the origin does not support it, never "no
  companions"; an empty list is real.
- `PresentationHub.companionsKind = "companions"`, added to `supportedKinds`; `publishCompanions(_:session:)` mirrors
  `publishLayout` (dedupe against the last sent list) and sends only to subscribers whose kinds include it, held
  replay included.
- Origin ids are `String` throughout the viewer, matching `remoteSessionID`; the wire `Member.id` is decoded as a UUID
  and kept as its string.
- Viewer state, two independent fields on `Session`: `followedCompanions: Set<String>` (origin ids handled here,
  default empty) and `companionsBaselined: Bool`. Saved as optional `AttachedSessionSnapshot.followedCompanions` and
  `.companionsBaselined`; a snapshot without them (legacy row) restores as empty and `false`. Marks always merge into
  the set, whatever the flag. A row with `companionsBaselined == false` takes its first complete membership list as
  the baseline: every listed id joins the set, the flag turns `true`, nothing is attached. So a mark recorded before
  that first list neither seeds the row early nor is lost.
- Reconcile, host-free in agtermCore, as a pure query plus two mutators:
  `AppStore.companionsToFollow(_ list: PresentationCompanions, forSession:, shown: Set<String>) -> CompanionFollow`
  where `CompanionFollow { attach: [Member], markOnly: [String] }` lists, in origin order, the members to attach and
  the ids to mark without attaching (already shown here); it returns nothing for a row not baselined.
  `baselineCompanions(_:forSession:)` takes the first list; `markFollowed(_:forSession:)` merges marks. The app
  builds `shown` at the library seam from `allOpenSessions()` and `showsOriginSession`, and checks it again at
  insertion after every ssh wait (two page offers can be in flight).
- Reconcile always runs against the latest accepted list for that parent; an attach in flight for an id the newest
  list no longer names is dropped before placement.
- Terminal placement requires the fresh `zmx tree` entry's `parent` to equal the row's bound origin session and its
  endpoint to match the binding; `attachWhenListed` today matches the child id only
  (`ControlServer+RemoteCompanions.swift:389-396`), so a child moved away while its daemon starts would otherwise
  attach under the old parent.
- Shared attach contracts change only by opt-in: `RemotePlacement` gains a lead option defaulting to claim, and
  `attachWhenListed` gains an optional expected parent and endpoint, unset by its two existing callers. A test pins
  that `attachCreatedCompanion` and `attachCreated` still claim the lead and do no parent check.
- The follow logic lives in its own file, `agterm/Control/ControlServer+FollowCompanions.swift`, with its own test
  file; waits use the injected `hudClock` and `remoteCompanionPause`, never wall-clock time (`.claude/rules/tests.md`).
- Own New Companion: from before `createRemoteCompanion` issues the create until its explicit placement settles,
  reconcile is deferred for every local row bound to that origin session (host, endpoint, session id), not only the
  initiating row; the result is placed under the initiating row, the created id is marked in all copies, then each
  copy reconciles its newest list. Selection, tint and lead of the user's own request are kept, and no other copy
  attaches the same child meanwhile.
- Each local copy of one origin session follows on its own, keyed by local parent id and origin child id.
- Page follow reuses `requestRemotePage` with a per-copy token and checks the offer's returned parent against the
  local row's origin session before placing.
- Control read-back: the attached parent's session node (declared in `ControlProjection.swift`, built at
  `AppStore.swift:406`) reports `followsCompanions: true` when its origin agreed
  the kind (omitted otherwise), so a script can tell a following row from one on an older origin. No new command:
  the behavior is automatic, and rows it attaches already emit `remote.opened` and carry `parent`.

## What Goes Where
- **Implementation Steps** (`[ ]` checkboxes): code, tests, docs in this repo.
- **Post-Completion** (no checkboxes): two-host manual checks.

## Implementation Steps

### Task 1: Companion membership on the presentation stream (origin side, both origins)

**Files:**
- Modify: `agtermCore/Sources/agtermCore/PresentationFrames.swift`, test `PresentationFramesTests.swift`
- Modify: `agtermCore/Sources/agtermCore/PresentationHub.swift`, test `PresentationHubTests.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+Presentation.swift` (snapshot field), test
  `AppStorePresentationTests.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+Events.swift` (`scheduleTreeChanged` schedules the flush)
- Create: `agtermCore/Sources/agtermCore/AppStore+CompanionMembership.swift` (membership projection and flush)
- Create: `agtermCore/Tests/agtermCoreTests/AppStoreCompanionMembershipTests.swift`

- [x] write failing tests: codec round-trip of the `companions` body and the optional snapshot field; an older
      decoder ignores both; hub sends `companions` only to a subscriber listing the kind, live and from held replay;
      dedupe of an unchanged list
- [x] write failing tests: the snapshot lists a parent's companions in order with kinds; add, page add, convert,
      move (both parents), same-parent reorder, close, soft close and undo of a soft close each publish the
      resulting list one main-queue turn later; finalizing a soft close publishes nothing more (the list is
      unchanged); a batch undo publishes only the final grouping; a session with no companions lists `[]`; the same
      on a headless store, which is what agterm-server runs
- [x] add `PresentationCompanions`, the body case, the snapshot field and `companionsKind`
- [x] add kind-filtered `publishCompanions` in the hub and the filter in held replay
- [x] add the flush: `scheduleTreeChanged` schedules one main-queue turn, once per burst, that reads each subscribed
      session's completed membership and publishes what differs; no mutation site is edited
- [x] run the touched suites with `swift test --filter` - must pass before task 2

### Task 2: Viewer follow state, seeding and reconcile rule (host-free)

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Session.swift` (two fields)
- Modify: `agtermCore/Sources/agtermCore/AttachedSnapshot.swift`, `AppStore+AttachedRestore.swift`, test
  `AppStoreAttachedRestoreTests.swift`
- Create: `agtermCore/Sources/agtermCore/AppStore+FollowCompanions.swift`
- Create: `agtermCore/Tests/agtermCoreTests/AppStoreFollowCompanionsTests.swift`

- [x] write failing tests for `companionsToFollow`: new ids in `attach` in origin order; remembered ids skipped; ids
      in `shown` returned in `markOnly`; a row not baselined returns nothing; a moved-in id counts as new; each local
      copy keeps its own remembered set
- [x] write failing tests for the mutators: `baselineCompanions` adds every listed id and sets the flag, an empty
      list included; a `markFollowed` before the first list keeps the row unbaselined and survives the baseline
- [x] write failing tests for persistence: both fields saved and restored unchanged, an empty baselined set kept
      apart from an unbaselined one, an older snapshot without the keys restores as empty and not baselined
- [x] add `followedCompanions`, `companionsBaselined`, `CompanionFollow`, `companionsToFollow`,
      `baselineCompanions` and `markFollowed`
- [x] save both fields on `AttachedSessionSnapshot` and restore them in `AppStore+AttachedRestore.swift` without
      reseeding
- [x] run the touched suites with `swift test --filter` - must pass before task 3

### Task 3: Viewer attaches followed companions (app)

**Files:**
- Create: `agterm/Control/ControlServer+FollowCompanions.swift` (reconcile driver, per-parent coalescing, retry,
  cross-copy marks and the own-create hold)
- Create: `agtermTests/ControlServerFollowCompanionsTests.swift`
- Modify: `agterm/Control/ControlServer+RemotePresentation.swift` (route the effect), `ControlServer+Zmx.swift`
  (`RemotePlacement` lead option), `ControlServer+RemoteCompanions.swift` (`attachWhenListed` expected parent, page
  receipt parent, own-create hold), `ControlServer+RemoteGroup.swift` and `ControlServer+AttachedRestore.swift`
  (seeding and marks)
- Modify: `agtermCore/Sources/agtermCore/RemotePresentationClient.swift` (advertise the kind, route the body), test
  `RemotePresentationClientTests.swift`
- Modify: `agtermTests/ControlServerRemoteCompanionsTests.swift` (existing callers unchanged)

- [x] write failing hosted tests in `ControlServerFollowCompanionsTests.swift`: a list naming a new terminal companion
      attaches it under the row with no lead claim and no selection change; a new page companion attaches under the
      row; a companion closed here is not attached again; a transport failure, a valid page receipt over a failed
      ssh exit included, is retried on the backoff with no membership change; a loopback page companion is requested
      once and not again; a listed child that never becomes attachable (an ended row) is polled once, parked, and
      polled again only on the next list or reconnect; a persistent page arriving while browser storage is being
      cleared attaches once the clear completes, with no new list, on the backoff; with two local copies a new
      companion gets one row in
      total and the other copy remembers it, two page offers in flight included; a
      child moved away on the origin while its daemon starts is not attached under the old parent; with two copies,
      one stream down, a child the other copy followed and that was then closed here is not attached when the second
      stream reconnects, and the same for a child attached by hand and closed; the user's own New Companion on a row
      is attached once, selected and tinted as requested, and with two copies the other copy attaches nothing and
      remembers it; plain `zmx attach` and `recent.open` of a parent do not pull its existing companions while
      `--companions` still does; an attach-time tree without `companions` leaves the row unbaselined; a restored row
      with a saved set attaches a child created while this Mac was away and leaves a child it had detached alone; a
      row in a remote window (catalog-owned) ignores the frame; an auto-attached headless child takes the presenter
      role as an explicit attach would
- [x] write a test in `ControlServerRemoteCompanionsTests.swift` that `attachCreatedCompanion` and `attachCreated`
      still claim the lead and do no parent check
- [x] advertise `companions` in the client hello and route the body to a new effect
- [x] add the `RemotePlacement` lead option (default claim) and the optional expected parent and endpoint on
      `attachWhenListed`
- [x] seed at plain attach, group attach and `recent.open` from the attach-time tree's `companions`; restore keeps
      the saved set
- [x] attach each followed id: terminal through `attachWhenListed` and `attach` with a `claim: false` lead,
      `select: false` and the expected parent; page through `requestRemotePage` with the returned-parent check and
      `placeRemotePage`; build `shown` at the library seam and check it again at insertion; revalidate the local row
      and its binding after every await; drop an attach the newest list no longer names; mark on success and on a
      final refusal, retry retryable failures on `RemoteRetryBackoff`, park origin-state failures until the next
      list or reconnect; split `requestRemotePage`'s receipt-over-failed-transport case out of `.refused`; log
      failures; waits use the injected clock
- [x] mark every attached origin child, by any attach path, in all local rows bound to the same origin session, and
      do the same for `markOnly` ids
- [x] defer reconcile on every local copy of the origin session while `createRemoteCompanion` runs, then place under
      the initiating row, mark in all copies and reconcile each copy's newest list
- [x] run the targeted hosted tests (`-only-testing:`) and touched `swift test --filter` suites - must pass before
      task 4

### Task 4: Membership-only stream for an attached Mac page root

**Files:**
- Modify: `agtermCore/Sources/agtermCore/RemotePresentationClient.swift` (observer mode), test
  `RemotePresentationClientTests.swift`
- Modify: `agterm/Control/ControlServer+FollowCompanions.swift` (start and stop the observer),
  `ControlServer+RemoteCompanions.swift`, `ControlServer+AttachedRestore.swift`
- Modify: `agtermTests/ControlServerFollowCompanionsTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/RemotePresentationStateTests.swift` (origin read-back with an observer)

- [ ] write failing tests: an observer client advertises only `companions`, never sends `presenterAcquire` on hello
      or vacancy, takes no asks, picks, pages or lead, and closes its stream when the origin's hello does not agree
      the kind; a Mac page root attached directly, refilled at restore and brought back by undo starts the observer
      stream; its page channel stays its lifecycle; an origin without the kind leaves the page row as it is today;
      the origin's `presenters` read-back counts the observer as a viewer
- [ ] add the observer mode and start it for a non-headless page root; keep headless page roots on their stream
- [ ] run the targeted tests (`-only-testing:`, `swift test --filter`) - must pass before task 5

### Task 5: Read-back, skill, docs, and acceptance

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProjection.swift` (node field), `AppStore.swift` (node builder), test
  `AppStoreTreeProjectionTests.swift`
- Modify: the `agtermctlKit` tree printer and its test in `agtermCore/Tests/agtermctlKitTests/` if it prints remote
  fields
- Modify: `plugins/agterm/skills/agterm/SKILL.md`, `plugins/agterm/skills/agterm/reference.md`
- Modify: `site/docs.html`, `site/commands.html`
- Modify: `.claude/rules/control-api.md`, `ARCHITECTURE.md` if it lists the frame kinds

- [ ] write failing tests for `followsCompanions` on the session node: true with an agreeing origin, omitted
      otherwise; and for its CLI output if the tree printer shows remote fields
- [ ] add the read-back and its CLI output
- [ ] docs: `site/docs.html:788` names attaching a Linux host's session into a normal window as well as remote
      windows; `site/docs.html:826`, `site/commands.html:4592` and `reference.md:2558` replace "Companions created
      over there later are not followed" with the follow and local-detach behavior; `site/commands.html` lists
      `followsCompanions`; the skill's SKILL.md says rows follow their origin's companions; with two local copies,
      the docs say a new child gets one row, under either copy; the parked-child restart limit is stated; the
      origin's viewer count
      including a page root's observer is stated
- [ ] rules: `control-api.md` gets the `companions` kind, the relay, the remembered-set contract and the observer
      stream; `:496` is reworded (a child already shown that moves between parents still keeps its old grouping) and
      `:467` is reworded (a Mac page root has a membership-only observer, no full stream)
- [ ] verify every Overview requirement, both origins and the page root case
- [ ] run gates once: `cd agtermCore && swift test`, `make test-app`, `make lint`, the Release build
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification:**
- two Macs on this build: attach S from Mac A on Mac B, then on A run `session new --parent S` and
  `session overlay open --html FILE --companion --target S`; both appear under S on B, B's selection and A's lead
  unchanged; close one on B, create another on A, the closed one stays closed
- the same with an agterm-server host as the origin
- a Mac page root attached on B gains a companion on A
- Mac B on this build attached to Mac A on the previous release: nothing follows, explicit attach still works

Smells pre-check: skipped — non-Go project
