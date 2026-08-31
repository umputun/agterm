---
worth: later
where: agterm/Ghostty/GhosttySurfaceView+Visibility.swift
added: 2026-08-28
---
# hidden windows keep their on-screen hosts' swap chains

`showsOnScreen` is `deckOnScreen && window != nil`, and `window` stays set when a window is miniaturized,
ordered out, or the app is hidden. Each hidden window therefore keeps the swap chains of its selected
session's on-screen hosts, including both panes of a shown split and a floating overlay or HUD. Its inactive
sessions release normally.

`observeWindowVisibilityChanges` at `GhosttySurfaceView.swift:406` subscribes to miniaturize,
deminiaturize, app hide and app unhide, but its callback only calls `postAccessibilityExposureChange()`.
It never calls `updateRendererVisibility()`, so none of those signals currently updates renderer occlusion.

A fix must change `showsOnScreen` so an attached window is not automatically considered visible, route the
existing hide and reveal signals through the renderer path, and cover both order-out and order-in. Verify the
real swap chain releases while hidden and rebuilds without a blank or stale frame on reveal, including the
initial attach and SwiftUI reparent paths. Surfaced by the PR 492 review.
