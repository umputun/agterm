---
worth: later
where: agterm/Ghostty/GhosttySurfaceView+Visibility.swift
added: 2026-08-28
---
# hidden windows keep their on-screen hosts' swap chains

`showsOnScreen` is `deckOnScreen && window != nil`, and `window` stays set when a window is miniaturized,
ordered out, or the app is hidden. Each hidden window therefore keeps the swap chains of its selected
session's on-screen hosts — both panes of a shown split plus a floating overlay or HUD — while its inactive
sessions release normally. `observeWindowVisibilityChanges` already subscribes to miniaturize,
deminiaturize, app hide and app unhide, so most of the hook exists; `orderOut` would need a separate
signal. Surfaced by the PR 492 review.
