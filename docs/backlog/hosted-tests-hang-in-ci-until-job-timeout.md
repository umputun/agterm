---
worth: later
where: .github/workflows/ci.yml
added: 2026-10-22
---
# app-hosted tests hang intermittently in CI

Recorded hangs stopped producing output mid-suite and reached the 30-minute job timeout without a
reported test failure, stack, or process state, so each run says only which test case started last.

- run 39877572962, attempt 1 (PR #798): `ControlServerTests.testStartBindsAndStopUnlinksThePath` started
  at 00:31:58 UTC, then nothing until the cancel at 00:51:22. The re-run passed, and the full hosted suite
  (1408 tests) passed locally in two minutes on the same commit.
- run 39285473441 (branch `pane-focused-event`): last test started was
  `ZmxLaunchTests.testZshConfigurationDoesNotCopyTheInheritedXDGDataDirectories`.

The last-started tests differ; the logs do not locate the hang. The cause is open.

The hosted job now compiles with `xcodebuild build-for-testing` first and runs `test-without-building` under
`scripts/watchdog.sh` at 600s, with `WATCHDOG_RUNNER` naming this checkout's DerivedData test host, which
xcodebuild launches outside the command's tree. On a
hang it samples that host and the command's tree, kills both, and uploads `hosted-test-hang` with the
xcresult under `build/DerivedData/Logs/Test`. The next hang's artifact is where to start.
