---
worth: later
where: plugins/agterm/skills/agterm/examples.md:32
added: 2026-08-26
---
# the copy-paste restore capture example does not warn that it records itself

`agtermctl restore capture` typed at a pane's own prompt is that pane's foreground process group while it
blocks on the response, so the slot gets `["agtermctl","restore","capture", ...]` and the pane comes back
running it after an unclean exit, printing a stray "captured N panes". The warning is in the CLI help
(`MiscCommands.swift`), `reference.md:1195` and `site/commands.html`. `examples.md:32` is the one bundled
surface without it, and `SKILL.md:552` names that file the copy-paste surface.

`SKILL.md`'s own command summary is fine as it stands: its header points at reference.md for full detail,
and CLAUDE.md says to own each contract once rather than repeat it across surfaces.

The exposed caller is a human pasting the snippet at a prompt. An agent is unaffected: a tool-spawned
child never `tcsetpgrp`s, so the group leader stays `claude`/`codex`, which is the argv you want captured.

Fix is one clause beside the snippet - follow an interactive run with `restore clear`. Surfaced reviewing
PR #452, merged as 22f3c7c; the round-4 disposition scoped the documentation fix to three surfaces and the
author delivered all three, so the fourth is not his to carry.
