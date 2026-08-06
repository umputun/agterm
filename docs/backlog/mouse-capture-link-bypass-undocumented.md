---
worth: yes
added: 2026-08-05
---
# the ⌘⇧ mouse-capture bypass for link hover/click is undocumented

libghostty runs link detection only while the foreground program has mouse reporting off
(`Surface.zig:2704,4593` at the pinned `4dcb09ada`, both the motion and mods-change refresh paths). While a
program has it on, ⌘-hover does not underline, the pointer stays a bar, and ⌘-click does not open, all
four at once. Same core as Ghostty.app, not an agterm bug. ⌘⇧-hover / ⌘⇧-click bypasses the capture unless
the program claims shift itself, and `mouse-reporting = false` in `~/.config/agterm/ghostty.conf` turns
reporting off globally.

It is per-program, not a property of any class of app: tmux with `mouse on` and stock vim (`defaults.vim`
sets `mouse=a`) suppress it, codex does not touch mouse reporting at all and links work there normally.

None of that is written down for users. `README.md`, `docs/troubleshooting.md`, `site/docs.html` and
`plugins/agterm/skills/agterm/` say nothing about it, so ⌘-hover reads as broken inside a mouse-grabbing
program with no hint that a modifier fixes it.

Surfaced in #206, which was closed as stale on 2026-08-05 without the docs ever going in. Note that #206's
framing (agent TUIs in general) was wrong; the rule above is what the source actually does.
