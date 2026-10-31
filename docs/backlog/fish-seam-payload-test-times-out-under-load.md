---
worth: later
where: agtermTests/SessionHostFishSeamTests.swift
added: 2026-10-25
---
# fish seam payload tests time out intermittently, cause unknown

Two patterns, not shown to share a cause:

- Captured payload, local, 2026-10-25: `testFailingPayloadsStillLandOnIntegratedFish` timed out in the
  fixture's wait after 16.7s in a full `make test-app` run at a load average of 14-20, and passed alone right
  after. The run left its fixture's `zmx attach` and `fish -il` running from `/tmp/shf-<uuid>/FishSeam.app`,
  holding the Debug app's `lsappinfo` entry as `exited-with-subordinates`.
- Durable creation command, CI: run 40945427430 (2026-10-29) timed out
  `testDurableCreationCommandLandsOnIntegratedFish` and both
  `testSurvivingDaemonDoesNotReplayDurablePayload...` tests. In the bare variants the attach exited at once,
  even with a `sleep 600` probe, so the pane ended before the probe wrote its argv. Run 41147902990
  (2026-10-30) timed out the supervised variant of `testDurableCreationCommandRunsUnderFishAndEndsThePane`:
  its attach started and nothing followed for 10s.

Not reproduced: 50 local runs of the durable test, and on CI (PR #848) 30 isolated runs of the fish class
plus 8 fresh full hosted-suite passes, all green. Neither a dependence on earlier suites nor a common cause
across the two patterns is established.

When a fixture operation throws, the fixture now prints the current wait phase, each pane's seed and screen,
the fixture files, the session host log, a bounded zmx listing and the app's generated ghostty config. The
next failure's report is where to start. Cleanup always ran on a throw; it discarded zmx failures and deleted
the fixture paths, and it now keeps them when it cannot confirm the daemon ended. The supervised fixture wait
(10s) is shorter than the session host client's reply deadline (12s), so a supervised report can end before
the client prints its own error.
