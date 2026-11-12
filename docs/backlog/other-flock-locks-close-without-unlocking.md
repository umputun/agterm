---
worth: maybe
where: agtermCore/Sources/SessionHostRuntime/ClientConnector.swift:startHost
added: 2026-11-09
---
# session-host spawn lock closes without unlocking

`StateDirectoryLock` and `ControlServer.releaseOwnership` call `flock(fd, LOCK_UN)` before `close(fd)`: a child spawned on another thread holds a copy of every descriptor until its exec, so a plain close leaves the lock held through that copy (regression tests `releasingTheLockFreesItWhileAChildHoldsACopyOfItsDescriptor` and `testStopReleasesTheLockWhileACopyOfItsDescriptorIsOpen`).

`ClientConnector.startHost` (`agtermCore/Sources/SessionHostRuntime/ClientConnector.swift`) still closes `spawnLock` in a `defer`. A spawn from another thread at that moment could make a waiting client loop once more (20 ms). Its own host spawn returns only after the child's exec, so that spawn is not the holder. Not reproduced.
