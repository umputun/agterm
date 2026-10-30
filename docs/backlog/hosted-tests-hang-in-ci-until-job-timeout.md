---
worth: later
where: .github/workflows/ci.yml
added: 2026-10-22
---
# app-hosted tests hang in CI until the 30-minute job timeout

The `Application-hosted unit tests` step sometimes stops producing output mid-suite and runs until the
`App-hosted tests` job's `timeout-minutes: 30` cancels it. No test failure is reported before cancellation, and
no stack or process state is kept, so the run says only which test case started last.

- run 39877572962, attempt 1 (PR #798): `ControlServerTests.testStartBindsAndStopUnlinksThePath` started
  at 00:31:58 UTC, then nothing until the cancel at 00:51:22. The re-run passed, and the full hosted suite
  (1408 tests) passed locally in two minutes on the same commit.
- run 39285473441 (branch `pane-focused-event`): last test started was
  `ZmxLaunchTests.testZshConfigurationDoesNotCopyTheInheritedXDGDataDirectories`.

The last-started tests differ; the logs do not locate the hang. The `swift test` step already runs under
`scripts/watchdog.sh` and uploads a `test-hang` artifact on a hang; the hosted step has nothing like it.
The agreed first move is
the same treatment for `xcodebuild test`: a deadline that captures `sample` or `spindump` of the host and
the test runner plus the xcresult before killing them, so the next hang leaves evidence for diagnosis.
That deadline has to leave enough of the job's 30 minutes for the capture and the artifact upload.
