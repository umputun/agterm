---
worth: maybe
where: agterm/Control/ControlServer+PasteTransfer.swift:sendPaste
added: 2026-11-17
---
# Ctrl-V in a remote Claude Code cannot see the viewing Mac's screenshot

Claude Code's Ctrl-V reads the clipboard of the host it runs on. In a pane attached from another Mac that is
the origin Mac's clipboard, so Ctrl-V cannot see a screenshot taken on the viewing Mac; ⌘V works, since
agterm copies the image to the origin and pastes its path.

Writing the image onto the origin's clipboard as part of a paste, or on a dedicated chord, would let the
program's own Ctrl-V find it. The cost is that the origin Mac's clipboard is shared with whoever uses that Mac:
a paste from the viewer replaces what its user copied there, silently. An agterm-server Linux host has no
clipboard a program reads this way, so it would cover Mac origins only.
