---
worth: maybe
where: agtermCore/Tests/SessionHostRuntimeTests/SessionHostServerTests.swift:Fixture.start
added: 2026-11-08
---
# session-host test fixture sometimes sees no pidfile within 5 s

`Fixture.start()` spawns a copied `agterm-session-host` and waits 5 s for its pidfile. In one core
`swift test` run on 2026-11-08, started while a full `make test-app` was building, 7 consecutive
`SessionHostServerTests` tests failed there with `ETIMEDOUT`, about 5.01 s each.

What the original window shows:

- `amfid` logged each fresh host copy about 5.02 s apart (01:41:25.4, 30.4, 35.4, 40.4, 45.4, 50.5),
  once per test right after its spawn, so the recorded checks were prompt. They do not show where the
  rest of the time went.
- No `session host failed:` line in the run's output, although the spawn inherits stderr and
  `Host.run` reports any error thrown before the pidfile there. No crash report.
- No `tccd` record naming the copies in that window.

The pidfile was not observed within 5 s; child state and the startup phase were not captured, so a
pidfile published and removed before the poll saw it is not ruled out. Before the endpoint publishes it,
the host runs its startup, `HostIdentity`'s `proc_pidpath` and `Info.plist` read, and the `Responsibility`
check. The cause is unknown.

Not reproduced: 0 timeouts in 11 suite runs under load, 3 beside a fresh full build and 8 beside
`make test-app`, 132 starts in all. A start normally takes about 500 ms (max 601 ms). A relaunch of
an already-started copy takes about 11 ms.

On recurrence, record at the timeout: the spawn call's own duration, `waitpid(WNOHANG)` and the
exit status, `ps` state, which endpoint files exist, a one-second `sample` of the child, then 30 s
more watching whether the pidfile appears late or the child exits. A raised deadline is not a fix
until that shows the host is merely slow.
