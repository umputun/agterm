---
worth: maybe
where: agterm/Ghostty/GhosttyCallbacks.swift:action
added: 2026-10-21
---
# program status waits on an upstream app action

OSC 7501 (program status protocol, https://github.com/ghostty-org/ghostty/pull/14560) could feed
session status from the pane's own pty, but the embedded app layer drops it: `src/termio/stream_handler.zig`
ignores `.program_status` and `include/ghostty.h` has no action for it. The terminal also leaves the
`OSC 7501 ; ?` probe unanswered, and Claude Code 2.1.307 sends no reports until that probe is answered
(its `programStatus` capability starts false and only a probe reply sets it).

agterm carries no patch to the embedded libghostty for this
(https://github.com/umputun/agterm/discussions/794). On a `GHOSTTY_REV` bump, check whether `ghostty.h`
gained a program-status action and a way to answer the probe; until both exist there is nothing to build.
At v1.4.0 (`83fb956`) neither exists and `stream_handler.zig` still ignores `.program_status`.
It would not replace the hook adapters' nested-agent guard or clear a glyph after a hard kill; that gap
is `agent-status-outlives-its-agent-at-the-prompt.md`.
