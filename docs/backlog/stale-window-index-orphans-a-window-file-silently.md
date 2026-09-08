---
worth: later
where: agtermCore/Sources/agtermCore/WindowLibrary.swift:bootstrap
added: 2026-08-20
---
# a valid-but-stale windows.json orphans a window file with no recovery and no signal

`saveIndex()` catches and logs its own write failure, and nothing above it ever learns the index did not
reach disk. `bootstrap()` then calls `recoverOrphanedWindows()` only when `loadIndex()` returns nil,
so an index that is valid JSON but missing an entry short-circuits straight to `reopen(index)`
and the orphaned `windows/<id>.json` is never scanned. The window and every pane in it are gone on the
next launch, with nothing in the UI saying so.

Reaching it takes a failed atomic write of `windows.json`, storage recovering afterwards, no
window create, close, rename or delete in the meantime (`newWindow`, `closeWindow`, `renameWindow` and
`removeWindow` each rewrite the index), and then a crash before any clean quit, since
`AppDelegate.applicationWillTerminate` repairs it. Remote, but a full disk gets there.

Found while reviewing PR #452, which does not cause or worsen it: the same loss happens without
`restore.capture` ever running. The fix is not to gate that one command's `ok` on a checked index write,
which would repair the index only for its own callers. What the gap wants is either a checked `saveIndex`
whose failure surfaces, or an orphan scan that runs even when the index loads cleanly.

Two constraints on the orphan-scan route, found triaging this in 2026-09. `recoverOrphanedWindows` cannot
be called as it stands after a clean load: it builds an auto-named `window N` record for EVERY window file
and appends the lot to `windows`, so each indexed window gains a second entry under a name it never had
while the original keeps its own, and it then overwrites `frontmostWindowID`. On the index-loss path
`windows` is empty, which is why appending reads as replacing there and does no harm. A merge has to go
through `strayWindowFileIDs(indexed:)` and preserve the indexed windows' order, names, closed flags and
frontmost. And `removeWindow` ignores its snapshot-removal failure, so scanning on every clean launch can
resurrect a window the user explicitly deleted; the existing scan can do this only after index loss. That
tradeoff has to be accepted deliberately or paired with reporting the failed deletion; the extra scan is
not behavior-neutral.
