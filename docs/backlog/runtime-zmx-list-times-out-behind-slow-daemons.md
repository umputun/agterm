---
worth: maybe
where: agterm/Ghostty/ZmxClient.swift:sessionRecords
added: 2026-11-17
---
# runtime zmx list times out behind slow daemons

Pinned zmx probes daemons one at a time, up to 1 s each (`src/ipc.zig` `probeSession`), and prints nothing
until every probe is done. Waits on slow daemons add up, so a few of them can use up the caller's timeout
and fail the whole listing for every caller that needs it at runtime: tree builds (`ControlServer.buildTree`),
restarts, companion changes, the launch reap. The quit capture stopped depending on the listing in #1042;
these callers still do.

The #1042 reporter logged `zmx list failed: timedOut` 10 times in about 30 s while restarting 47 panes with
limits of 1-3 s. His logs show the timeouts, not what held those listings up.

Options: the per-pane kernel lookup the quit capture uses, where a caller only needs leader pids; or an
upstream zmx `list` deadline that returns the rows finished so far.
