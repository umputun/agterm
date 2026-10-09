---
worth: later
where: agtermCore/Sources/agtermCore/TerminalClipboard.swift:copy
added: 2026-10-08
---
# zmx print can land inside the program's unfinished escape sequence

The zmx daemon reads the pty in 4096-byte chunks and forwards each as its own message. `handleOutput`
(loop.zig, pinned `8bab1f0`) forwards a `zmx print` payload at once, so it can sit between two chunks
where the program's escape sequence or multi-byte character is half written. `agtermctl clipboard set`
injects its OSC 52 write this way.

Measured in a throwaway zmx session with a marker OSC: against a program writing one short line every
80 ms, 0 of 200 injections landed inside a sequence; against 33 KB bursts back to back, 37 of 278 did.

The injected OSC 52 still parses whole: in ghostty `683d8db` ESC leaves every parser state, and a partial
UTF-8 character retries the ESC. What breaks is the program's own sequence. An interrupted CSI is
aborted, so the operation it carried can stay unapplied. An interrupted OSC is finalized with the prefix
received so far, which can apply a truncated title, working directory or hyperlink. A repaint does not
necessarily undo either.

The fix is a daemon patch that queues injected output until the parser is at ground, the way the
leadership patch's `Relay.forward` already delays its own role title. It reaches only daemons started
after the update, and it changes the zmx build id. A CLI-side sleep or a reset prefix cannot restore the
interrupted sequence.
