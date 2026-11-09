---
worth: maybe
where: agtermTests/AppDelegateCaptureTests.swift:testExitCaptureReadsALiveListingSlowerThanAHundredMilliseconds
added: 2026-11-09
---
# exit capture test misses a 120 ms listing in full hosted runs

`testExitCaptureReadsALiveListingSlowerThanAHundredMilliseconds` pins #915: the quit-time capture must read
a zmx listing slower than 100 ms within `ZmxClient.captureInvocationTimeout` (0.3 s). Its fake zmx is one
`zsh -f` that waits 120 ms with `zselect`, then prints the listing.

It fails intermittently in full `make test-app` runs and passes alone. The convert-to-companion plan
(`docs/plans/completed/20261107-convert-to-companion.md`) recorded it failing in two of four full runs, with
the fake finishing as late as 287 ms under the suite's load. The `zsh -f` plus `zselect` fake replaced
`/bin/sh` plus `/bin/sleep` then, and the cause (a slow child or a late termination callback) was not
observed at a failure.

On 2026-11-09 it failed again in a full run on master `0dcdd6e8` (with doc and test edits outside the
capture path), load under 40: 0.620 s, `count` 0 and `foregroundCommand` nil
(AppDelegateCaptureTests.swift:94-95). Run alone right after, its class passed, and this test took 0.300 s,
the whole budget, for a script that waits 120 ms.

Open: why a passing run takes the full 0.3 s. [Inference] If the listing read returns only near the
deadline even when the child has already printed, the margin for a real slow listing at quit is thinner
than the budget suggests, and #915's symptom (reattached panes with no command) can come back on a loaded
Mac. Timing the child's exit against the read's return in a passing run is where to start.
