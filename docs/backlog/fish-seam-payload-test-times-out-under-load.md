---
worth: later
where: agtermTests/SessionHostFishSeamTests.swift:testFailingPayloadsStillLandOnIntegratedFish
added: 2026-10-25
---
# fish seam payload test times out under load and leaks its zmx and fish

`testFailingPayloadsStillLandOnIntegratedFish` failed once in a full `make test-app` run (1414 tests) with
`POSIXError(.ETIMEDOUT)` thrown from the fixture's `wait(timeout:until:)` after 16.7s, while the machine sat
at a load average of 14-20. Run alone right after, it passed. Which `wait` expired is not known: the
failure line points at the throw inside the helper, not at the caller.

The failed run left its fixture's `zmx attach agterm-...` and `fish -il` running from
`/tmp/shf-<uuid>/FishSeam.app`, holding the Debug app's `lsappinfo` entry as `exited-with-subordinates`,
so the cleanup path does not run when a wait throws. Two things to find: what the fixed 5-10s waits are
racing under load, and why a thrown wait skips killing the attach client and its shell.
