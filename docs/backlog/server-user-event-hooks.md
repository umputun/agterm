---
worth: maybe
where: agtermCore/Sources/AgtermServerKit/AgtermServer.swift:start
added: 2026-11-14
---
# user event hooks on agterm-server

`hooks.conf` event hooks run only on a Mac, from the events of the rows that Mac shows. agterm-server has no hook
scheduler, config loader or process runner, and `hooks.list`/`hooks.reload` are refused there. So nothing on the
host reacts to a server session's status, notify or lifecycle events while no Mac is connected.

Undecided whether this belongs on the host at all, since hooks are Mac-side user config today. The case for it:
hooks exist to react unattended, a server with no Mac attached cannot, and `HookScheduler` (agtermCore) already
runs without a GUI; only `HookProcessRunner` is app-side. If done: server-configured hooks run on server events
there, Mac-configured hooks on Mac events here, and a Mac's config is never uploaded or run on the host. The
server event ring it would read from exists (`ServerEvents.swift`, #999).
