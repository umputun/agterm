---
worth: later
where: scripts/zmx-patches
added: 2026-10-17
---
# a DA query in the creation attach's pre-Init window is answered twice

A shell's DA1/DA2 query that zmx reads in the same loop iteration that accepted the creation attach, or
any iteration before that client's `Init` is read, gets two replies. The extra one stays in the tty as
input nobody asked for. Since #760 `NativeHostChild` (`agtermCore/Sources/SessionHostRuntime/HostBackend.swift`)
answers every DA query reaching the creation attach's pty. zmx at the pin (`src/loop.zig`) answers on the
terminal's behalf while `!hasTerminalClient()` (`is_terminal` is set only in `handleInit`), yet broadcasts
the raw PTY bytes to every client in `daemon.clients`, the not-yet-`Init` one included. A client accepted
mid-iteration is not polled until the next one, so its `Init` always trails that first read.

Symptom: `SessionHostServerTests.realHostStartupReplyAndClientlessControl` fails about 1 run in 12 of
`swift test --filter SessionHostRuntimeTests`. Its clientless DA2 probe reads `ESC[?62;22c`, the leftover
DA1 reply, at `controlMatches`.

The host cannot tell whether zmx already answered, so the fix belongs in zmx: a new
`scripts/zmx-patches/0003` that drops a query the daemon answered itself from the broadcast, passes every
other byte, and shares matching with reply generation, keeping the existing split-query behavior. Zig
regression in `loop.zig`: a connected client without `Init` gets one daemon reply and no forwarded query;
after `Init`, the query is forwarded and the daemon does not reply. Deferred because the patch rebuilds
zmx for everyone and its new build id flags every existing Live session as predating the last Live
sessions update. The race also exists upstream for any terminal client, so it may be worth reporting to
neurosnap/zmx.
