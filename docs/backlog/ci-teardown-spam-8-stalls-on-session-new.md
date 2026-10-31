---
worth: maybe
where: scripts/test-surface-teardown.py:run_case
added: 2026-10-30
---
# CI teardown smoke test stalls on `session new` before any close

The `Surface teardown under mailbox pressure` step's spam-8 case has timed out on the third
`agtermctl session new` (`spam-8-2`) in CI, with two title producers running and no session closed yet:

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

The next occurrence needs a stack first. The step uploads `surface-teardown` evidence, but a `sample` that
outlives its 20 s limit leaves only `sample_errors` in `result.json`.
