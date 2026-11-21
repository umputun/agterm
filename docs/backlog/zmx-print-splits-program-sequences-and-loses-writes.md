---
worth: later
where: agtermCore/Sources/agtermCore/TerminalClipboard.swift:copy
added: 2026-10-08
---
# zmx print splits the program's escape sequences and can lose its write with exit 0

`agtermctl clipboard set` sends its OSC 52 write through `zmx print`, and two defects at that seam share one fix.

**Injection lands mid-sequence.** The daemon reads the pty in 4096-byte chunks and forwards each as its own
message; `handleOutput` (loop.zig, pinned `8bab1f0`) forwards a print at once, between two chunks where the
program's escape sequence or multi-byte character may be half written. Measured in a throwaway session with a
marker OSC: 0 of 200 injections landed inside a sequence against one short line every 80 ms, 37 of 278 against
33 KB bursts back to back. The injected OSC 52 still parses whole (in ghostty `683d8db` ESC leaves every parser
state, and a partial UTF-8 character retries the ESC); the program's own sequence breaks. An interrupted CSI is
aborted, so its operation can stay unapplied; an interrupted OSC is finalized with its prefix, which can apply a
truncated title, working directory or hyperlink. A repaint does not necessarily undo either. A CLI-side sleep or
a reset prefix cannot restore the interrupted sequence.

**Exit 0 proves nothing.** The client's `send` (main.zig) writes the message, reads no reply, and maps
`BrokenPipe` and `ConnectionResetByPeer` during the write to success; the one-second probe timeout in
`ipc.zig` already returns an error. Patch 0007 also answers `Info` while ignoring `Output` during a drain.
Measured against the 33 KB bursts (162 MB through the pty): 278 of 300 markers reached an attached client, 22 were
not observed, with exit status and stderr not captured per print, so the cause is not established. Against one
line every 80 ms, 200 of 200 arrived. Capture status and stderr per print before choosing the fix.

**The fix.** One zmx patch: the daemon queues injected output until its parser is at ground, the way the
leadership patch's `Relay.forward` delays its role title, and the client reports write errors. Decide what a new
print client promises against an older daemon, which keeps the old behavior, before calling delivery fixed.
Acceptance: a deliberately split program sequence survives an injection intact, and a dropped or refused print
has the agreed result, on an older daemon too. Any zmx patch changes the build id in `.zmx-build-stamp`.
