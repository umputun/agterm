---
worth: maybe
where: agtermCore/Tests/agtermctlKitTests/OverlayRunJobTests.swift
added: 2026-11-16
---
# overlay job cancel and page tests failed once during a macOS CI stall

macOS Unit tests failed once on #1016 at f68b4955 (run 43831232607, job 133176908462) in four tests whose failures
lie outside that PR's changed code, though the page tests read the tree it changed. A rerun of the same job passed, which does not rule out scheduling influence from the PR:
it raised the control socket's reply task to `.high` and added a 600-job same-priority flood test to the shared
process. The run took 189.9 s against 71.6 s on the previous commit; the flood test, which only waits for its own
jobs, passed after 65 s, and unrelated tests around 08:36 to 08:37 reported 98 s.

- `OverlayRunJobTests.aCancelFromTheAppEndsTheProgramCanceled` and `aCancelKillsAProgramThatIgnoresTheFirstSignal`:
  status 0 after about 30 s (`sleep 30` ran to the end), and both failed `origin.frames() == [.started, .canceled]`.
  Swift Testing does not print the received frames for an `await` expression, so whether `.canceled` was recorded
  late or never is unknown. The cancel is delivered through `DispatchQueue.global().asyncAfter(+0.3 s)`; the second
  test calls `runner.cancel()` directly, so socket delivery is not the cause there. Cause unresolved.
- `ServerStreamsTests.everyPageKindOpensInEveryLinkMode` (`.overlay50`, `.overlay`, `.browser`): close answered
  `no overlay` after the page request arrived. `textCommandsReachThePresenterAndAnswerWithItsResult`: the text node
  was gone (`ServerStreamsTests.swift:1377`) and a page command never came (`:1419`). [Inference] These tests never
  claim the page, so `AppStore.pageClaimWindow` (30 s, real clock) would end it during a long stall; the page offer
  time was not measured. `docs/ci-flakes.md` lists the same test under #949's pre-merge runs. Cause unresolved.

Diagnostics for the next occurrence: print the received frames; record when the `asyncAfter` callback starts, when
`cancel()` runs and which group it signals, and when the child is reaped; for the page tests, record the page offer
time, its claim deadline and when the slot was removed.
