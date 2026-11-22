---
worth: no
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

`agterm-session-host stop SOCKET_DIR` exists, but it retires hosts of other builds: `HostRetirement.run`
skips the endpoint this build and login session create through, which is exactly the test's host. A fix
needs a form that includes that endpoint, plus a way for the app to run it at tearDown, such as a custom
command seeded in the test's keymap. `handleStop` refuses a row without a live leader, so if daemons are
ever kept after their command ends, they have to be reaped first.

Not worth it: that form ships in the bundled helper and only tests would call it, and the project keeps
no production code that exists only to serve tests. A leaked test host stays a manual
cleanup by pid, which the `lsappinfo` check after a hosted or UI test run already catches. On macOS 27 and
later the host runs as a launchd job with a coalition of its own and is absent from `lsappinfo`; a leaked
one shows as a loaded `<bundleID>.session-host.*` job in `launchctl list` instead.
