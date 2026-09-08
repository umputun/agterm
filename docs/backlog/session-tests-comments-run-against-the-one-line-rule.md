---
worth: maybe
where: agtermCore/Tests/agtermCoreTests/SessionTests.swift:clearPendingForegroundCommandsDropsBothCapturesAndKeepsTheRestorePins
added: 2026-08-27
---
# SessionTests carries 24 multi-line test comments against the one-line rule

CLAUDE.md says test comments are rare and one line, added only where neither the name nor the setup
reveals the goal, and never restating an assertion or explaining why a test exists. `SessionTests.swift`
has 24 multi-line comment blocks: 18 inside test bodies and 6 sitting above a test. All 24 break the
one-line clause. Not all of them break the others, so a sweep has to read each one rather than trim by
line count. The block at `:532`, on `clearPendingForegroundCommandsDropsBothCapturesAndKeepsTheRestorePins`,
breaks all three: it opens with why the test exists, and its closing sentence, "The session.restore pins
are sticky and must survive", restates the `#expect` at `:545`.

Filed as one item rather than as findings because the fix is file-wide or nothing. PR #490's new test at
`:549` copied the `:532` block near-verbatim, which is the right instinct for a contributor matching his
neighbour and the wrong outcome against the rule. Trimming only the newest one leaves the pair mismatched
and buys nothing.

Two ways out, and choosing between them is the work: trim all 24 to the one line that neither the name nor
the setup reveals, or state in CLAUDE.md that this file's restore/capture tests are exempt because the
persisted versus pending distinction is not readable from the setup. Do not start until that is decided.
