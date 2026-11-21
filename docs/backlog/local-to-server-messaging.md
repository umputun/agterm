---
worth: yes
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
