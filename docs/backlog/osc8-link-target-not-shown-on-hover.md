---
worth: maybe
where: agterm/Ghostty/GhosttyCallbacks.swift
added: 2026-11-10
---
# OSC 8 link target is not shown on hover

An OSC 8 link lets terminal output pick a label unrelated to its target, and agterm never shows the target
before the click: `GhosttyCallbacks` handles `GHOSTTY_ACTION_MOUSE_SHAPE` and `GHOSTTY_ACTION_OPEN_URL` but
not `GHOSTTY_ACTION_MOUSE_OVER_LINK`, which libghostty already sends with the hovered URL. A mislabeled
http link is reachable today; the `agterm://session/<uuid>` links accepted in
https://github.com/umputun/agterm/discussions/958 add a session jump to the same gap. A small status
line or tooltip with the target (the session name for a session link) would close it.
