---
worth: maybe
where: agterm/Control/ControlServer+Zmx.swift
added: 2026-10-15
---
# An orphan zmx daemon has no supported way back into the tree

`zmx list` reports a daemon no pane claims as `orphan`, and the only actions on it are `zmx prune` and
`zmx kill`, which end it. `zmx attach` resolves only `zmx tree` rows, so a still-running orphan, such as
an agent session lost from the saved window file in #741, cannot be reopened as a session. The reporter's
workaround is a `session new --command` that runs the bundled `zmx attach <name>` with `ZMX_SESSION`,
`ZMX_MANAGED` and `ZMX_MANAGED_CLAIM` unset, so the nested attach does not return at once.

The ask is `agtermctl zmx adopt <daemon>`: create a session whose pane claims the orphan's identity and
attaches to it. It is a new control command, so it owes protocol, dispatcher, CLI, tree read-back and
tests. Open questions: which workspace and window it lands in, and whether adoption reuses the daemon's
pane identity or mints one.
