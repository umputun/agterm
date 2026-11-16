---
worth: later
where: agterm/agtermApp.swift:makeOverlaySurface
added: 2026-11-16
---
# a running program overlay stays behind when the lead moves

Since #1023 an open ask, pick or page follows the pane lead between attached Macs and the origin, but a
running program overlay stays on the Mac it started on. A split's program lives in a zmx daemon on the
origin, so its pane follows the person; an overlay's program is a child of one terminal: a local overlay is
a ghostty surface spawning `/bin/sh -c` in the app (`makeOverlaySurface`), a remote one runs under the
viewer's ssh pty (`OverlayRunJob`, `run-job`), where a hangup counts as a cancel. On screen the two look
alike, so the person moving to another Mac cannot tell which one comes along. A local overlay also does
not survive an app restart, which a Live pane beside it does.

Raised by the #1017 reporter on https://github.com/umputun/agterm/pull/1023, who offered to test on two
Macs. Suggested direction: host the overlay program where its pane is hosted (zmx under Live sessions)
and keep the overlay a presentation of it, so moving it is the same lead switch as a pane. That needs an
explicit cancel (`overlay close` or the `cancel` frame) instead of the ssh hangup, and a stop condition
for a daemon nobody attaches to, like the held-ask deadline on agterm-server. Without Live sessions
nothing changes. Today the user guide and the skill say a program overlay stays where it started.
