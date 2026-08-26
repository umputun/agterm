---
worth: later
where: agterm/Control/ControlServer.swift:651
added: 2026-08-26
---
# nothing reports whether a restore capture is armed

`ControlSessionNode.foreground` and `.splitForeground` are built from `ForegroundProcess.running` over the
LIVE surface, not from the captured `session.foregroundCommand` slot, so no tree, window node or top-level
field says whether a capture is armed. CLAUDE.md's cross-surface contract says a state-setting command
must expose its result on one of those three, and `restore.capture` writes state that outlives the call.

A scheduled caller polling `tree` to confirm a capture is still armed reads the live process instead:
after the pane's command exits it sees `foreground: null` while a stale capture is armed and will re-run
at the next launch, and the reverse during the pre-mount launch gap. `result.count` answers only for the
one call that produced it.

`.claude/rules/settings.md:183` still reads "`restore.clear` and tree foreground fields are the control
surface", which now describes a tree that does not answer "what will restore".

Two ways out. Project the persisted `foregroundCommand` / `splitForegroundCommand` slots as distinct
fields alongside `foreground`, staying nil mid-run for a launch that armed only the transient pending
slots so the two never read as the same fact - that touches `ControlSessionNode`'s public initializer, the
`controlTree` closure set, control-api.md, commands.html, reference.md and the protocol tests. Or state in
control-api.md's Restore section that the slots stay read-back-free by design and amend the settings.md
line, which is a paragraph. The design half was already decided on PR #452 round 1: whether these slots
become a public read surface is a decision for `restore.capture` and `restore.clear` together, not
something to bolt onto one of them. This item is the write-up that decision never got.

Surfaced reviewing PR #452, merged as 22f3c7c. Deferred rather than asked of the contributor because the
wider fix reaches shared code he did not come to touch.
