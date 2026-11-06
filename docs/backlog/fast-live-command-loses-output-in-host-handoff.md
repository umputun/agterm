---
worth: maybe
where: agtermCore/Sources/SessionHostRuntime/Host.swift:handle(ensure:)
added: 2026-11-01
---
# a fast Live --command loses its output in the session-host handoff

A Live `--command` pane is created in two steps: `agterm-session-host` attaches with the full payload, waits
for a leader, terminates its client and answers `.ok(.created)`; the pane's client then attaches again. zmx
ends a daemon on PTY EOF whoever is attached (`loop.zig` `daemonLoop`), so a command that ends inside that gap
is gone before the pane connects. The pane's attach carries a "session is gone" guard payload, so it ends with
that line rather than starting a shell, but the command's output is lost.
`SessionHostServerTests.paneAttachAfterTheCreatedCommandEndedStartsNoShell` reproduces the gap every time; one
`ZmxLiveUITests` run in about nine matched it, and `testAWaitCommandKeepsScrollbackPastOneScreenAfterExit` can
still fail that way, now on the gone line. Unmeasured: how often an instant command such as `echo x` hits it.

Keeping the output means a zmx patch that retains an opted-in daemon after EOF, for a fixed bound, until the
pane's own managed client has been sent the final snapshot (zmx already replays scrollback and screen on
attach). Delaying the command's start until the pane attaches was rejected: it moves when side effects begin.
Edges the design must settle, from codex and plan review:

- host readiness accepts a completed row whether its creation client still runs or exited; `awaitLeader`
  polls the child before listing, and the existing-row branch also requires a live leader;
  `SessionHost.Ready.leaderPid` must become optional
- a second ensure against a kept daemon, including companion respawn under the same pane identity; the
  socket must be unlinked before any client gets EOF
- the host's bootstrap client inherits the pane's managed nonce, so it needs an explicit mark, or the host
  strips `ZMX_MANAGED` from it; an unmanaged client never ends retention
- new zmx variables are unset before the payload runs and cleared from inherited pane environments
- a host left from before an app update sets none of this; bump `protocolVersion` or document it
- `zmx list` reports `state=completed` without `pid=`; `ControlZmxEntry`, the CLI and the command reference
  gain the field; the leader map already drops pid-less rows, so foreground and capture need tests only
- a fixed 30 s bound makes an expiry test wait 30 s; reach the guard case through `zmx kill` instead
