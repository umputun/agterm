---
worth: maybe
where: agtermCore/Sources/agtermCore/AppStore+Status.swift:applyControlStatus
added: 2026-11-16
---
# a local active replaces the origin's status on an attached row

On a row attached from another Mac, an agent in this Mac's own scratch posts `active` and then `completed`, as the
bundled Claude hooks do. The local `active` replaces the origin's status and the row stops tracking the origin. When
the local `completed` arrives, `applyControlStatus`'s keep rule (`originWorks`, which leaves the origin's `active`
shown) no longer applies, so the row shows `completed` while the origin's agent still works, until the origin's next
status frame (Claude sends one after every tool run).

Not a regression: local writes replaced the origin's status before #1016 too. The keep rule mostly helps scripts that
post a bare completion. Found by the round 2 review of #1016 and left out of it deliberately.

The fix is a design decision: how this Mac's own pane work and the origin's status coexist on one row, covering a
local `active` under the origin's `active` and the origin's later frames dropping local work. It changes remote status
precedence, so it needs its own design, not a guard in `applyControlStatus`.
