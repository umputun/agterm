---
worth: maybe
where: agtermCore/Sources/SessionHostRuntime/ClientConnector.swift:startHost
added: 2026-10-12
---
# a deleted session-host.lock lets a second host take the live host's socket

The owner lock is a `flock` on `session-host.lock` under `/tmp`. When that file is deleted while the
host runs, the host keeps the lock on an inode no path names. A client whose connect is then refused
reaches `startHost`, where `openLock` creates a fresh lock file and the `flock` succeeds, so it spawns a
second host. That host's `HostEndpoint.init` locks the new inode and unlinks the live host's socket.
The first host keeps running with its daemons and can no longer be reached.

Both conditions are needed: the lock file gone, and a refused connect while the host is alive. Darwin
refuses a connect when the listener's backlog (128) is full, which a stalled host could produce.

How the lock gets deleted: macOS `/usr/libexec/tmp_cleaner` removes regular files under `/tmp` after
three days untouched (issue #732). The host refreshes the lock's times hourly, which prevents that
for a host started by a build carrying the refresh. A host started by an older build, or a lock removed
by anything else, stays exposed. Not observed in practice; surfaced reviewing the #732 fix.

Undecided: whether the host should detect that its lock path no longer names its inode (compare
`fstat` on the held descriptor with `lstat` on the path during upkeep) and what it may safely do then,
since recreating the lock by path races a client already inside `startHost`.
