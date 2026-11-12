---
worth: later
where: agtermCore/Tests/agtermCoreTests/HudHelperTests.swift:Run.waitForExit
added: 2026-11-12
---
# synchronous test waits hold concurrency worker threads during the Linux startup stall

Every Linux core run opens with a 20 to 30 s stall in which trivial `@MainActor` tests report 22 to 33 s
(see the `SshConnectionPoolTests` entry in `docs/ci-flakes.md`). In a local reproduction (CI image, 4 pinned
CPUs) a backtrace 12 s in showed concurrency worker threads parked in synchronous test code: six in
`HudHelperTests.Run.waitForExit` (`Thread.sleep` polling, as `Run.wait` also does) and one in
`OverlayRunJobTests.FakeOrigin.frames` (`DispatchSemaphore.wait`). The blocking reads in the same stacks
(`FakeOrigin.readLine`, `OverlayJobRunner.readLine`) run on dedicated `Thread`s, off the pool. A continuation resuming after `MainActor.run` took
14.2 s in the full suite and about 1 s with `OverlayRunJobTests` skipped; one run per configuration, so the
share each suite contributes is not sized, and skipping both left a stall of about 18 s.

The fix moves those pool waits elsewhere: async polling with `Task.sleep` in `HudHelperTests.Run`, and an
async wait for `FakeOrigin.frames`. It changes fixture execution and cleanup, so it needs a before/after
comparison of the stall in the same container, several runs each. The four observed `held()` failures are
addressed; the scheduling delay remains.
