---
worth: maybe
where: agterm/Ghostty/GhosttySurfaceView+IO.swift:inject
added: 2026-09-30
---
# session type: long or multi-line input reads as paste in an agent TUI

#679 paced only the final Return of a `session.type` payload. Two cases remain, both about a receiver
classifying a fast burst as a paste:

- One very long line is taken whole as a paste block. Observed against Claude Code 2.1.286 at 2000
  characters on a Live pane (the zmx daemon route): the line submitted, but `/rename` was not parsed as
  a slash command and ran as a prompt. The surface route was not inspected for this; on master its
  input box showed a `[Pasted text]` summary at the same size.
- [Unverified] Returns inside a multi-line payload still go back to back with their text, so by the
  mechanism #679 measured each would be taken as pasted content and only the last would submit. No
  multi-line trial was run against a receiver.

`chat-claude.py` types in 900-byte pieces 100 ms apart to stop Claude Code from 2.1.246 dropping runs
of 64-byte chunks out of one burst. Whether that pacing also avoids the paste classification is
unverified. Pacing inside agterm would mean a gap per line or per piece on both routes, blocking the
main thread for each, so the open question is whether this belongs in `session.type` at all or stays
the caller's job and gets documented.
