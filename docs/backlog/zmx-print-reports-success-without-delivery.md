---
worth: later
where: agtermCore/Sources/agtermCore/TerminalClipboard.swift:copy
added: 2026-10-08
---
# zmx print exits 0 without proof the daemon took the write

`agtermctl clipboard set` runs `zmx print`, and its exit status is all the command knows. zmx's client
`send` (main.zig, pinned `8bab1f0`) writes the message and returns without reading a reply, and maps
`BrokenPipe` and `ConnectionResetByPeer` during the write to success. So a copy can be lost with exit 0.

Measured in a throwaway zmx session: 300 prints against a program writing 33 KB bursts back to back
(162 MB through the pty), 278 markers were captured at an attached client and 22 were not observed.
Exit codes and stderr were not captured per print, so the cause is not established. Candidates:
the swallowed write errors above, or the one-second probe timeout in `ipc.zig` returning before the send.
Against a program writing one short line every 80 ms, 200 of 200 arrived.

The fix is a zmx client patch that reports those errors, which a new client can use against daemons
already running. Deferred because any zmx patch changes the build id in `.zmx-build-stamp`, and the first
launch of the new build then classifies every daemon created before its recorded cutoff as outdated. Take
it with the next zmx patch rather than alone. Reproduce with exit status and stderr captured per print before choosing the fix.
