# Hold a new pane's command until its terminal attaches

## Overview
- A Live pane's program can query the terminal before any real terminal is attached, and the query is lost.
  Locally, `agterm-session-host` creates the daemon through a temporary `zmx attach` on its own PTY. That
  attach is the daemon's only terminal until the pane's client attaches, and it answers DA1/DA2 only. OSC 10/11
  and CPR written in that window get no reply. On agterm-server the pane is created with `attach --detached`, and
  the Mac attaches later over ssh, so the same queries reach no client at all.
- Visible symptom: codex probes DA1, CPR, OSC 10 and OSC 11 once at startup under one 250 ms deadline and,
  without both colour replies, draws its composer with no background band for the life of the process.
- Evidence (2026-11-21, live terminal, read-only):
  - daemon grids (`zmx history --screen --vt`): the failing `.dot-files` and reproxy codex panes emit RGB
    foregrounds (`38;2;...`) but no background anywhere; a codex started in the same directory in a companion
    emits the expected `48;2;72;72;72` composer fill from the reported `#303030` background.
  - the failing pane's zmx log at its restart: the host's creation attach connects, becomes leader and sends
    Init, then disconnects leaving zero clients; the pane's attach then connects and Inits with a screen snapshot.
  - a survey of ~38 live codex panes found the band missing in most, including all 21 restored together at
    launch on Nov 13; a raw probe restarted 13 times in a companion got every reply, so the loss is timing-bound.
- Fix: a zmx opt-in that creates the daemon detached and parks the forked child before `exec` until the first
  real terminal has sent Init and set the PTY size, or until a bound expires, whichever comes first. Either way
  the command starts exactly once. A bound expiry delays the start by the bound and otherwise gives today's
  behaviour: unanswered queries and, for a fast command, output lost before the attach.
- The session host creates through it for every local pane. agterm-server uses it when the create or restart
  carries an explicit attach-pending intent, which the Mac sends from every path that creates or restarts an
  origin pane and then attaches it.
- Approved limitation (Eugene, 2026-11-21): a create or restart that starts on the server itself, such as an
  agent running `agtermctl session new --command codex` or `/chat` restarting its right pane inside a server
  session, carries no intent and starts at once, as today; codex started that way can still miss its band. It is
  documented, not fixed.
- Also fixes `docs/backlog/fast-live-command-loses-output-in-host-handoff.md`: a fast command's output now
  reaches the pane's client, because the client is attached before the command runs (unless the bound expired).

## Context (from discovery)
- zmx creation: `daemonize.zig` `daemonize`/`spawnPty`/`exec` (fork, child execs the payload; the daemon takes
  its initial size from the creator's stdout), `main.zig` `--detached` (`zmx.create`), `loop.zig` `handleInit`
  (leader, resize, snapshot) and `relayPtyOutput` (pre-Init DA answers). Patched tree: `scripts/zmx-patches/`,
  checked by `check.py`.
- Session host: `SessionHostRuntime/Host.swift` `handle(ensure:)` / `awaitLeader` / `Configuration`,
  `HostBackend.swift` `NativeHostChild` (PTY drain, `settleAttributeReplies`) and `spawn` (`PTYProcess.spawn`
  with the pane's rows and cols, the responsibility-root spawn TCC attribution relies on),
  `DeviceAttributeResponder.swift`, `Client.swift` (the pane's client asks the host to ensure, then execs the
  real attach).
- Foreground reads: `CommandRestore.paneForeground`, called by `agterm/Ghostty/ForegroundProcess.swift:31`
  (restore capture) and `:80` (tree, replay, duplicate), `AgtermServerKit/ServerActions.swift:116` (server tree)
  and `ProcTable.swift:87` (server replay).
- Server: `ZmxRunner.swift` `create`, `ServerPanes.start`, `ServerActions+Sessions.swift`,
  `ServerActions+Companions.swift` (`startCopy`, `convertCompanion`), `ServerActions+Scratch.swift`
  (`scratchSession`), `ServerActions+Recent.swift` (`recent.open`), `ServerActions+Restart.swift`
  `follow`/`watch` (reply waits `restartWaits.shell`, 10 s), `ProcTable.swift` `select` (matches the creator argv).
- Mac remote creates and restarts: `RemoteSessionCreate.arguments`, `ControlServer+RemoteSessionNew.swift`,
  `ControlServer+RemoteCompanions.swift`, `RemoteCatalogActions.swift` (`RemoteOperation`, `setScratch`,
  `duplicateCompanion`, first split), `ControlServer+AttachedForward.swift` (restart, duplicate, first split and
  `scratch` on a row opened by `zmx attach HOST ID`, sent through `runOnOrigin`).
- Compatibility: `ControlArgs` has no `CodingKeys`, so an origin predating a field drops it and answers ok
  (`control-api.md`), which gives today's behaviour. The remaining failure is a stale remote `agtermctl` whose
  argument parser refuses the unknown flag before dispatch.
- Prior decision this reverses: the backlog item above rejected delaying the command until the pane attaches
  because it moves when side effects begin. Eugene approved reversing it for this fix (2026-11-21), with the
  bound releasing rather than killing, and approved covering the remote path in the same plan.

## Development Approach
- **testing approach**: TDD. Each behaviour gets a failing test first, then the code.
- complete each task fully before moving to the next; tests scoped to what the task touches pass before the
  next task; full gates run once, in the last task
- update this plan when scope changes during implementation

## Testing Strategy
- zmx: Zig unit tests in the patch (`env -u ZMX_NO_DETACH_KEY zig build test`) with an injected clock for the
  deadline, and a new `check.py` check that drives a real daemon.
- agtermCore: `swift test --filter` per task for host, server, protocol, dispatcher, CLI and foreground parsing;
  the host's bound is a `Host.Configuration` field so tests set it short.
- app: Live end-to-end paths via `-only-testing` on the named `ZmxLiveUITests` methods.
- gates once at the end: `cd agtermCore && swift test`, `make test-app`, `make lint`,
  `scripts/server-container.sh check`.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix

## Solution Overview
- **One mechanism in zmx.** `ZMX_HOLD_UNTIL_ATTACH=<seconds>` in the environment of
  `zmx attach --detached NAME [command...]` opts in. An env var, not a flag: the patched parser reads every
  token after the name as payload, and a flag before the name would break `ProcTable.select`'s argv match.
- **Release exactly once**: on the first Init of a terminal client, after leadership and `TIOCSWINSZ`, or at a
  monotonic deadline. A kill or daemon teardown while held ends the child without running the command.
  IPC is served throughout the hold.
- **Local**: the host spawns the detached creator through the same `PTYProcess.spawn` with the pane's rows and
  cols, so the responsibility root and coalition stay the host's and the daemon starts at the pane's size even
  if the bound expires. The creator exits once the daemon exists; the host verifies the daemon's live,
  host-rooted PTY child as today and answers. The pane's client then attaches and its Init starts the command.
  The host's PTY no longer carries program output, so `DeviceAttributeResponder` and the settle logic go.
  `SessionHost.protocolVersion` stays 1: the endpoint key includes the loaded image UUID, so an updated app
  starts a new host, and the old host keeps rooting its daemons until it retires.
- **Remote**: one rule, every Mac path that creates or restarts an origin pane and then attaches it sends the
  attach-pending intent: `session new` (top-level and `--parent`), `session duplicate` (and the catalog's
  `duplicateCompanion`, whose server `startCopy` replays the source program), the first split, scratch with a
  command, `session restart`, and the plain-shell paths (`convertCompanion`, `recent.open`) for uniformity.
  The catalog's `RemoteOperation` forwards, `ControlServer+AttachedForward` and the attached-row reopen in
  `ControlServer+AttachedRecent` (`reopenOnOrigin` -> `recent open`, through its own `originCommand`) carry it
  like the CLI paths.
  agterm-server passes the hold with a 30 s bound when the intent is set; everything else starts at once. A Mac
  origin accepts the intent and ignores it, since its own surfaces attach locally.
- **Compatibility, no capability layer**: an older origin drops the unknown field and answers ok with today's
  behaviour. A current origin reached through a stale remote `agtermctl` refuses the flag before dispatch; only
  that pre-dispatch argument refusal is retried once without the flag, on every route including `runOnOrigin`
  and `AttachedRecent.originCommand`, before that helper classifies a refusal as an unknown outcome.
  A lost or post-dispatch reply is never retried, as today.
- **Ready versus executed**: the daemon is ready (attachable, has its child pid) before the command runs.
  Attach opportunities (the server's respawn notice, the local surface) are published at ready, so a viewer can
  attach and release the hold. Restart confirmation waits for `exec`: the leader pid's argv is no longer the
  creator's. Locally that wait ends within milliseconds of the pane's attach. On the server the reply still
  waits 10 s (`restartWaits.shell`); a viewer that reattaches later than that gets "could not be verified in
  time" while the 60 s follow still confirms and publishes, which is documented.
- **Parked child**: before `exec` the child carries the daemon's zmx argv. `CommandRestore.paneForeground`
  itself returns nil for the creator's argv, so restore capture, the tree, replay and duplicate on both sides
  see no foreground program. Only the operations that read the foreground to replay it change inside the hold
  window: a restart without `--command` and Duplicate as Companion refuse as `.unreadable` (`RestartReplay.swift`),
  the same as any unreadable foreground. A restart with `--command` and an ordinary Duplicate read no foreground
  and are unchanged. The same predicate tells restart confirmation that `exec` has not happened yet.
- **Read-back exemption**: the intent is a timing request with no state to read back; the exemption is recorded
  in the commands' contract in `control-api.md`.

## Technical Details
- Gate: a pipe made before `forkpty`, both ends `O_CLOEXEC`. The child closes the write end and blocks reading
  one byte; a byte continues to `exec` after closing the read end, EOF (daemon gone) exits 1. The daemon closes
  the read end, keeps the write end, writes the byte on release and closes it, tolerating `EPIPE` when the
  parked child died first (for example a `^C` typed with `zmx type` while held).
- `ZMX_HOLD_UNTIL_ATTACH` is read only on `--detached` creation and unset in the child before `exec`, beside
  the existing `ZMX_MANAGED` unsets; the daemon itself runs nothing that would read it.
- The deadline release runs at the top of the daemon loop, never right after poll, so a kill or SIGTERM ready
  in the same turn ends the loop first and the teardown cancels the hold. A non-numeric or zero value is
  rejected as a creation error, never treated as unbounded.
- The deadline is checked in the daemon loop's poll timeout against a monotonic clock the Zig tests inject.
  Release on Init happens in `handleInit` after the leader resize; a follower's Init does not release (the first
  terminal on a vacant daemon always leads).
- Bounds: 5 s local (`Host.Configuration`); 30 s remote, confirmed by a cold-ssh measurement (Post-Completion).
  A server create without a creator PTY starts at zmx's default size if the bound expires, until a viewer
  resizes it.

## Decisions carried from the draft
| decision (backlog `fast-live-command-loses-output-in-host-handoff.md`) | status | reason |
|---|---|---|
| keep the output by retaining a completed daemon after EOF until the pane's client got its snapshot | dropped | holding before exec delivers the output to an already attached client; no retention state needed |
| delaying the command's start until the pane attaches is rejected | changed | approved by Eugene 2026-11-21; bounded, releases on expiry, so a lost client gives today's behaviour |
| `SessionHost.Ready.leaderPid` must become optional | dropped | the parked child has its pid from fork, so readiness keeps a leader pid |
| host's bootstrap client inherits `ZMX_MANAGED` | dropped | the detached creator is not a client and never attaches |
| new zmx variables are unset before the payload runs | kept | `ZMX_HOLD_UNTIL_ATTACH` is unset before exec |
| a host from before an app update sets none of this; bump `protocolVersion` or document it | changed | no bump: the endpoint key includes the loaded image UUID, so an updated app starts a new host; a bump would break the old host's retirement through its exact-version hello |

## Implementation Steps

### Task 1: zmx hold-until-attach opt-in

**Files:**
- Create: `scripts/zmx-patches/0013-hold-until-attach.patch`
- Modify: `scripts/zmx-patches/README.md`, `scripts/zmx-patches/check.py`

- [x] worktree artifacts: symlink only the ghostty set from the main checkout; build zmx locally (no zmx
      artifact or stamp links), since this patch changes the zmx digest
- [x] write Zig tests first: a held child does not exec before Init; the first terminal Init releases it after
      the resize; the deadline releases it with no client (injected clock); a kill while held ends it without
      exec; a release write after the child died tolerates `EPIPE`; the env var is absent in the child; both
      gate ends are close-on-exec; a bad value fails creation
- [x] implement the gate in `spawnPty`/`exec`, the opt-in parse in `--detached` creation, release in
      `handleInit` and the loop deadline, cancellation in teardown
- [x] add a `check.py` check: a held detached create whose command writes CPR and OSC 10/11 at exec and exits
      on the replies; a managed client attaching after a delay answers them, and the command's output reaches
      that client
- [x] README entry for `0013`; regenerate the series outside the enclosing checkout and confirm it applies
- ➕ the `setup.sh` `ZMX_REV` comment naming `DeviceAttributeResponder.swift` moves to Task 2, which deletes it
- [x] `env -u ZMX_NO_DETACH_KEY zig build test` and `check.py` pass; Linux musl builds via `setup-zmx-linux.sh`

### Task 2: session host creates through the held detached create

**Files:**
- Modify: `agtermCore/Sources/SessionHostRuntime/Host.swift`, `HostBackend.swift`
- Delete: `agtermCore/Sources/SessionHostRuntime/DeviceAttributeResponder.swift`,
  `agtermCore/Tests/SessionHostRuntimeTests/DeviceAttributeResponderTests.swift`
- Modify: `agtermCore/Tests/SessionHostRuntimeTests/SessionHostServerTests.swift`, `HostBackendTests.swift`,
  `docs/ci-flakes.md` (its entry keyed on `paneAttachAfterTheCreatedCommandEndedStartsNoShell`),
  `scripts/setup.sh` (the `ZMX_REV` comment that names `DeviceAttributeResponder.swift`)
- Delete: `docs/backlog/fast-live-command-loses-output-in-host-handoff.md`

- [x] tests first: ensure spawns `zmx attach --detached NAME payload` with `ZMX_HOLD_UNTIL_ATTACH` from
      `Host.Configuration`; a creator exit 0 plus a live host-rooted PTY child answers `.created`; a nonzero exit
      or no row answers `.started` failure; existing-daemon and no-replay cases keep their current outcomes
- [x] test the fix end to end through the host: a Live command that writes CPR and OSC 11 at exec gets the pane
      client's replies
- [x] convert `paneAttachAfterTheCreatedCommandEndedStartsNoShell` to the new contract: a fast command's
      output reaches the pane's attach and no shell starts; update its `ci-flakes.md` entry
- [x] implement the creator spawn through `PTYProcess.spawn`, readiness on creator exit, the bound as a
      `Host.Configuration` field, and remove `DeviceAttributeResponder`, `settleAttributeReplies` and the
      reply-write path; `SessionHost.protocolVersion` stays 1
- [x] `swift test --filter SessionHostRuntimeTests` passes
- [ ] via `-only-testing`: `ZmxLiveUITests/testAWaitCommandKeepsScrollbackPastOneScreenAfterExit` and
      `ZmxLiveUITests/testBundledZmxBacksPrimaryAndSplitAndRunsLongCreationCommandOnce`
- ⚠️ the two XCUITests need Eugene's go-ahead (`ui-tests.md`: ask before XCUITest; they send real input);
  asked once at the end of the run, with any other XCUITest the later tasks name

### Task 3: parked child: no foreground, restart confirms after exec

**Files:**
- Modify: `agtermCore/Sources/agtermCore/CommandRestore.swift` (`paneForeground`),
  `agtermCore/Sources/AgtermServerKit/ServerActions+Restart.swift` (`follow`/`watch`),
  `agterm/Control/ControlServer+Restart.swift` (`follow`)
- Modify: the `paneForeground` tests in `agtermCoreTests`, the server restart tests in `AgtermServerTests`

- [x] tests first: `paneForeground` returns nil for the creator's argv (`<zmx> attach --detached <name> ...`)
      and is unchanged for ordinary programs and shells; a restore capture inside the hold window records no
      foreground; a restart without `--command` and Duplicate as Companion inside it refuse as `.unreadable`,
      while a restart with `--command` and an ordinary Duplicate are unchanged
- [x] implement the predicate inside `paneForeground` (additive for the agterm-linux fork)
- [x] tests first: the server publishes the respawn notice once the new daemon is ready, before `exec`, and
      confirms only after `exec`; a close during the hold yields no confirmation; a viewer reattaching after
      10 s gets the unverified reply and the follow then confirms; the local restart receipt confirms only an
      executed shell
- [x] split the server `watch` into publish-at-ready and confirm-at-exec; apply the exec check to the local
      `follow`
- [x] `swift test --filter` for the touched agtermCore and AgtermServer suites passes, plus hosted
      `ControlServerRestartTests`
- [ ] via `-only-testing`: the `ZmxLiveUITests/testRestart*` methods (⚠️ XCUITest, asked at the end with Task 2's)
- ➕ an unreadable new-shell argv counts as executed only while the daemon still names that pid, so a replayed
  setuid program (`sudo`) confirms and a vanished one is neither announced nor confirmed; the held predicate keys
  on the daemon name, not the zmx executable, which agterm-server's `--zmx` may rename

### Task 4: remote attach-pending intent and server hold

**Files:**
- Modify: `ControlArgs` and the CLI options for `session new`, `session duplicate`, split, `session scratch`,
  `session restart`, companion conversion and `recent open`; `ControlDispatcher`; `AgtermServerKit`
  (`ServerActions+Sessions.swift`, `ServerActions+Companions.swift`, `ServerActions+Scratch.swift`,
  `ServerActions+Recent.swift`, `ServerActions+Restart.swift`, `ServerPanes.swift`, `ZmxRunner.swift`);
  `RemoteSessionCreate.swift`, `RemoteCatalogActions.swift`, `ControlServer+RemoteSessionNew.swift`,
  `ControlServer+RemoteCompanions.swift`, `ControlServer+AttachedForward.swift`,
  `ControlServer+AttachedRecent.swift`;
  `scripts/server-container.sh` (a held-create check)
- Modify: the protocol, dispatcher, CLI, server, remote-create, catalog and attached-forward tests beside those
  sources

- [x] confirm the path list in the Solution Overview against the code and record any further create-then-attach
      path found here
- [x] tests first: the intent round-trips through protocol, dispatcher and CLI for every listed command; the
      server passes `ZMX_HOLD_UNTIL_ATTACH` only when it is set; creates and restarts without it pass none; a Mac
      origin accepts and ignores it; an older server's `ControlRequest` decoder (`ServerControlSocket`), fed the
      forwarded request with its opID, drops the field and runs the command
- [x] tests first, Mac side: each create-then-attach path (CLI, catalog `RemoteOperation`, `AttachedForward`
      including a directly attached server pane's restart, `AttachedRecent` reopen with its recent-entry operand
      preserved) sends the intent; a pre-dispatch argument refusal is retried once without it; a lost or
      post-dispatch reply is never retried
- [x] implement server, dispatcher, CLI and Mac changes
- [x] add a `server-container.sh` check: a create with the intent has not run its command before an attach and
      has run it after; existing headless shell and `--command` checks keep starting at once
- [x] `swift test --filter` for the touched suites passes
- ➕ paths found: `AttachedForward.convert` (a new origin parent attached here) and the attached ordinary
  duplicate (`session new --after ... --no-select`)
- ➕ no dispatcher change: agterm-server binds `ControlArgs.attachPending` as a task-local around dispatch
  (`AttachIntent`, in `runOperation`, which `serve` also goes through), so no public `ControlActions` signature
  changes for the agterm-linux fork; `PaneObserver`'s recovery start passes no hold, since a failed held restart
  settles inside its own request
- ➕ the `server-container.sh` held-create check runs with Task 5's gates

### Task 5: docs and gates

**Files:**
- Modify: `.claude/rules/windows.md` ("Live session host": creation through the held detached create),
  `.claude/rules/control-api.md` (the intent, its read-back exemption, compatibility, ready versus executed
  restart and the 10 s reply), `site/commands.html` and `plugins/agterm/skills/agterm/` for the new option,
  `site/docs.html` (the approved limitation for server-originated creates)

- [ ] update each surface once, cross-referencing the contract owner instead of repeating it
- [ ] run gates once: `cd agtermCore && swift test`, `make test-app`, `make lint`,
      `scripts/server-container.sh check`
- [ ] `lsappinfo list | grep -A4 agterm.debug` after the hosted run; clean up leaked test processes
- [ ] verify the Overview's requirements against the result; move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems*

**Manual verification**:
- signed microphone attribution check from the supervisor plan, repeated across app quit and relaunch: a
  command started by a held pane still resolves to the host and the existing grant is used
- isolated Debug instance: restart a codex pane 10 times and confirm the composer band every time; restore
  20+ codex panes at launch and confirm every one has the band
- remote: cold-ssh create-and-attach of a codex pane on a real agterm-server host; measure the attach delay
  against the 30 s bound and confirm the band

**External system updates**:
- agterm-linux consumes `agtermCore` and the patched zmx; its server picks up the hold once it rebuilds
