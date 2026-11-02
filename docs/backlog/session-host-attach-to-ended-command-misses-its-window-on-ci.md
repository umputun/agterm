---
worth: maybe
where: agtermCore/Tests/SessionHostRuntimeTests/SessionHostServerTests.swift:paneAttachAfterTheCreatedCommandEndedStartsNoShell
added: 2026-11-02
---
# session host attach to an ended command missed its 3 s window once on CI, cause unknown

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
