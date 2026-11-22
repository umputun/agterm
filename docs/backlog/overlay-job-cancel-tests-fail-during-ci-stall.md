---
worth: maybe
where: agtermCore/Tests/agtermctlKitTests/OverlayRunJobTests.swift
added: 2026-11-16
---
# overlay job cancel tests fail during a macOS CI stall

`OverlayRunJobTests.aCancelFromTheAppEndsTheProgramCanceled` and `aCancelKillsAProgramThatIgnoresTheFirstSignal`
failed together in two macOS Unit runs: #1016 at f68b4955 (run 43831232607, job 133176908462) and #1021 at f5a04f7b
(run 43866829158, job 133297572799), a change with no `agtermCore` code; #1016's rerun passed. Each time the program
ended with status 0 after about 30 s (`sleep 30` ran to the end) and `origin.frames() == [.started, .canceled]`
failed. Both runs were stalled: #1016's took 189.9 s against 71.6 s on the previous commit, with unrelated tests
reporting 98 s, and #1021's went silent until the 600 s watchdog ended it.

Whether `.canceled` was recorded late or never is unknown: Swift Testing prints no operands for an `await`
expression, so both tests bind the received frames to a local, and the next failure shows them. Both schedule the
cancel with `DispatchQueue.global().asyncAfter(+0.3 s)`: the first sends it over the socket, the second calls
`runner.cancel()`, so socket delivery is not the cause there, while the delayed dispatch is shared. Cause unresolved.

The page tests that failed in the same runs are recorded in `docs/ci-flakes.md`; #1051 put page claim expiry on
`ServerStreams.now`, which the harness freezes.

Diagnostics still to add for the next occurrence: record when the `asyncAfter` callback starts, when
`cancel()` runs and which group it signals, and when the child is reaped.
