---
worth: maybe
where: agtermTests/TextPageRenderingTests.swift:testANearCapFileRendersInBoundedTime
added: 2026-11-16
---
# near-cap colored log page took 41 s in a full hosted run

`testANearCapFileRendersInBoundedTime` failed once in a local full `make test-app` run on the `jsonl-page`
branch: `XCTAssertLessThan failed: ("40.986949334 seconds") is not less than ("30.0 seconds") - colored.log`.
The other three cases passed. The rerun of the full suite passed it in 5.96 s, and a targeted run of the
text page classes in 5.9 s. That branch leaves the colored-page path unchanged (`ansi()`, `paintRuns()`, the
gutter and finder setup). No branch-specific cause was found; the slow stage and cause remain unresolved. Load was about 19 on 20 cores, and the log shows no
WebContent crash or relaunch, only 2-6 s gaps with nothing logged.

The 30 s bound came from c9abe6ff, which retired the earlier `big.diff` 11.5 s sighting by raising the bound
from 10 s with its stage-level cause unresolved (`docs/ci-flakes.md`). This sighting goes past the raised bound.

The clock covers writing and opening the file, page and WKWebView construction, reading and escaping, the ANSI
span build over the whole admitted file, gutter and search setup, and polling. `waitForScript` checks its own
deadline only after each `evaluateJavaScript` returns, so one slow reply can overrun it. Next step: time those
stages separately inside this test, reproduce in full runs, and compare the slow stage with master.
