---
worth: maybe
where: agtermCore/Sources/agtermCore/LiveReset.swift:select
added: 2026-11-18
---
# reset selects working panes on older hosts

Since #972, a helper build change can leave working Live panes on an earlier session host. Reset Live
Sessions can select those panes based on host age alone, which reads as routine upkeep after an update.
The reset is meant to be a rare repair for a pane that is actually broken, and such panes can keep
working: on 0.43.0 the maintainer's terminal had 64 sessions with panes under an earlier host and no Local
Network blocks in a week of system log.

#1047 came from a user resetting after most updates. Undecided: whether a stale host alone should select
a pane, or only alongside a symptom. Changing it changes what the dialog counts and what
`zmx.reset --force` kills, so it needs its own decision.
