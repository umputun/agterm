---
worth: maybe
where: agtermTests/TextPageRenderingTests.swift:testANearCapFileRendersInBoundedTime
added: 2026-11-10
---
# near-cap diff page took 11.5 s against the test's 10 s bound on CI

`testANearCapFileRendersInBoundedTime` failed in run 42883406544 (PR #955 head `60e0a272`, App-hosted tests job):
`XCTAssertLessThan failed: ("11.543139667 seconds") is not less than ("10.0 seconds") - big.diff`. The other three
cases (`high.go`, `plain.log`, `colored.log`) passed, and the later hosted runs on #955 and #957 passed it.

The diff fixture is a single-change patch near `TextPage.maxBytes`, past `maxHighlightBytes`, so it skips syntax
highlighting. The clock starts before the file is written and opened and stops after the DOM check, so the 11.5 s
does not isolate any one stage, and the cause is unmeasured. Time the four cases on a runner before changing the
bound.
