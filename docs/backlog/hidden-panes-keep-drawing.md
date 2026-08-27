---
worth: no
where: agterm/Ghostty/GhosttySurfaceView.swift
added: 2026-08-10
---
# hidden deck panes kept drawing because occlusion was never reported

Resolved by advancing to Ghostty's hidden-surface GPU release and reporting agterm's actual on-screen hosts
through `ghostty_surface_set_occlusion`. Hidden shells stay live while libghostty drops their Metal swap chains.

Surfaced while instrumenting the display-sleep surface-creation bug (#416, fixed in #417); the occlusion
angle came from reviewing the #196 memory patch. Split out of
`render-action-appears-never-to-fire.md` when that item's dead-code half was fixed, since the RENDER
finding itself now lives in `.claude/rules/libghostty.md`.
