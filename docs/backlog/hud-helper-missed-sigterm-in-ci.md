---
worth: maybe
where: agtermCore/Tests/agtermCoreTests/HudHelperTests.swift:Run.stop
added: 2026-10-18
---
# a hud.sh test helper kept painting after SIGTERM in CI

CI run 39101378893 (PR #771) hung `swift test` until the 600s watchdog. The `test-hang` artifact shows
`HudHelperTests.paintsWhicheverFramesTheHeaderCarries(style:)` in `Run.stop()`'s then-unbounded
`waitUntilExit`, with its `/bin/sh agterm/Resources/hud/hud.sh` child five minutes old and still ticking
(a fresh `sleep 0.08`), although the script traps TERM to exit. Not reproduced in 25 local runs.
`Run.stop()` now bounds the wait and records `hud.sh ignored SIGTERM` before falling back to removing the
body file, so a recurrence fails that test by name instead of hanging the suite.

It recurred in CI run 39110701002 (PR #775) as a 2s miss in
`rewritingResizesTheContentInsideTheSameBox`, a spinner test stopped after a rewrite; the helper exited
within the next 2s after body-file removal. A 2s miss alone does not prove the loop kept running, so `Run.stop()` now records two
`ps` snapshots of the shell and its children (state, pending and blocked signals, age) and the output size,
before the fallback. A continuing loop shows new `sleep` pids; PENDING 0 fits a consumed, ignored or
never-delivered TERM.

Local probes observed `Process` resetting inherited blocked/ignored TERM and `terminate()` signaling the
child process group, so TERM reaches the helper and its foreground `sleep` together. The failed CI child's
signal state and delivery remain unmeasured. No local reproduction: HudHelperTests repeated 40
times, the full agtermCore suite repeated 20 times, and 480 helpers terminated at random moments.

The cause is open. One state that produces it: a shell that starts with TERM already ignored cannot trap
it, which `stopFailsAndStillEndsAHelperThatIgnoresTerm` reproduces on purpose. [Unverified] whether the CI
child inherited an ignored or blocked TERM. Production teardown does not depend on TERM: the app removes
the body file (`Session.discardHudBody`), and the helper also checks owner liveness.
