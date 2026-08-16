---
worth: later
where: agterm/Ghostty/GhosttySurfaceView.swift
added: 2026-08-10
---
# hidden deck panes keep drawing because occlusion is never reported

libghostty's render thread returns early on `!self.flags.visible` (`src/renderer/Thread.zig:495`), so the
paint path does honour occlusion. agterm calls `ghostty_surface_set_occlusion` nowhere, so every hidden
deck pane redraws whenever its own terminal changes. Measured on a live 63-surface instance that is ~5% of
one core in total, which is why this stays `later`: too small to be worth a change on its own.

It is worth more as the "stop drawing" half of shrinking hidden panes' layer bounds, the only route to the
~4 GB of IOSurface those panes hold that does not need a libghostty patch (discussion #196).

Surfaced while instrumenting the display-sleep surface-creation bug (#416, fixed in #417); the occlusion
angle came from reviewing the #196 memory patch. Split out of
`render-action-appears-never-to-fire.md` when that item's dead-code half was fixed, since the RENDER
finding itself now lives in `.claude/rules/libghostty.md`.
