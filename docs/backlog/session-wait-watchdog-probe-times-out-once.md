---
worth: later
where: agtermCore/Tests/agtermctlKitTests/SessionWaitCommandsTests.swift
added: 2026-11-02
---
# session wait watchdog probe test timed out once, cause unknown

`watchdogFiresWhileTheGlobalQueueIsExhausted` failed once on 2026-11-02 with `watchdog probe did not exit
within 15 s`, in a full `swift test` run that came right after a build which relinked the probe. That run
starts the three test binaries together, so the CLI suite ran beside the core suite. The probe's own waits
add up to about 4.5 s, but startup and `exit()` are not bounded by them.

Not reproduced: the test passed in 26 later runs, 3 of the CLI suite alone and 23 of the full parallel
suite at a load average of 6-13, and the probe exited 0 in 1-2 s in 6 direct runs. All of them reused the
built binary, so a run right after a relink was not repeated. Fresh
signed copies of the probe launched in about 1.27 s initially and 1.08 s on repeat; no cause established.

Open: the probe stalled (in startup, before `main`, or in `exit()`), or it exited and the parent's
`Process.isRunning` had not caught up. On a timeout the test now records the probe's stage log (uptime ms,
`main entered` through `calling exit(N)`), the uptime when `run()` returned, `isRunning`, the `p_stat`
snapshot and `kill(pid, 0)`, then cleans up with a 5 s bound. These are sampled one after another and can
disagree while the probe exits, and they locate a phase without explaining it. The next report is where to
start; if it is not enough, collect stacks of both processes at the timeout.
