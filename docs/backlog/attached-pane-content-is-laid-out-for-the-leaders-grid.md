---
worth: maybe
added: 2026-09-10
---
# attached pane content is laid out for the leader's grid

Pinned zmx (`fb1b6b6`) keeps one leader per pane and sizes the daemon pty to the leader alone. Once
another Mac attaches and types, its client leads: the daemon resizes to that grid and broadcasts the
program's redraw unchanged to every client, so this Mac's libghostty core, still at its own grid, holds
rows laid out for the other one. Followers get no size or role message (`src/loop.zig:806-812` sends
the empty Resize only to the new leader, `:150-153` appends Output raw, `:981-986` ignores a follower's
own resize), `Info` and `History` carry no geometry or leader field (`src/ipc.zig:74-87`,
`src/loop.zig:1039-1108`), and while another leader exists only classified Input takes the lead
(`src/util.zig:688-728`), forwarded before the resize round trip completes; a vacant slot is claimed by
Init or Resize without input. `zmx send` bypasses leadership.

Consequence: when another client leads at a different terminal size, local cursor and screen-text
reads can disagree with the application's layout. The chat transport's two gates (`surface cursor` at
column 2 before typing, the composer's first row before the submit key) are such reads, and the pane
itself renders oddly. A matching-size follower was not shown broken. Documented as unsupported in the
remote-attach docs; deferred on 2026-09-10.

Candidate mechanisms, none verified or started:

- zmx size policy: size the pty to the smallest attached client (tmux `window-size smallest`) or
  broadcast the leader's grid to followers, with agterm rendering the pane to that grid. Intended to
  make local reads match the layout; the smallest-size variant alone does not establish that a larger
  local core uses that grid. Needs a zmx change first (upstream option or a vendored patch against the
  plain pin).
- transport-only: the say script takes the lead with an empty bracketed paste, waits for the reflow,
  then runs its guards. zmx forwards the paste bytes before the resize completes, so the wait is a
  guess; nothing else improves and the other Mac's view reflows on every send.
