---
worth: maybe
where: agtermCore/Sources/agtermctlKit/EventCommands.swift:Events
added: 2026-11-10
---
# idle event and message followers still cost CPU by polling every 250 ms

`agtermctl events` and `agtermctl msg read --wait` sleep 250 ms after an empty reply and ask again (`Events.poll`,
`Msg.Read.pollDelay`), so each idle follower sends up to four `events.read` / `msg.read` requests a second.
#955 removed the two per-request costs the profiles found: the event ring scan from its start and the window cache
rebuild after every read.

Measured on a Debug build with 20 idle followers and a full 4096-entry event ring, app CPU before and after #955:
events 17.9% to 5.6%, messages 8.1% to 5.9%. At N=20 that is about 0.28% of a core per idle event follower. No
post-fix slope across follower counts was measured, and the residual is not attributed to any one part of the
request path.

Long-polling would remove the fixed idle cadence: the server holds a read open until an entry arrives or a timeout
passes, and the CLI drops its idle sleep. The `ControlServer` accept loop serves one connection at a time, so a held
read cannot sit on it, and `control-api.md` keeps polled `events.read` as the in-scope design. The compatibility
design is open, which is why it was not part of #955.
