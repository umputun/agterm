---
worth: maybe
where: agtermCore/Tests/agtermCoreTests/HudHelperTests.swift:Run.stop
added: 2026-11-15
---
# hud helper test reports an ignored SIGTERM on Linux CI

Linux core tests failed once on PR #1010's run (https://github.com/umputun/agterm/actions/runs/43768521443,
job 132979003729) in `keepsPaintingWhenTheOwnerFieldIsNotAPid(owner: "")`, at `HudHelperTests.swift:131`:

```
hud.sh ignored SIGTERM: pid 7339
  output 64 -> 64 bytes over 0.5s
  PID PPID STAT ... ELAPSED COMMAND
  7339 7059 Z   ... 00:24   [sh] <defunct>
```

After `Run.stop`'s 2 s wait expired, the diagnostics showed the helper as a zombie. The neighbouring tests in
that run all reported about 29 s, the Linux startup stall. [Inference] Exit observation may have been delayed
during the stall; the cause is not established. A single failure; master's previous 15 runs were green, and
the PR touched neither agtermCore nor `hud.sh`.

Related: the pool-wait item fixed in #1001 (f30f8a06) moved these waits to `Task.sleep`; that fix did not
remove the stall itself. A `docs/ci-flakes.md` entry is owed once the cause is understood.
