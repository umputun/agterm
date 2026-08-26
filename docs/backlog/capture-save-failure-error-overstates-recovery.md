---
worth: later
where: agterm/Control/ControlServer.swift:544
added: 2026-08-26
---
# "the next save writes it" is true of only one store, not the next save

When `saveAllOpenChecked()` returns false, `restore.capture` answers "captured N pane(s) but at least one
window's save failed; the argv stays in memory and the next save writes it". The memory half is right,
nothing rolls the fields back. "The next save" is not: only a later successful save of the FAILED
window's store, or a successful global flush, writes that window's argv. An unrelated window's ordinary
save (session select, rename, split) writes its own store and does nothing for the failed one, so a user
who reads the sentence and then works in another window still has no capture where it failed.

`saveAllOpenChecked` attempts every store before returning its verdict
(`WindowLibrary.swift:544`), so with several windows open the successful ones already have the new
captures on disk while the failed one keeps its old snapshot. The verdict is an AND across stores and
that part is correct.

This is the same sentence corrected once already on PR #452 round 3, where the original claimed nothing
reached disk. It is now narrower-wrong rather than wrong. Found by codex during a second-opinion pass on
PR #452, merged as 22f3c7c. Fix is naming the failed window's own next save.
