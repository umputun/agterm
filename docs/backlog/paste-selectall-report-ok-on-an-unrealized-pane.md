---
worth: yes
where: agterm/Control/ControlServer+SurfaceIO.swift:16
added: 2026-08-10
---
# session.paste and session.selectall answer ok on a pane with no terminal

`surfaceBindingAction` guards that the surface SLOT is occupied, not that the terminal exists: a parked
`GhosttySurfaceView` whose libghostty surface never came up passes the `as? GhosttySurfaceView` cast, so
the `else` branch never runs. `performBindingAction` then returns `false` on its own `guard let surface`
(`GhosttySurfaceView+IO.swift:129`), and that return is discarded at the call site, which replies
`ok: true` with the session id regardless. Nothing was pasted and nothing was selected.

Same construct as the `session.text` case fixed in #417, one command over. That one now checks
`isRealized` before reading; these two still do not, so one control command calls the state
`session not realized` while its neighbours call it success. The failing state is reachable without any
exotic setup: a session created while the display is asleep sits exactly here until the displays wake.

The fix is small - check `isRealized`, or stop discarding `performBindingAction`'s Bool and map false to
`session not realized`. Preferring the Bool would also cover any future caller that forgets the guard.
Deferred rather than folded into #417 because it is pre-existing and widening that branch past #416 was
not worth it; the sweep that should have caught it at the time did not run.

Surfaced by revmux as a pre-existing major while reviewing PR #417.
