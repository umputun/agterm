---
worth: later
where: agterm/Control/ControlServer+AttachedRecent.swift:attachedRecentRoute
added: 2026-11-20
---
# a bare reopen of an attached row can land in a frontmost server window

`recent open` of a Recent Closed entry for a row attached from another host resolves its window when no
`--window` is given: the frontmost one. `attachedRecentRoute` only steps aside for an explicit `--window`
that names a server window, so with a server window frontmost a bare reopen attaches into that mirror.
The server's catalog does not own the session, so the next catalog reconcile removes the row, while the
reply said `complete: true` and the entry already left Recent Closed.

The fix is a destination rule for a bare reopen while a server window is frontmost: refuse and ask for
`--window`, or fall back to the most recent local window. Present on master; surfaced by the revmux
round on the top-level sessions branch.
