---
worth: maybe
where: agtermTests/SessionHostClientTests.swift:testTwoRacingClientsUseOneRoot
added: 2026-09-20
---
# a racing session-host client sometimes creates an app-rooted daemon

`testTwoRacingClientsUseOneRoot` once observed responsibility roots `[6015, 1146]` instead of
`[6015, 6015]`: 6015 was the disclaimed session host and 1146 the hosted test app.
During validation of remote split mirroring rebased onto #635, this failed in 1 of 9 full hosted runs
and passed 6 of 6 isolated runs. All five instrumented full runs passed.
Their successful clients received `ok(created)`; the only recorded fallbacks were the expected
`beforeDispatch` timeouts in `testLockedOwnerWithoutListenerIsLeftAlone`.

Unverified correlation: the failing run immediately followed a fresh worktree zmx build.
That is one data point, not an established cause. The zmx `timedOut` lines occurred 14 times in the
failing run and 14 in every passing run, so they do not distinguish it or establish machine saturation.
The original failure had no retained client diagnostics. The cause and an appropriate fix remain open.

Two source-confirmed routes can create a daemon under the app without a timeout; neither is confirmed
as the route taken in this failure:

- An initial inventory launch, exit or parse failure in
  `agtermCore/Sources/SessionHostRuntime/HostBackend.swift:149` makes
  `Host.swift:82` return a `before` failure. `agtermCore/Sources/agtermCore/SessionHost.swift:190`
  selects `fullAttach`, and `agtermCore/Sources/SessionHostRuntime/Client.swift:45` executes the
  original attach from the app's child. If the daemon is absent, that client creates it.
- A temporary attach spawn failure at `agtermCore/Sources/SessionHostRuntime/Host.swift:87`, or an
  early child exit at `Host.swift:117`, returns a `started` failure. The client selects `uncertain`.
  A `session new --command` request (`--ends-pane`) then attaches with a "session is gone" guard
  (`Client.attachArgv`), which never replays the payload and ends the pane when the daemon is absent, so
  it creates no shell under the app. A replay, a restart and a plain shell still execute bare
  `zmx attach NAME`, which creates an absent daemon under the app; the earlier sightings were plain
  shells, so this route stays open.

On recurrence, read unified logging for the client PID and failure time:

```sh
/usr/bin/log show --last 1h --style compact \
  --predicate 'subsystem == "com.umputun.agterm" AND category == "session-host"'
```

`client NAME phase=... error=...` records a thrown error. `beforeDispatch` includes finding/starting
the host and its hello; `afterDispatch` means sending the ensure has begun.
`client NAME host stage=... message=...` records a host rejection: `before` permits full attach,
while `started` permits only bare attach. These records add no pane output; the existing uncertainty
message still appears when a command may have run.

The hosted fixture retains `client-INDEX-NAME_SUFFIX.stderr` for non-terminal clients only; terminal
clients keep stderr on their PTY. Every run retains these files and, when present, `host.log` under
`/tmp/agterm-session-host-evidence/shc-UUID/`, outside the removed fixture directory.
The host log includes the underlying initial inventory error and connection rejection errors.
Preserve those files and the test result before investigating a recurrence.
Do not change deadlines or fallback policy without identifying the failing path.

Second sighting, 2026-09-26, in `agtermTests/SessionHostAcceptanceTests.swift`
`testPrimaryDaemonLostAfterInventoryIsRecreatedByHost`: the recreated daemon's leader reported
responsible process 88892 instead of the session host 90216. It failed once in a full hosted run
(977 tests) and passed in the full run before it and in an isolated rerun of the class. The session-host
log for that run holds `agterm-session-host[90241] ... host stage=started message=attach client exited or
failed before readiness` at 01:43:48, inside the failing test's window, which matches the second route
above (`started` failure, bare attach from the app's child). The correlation is by time only; the pid in
that line is not the host pid the test recorded, and the retained `shc-FF830277-...` files from that minute
are empty.

Third sighting, 2026-10-01, in `agtermTests/ControlServerZmxTests.swift`
`testRealClientPaneChangesFromSupervisorToOrphanedWhileBarePaneReadsApp`: the supervised pane read `app`
instead of `supervisor`. It failed once in a full hosted run (1086 tests) and passed in the full run
before it. The session-host log holds `client agterm-aaaa... host stage=started message=attach client
exited or failed before readiness` at 11:48:27, inside the failing test, the second route again. The
retained `shc-7B86B412-...` `host.log` is empty. Afterwards the test passed 83 times alone, its class 60
times, and 7 further full hosted runs showed no early stop.

Fourth and fifth sightings, 2026-10-05, the same test: once in a full hosted run (1186 tests) and once
in 5 isolated iterations of the method, where the 2026-10-01 count was 83 passes alone. Both retained
`host.log` files, and a third from a full run 20 minutes earlier in which no test failed, hold the same
stop reason:

```
attach client PID for agterm-aaaa... stopped before readiness: exited with wait status 256;
output: session "agterm-aaaa..." created
error: cannot connect to session "agterm-aaaa...": FileNotFound
```

So the second route is confirmed, and the attach client's own exit is now on record: `zmx attach`
reports the session created, then fails to connect to it with `FileNotFound` and exits 1, after which
the client's bare attach runs under the app. [Inference] the socket file is not published yet when
the creating client connects; that is read from the message, not measured. The
directories are `shc-41C6C839-...`, `shc-077BC984-...` and `shc-C5E60B42-...`.

Since the third sighting the host records why the attach client stopped. On recurrence, read the retained
`host.log` for `attach client PID for NAME stopped before readiness:`, which carries whichever
stop details apply (wait status, pre-exec errno, poll error) and the tail of the client's terminal output. The fixture also keeps zmx's
own logs in `zmx-logs` beside it.

Sixth sighting, 2026-10-05, the same test, once in a full hosted run (1190 tests), with a different
symptom: the test stopped after 10.2 seconds, the length of the fixture's `waitForLeaders` and `hostPID`
deadlines. XCTest reported `No such process` at `SessionHostClientTests.swift:345`, which is the throw
`cleanup()` swallows with `try?` and not the error that ended the test. The retained `zmx.log` in
`shc-A35A9015-...` shows the UNMEDIATED client (`agterm-bbbb...`) logging `creating session` and
`pty spawned` but never `attached`; its daemon log has no `client connected` and no `kill received`,
while `zmx kill` was sent, so that daemon was unreachable through its socket. `host.log` is empty and
unified logging has no `session-host` record in the window, so the host and the mediated client saw no
error. The unmediated client is plain `zmx attach`, which puts the create-then-cannot-connect failure
inside zmx, independent of the session host.

One candidate was that `createSocket` binds and then listens, so a concurrent `zmx list` connecting
between the two deletes the socket as stale. `scripts/zmx-patches/0003-atomic-socket-publish.patch`,
added after this sighting, publishes the socket name only once it listens, so a recurrence on the
patched build rules that route out wherever the staged publication ran. Its direct-bind fallback, taken
when `.s` cannot be made or the staged path is too long, still binds then listens. The two app-rooted
routes above stay open.

The fixture now keeps what was missing: `terminal-INDEX.out` holds each terminal client's pty output,
which is where a terminal client's `cannot connect` line goes, and `leaders-timeout.list` holds the
last `zmx list` output when `waitForLeaders` gives up.

Re-filed after the 71a9483f drop because the seventh sighting, on the 0003-patched build, shows the staged
publish did not remove the symptom, and source reading found a remover that logs nothing.

Seventh sighting, 2026-11-07, PR #930's branch: `testRealClientPaneChangesFromSupervisorToOrphanedWhileBarePaneReadsApp`
failed in one full hosted run and `SessionHostClientTests.testClientQueuedBehindStalledPeersStillJoinsTheHost`
in another, 2 of 3 full runs, each with the fifth sighting's `created` then `FileNotFound` stop reason.
The method then failed 2 of 20 iterations beside concurrent core `swift test --filter SessionHost` loops,
one set from another session, and 0 of 20 alone.

2026-11-08, no reproduction: 0 of 120 contended iterations with a zmx trace that wrote records inside the
create window, 0 of 40 untraced on the same build that failed, and 0 failures in two and a half full hosted
runs with a failure-only trace (each final-name delete recorded after it ran, plus failed connects). Every
retained trace held only the teardown removals. Each fixture keeps its own `ZMX_DIR` and zmx's kill and
cleanup touch only that directory, so the shared `agterm-aaaa...` name in core and hosted tests is not a
cross-suite remover.

With 0003 the staged socket is published under its final name before `created` is printed, which
supersedes the fifth sighting's not-published-yet inference: the name existed and then went away.

Source-confirmed removers of a published name, neither confirmed as the route taken:

- `Daemon.run` in zmx's `loop.zig`: `daemonize()` returns errors raised in the forked child (`setsid`,
  `/dev/null` open or `dup2`, `forkpty`, `fcntl`), and the caller's `else` branch then runs in that child,
  closing the socket and deleting the session name with no log line. The parent independently prints
  `created` after its 10 ms sleep, so child-side cleanup can leave the name absent when it connects.
- The daemon's shutdown `defer` deletes the name when the shell exits at once. It logs
  `deleting socket file` before the unlink, and no such line was found for the failing creator, so this
  route is weaker, though zmx's logs are not written with `O_APPEND` and a missing line proves little.

A C probe kept a hard-linked socket connectable after its staged name was unlinked in 200 of 200
attempts; it did not reproduce the symptom. On recurrence, a failure-only zmx trace that records each
final-name delete after it runs, with pid, ppid and site, can identify which instrumented zmx path
deleted the name; a removal outside zmx stays unobserved. The heavier trace that also logged the create
path never reproduced.

Eighth sighting, 2026-11-08, in the host-free suite: `SessionHostServerTests`
`readinessTransitionMeasuresWrittenQuerySeparatelyFromReceivedReply` failed once in 8 loop runs of the suite
beside a full `make test-app`, with `attach client exited or failed before readiness` and the child
`exited with wait status 256; output: session "agterm-…" created`. So the route is reachable from
core `swift test` as well as from hosted tests. No zmx trace was running.
