---
worth: later
where: agtermCore/Sources/agtermCore/ControlProjection.swift:87
added: 2026-09-03
---
# The control tree exposes no split-pane cwd

`ControlSessionNode` carries one `cwd`, the primary pane's. It already exposes the split's other
per-pane state — `splitFocused`, `splitRatio`, `splitAxis`, `splitFontSize`, `splitForegroundShell` —
so the directory is the one split field a caller cannot read. `Session.splitCwd` (and its restored
`initialSplitCwd` fallback) is what `cwd(for: .right)` resolves, and nothing projects it.

A caller cannot tell where a split pane actually is. That matters for any script that reasons about a
session's panes separately: spawning something in the split's directory, or checking a pane's location
before acting on it, both need a `tree` read the API cannot answer.

It also blocks verification. The synthetic-title harness asserts each session's sidebar name against
the basename of its cwd, and for the one session whose split lives in a different directory
(`reproxy`, split in `fya`) it has no expectation to build, so that session's split pane is excluded
from the check rather than verified. Any future harness comparing a pane against its own directory
hits the same wall.

Adding it is a `splitCwd` field on `ControlSessionNode`, populated from `session.splitCwd ??
session.initialSplitCwd` next to the existing split fields, plus the read-back test the control-api
rule requires. The `title`/`splitTitle` pair has the same asymmetry and is worth deciding at the same
time. Surfaced by Fable while reviewing the synthetic-title fix.
