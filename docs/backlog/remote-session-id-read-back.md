---
worth: later
where: agtermCore/Sources/agtermCore/ControlProjection.swift:ControlSessionNode
added: 2026-11-08
---
# attached row does not expose its far-side session id

`zmx attach` binds a row to one far-side session (`RemoteBinding.remoteSessionID`), but neither the
`tree` session node nor the `remote.opened` event carries that id: they report only `remoteHost` and the
row's name, and names repeat across workspaces. A hook therefore cannot record which remote session a
row shows, so it cannot re-attach rows after a relaunch, the user-space route suggested for
https://github.com/umputun/agterm/discussions/932. Adding the id to both is an additive control API
change (protocol field, event payload, `EventFormatter.human`, commands page, skill reference, tests).
The field is `remoteSessionID` on the node and on both `remote.opened` and `remote.closed`, for every attached
row: terminals, companions and page rows. `remote.opened` fires inside `addSession`, before `bindRemote` runs,
so the id must be known when the row is created; test it through a real attach, not a pre-bound row.
