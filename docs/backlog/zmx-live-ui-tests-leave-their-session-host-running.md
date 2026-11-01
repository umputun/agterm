---
worth: maybe
where: agtermUITests/ZmxLiveUITests.swift:tearDown
added: 2026-11-01
---
# ZmxLiveUITests leave their session host running

Every `ZmxLiveUITests` method starts an `agterm-session-host host /tmp/agterm-zmx-<hash>` for its throwaway
state directory, and the host is still alive after teardown, reparented to launchd and holding a
`exited-with-subordinates` `lsappinfo` entry for the Debug app. Three were stopped by pid in one session
(#857). `reapTestDaemons` ends the daemons through `zmx.kill`, but nothing stops the host: outliving the
app is its design (`windows.md`, Live session host), and production never sends it `stop`.

The test runner cannot do it either. It gets EPERM signalling app-spawned processes (the
`reapTestDaemons` comment), its sandbox refuses `/tmp` where the host socket and pidfile live, and the
host accepts `stop` only from a peer in its own bundle (`HostIdentity.peer`, `handshakeAccepts`).
Killing the pidfile's pid would also skip `handleStop`'s rooted-daemon and pending-child checks and
`HostEndpoint.close()`.

A fix needs a deliberate `agterm-session-host stop` entry point (none in `main.swift`) that sends the
host's own request without `ClientConnector.ensureRunning()`, which could start a host during cleanup,
plus a way for the app to run it at tearDown, such as a custom command seeded in the test's keymap. It
should require `.stopped`, bound the wait for the exit, and keep reap and stop errors. `handleStop` refuses
a row without a live leader, so if daemons are ever kept after their command ends
(`fast-live-command-loses-output-in-host-handoff.md`), they have to be reaped first. Undecided whether
a production entry point that only tests call is worth it.
