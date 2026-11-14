---
worth: yes
where: agtermCore/Sources/agtermCore/AppStore+Messages.swift:pendingMessages
added: 2026-11-13
---
# pending mail counts on rows attached alone or from another Mac

A row in an agterm-server window reads back its server's mail counts (`pendingMessages` on surfaces,
`scratchPendingMessages` on the session), because they travel in the catalog. Two other ways of viewing a
session elsewhere get the `message` event but no counts: a server session attached alone with `zmx attach`
or `zmx attach group`, and a session attached from another Mac. Their rows read nil, so a script polling
`tree` there cannot see unread mail.

Closing it means carrying counts in the presentation stream rather than the catalog:

- the counts in the snapshot a viewer takes on connect and reconnect;
- an update on every change: send, read with `--ack`, ack, and each disposal site;
- mapping each origin pane id to the viewer's local pane identity before the tree reads it;
- the same session-level scratch fields the catalog rows have.

Left out of the server message bus branch with Eugene's approval as a read-back exception; the event half shipped.
