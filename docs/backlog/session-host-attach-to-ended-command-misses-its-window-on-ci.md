---
worth: maybe
where: agtermCore/Tests/SessionHostRuntimeTests/SessionHostServerTests.swift:paneAttachAfterTheCreatedCommandEndedStartsNoShell
added: 2026-11-02
---
# session host attach to an ended command misses its 3 s window on CI, cause unknown

`paneAttachAfterTheCreatedCommandEndedStartsNoShell` failed in run 41408692761 (PR #864 head `560228b4`) with
`the pane's attach to an ended command kept running`: the pane's `zmx attach`, which carries the
"session is gone" guard payload, was not reaped within the test's 3 s window and was killed. No daemon was
left under the name. The whole test took 4.40 s there; locally it passes in about 1.2 s, alone and in every
full parallel run. The branch changed nothing in the session host, zmx or this test, and master's CI on the
same base passed it. The next run, on `50de4c44`, passed.

Open: a slow exit and a stuck one look the same at the 3 s mark. On a stall the test now reports the pane's
last `waitpid` result and errno, its `p_stat`, argv, whatever its PTY and exec-error pipe hold, the `zmx list`
output and the host log, recorded before the kill. The next failure's report is where to start; collect
stacks of the pane and host if it does not locate the phase.

Run 41899293201 (PR #891 head `e109e4f7`) failed it again, 3.88 s in, with the stall report: `waitpid` 0,
errno 0, `p_stat` SRUN after 3.06 s. The argv was the guard payload (`zmx attach <name> /bin/sh -c
"printf ... 'agterm: session is gone'; exit 1"`), the exec-error pipe was empty, and the PTY held zmx's
`session "<name>" created` plus its screen reset, but not the payload's message. `zmx list` showed no
session under the name and the host log was empty. So the daemon zmx created for the payload was gone or
never listed while the attach client kept running; whether the payload ran and its output was lost, or the
attach never saw the daemon end, is not established.

Run 42295772822 (master `255f13a2`, the v0.41.0 release commit) failed it a third time, 4.32 s in: `waitpid` 0,
errno 0, `p_stat` SRUN after 3.16 s, empty `zmx list` and host log. This time the PTY held the payload's
output after zmx's `session "<name>" created` and screen reset: `agterm: session is gone`. So the payload
reached its `printf` in this run, and the attach client was still not reapable at the last poll. Whether it
exits late or never, whether the daemon process had ended, and what happened in the earlier run without
that message, are still open.
