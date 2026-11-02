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
