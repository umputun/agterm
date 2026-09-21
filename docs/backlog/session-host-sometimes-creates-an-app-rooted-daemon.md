---
worth: maybe
where: agtermTests/SessionHostClientTests.swift:29
added: 2026-09-20
---
# a racing session-host client sometimes creates an app-rooted daemon

`testTwoRacingClientsUseOneRoot` once observed responsibility roots `[6015, 1146]` instead of
`[6015, 6015]`: 6015 was the disclaimed session host and 1146 the hosted test app.
During validation of remote split mirroring rebased onto #635, this failed in 1 of 9 full hosted runs
and passed 6 of 6 isolated runs. All five instrumented full runs passed.
Their successful clients received `ok(created)`; the only recorded fallbacks were the expected
`beforeDispatch` timeouts in `testLockedOwnerWithoutListenerIsLeftAlone`.

Unverified correlation: the failing run immediately followed a fresh worktree zmx build.
That is one data point, not an established cause. The zmx `timedOut` lines occurred 14 times in the
failing run and 14 in every passing run, so they do not distinguish it or establish machine saturation.
The original failure had no retained client diagnostics. The cause and an appropriate fix remain open.

Two source-confirmed routes can create a daemon under the app without a timeout; neither is confirmed
as the route taken in this failure:

- An initial inventory launch, exit or parse failure in
  `agtermCore/Sources/SessionHostRuntime/HostBackend.swift:124` makes
  `Host.swift:79` return a `before` failure. `agtermCore/Sources/agtermCore/SessionHost.swift:190`
  selects `fullAttach`, and `agtermCore/Sources/SessionHostRuntime/Client.swift:45` executes the
  original attach from the app's child. If the daemon is absent, that client creates it.
- A temporary attach spawn failure at `agtermCore/Sources/SessionHostRuntime/Host.swift:86`, or an
  early child exit at `Host.swift:116`, returns a `started` failure. The client selects `uncertain`
  and executes bare `zmx attach NAME` at `Client.swift:45`. Removing the command payload prevents its
  replay, but bare attach still creates an absent daemon under the app.

On recurrence, read unified logging for the client PID and failure time:

```sh
/usr/bin/log show --last 1h --style compact \
  --predicate 'subsystem == "com.umputun.agterm" AND category == "session-host"'
```

`client NAME phase=... error=...` records a thrown error. `beforeDispatch` includes finding/starting
the host and its hello; `afterDispatch` means sending the ensure has begun.
`client NAME host stage=... message=...` records a host rejection: `before` permits full attach,
while `started` permits only bare attach. These records add no pane output; the existing uncertainty
message still appears when a command may have run.

The hosted fixture retains `client-INDEX-NAME_SUFFIX.stderr` for non-terminal clients only; terminal
clients keep stderr on their PTY. Every run retains these files and, when present, `host.log` under
`/tmp/agterm-session-host-evidence/shc-UUID/`, outside the removed fixture directory.
The host log includes the underlying initial inventory error and connection rejection errors.
Preserve those files and the test result before investigating a recurrence.
Do not change deadlines or fallback policy without identifying the failing path.
