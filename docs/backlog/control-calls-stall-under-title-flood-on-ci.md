---
worth: later
where: agterm/Control/ControlServer.swift, libghostty App.drainMailbox
added: 2026-11-11
---
# control calls stall for seconds under an OSC title flood on 3-vCPU runners, cause unknown

The surface teardown smoke's eight-producer case (`spam-8`) failed about 20 CI runs: with two to seven panes
printing titles in a loop, one `agtermctl session new`, `tree` or `session close` got no reply for 5 to 125 s.
The case is retired; `docs/ci-flakes.md` lists every run and what was measured. The stall itself is not
explained, and nothing in CI watches for it now.

The one lead: every OSC title is one app-mailbox message, and `App.drainMailbox` loops
`while (mailbox.pop())` inside `ghostty_app_tick` on the main thread. `ControlServer.acceptLoop` serves one
connection at a time, so any call queues behind a stuck one. On a 20-core Mac a Release build took about
280k titles/s with ticks using 60 to 95% of the main thread, yet calls still answered in 48 to 78 ms.
`TitleAdmission` cut titles reaching main from 1.68M to 290k in that run; whether that is enough on a
3-vCPU runner is unknown. [Inference] A low-core Mac could show the same stall as a frozen UI.

To reproduce: the case and its capture steps are in `scripts/test-surface-teardown.py` at `6a56d084`. On the
runner, every `sample` and `spindump` report timed out or stalled while processing symbols. The raw stuck
stackshots saved instead decode offline only to bare addresses, because the runner's shared cache and the
run's Release binary do not survive the job. The next capture has to decode the stackshot on the runner
inside the step, or keep the Release binary and its symbols with the evidence.
