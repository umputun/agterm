---
worth: maybe
where: scripts/test-surface-teardown.py:run_case
added: 2026-10-30
---
# CI teardown smoke test stalls on `session new` before any close

The `Surface teardown under mailbox pressure` step's spam-8 case times out in CI on one `agtermctl session
new` before any session is closed: `new-2` in the first sightings, later `new-3`, `new-5` and `new-7`, so with
two to seven title producers already running. Each producer writes titles in an unthrottled loop, and the
runner is a 3-vCPU VM; whether they starve the app and the collectors is open (see the last section).

- run 41121304109, attempts 1 and 2 (PR #844 head `87d74a7d`): `new-0` and `new-1` answered in 33 and
  46 ms, `new-2` got no reply within 5 s. The app `sample` itself timed out after 20 s and the CLI
  sample ran after the CLI had exited, so neither stack exists.
- run 40747601941 (master, 2026-10-28): the same call timed out the same way, before in-flight app and
  CLI sampling was added.

#844 fixed the stall this test reproduces locally: the teardown patch drained its deferred backlog with
`orderedRemove(0)`, and after a 1.1 s close the main thread sat in `memmove` under `ghostty_app_tick`.
That shape follows a close; this one has none before it, so the fix is not shown to cover it. Run
41132248681 (`aa772641`, with the fix) passed spam-8 in 9 s, and so did a concurrent PR's run of the old
code, so one pass proves nothing.

Run 41408692761 (PR #864 head `560228b4`) stalled the same way: `new-0` and `new-1` in 75 and 177 ms,
`new-2` timed out, the app `sample` timed out after 20 s and the CLI had exited before its sample ran.

A stalled call now also gets a `sudo -n spindump` of the app, bounded at 15 s, and the step checks that
collector once against a throwaway process into `spindump-check.json`. Run 41414892558 validated the previous
two-target invocation on the runner (a readable 1.3 MB report naming its target). The next stall's evidence
should include `spindump-NN-<op>.txt`; start there.

Run 41424943333 (PR #865 head `acef8084`) stalled the same way: `new-0` and `new-1` in 57 and 131 ms, `new-2`
timed out. All three collectors failed: the app `sample` timed out after 20 s, the CLI `sample` could not
examine the CLI pid, and the spindump, which then also named the CLI with `-proc`, failed whole with `Cannot
find process with pid or partial name` for that pid. Collectors start at 3 s and the CLI is killed at 5 s, so
the spindump may have looked after the CLI was gone; the cause is not established. The CLI was dropped from
the spindump so a lost CLI cannot cost the app snapshot; that does not guarantee the app stack next time.

Run 41481808137 (PR #869 head `66b49472`) stalled one call later: `new-0` to `new-2` answered in 39 to 88 ms
with three producers running, and `new-3` timed out after its CLI took 0.62 s to spawn. The spindump self-check
on that runner produced a 1 MB report, yet all three in-flight collectors failed: the app `sample` timed out
after 20 s, the CLI `sample` could not examine the CLI pid, and the app-only spindump timed out after 15 s and
left an empty `spindump-04-new-3.txt`. A collector that works against a throwaway process and times out
against the stalled app suggests the app or the runner resists inspection during the stall, rather than the
collector's arguments being wrong; that is not established.

Run 41525711638 (PR #874 head `2b85193d`) stalled later still: `new-0` to `new-6` answered in 58 to 507 ms,
and `new-7` timed out. The spindump self-check produced a 1.3 MB report, yet every in-flight collector failed
again: the app `sample` timed out after 20 s, the CLI `sample` could not examine the CLI pid, and the app-only
spindump timed out after 15 s and left an empty `spindump-08-new-7.txt`. The re-run passed.

Run 41899293201 (PR #891 head `e109e4f7`) stalled the same way: `new-0` to `new-6` answered in 69 to 638 ms,
and `new-7` timed out after its CLI took 0.26 s to spawn. The spindump self-check produced a 1 MB report, yet
every in-flight collector failed again: the app `sample` timed out after 20 s, the CLI `sample` could not
examine the CLI pid, and the app-only spindump timed out after 15 s and left an empty `spindump-08-new-7.txt`.

Two master runs stalled on `new-5`: 41719380918 (`1ff85c6`, 2026-11-03) and 41905113022 (`78cf140`,
2026-11-04). `new-4` took 0.85 s in both, and every in-flight collector failed as before. In 41719380918 the
spindump self-check against a throwaway process also timed out, so the runner itself resisted inspection then.
That is nine failed runs, ten attempts, and no stack.

A stalled call now also records `ps` CPU per process, the app's thread states (`ps -M`) and `vm.loadavg`,
none of which needs a task port. High aggregate CPU with runnable producers would support starvation; a low
snapshot would not rule it out, since `pcpu` is a decaying average. A concurrent `agtermctl version` is
useless here: `ControlServer.acceptLoop` serves one connection at a time, so it queues behind the stuck call.
If starvation shows, throttling the producers is a test change, and whether it still loads the mailbox
enough to catch the #844 regression has to be checked.

Run 42292892846 (master `aa1201e5`, 2026-11-06) is the first stall with that capture: `new-0` and `new-1`
answered in 41 and 38 ms, and `new-2` timed out. `ps-03-new-2.txt` shows the app at
183% CPU, the three producer pythons at 95% together, and `vm.loadavg` at 24.3 on the 3-vCPU runner. The
capture is late: `new-2` had run 9.9 s and its CLI was already defunct, `pcpu` is a decaying average and
the load average spans minutes, so this shows heavy app CPU under title load without placing it in the
5 s window. The app `sample` and spindump failed again; spindump finished sampling and stalled while
processing symbols. What blocked the call is still open.

Run 42302198754 (PR #910 head `f593d7b2`, 2026-11-06) stalled at `new-5`: `new-0` to `new-4` in 56 to 357 ms.
The `ps` capture lists six producers, the sixth started about 3 s after the others, so `new-5` reached the main
thread and created its surface late; its reply still missed the 7 s the script waited. Both app collectors
logged `Sampling completed, processing symbols...`: they attach, and lose the report while symbolicating.
Spindump's stuck notice suggested `-noIPC` and saved a raw stackshot under `/var/tmp`. The step now passes
`-noIPC` and copies such a stackshot into the case folder (`spindump -i` reads it), recording copy failures as
`stackshot_errors`.

Every OSC title is one message: the pinned libghostty does not dedupe, and `App.drainMailbox` loops
`while (mailbox.pop())` inside `ghostty_app_tick` on the main thread, while each SET_TITLE callback queued
another main block. Measured locally on a Release build with a throwaway probe, eight producers on the 20-core
Mac: about 280k titles/s, ticks taking 60-95% of the main thread with single ticks up to 135 ms, and up to
34k title blocks waiting on main. Calls made after 2 s of flooding still answered in 48-78 ms, so the local
run shows pressure, not the stall. `TitleAdmission` now skips a title while an identical one from the same pane
is still queued: in the same run titles reaching main fell from 1.68M to 290k, the peak backlog from 34k to 11,
tick time from 179 to 116 ms per 250 ms window, and late `session new` to 22-35 ms. The ticks themselves
remain, so whether this removes the CI stall is unproven; the next stall's stackshot is the evidence to read.
