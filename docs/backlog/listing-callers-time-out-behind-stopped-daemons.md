---
worth: maybe
where: agterm/Ghostty/ZmxClient.swift:reap
added: 2026-11-23
---
# listing callers still time out behind stopped daemons

Pinned zmx probes daemons one at a time, up to 1 s each (`src/ipc.zig` `probeSession`), and prints nothing
until every probe is done, so a few stopped daemons fail the whole listing. Runtime leader reads moved to
a kernel scan (`ZmxClient.sessionLeaderPIDs`, `ServerPanes.daemonShells`); the callers below still need
what only the listing reports, a daemon's reachability (`clients`) and unreadable rows:

- the Mac launch reap, `ZmxClient.reap`: a timeout kills nothing and returns `runningNames: nil`
- Live sessions reset: `ControlServer.liveResetSelection` and `LiveResetConsumer`
- `zmx.prune`, `zmx.list`, `zmx.tree` and the Mac's `zmx.kill` inventory
- a Mac origin's catalog evidence, `ControlServer.readOriginEvidence`: a timeout leaves remote viewers'
  running-pane evidence unrefreshed
- the session host's `HostBackend.list`: in `Host.handle(ensure:)` a timeout is a `before` failure, so the
  client falls back to a full attach from the app (see `session-host-sometimes-creates-an-app-rooted-daemon.md`);
  in `Host.awaitLeader` it is a `started` failure, and `Host.handleStop` refuses to stop
- agterm-server's `AgtermServer.adopt` at startup and its `PaneObserver` tick

Options: an upstream zmx `list` deadline that returns the rows finished so far, marking the rest
unreadable; or a reachability probe of our own per socket, which would duplicate zmx's.
