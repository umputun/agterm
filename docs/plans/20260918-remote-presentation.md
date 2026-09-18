# Remote presentation for attached sessions

## Overview

A session attached from another Mac (`zmx.attach`) is an ssh pane running `zmx attach` on the origin.
Programs in it run on the origin, carry the origin's `AGTERM_SESSION_ID`, and their `agtermctl` resolves
the origin's socket. So status, notifications, HUD panels, ask dialogs and overlays are drawn on the
origin only; the attaching Mac receives terminal bytes and nothing else.

This plan adds a presentation stream between the two apps, opened by the attaching Mac, in two slices
shipped as two PRs:

- Slice 1, mirror: the origin keeps drawing; the attaching Mac also shows status, control
  notifications and HUD for the attached session.
- Slice 2, sole presenter: the attaching Mac acquires the presenter role and draws session-associated
  ask dialogs and program overlays; the origin stops drawing those while the role is held. The overlay
  program still runs exactly once, on the origin.

Terms: **origin** is the Mac owning the session and its daemons; **viewer** is the Mac that attached.

Decisions already taken:

- the stream opens automatically on every `zmx.attach`; an origin that does not support it leaves the
  terminal attach untouched; malformed frames and failures of a supported protocol are diagnosable through
  logs and read-back and never break the terminal attach
- with a presenter attached, an overlay the viewer rejects or never claims fails as `launch-failed`; the
  origin never opens it locally, where nobody at the viewer could see it
- while a viewer presents an overlay the origin draws nothing for it and its terminal stays usable
- close and resize against a remotely presented overlay are best effort with truthful replies; there is no
  acknowledgment protocol
- `ControlDispatcher.swift` (998 lines against a 1000-line lint limit) has its overlay dispatch moved to
  `ControlDispatcher+Overlay.swift`; no other cleanup

## Context (from discovery)

- `agterm/Control/ControlServer.swift:382-448` `handleConnection` is one request, one reply, close. It sets
  `SO_RCVTIMEO` and `SO_SNDTIMEO` unconditionally (391-395), before the branch that hands
  `zmx.tree`/`zmx.attach` to a worker thread owning the descriptor. `writeResponse` checks its deadline only
  between writes (483-489). Every other request blocks the sole accept thread on
  `runBlocking { await server.dispatch(request) }` (434-437).
- `agterm/Control/ControlServer+Zmx.swift:174-226` `attachRemoteSession` knows the remote session id and
  the per-role daemons, then keeps only `remoteHost` on the local `Session`. It runs `zmx.tree` against
  the origin first. `remoteTree(host:)` rebuilds the decoded answer to stamp `host`, copying only `endpoint`
  and `sessions` (122). `ControlRemoteTree` is declared in `ControlPayloads.swift:149-159` and exposes a
  daemon name per pane (97-109), which `ZmxSupport.swift:181-200` makes a deterministic encoding of the pane
  UUID. The viewer creates its own `Session` identities (`Session.swift:85-87`).
- `agtermCore/Sources/agtermCore/RemoteSession.swift` builds the ssh argv (`BatchMode`, appended PATH
  chain, `/bin/sh -c` wrapping) that the stream's ssh reuses.
- `agtermCore/Sources/agtermCore/ControlEvents.swift` is the public event ring: session, tree, pane,
  remote-visibility, status and notify kinds, 4096 entries, cursor expiry. It is not the stream protocol.
- `AppStore.recordNotificationEvent` (`AppStore+Events.swift:53-61`) receives identical arguments from the
  OSC and the control producers in `agterm/Notifications/NotificationManager.swift`, so provenance has to
  be added at those two call sites. The OSC producer fires from the local surface with focus suppression
  (55-71); an explicit control notify deliberately gets none and records a `notify` event (`send`, 97-108).
- HUD: `HudAutoHide` holds a revision and a task, no deadline (`ControlServer+Hud.swift:12-15`); the store
  is mutated before `writeHudBody` and rolled back on a failed update (136-146); a replacement open first
  destroys the old HUD (`AppStore+Panes.swift:327`) and closes the new one when its body write fails
  (`ControlServer+Hud.swift:99-101`); the real discard seam is `Session.discardHudBody` (406-419), whose
  callback already cancels the timer. `ControlProjection.swift:31-69` projects the configured `hideAfter`.
- `agtermCore/Sources/agtermCore/AppStore+Status.swift:29-37` `applyControlStatus` can refuse a clear
  coming from a different pane, so mirrored state cannot be replayed through `session.status`.
- Ask: `.terminal` is the default style (`Ask.swift:43`). `presentTerminalAsk` uses `session.openAsk` and an
  `AskRegistry` `.session` owner; `presentAsk` reserves the `PickController` window slot and requires the
  target visible on the origin (`ControlServer+Ask.swift:7-85`). `ask.cancel` and `Session.cancelAsk` retain
  a terminal canceled result (94-105); `softCloseSession` cancels before removing the row
  (`AppStore+PendingClose.swift:91-94`); `agterm/Views/AskDialogView.swift:35-42,87-99` renders and resolves
  whenever `askPending` is set and visible. Esc and Command-W resolve as the escaped outcome.
- Overlay: dispatch is in `ControlDispatcher.swift:613-678` and `ControlActions` overlay operations are
  synchronous (92-96). `--block` polls `session.overlay.result` by session plus pane
  (`agtermctlKit/SessionCommands.swift:579-610`, `ControlServer+SessionActions.swift:100-118`); the slot
  result is reset by the next open (`AppStore+Panes.swift:333`). Local completion flows only through
  `agtermApp.swift:664-665,678-680` into that slot. The command contract is a shell string through
  `AGTERM_OVL_CMD`; `OverlayCapture.shellLine` is `( eval "$AGTERM_OVL_CMD" ); echo $? > "$AGTERM_OVL_CODE"`
  (`OverlayCapture.swift:10`), so its shell returns the `echo` status and local overlays read the code file.
  `overlayActive` mounts the local surface (`WindowContentView+Detail.swift:301`) and
  `programOverlayActive` gates zoom, deck and focus (`TerminalZoom.swift:61,78-87`). Read-back today is
  `overlay: Bool`, `overlaySizePercent` and `paneOverlays: [String]?` (`ControlProjection.swift:139-155`).
- An older app ignores an unknown request argument (`control-api.md:120-130`), so a new argument on an
  existing command can be answered for the wrong object; an unknown command fails cleanly.
- `pick.open` carries no session origin (`ControlDispatcher+Pick.swift:48-51`); it and an untargeted GUI
  ask stay on the origin in both slices.
- Soft close emits `session.closed` while the pane survives the undo grace; undo reinserts the same
  `Session` and calls `emitSessionCreated`, not `attachRemoteSession`
  (`AppStore+PendingClose.swift:399-416`); workspace restoration does the same.
- `WindowLibrary.onControlEvent` is `HookController`'s single callback
  (`agterm/Commands/HookController.swift:20`) and is not available to the stream.
- `agtermctlKit/SocketClient.swift` reads one reply; `RemoteCommandProcessRunner` captures until exit or
  deadline. Neither can stream.
- An old installed `agtermctl` rejects an unknown `zmx present` subcommand in ArgumentParser
  (`ZmxCommands.swift:18`) before any new code runs.
- The launched app builds `ControlServer` with no runner (`agtermApp.swift:96-99`), so it gets the real
  default (`ControlServer.swift:175`); only hosted tests inject a fake.

## Development Approach

- **testing approach**: TDD for the host-free state machines in `agtermCore` (frame codec, generation and
  revision ordering, presenter grant, job table, ask ownership). Regular, code then tests in the same
  task, for app-target adapters (stream owner, ssh process, overlay launch).
- model, protocol, validation, routing and response shaping live in `agtermCore`; the app target stays a
  side-effect adapter. `agtermCore` imports no AppKit or GhosttyKit.
- work in a native worktree forked from fetched `origin/master`; symlink the six build artifacts per
  CLAUDE.md.
- start Swift tasks with the `swift-concurrency`, `swift-testing-expert` and, for UI, `swiftui-expert`
  skills.
- every ssh-dependent path runs behind an injected seam with a fake, so no test needs a second Mac.
- no production code path exists only for tests: end-to-end coverage is hosted, where the seams are
  injected, not XCUITest, which would need a launch-selectable fake transport.
- the stream never takes `WindowLibrary.onControlEvent` and never changes the public event ring.
- remote overlay execution is unreachable until Task 20 routes to it; Tasks 16 to 19 leave every overlay
  local.
- `agtermctlKit/SessionCommands.swift` is 907 lines; if a task would push it past 1000, stop and ask before
  splitting it.
- during a task run only its tests (`swift test --filter`, `-only-testing:`); the full gates run once per
  slice, in Tasks 11 and 23.
- complete each task fully before the next; every task includes tests for the code it adds or changes,
  success and error paths; all tests pass before the next task starts.
- update this plan when scope changes during implementation.

## Testing Strategy

- **package tests** (`cd agtermCore && swift test`): all protocol, ordering, grant, job and ask-ownership
  logic, driven with fake clocks and fake transports.
- **hosted tests** (`make test-app`): stream owner descriptor lifecycle against a real socket pair,
  `ControlServer` hand-off keeping the accept thread free, HUD publication and discard, the ask and overlay
  rendering gates, and one end-to-end case per slice with both roles in one process through the injected
  runner. Those end-to-end cases assert what is rendered, not only read-back, so "state exists but nothing
  paints" fails.
- **XCUITest**: exempt, recorded once in `control-api.md`. The commands need a second machine or a
  transport the launched app cannot select.
- **decisive failure tests** (slice 2), each asserting at most one launch, one authoritative answer, and a
  terminating or explicitly unknown result:
  - claim raced against the launch deadline: one winner, and a late claim spawns nothing
  - helper killed before the claim, and after it
  - a healthy job running longer than every failure timeout stays running
  - presentation stream broken while the job ssh stays live, then a close from the origin
  - an old job's result delivered after a new open
  - the viewer rejecting an ask on occupancy
  - the stream lost during ask resolution

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update the plan if implementation deviates from the original scope

## Solution Overview

**Capability.** `zmx.tree` gains an optional `presentation` protocol version in its answer. The viewer
reads it during the attach it already performs. Absent means the origin app predates the feature:
the row reads `unsupported` and no stream ssh is ever launched. This covers an old CLI with an old app and
a new CLI with an old running app alike, and keeps arbitrary ssh or protocol errors out of the
`unsupported` classification.

**Transport.** The viewer opens one non-PTY `ssh -T` per attached session and runs
`agtermctl zmx present` on the origin. That CLI is a thin bridge: it opens the origin's control socket,
sends a `zmx.present` request, and then pumps newline-delimited JSON frames between its stdio and the
socket. Its stdout carries frames and nothing else.

**Origin server.** `handleConnection` recognizes a streaming command, hands the descriptor to a dedicated
stream owner and returns, freeing the accept thread. The owner replaces request/reply socket timing with
stream timing: no idle receive timeout, writes still bounded so a blocked write cannot hang, and a
consumer that stalls past the queue bound or the write bound is disconnected. It reads, writes and shuts
down off the main actor; only short model operations hop onto it. The hub owns liveness state (last ack,
stale timeout, injected clock); the owner owns wire I/O and sends the pings the hub asks for.

**Ordering.** Registering a subscriber, capturing the snapshot and fixing its queue position happen in one
unsuspended main-actor operation, so no change falls between snapshot and first delta. Every connection
has a generation; every frame a monotonic revision. A reconnect gets a new generation and a fresh
snapshot; frames from a stale generation are ignored. Status and HUD are replaceable state. Control
notifications are live one-shot frames, absent from the snapshot and never replayed, so one raised while
the stream is down is not delivered to the viewer.

**Notifications.** Only control-origin notifications are mirrored. An OSC 9/777 notification is excluded
because zmx already carries its bytes to the viewer's own pane, which raises it locally; mirroring it would
post it twice. A mirrored notification is delivered like a local explicit `notify`, with no focus
suppression, and the viewer's own ring records a `notify` event for it, so one originating notification
produces one event on each app. A mirrored delivery is never relayed onward.

**HUD expiry.** The origin stores an expiry deadline from an injected clock. Remaining lifetime is sampled
from it at every publication, the subscribe snapshot included, so a late subscriber never extends a HUD.
State is published only after `writeHudBody` succeeds. Expiry on the two Macs is not synchronized and the
docs say so.

**Meaning of the stream.** An open stream means "presentation connected". It says nothing about the pane
ssh connections, which fail independently. `docs/backlog/host-side-remote-client-events.md` stays open.

**Viewer side.** The attach records the remote session id, an attachment id, and a mapping from each
remote pane identity (decoded once from the daemon name) to the stable local pane identity. The local role
is resolved at use time through `paneRole(forIdentity:)`, so a swap or promotion on either side keeps
status owner, HUD, ask anchor and pane overlay routing correct. Mirrored state is applied through a narrow
remote-owned seam, not through `session.status`. On disconnect the bridge-owned status and HUD are both
cleared, leaving any local state untouched; a local program overlay keeps the slot under the existing
`Session.programOverlayActive` rule. The client follows row visibility: it stops on soft close and restarts
when undo or workspace restoration reinserts the row.

**Reconnect.** While the remote row is visible and the origin advertised the capability, the viewer retries
with backoff capped at 30s, growing to a five-minute cap after repeated failures and resetting after a
healthy connection. It never gives up: an offline or sleeping laptop is ordinary. One `os.Logger` warning
is written per failure episode or changed reason, and the reason is kept in read-back.

**Presenter (slice 2).** After hello the viewer sends an explicit acquire. The origin grants the role to
one connection per session, bounded by the heartbeat; a second viewer is refused and stays a mirror; there
is no preemption and no manual release, since disconnect and lease loss already revoke. The grant affects
new requests only: an overlay already open on the origin stays there. Connection existence alone never
selects a presenter.

**Ask (slice 2).** Both ask styles are covered: the default terminal ask and the GUI ask. The origin owns
the pending ask and its result, separately from any local UI reservation. While remotely presented, the
origin neither renders the ask nor accepts input for it. Frames: `ask.request`, `ask.accepted`,
`ask.rejected`, `ask.resolve` (a button id, or the escaped outcome for Esc and Command-W), `ask.dismiss`.
The origin validates a button id against its stored buttons and derives label and index itself. First
result wins, as today. Three transitions stay distinct:

- cancellation (`ask.cancel`, session or pane teardown): the ask completes canceled, as today, and the
  viewer's replica is dismissed. It is never handed back.
- user dismissal on the viewer: resolves as escaped.
- presentation loss (stream loss, revoked grant, viewer rejection): the origin bumps the ownership
  generation, rejects late resolves, and presents the ask itself. When it cannot, because the target is
  hidden for a GUI ask or an unrelated pick holds the modal slot, the ask completes canceled with reason
  `presentation-lost`. It never waits invisibly and never displaces the unrelated pick.

**Overlay (slice 2).** With a presenter, `session.overlay.open` registers a job, reserves the session or
pane slot against a second open, and sends `overlay.request`. The reservation is separate from coverage:
`programOverlayActive` stays false on the origin, no local surface is mounted, and zoom, deck and focus
behave as drawn. The viewer opens a local overlay whose command is
`ssh -tt <origin> agtermctl session overlay run-job <id>`. The helper's claim is the authoritative
acceptance; `overlay.rejected` fails the job at once and the launch deadline covers silence. Claim and
deadline expiry have one atomic winner: once the claim wins the deadline cannot fail the running job, and
once expiry wins a late claim spawns nothing. A job is never rerun and never launched locally. With no
presenter, overlays behave as they do today.

**Job helper.** `run-job` supervises. It opens a streaming connection to the origin's local socket
(`session.overlay.job.run`, handed off the accept thread like `zmx.present`), claims the job over it,
receives the shell command, cwd and environment, launches the command under the ssh pty, reports
`started`, waits, and reports the exit. It evaluates the command with status-preserving shell semantics
(`/bin/sh -c 'eval "$AGTERM_OVL_CMD"'`), not through `OverlayCapture.shellLine`; what is shared with a
local launch is the command string and the environment. That connection is the helper's liveness: it
stays open for the whole run with ping/ack, the origin sends `cancel` over it, and it is independent of the
presentation stream. Losing the pty or receiving SIGHUP or SIGTERM is a cancellation, the same as a
`cancel` frame: the helper terminates the child, escalates to SIGKILL after a grace period, and reports
`canceled`. That is what makes closing the overlay on the viewer work with no presentation stream.
Outcomes are `exited(code)`, `canceled`, `launch-failed`, and `unknown`. `unknown` is reached only by a
claim with no `started` inside the bounded launch window, or by the helper connection closing without a
terminal report. Elapsed program runtime and presentation-stream loss never produce it, and an ssh exit
of 255 is never read as the program's exit. A claimed job's completion stays valid across
presenter-generation changes.

**Job handle.** `session.overlay.open` returns an additive job id for every overlay, local ones included,
and local completion and close feed the same job table. `--block` polls the job's retained outcome when
the reply carries a job id and falls back to the session-plus-pane lookup when it does not, so a new CLI
still works against an older running app. The job lookup is a distinct command,
`session.overlay.job.result`: an older app fails it as unknown, where a new argument on
`session.overlay.result` would be ignored and answered with another overlay's exit code. A late result for
one job never closes or overwrites another.

**Remote close and resize.** Both send a fire-and-forget frame. Close also cancels through the helper
connection, leaves the accept thread, and waits off the main actor with a bounded deadline for the helper's
terminal report: it replies `execution: ended` with the outcome, or `execution: pending` when the deadline
passes, and always `surface: pending` for a remote overlay, since surface removal is reconciled and not
confirmed. A close that arrives before any helper claimed the job cancels the unclaimed job atomically
and revokes its launch permission: the job ends `canceled`, the slot is released, a late claim is refused
and nothing is launched; racing a claim, either close wins and nothing launches or the claim wins and the
claimant is canceled through its connection. An already-finished job reports its known outcome at once,
except that a retained `unknown` never reads as ended: the helper may have died while the program
survived, so the reply is `execution: unknown` and the outcome stays `unknown`. Resize replies `requested`; read-back
carries the requested size and claims nothing about what the viewer applied, and a viewer-side resize
error is not reported back. Resize with no stream fails explicitly. `session.overlay.text` and
`session.overlay.copy` are refused for a remotely presented overlay.

**Reconciliation.** The origin keeps the set of remote jobs it still expects a viewer to show and sends it
in every snapshot; on reconnect the viewer closes any remote overlay surface whose job is not in it, a held
`--wait` surface included. The viewer's hello lists the remote job ids whose surfaces it still shows for
that attachment, and the origin releases the slot of any expected job missing from that list. That covers
a held surface closed on the viewer while no stream and no helper existed to say so. Releasing the slot
never touches the job's retained outcome.

**Environment.** Nothing but the job id and render settings reaches the viewer. The origin resolves cwd
and builds the launch environment with its own `AGTERM_*` identities, and the helper takes `TERM` from the
ssh pty.

## Technical Details

**Commands added**

| Command | CLI | Slice | Purpose |
|---|---|---|---|
| `zmx.present` | `agtermctl zmx present --session <id> --attachment <id>` | 1 | presentation stream; streaming |
| `session.overlay.job.run` | `agtermctl session overlay run-job <id>` | 2 | helper connection: claim, started, exit, cancel; streaming |
| `session.overlay.job.result` | `agtermctl session overlay job-result <id>` | 2 | retained outcome by job id |

`zmx.tree` gains the optional `presentation` version field. `session.overlay.open` gains `job` in its result.

**Presentation frames** (newline JSON, each with `gen` and `rev`)

- both directions: `hello` (protocol version, supported kinds, mode; slice 2 adds the viewer's shown
  remote job ids), `ping`, `ack`
- origin to viewer, slice 1: `snapshot` (slice 2 adds the expected remote job ids), `status`,
  `hud` (full spec or absent, HUD generation, remaining lifetime sampled at send),
  `notify` (control origin only, with pane and source)
- viewer to origin, slice 2: `presenter.acquire`, `ask.accepted`, `ask.rejected`, `ask.resolve`,
  `overlay.rejected`, `overlay.closed`
- origin to viewer, slice 2: `presenter.granted`, `presenter.refused`, `presenter.revoked`, `ask.request`,
  `ask.dismiss`, `overlay.request` (job id, size, color, follow, pane scope, wait), `overlay.close`,
  `overlay.resize`

**Helper frames** on `session.overlay.job.run`: `claim`, `context`, `refused`, `started`, `exited`,
`canceled`, `launch-failed`, `cancel`, `ping`, `ack`.

Frame size and the pending-output queue are bounded; the limits are constants beside the codec.

**Model additions**

- `Session.remoteBinding`: remote session id, attachment id, remote-pane-to-local-pane identity mapping.
  Immutable, set at construction like `remoteHost`, never persisted.
- `Session.remotePresentation`: bridge-owned status and HUD, connection state (`connecting`, `connected`,
  `unsupported`, `failed(reason)`) and mode (`mirror`, `presenter`).
- origin side: per-session subscriber list, presenter grant (connection, generation), remote ask
  ownership marker, overlay job table with retained outcomes, expected remote job set, HUD expiry deadline.

**Read-back**

- viewer `ControlSessionNode`: `presentation` with state, mode and last error
- origin `ControlSessionNode`: `presenters` with the mirror count (slice 1) and the grant flag (slice 2)
- `overlayJobs`: a new additive list (job id, pane scope, state, `remote`, requested size), beside the
  unchanged `overlay`, `overlaySizePercent` and `paneOverlays`
- while a viewer presents: the origin reports `overlay: false` and `paneOverlays` without that pane, since
  nothing covers it, and the job in `overlayJobs` with `remote: true`; its `ask` node carries the pending
  ask with `remote: true`. The viewer reports a session-wide replica through `overlay: true` and a
  pane-scoped one through `paneOverlays` only, as local overlays do; either way its `overlayJobs` entry
  names the origin job. Its `ask` node carries the replica with `replica: true`.

## What Goes Where

- **Implementation Steps**: code, tests and documentation in this repository.
- **Post-Completion**: verification that needs two real Macs.

## Implementation Steps

### Task 1: Presentation frame model and codec

**Files:**
- Create: `agtermCore/Sources/agtermCore/PresentationFrames.swift`
- Create: `agtermCore/Tests/agtermCoreTests/PresentationFramesTests.swift`

- [ ] write failing tests: round trip of every slice-1 frame, unknown kind tolerated, oversize line refused,
      malformed JSON reported with a diagnosable error, version negotiation picking the lower side
- [ ] define `PresentationFrame` (hello, ping, ack, snapshot, status, hud, notify) with `gen` and `rev`
- [ ] implement the newline codec with the frame-size bound
- [ ] run `swift test --filter PresentationFramesTests` - must pass before Task 2

### Task 2: Origin hub with atomic snapshot and ordered deltas

**Files:**
- Create: `agtermCore/Sources/agtermCore/PresentationHub.swift`
- Create: `agtermCore/Tests/agtermCoreTests/PresentationHubTests.swift`

- [ ] write failing tests: subscribe returns the snapshot before any delta; a change during subscribe lands
      after the snapshot; revisions are monotonic per generation; a second subscriber to one session gets
      its own generation; a full queue disconnects that subscriber only; unsubscribe releases state; the
      snapshot's HUD lifetime is sampled at subscribe through a supplied closure; a missed ack past the
      stale timeout marks the subscriber dead
- [ ] implement `PresentationHub` (`@MainActor`): subscribe, publish, unsubscribe, bounded per-subscriber
      queue behind an injected sink
- [ ] implement liveness state with an injected clock: last ack, stale timeout, ping requests to the sink
- [ ] run `swift test --filter PresentationHubTests` - must pass before Task 3

### Task 3: Publish status to the hub

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore+Status.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreStatusTests.swift`

- [ ] write failing tests: set, idle, clear and pane overrides each reach the hub as full state with owner
      pane and glyph overrides; a refused status change publishes nothing
- [ ] publish full status state from the status mutation seam
- [ ] run `swift test --filter AppStoreStatusTests` - must pass before Task 4

### Task 4: Notification provenance and control-origin publication

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore+Events.swift`
- Modify: `agterm/Notifications/NotificationManager.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreEventTests.swift`

- [ ] write failing tests: a control notification reaches the hub with pane and source; an OSC one does
      not; the public `notify` event is identical for both
- [ ] pass notification origin from both `NotificationManager` producers into `recordNotificationEvent`
- [ ] publish control-origin notifications as one-shot frames
- [ ] run `swift test --filter AppStoreEventTests` - must pass before Task 5

### Task 5: HUD expiry deadline, generation and publication

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Session.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+Panes.swift`
- Modify: `agterm/Control/ControlServer+Hud.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreHudTests.swift`
- Modify: `agtermTests/ControlServerHudAutoHideTests.swift`

- [ ] write failing tests: every discard path publishes absence (close, auto-hide, replacement by an
      overlay); a stale HUD generation cannot close a replacement; a late subscriber gets the remaining
      lifetime, not the configured one; a failed update publishes nothing and the prior HUD stays; a failed
      replacement open never publishes the rejected spec but does publish absence
- [ ] store an expiry deadline from an injected clock in `HudAutoHide`; add a HUD generation
- [ ] publish HUD state after `writeHudBody` succeeds, and absence from `Session.discardHudBody`, keeping
      its existing callback's timer cancellation
- [ ] run the targeted tests - must pass before Task 6

### Task 6: `zmx.tree` presentation capability

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlPayloads.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher+Zmx.swift`
- Modify: `agterm/Control/ControlServer+Zmx.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/RemoteTreeTests.swift`
- Modify: `agtermTests/ControlServerZmxTests.swift`

- [ ] add the optional `presentation` version to `ControlRemoteTree` and emit it from the bare `zmx.tree`
- [ ] preserve it where `remoteTree(host:)` rebuilds the decoded answer to stamp `host`
- [ ] write tests: the field absent decodes; the field present survives `remoteTree(host:)` and reaches
      `attachRemoteSession`
- [ ] run the targeted tests - must pass before Task 7

### Task 7: Stream owner and `zmx.present` hand-off in the control server

**Files:**
- Create: `agterm/Control/ControlStreamOwner.swift`
- Create: `agterm/Control/ControlServer+Presentation.swift`
- Modify: `agterm/Control/ControlServer.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher+Zmx.swift`
- Create: `agtermTests/ControlStreamOwnerTests.swift`
- Modify: `agtermTests/ControlServerTests.swift`

- [ ] add `zmxPresent` to `Command` with its arguments and validation (session must exist and be
      zmx-backed)
- [ ] in `handleConnection`, hand a streaming command's descriptor to `ControlStreamOwner` and return; the
      owner closes it
- [ ] implement the owner, generic over the frame handler so Task 18 reuses it: reader and writer off the
      main actor, `@Sendable` libdispatch closures, bounded write queue, hello exchange, pings on the hub's
      request, orderly shutdown on EOF, stall or server stop
- [ ] replace request/reply socket timing on the handed-off descriptor: no idle receive timeout, a bounded
      write that a blocked peer cannot hang
- [ ] write tests: the accept thread stays free while a stream is open (probe `window.list`); a stream idle
      past `readTimeoutSeconds` stays open; a stalled reader is disconnected without blocking the main
      actor; EOF unsubscribes; server stop closes streams
- [ ] run the targeted hosted tests - must pass before Task 8

### Task 8: `agtermctl zmx present` bridge

**Files:**
- Create: `agtermCore/Sources/agtermctlKit/StreamBridge.swift`
- Modify: `agtermCore/Sources/agtermctlKit/ZmxCommands.swift`
- Create: `agtermCore/Tests/agtermctlKitTests/StreamBridgeTests.swift`

- [ ] implement a streaming socket connection separate from `SocketClient.send`
- [ ] pump stdin to the socket and the socket to stdout; nothing else is written to stdout; diagnostics go
      to stderr
- [ ] a server refusal of the opening request exits nonzero with the error on stderr; it is a failure, not
      an `unsupported` signal, which comes from `zmx.tree` alone
- [ ] write tests against a socket pair: frames pass both ways unmodified, EOF on either side ends the
      bridge, a refused opening request exits nonzero with nothing on stdout
- [ ] run `swift test --filter StreamBridgeTests` - must pass before Task 9

### Task 9: Viewer model: remote binding and remote-owned presentation state

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Session.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`
- Create: `agtermCore/Sources/agtermCore/AppStore+RemotePresentation.swift`
- Modify: `agterm/Control/ControlServer+Zmx.swift`
- Create: `agtermCore/Tests/agtermCoreTests/RemotePresentationStateTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStorePaneSwapTests.swift`
- Modify: `agtermTests/ControlServerZmxTests.swift`

- [ ] write failing tests: a mirrored clear from another pane is applied where `applyControlStatus` would
      refuse it; disconnect clears the bridge-owned status and HUD and leaves local status alone; a local
      program overlay keeps the slot and the mirrored HUD yields; after a pane swap or promotion on the
      viewer, state for a remote pane still lands on the right local pane; the binding is never persisted;
      an origin without the capability sets `unsupported`
- [ ] write a hosted test asserting a mirrored HUD body is written to the surface, not only stored
- [ ] add immutable `Session.remoteBinding`, decoding each remote pane identity from its daemon name once,
      in `attachRemoteSession`, and resolving the local role through `paneRole(forIdentity:)` at use time
- [ ] add `Session.remotePresentation` and the apply/clear seam in `AppStore+RemotePresentation`
- [ ] render mirrored status and HUD through the existing views, reading the merged state
- [ ] run the targeted tests - must pass before Task 10

### Task 10: Viewer client, automatic start and row-visibility lifecycle

**Files:**
- Create: `agtermCore/Sources/agtermCore/RemotePresentationClient.swift`
- Modify: `agtermCore/Sources/agtermCore/RemoteSession.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+Events.swift`
- Create: `agterm/Control/RemotePresentationProcess.swift`
- Modify: `agterm/Control/ControlServer+Zmx.swift`
- Modify: `agterm/Notifications/NotificationManager.swift`
- Create: `agtermCore/Tests/agtermCoreTests/RemotePresentationClientTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/RemoteSessionTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStorePendingCloseTests.swift`
- Create: `agtermTests/RemotePresentationProcessTests.swift`

- [ ] write failing tests for the client state machine with a fake transport and clock: hello then
      snapshot then deltas; stale-generation frames ignored; missed ack marks the stream stale and
      reconnects; backoff capped at 30s, growing to five minutes after repeated failures, reset by a healthy
      connection, never stopping; one warning per failure episode; no launch at all for an `unsupported`
      row; soft close stops the client and undo restarts it with a fresh generation; workspace restoration
      restarts it
- [ ] add `RemoteSession.presentCommand(host:endpoint:session:attachment:)` reusing the BatchMode and PATH
      chain, `-T`, no lifetime deadline
- [ ] implement `RemotePresentationProcess`: long-lived `Process` with stdio pipes behind the injected seam,
      SIGTERM on stop, stderr to `os.Logger`
- [ ] drive start and stop from `emitSessionCreated` and `emitSessionClosed` for a remote row with a
      binding, so every producer of those edges is covered; a start failure never fails the attach
- [ ] deliver a mirrored `notify` through the explicit-notify path of `NotificationManager`, with no focus
      suppression, marked so it is never relayed onward
- [ ] run the targeted tests - must pass before Task 11

### Task 11: Slice 1 read-back, end-to-end test and gates

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlPayloads.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProjection.swift`
- Modify: `agtermCore/Sources/agtermctlKit/SocketClient.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreTreeProjectionTests.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/SocketClientTests.swift`
- Modify: `agtermTests/ControlServerZmxTests.swift`

- [ ] add `presentation` to the viewer session node and `presenters` with the mirror count to the origin
      session node, with CLI human output
- [ ] write projection and CLI tests for both fields, including `unsupported` and `failed(reason)`
- [ ] add one hosted end-to-end test with both roles in one process through the injected runner: attach,
      set status and open a HUD on the origin session, assert the viewer row renders both, close the stream,
      assert the mirrored status and HUD are both gone from the viewer
- [ ] run `cd agtermCore && swift test`, `make test-app`, `make lint` once; all green

### Task 12: Slice 1 documentation

**Files:**
- Modify: `.claude/rules/control-api.md`
- Modify: `ARCHITECTURE.md`
- Modify: `site/docs.html`, `site/commands.html`, `site/llms.txt`
- Modify: `plugins/agterm/skills/agterm/SKILL.md`, `plugins/agterm/skills/agterm/reference.md`,
  `plugins/agterm/skills/agterm/examples.md`

- [ ] document the stream and its meaning (presentation connected, not pane attached), unsynchronized HUD
      expiry, the OSC exclusion and its reason, one `notify` event on each app, the notification limitation
      while disconnected, the reconnect policy, and the far-side `agtermctl` PATH precondition
- [ ] rewrite the control-api.md statement that `zmx.tree` and `zmx.attach` are the only commands leaving
      the accept thread to describe streaming hand-off
- [ ] record the XCUITest exemption for the presentation commands in control-api.md
- [ ] no surface states a command total

Slice 1 ends here and ships as its own PR.

### Task 13: Presenter grant and viewer acquisition

**Files:**
- Create: `agtermCore/Sources/agtermCore/PresenterGrant.swift`
- Modify: `agtermCore/Sources/agtermCore/PresentationFrames.swift`
- Modify: `agtermCore/Sources/agtermCore/PresentationHub.swift`
- Modify: `agtermCore/Sources/agtermCore/RemotePresentationClient.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProjection.swift`
- Create: `agtermCore/Tests/agtermCoreTests/PresenterGrantTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/RemotePresentationClientTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/PresentationFramesTests.swift`

- [ ] write failing tests, origin: acquire grants one connection per session; a second is refused and keeps
      mirroring; no preemption; a missed heartbeat or a closed stream revokes and bumps the generation;
      a slice-1 peer negotiates down to mirror
- [ ] write failing tests, viewer: the client sends acquire after a hello that offers presenter mode;
      granted, refused and revoked each update `remotePresentation.mode`; a reconnect acquires again
- [ ] add the slice-2 frames to the codec, with round-trip tests
- [ ] implement `PresenterGrant`, wire it into the hub, and wire acquisition into the client
- [ ] project the mode on the viewer node and add the grant flag to the origin's `presenters`
- [ ] run the targeted tests - must pass before Task 14

### Task 14: Ask ownership split on the origin

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Ask.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlAsk.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher+Ask.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProjection.swift`
- Modify: `agterm/Control/ControlServer+Ask.swift`
- Modify: `agterm/Views/AskDialogView.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AskTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherAskTests.swift`
- Modify: `agtermTests/ControlServerAskTests.swift`, `agtermTests/AskDialogViewTests.swift`

- [ ] write failing tests for both styles, the default terminal ask (`session.openAsk`, `AskRegistry`
      `.session` owner) and the GUI ask (`PickController` reservation, origin visibility): with a presenter
      a session-associated ask is marked remotely presented and takes neither local path; `AskDialogView`
      neither renders nor resolves it; a resolve with an unknown button id or a stale generation is refused;
      an escaped resolve completes escaped; the first result wins when two resolves race
- [ ] write failing tests for the three transitions: `ask.cancel`, soft close and pane teardown complete
      canceled and send `ask.dismiss`, never handing the ask back; viewer rejection, stream loss and revoked
      grant return it to the origin under a new generation; when the origin cannot present it (hidden GUI
      target, or an unrelated pick holding the slot) it completes canceled with reason `presentation-lost`
      and the unrelated pick is untouched
- [ ] separate authoritative pending and result ownership from the local UI reservation
- [ ] route `ask.request` and `ask.dismiss` through the hub; untargeted GUI ask and `pick.open` stay local
- [ ] report a remotely presented ask on the origin's `ask` node with `remote: true`, with a projection test
- [ ] run the targeted tests - must pass before Task 15

### Task 15: Ask presentation on the viewer

**Files:**
- Modify: `agtermCore/Sources/agtermCore/RemotePresentationClient.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+RemotePresentation.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProjection.swift`
- Modify: `agterm/Control/ControlServer+Ask.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/RemotePresentationClientTests.swift`
- Modify: `agtermTests/ControlServerAskTests.swift`

- [ ] write failing tests: the viewer answers `ask.accepted` only after its dialog is reserved; occupancy or
      a missing visible pane answers `ask.rejected`; `ask.dismiss` and a revoked generation hide the dialog
      without resolving; a button travels as an id only; Esc and Command-W send the escaped outcome; the
      replica appears on the viewer's `ask` node with `replica: true`
- [ ] present the remote ask in its own style through the existing ask UI against the mapped local session
      and pane
- [ ] send `ask.resolve` with the presenter generation and tear the dialog down on dismiss
- [ ] run the targeted tests - must pass before Task 16

### Task 16: Overlay dispatch split, job table and job handle for local overlays

**Files:**
- Create: `agtermCore/Sources/agtermCore/ControlDispatcher+Overlay.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift`
- Create: `agtermCore/Sources/agtermCore/OverlayJobs.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlPayloads.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProjection.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+Panes.swift`
- Modify: `agterm/agtermApp.swift`
- Modify: `agterm/Control/ControlServer+SessionActions.swift`
- Modify: `agtermCore/Sources/agtermctlKit/SessionCommands.swift`
- Create: `agtermCore/Tests/agtermCoreTests/OverlayJobsTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherOverlayTests.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/CommandsTests.swift`
- Modify: `agtermTests/ControlServerSessionActionsTests.swift`

- [ ] move the overlay dispatch block out of `ControlDispatcher.swift` into
      `ControlDispatcher+Overlay.swift` unchanged; `ControlDispatcherOverlayTests` still pass
- [ ] write failing tests: every open gets a job id; local program exit and local close complete that job;
      a late result for job X leaves job Y and its slot untouched; the session-plus-pane lookup still
      answers; `--block` polls the job when the reply has one and falls back to the slot lookup when an
      older app returns none
- [ ] implement `OverlayJobs` with states unclaimed, claimed, running, and outcomes exited, canceled,
      launch-failed, unknown, retained for polling
- [ ] capture the job id in the overlay completion and close callbacks in `agtermApp.swift` and feed the table
- [ ] return `job` from `session.overlay.open`; add `session.overlay.job.result` and
      `agtermctl session overlay job-result <id>`
- [ ] add the additive `overlayJobs` read-back list, leaving `overlay`, `overlaySizePercent` and
      `paneOverlays` unchanged
- [ ] run the targeted tests - must pass before Task 17

### Task 17: Overlay launch context built on the origin

**Files:**
- Modify: `agtermCore/Sources/agtermCore/OverlayCapture.swift`
- Modify: `agtermCore/Sources/agtermCore/OverlayJobs.swift`
- Modify: `agterm/agtermApp.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/OverlayCaptureTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/OverlayJobsTests.swift`

- [ ] build the job's launch context in one place shared with the local overlay launch: the
      `AGTERM_OVL_CMD` command string, cwd resolved on the origin, the origin's `AGTERM_*` identities;
      `TERM` is left for the helper to take from its pty; the `shellLine` wrapper and its code file stay
      local-only
- [ ] write a test comparing the variables a local overlay launch receives with those the job context
      carries, listing every deliberate difference, and asserting no viewer session id or socket path can
      enter the context
- [ ] run the targeted tests - must pass before Task 18

### Task 18: Origin helper connection and the claim-versus-expiry state machine

**Files:**
- Modify: `agtermCore/Sources/agtermCore/OverlayJobs.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Create: `agterm/Control/ControlServer+OverlayJobs.swift`
- Modify: `agterm/Control/ControlServer.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/OverlayJobsTests.swift`
- Create: `agtermTests/ControlServerOverlayJobsTests.swift`

- [ ] write failing table tests: claim raced against launch-deadline expiry yields exactly one winner; once
      the claim wins, the deadline cannot fail the running job; once expiry wins, the job is
      `launch-failed` and a late claim is refused; the grant is single use and bound to job, attachment and
      generation; a claim with no `started` inside the launch window ends `unknown`; the helper connection
      closing without a terminal report ends `unknown`; a running job with a live connection stays running
      past every timeout; completion of a claimed job is accepted after the presenter generation changed
- [ ] add streaming `session.overlay.job.run`, handed to `ControlStreamOwner`, with the helper frames
- [ ] deliver `cancel` to a job's helper connection from the job table
- [ ] write hosted tests against a fake helper peer: claim returns the context; a second claim is refused;
      connection loss marks the job `unknown`; cancel reaches the peer
- [ ] run the targeted tests - must pass before Task 19

### Task 19: `run-job` supervising helper

**Files:**
- Create: `agtermCore/Sources/agtermctlKit/OverlayRunJob.swift`
- Modify: `agtermCore/Sources/agtermctlKit/SessionCommands.swift`
- Create: `agtermCore/Tests/agtermctlKitTests/OverlayRunJobTests.swift`

- [ ] implement `agtermctl session overlay run-job <id>`: connect, claim, spawn the shell command as a child
      under the inherited pty with foreground process-group handling, forward SIGWINCH, wait, report, exit
      with the program's status, evaluating the command with status-preserving semantics
- [ ] a `cancel` frame, pty loss, SIGHUP or SIGTERM terminates the child, escalates to SIGKILL after a grace
      period, and reports canceled
- [ ] write tests with a real child process: a program exiting 3 yields job result 3 and helper exit 3; pty
      loss with a child that ignores the first signal still ends `canceled` with the child gone; a refused
      claim launches nothing; cancel ends `canceled`; a report failure does not change the helper's own
      exit status
- [ ] run `swift test --filter OverlayRunJobTests` - must pass before Task 20

### Task 20: Origin overlay routing, best-effort close and resize

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher+Overlay.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlActionsDefaults.swift`
- Modify: `agtermCore/Sources/agtermCore/OverlayJobs.swift`
- Modify: `agtermCore/Sources/agtermCore/PresentationHub.swift`
- Modify: `agtermCore/Sources/agtermCore/Session.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProjection.swift`
- Modify: `agterm/Control/ControlServer.swift`
- Modify: `agterm/Control/ControlServer+SessionActions.swift`
- Modify: `agterm/Control/ControlServer+SurfaceIO.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlDispatcherOverlayTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreTreeProjectionTests.swift`
- Modify: `agtermTests/ControlServerSessionActionsTests.swift`, `agtermTests/ControlServerTests.swift`

- [ ] write failing tests: grant then open reserves the slot, sends `overlay.request`, mounts nothing
      locally, leaves `programOverlayActive` false, and zoom and deck on the origin behave as uncovered; a
      second open against the reserved slot is refused; an overlay already local when the grant arrives
      stays local; `overlay.rejected` and deadline expiry each end the job `launch-failed` with no local
      launch; with no presenter an open is local as today
- [ ] implement the reservation separately from coverage, the `overlay.request` emission and the launch
      deadline
- [ ] write failing tests for close: it leaves the accept thread and does not block `window.list` or the
      helper's report; it replies `execution: ended` with the outcome once the helper confirms and
      `execution: pending` at the deadline; `surface: pending` for a remote overlay; an already-finished job
      answers at once, but a retained `unknown` replies `execution: unknown` and stays `unknown`; with the
      stream down it still ends execution; open, close before any claim, then a late claim: the job is
      `canceled`, nothing launches, the slot is free; close raced against a claim either prevents the launch
      or cancels the claimant
- [ ] make `closeSessionOverlay` async in the `ControlActions` requirement (`ControlDispatcher.swift:94`)
      and its callers; for a remote overlay: atomic cancel of an unclaimed job in `OverlayJobs`, else cancel
      through the helper connection, bounded wait off the main actor, fire-and-forget `overlay.close` frame
- [ ] resize replies `requested`, records the requested size in `overlayJobs`, and fails explicitly with no
      stream; `session.overlay.text` and `.copy` refuse a remote overlay; tests for each
- [ ] project the origin's nodes during remote presentation (`overlay: false`, `paneOverlays` without the
      pane, the job with `remote: true`), with projection tests
- [ ] run the targeted tests - must pass before Task 21

### Task 21: Overlay reconciliation in both directions

**Files:**
- Modify: `agtermCore/Sources/agtermCore/PresentationHub.swift`
- Modify: `agtermCore/Sources/agtermCore/OverlayJobs.swift`
- Modify: `agtermCore/Sources/agtermCore/PresentationFrames.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/PresentationHubTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/OverlayJobsTests.swift`

- [ ] write failing tests: every snapshot carries the expected remote job set; a viewer hello missing an
      expected job releases that job's slot and leaves its retained outcome unchanged; a `--wait` job exits
      0, the stream drops, the viewer's held surface is closed, the viewer reconnects: the origin's slot is
      free, the job result is still exited 0, and a new overlay opens
- [ ] keep the expected remote job set on the origin and include it in the snapshot
- [ ] on a viewer hello, release the slot of every expected job the viewer no longer shows
- [ ] run the targeted tests - must pass before Task 22

### Task 22: Overlay presentation on the viewer

**Files:**
- Modify: `agtermCore/Sources/agtermCore/RemotePresentationClient.swift`
- Modify: `agtermCore/Sources/agtermCore/RemoteSession.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore+RemotePresentation.swift`
- Modify: `agtermCore/Sources/agtermCore/ControlProjection.swift`
- Modify: `agterm/Control/ControlServer+SessionActions.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/RemotePresentationClientTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/RemoteSessionTests.swift`
- Modify: `agtermTests/ControlServerSessionActionsTests.swift`

- [ ] write failing tests: `overlay.request` opens a local overlay with the run-job ssh command on the
      mapped pane; occupancy answers `overlay.rejected`; the stream dropping while the job ssh lives leaves
      the overlay running and a close from the origin still ends it; closing on the viewer tears down the
      job ssh and sends `overlay.closed` when a stream exists; with the stream down, viewer close still ends
      the job `canceled`; `overlay.close` and `overlay.resize` frames are applied locally; a reconnect
      snapshot lacking a job closes its surface, a held `--wait` one included; the reconnect hello lists
      only surfaces still shown
- [ ] add `RemoteSession.runJobCommand(host:endpoint:job:)` with `-tt`
- [ ] preserve size, color, follow, pane scope and `--wait` from the request; the held `--wait` surface on
      the viewer is distinct from program completion on the origin
- [ ] name the origin job on the viewer's `overlayJobs` entry; projection tests assert a session-wide
      replica sets `overlay` and a pane-scoped replica appears in `paneOverlays` only
- [ ] run the targeted tests - must pass before Task 23

### Task 23: Verify acceptance criteria

**Files:**
- Modify: `agtermTests/ControlServerZmxTests.swift`

- [ ] slice 1: status, control notifications and HUD for an attached session appear on the viewer;
      mirrored status and HUD clear on disconnect
- [ ] slice 2: a session-associated ask of either style and a program overlay appear on the viewer only,
      the program runs once on the origin, and `--block` returns its real exit status
- [ ] every decisive failure test from Testing Strategy exists and passes
- [ ] an origin without the capability leaves the attach working, launches no stream ssh, and the viewer
      row reads `unsupported`
- [ ] add one hosted end-to-end test for slice 2 through the injected runner: an ask answered on the viewer
      completes the caller; an overlay job runs once, renders on the viewer only, and returns its status
- [ ] run `cd agtermCore && swift test`, `make test-app`, `make lint` once; all green

### Task 24: [Final] Update documentation

**Files:**
- Modify: `.claude/rules/control-api.md`
- Modify: `ARCHITECTURE.md`, `README.md`
- Modify: `site/docs.html`, `site/commands.html`, `site/llms.txt`, `site/index.html`
- Modify: `plugins/agterm/skills/agterm/SKILL.md`, `plugins/agterm/skills/agterm/reference.md`,
  `plugins/agterm/skills/agterm/examples.md`

- [ ] extend control-api.md Remote sessions with the presenter, ask and overlay job contracts: the three
      ask transitions, the job outcomes, `launch-failed` in place of a local fallback, the uncovered origin,
      best-effort close and resize wording, and the `text`/`copy` refusal for a remote overlay
- [ ] update the streaming hand-off statement in control-api.md to include the helper connection and the
      async remote close
- [ ] mirror the new commands, arguments and read-back fields in `site/commands.html` and the bundled skill;
      update `site/docs.html`; touch `README.md` and `site/index.html` only where remote attach is described
- [ ] no surface states a command total
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification on two Macs**

- attach a session, run revdiff in it from the viewer, annotate, confirm the origin shows no overlay, its
  terminal stays usable, and the caller gets the result
- pull the network cable during an open overlay and during a pending ask; confirm the documented outcomes
- leave a revdiff overlay idle for longer than every timeout; confirm it stays open and completes normally
- open an overlay while the viewer already shows one; confirm the caller gets `launch-failed`
- attach the same session from two viewers; confirm the second stays a mirror
- soft-close an attached session and undo; confirm mirroring resumes
- sleep the viewer for an hour and wake it; confirm the stream reconnects
- attach to an origin running a build without the capability; confirm the terminal works and the row reads
  `unsupported`
- confirm the second ssh authenticates silently under the same key setup the attach already requires
