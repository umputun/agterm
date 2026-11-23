---
worth: maybe
where: agtermCore/Sources/agtermCore/AppStore+Messages.swift:messagePane
added: 2026-11-13
---
# messaging between a local pane and an agterm-server pane

`msg send/read/ack` work between the panes of one Mac and between the panes of one agterm-server, but not
across the two. Each host keeps its mailboxes in its own process, and no route carries `msg.*` from one to
the other: a Mac send to a server row is rejected `unknown pane` with detail `remote session`, a server send
to a Mac session is rejected `unknown pane`, and a server row as `--as` on the Mac is refused. This is a
parity gap, not a decision against it (discussion https://github.com/umputun/agterm/discussions/994).

Closing it needs:

- a two-way route over the ssh connection the remote window already holds, for sends in both directions;
- sender identity that names a pane on another host, so `from` stays a valid reply address;
- replies: a recipient answering `from` reaches the sender's host;
- mixed recipients in one send, some local and some remote, with one `messageID` and per-recipient results;
- the `--all` scope: whether a Mac broadcast reaches server rows and a server broadcast reaches the Mac.

Worth is open: the request in discussion #994 was for messaging within one server, which #996 shipped,
and nobody has asked for cross-host mail since.

A coherent first slice is a Mac-initiated send plus the server pane's reply to that sender, both as typed
request/result frames on the server session's presentation stream. The reply goes to the subscriber that
carried the send (`PresentationHub.send(_:toOwner:)`), never through `PresentationHub.route`: the pane
leader or presenter can be on another Mac, and leadership can move before the reply. It must also reach
the original sending pane, since that pane can close or respawn while the session stays attached; the
reply is refused when either the connection or that pane is gone. A server pane reaching a Mac pane that
never messaged it needs an addressing and authorization design no one has made yet.
