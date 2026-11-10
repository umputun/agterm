---
worth: maybe
where: agterm/Control/ControlServer.swift:releaseOwnership
added: 2026-11-09
---
# other flock locks close without unlocking

`StateDirectoryLock` was fixed to call `flock(fd, LOCK_UN)` before `close(fd)`: a child spawned on another thread holds a copy of every descriptor until its exec, so a plain close leaves the lock held through that copy (regression test `releasingTheLockFreesItWhileAChildHoldsACopyOfItsDescriptor`).

Two other release paths close a held `flock` the same way. Neither effect has been reproduced; both are candidates.

- `ControlServer.releaseOwnership` (`agterm/Control/ControlServer.swift`) closes the socket ownership lock. A second instance acquiring while the owner releases could read `refused` until its next window's `start()` retries. Needs a hosted test before the one-line unlock.
- `ClientConnector.startHost` (`agtermCore/Sources/SessionHostRuntime/ClientConnector.swift`) closes `spawnLock` in a `defer`. A spawn from another thread at that moment could make a waiting client loop once more (20 ms). Its own host spawn returns only after the child's exec, so that spawn is not the holder.
