---
worth: later
where: agtermCore/Sources/agtermCore/WindowLibrary.swift:bootstrap
added: 2026-08-20
---
# a valid-but-stale windows.json orphans a window file with no recovery and no signal

`saveIndex()` catches and logs its own write failure, and nothing above it ever learns the index did not
reach disk. `bootstrap()` then calls `recoverOrphanedWindows()` only when `loadIndex()` returns nil
(`:564-570`), so an index that is valid JSON but missing an entry short-circuits straight to `reopen(index)`
and the orphaned `windows/<id>.json` is never scanned. The window and every pane in it are gone on the
next launch, with nothing in the UI saying so.

Reaching it takes a failed atomic write of `windows.json`, storage recovering afterwards, no
window create, close, rename or delete in the meantime (each rewrites the index at `:333/450/460/496`),
and then a crash before any clean quit, since `applicationWillTerminate` repairs it at
`AppDelegate.swift:328`. Remote, but a full disk gets there.

Found while reviewing PR #452, which does not cause or worsen it: the same loss happens without
`restore.capture` ever running. The fix is not to gate that one command's `ok` on a checked index write,
which would repair the index only for its own callers. What the gap wants is either a checked `saveIndex`
whose failure surfaces, or an orphan scan that runs even when the index loads cleanly.

Two constraints on the orphan-scan route, found triaging this in 2026-09. `recoverOrphanedWindows` cannot
be called as it stands after a clean load: it appends EVERY window file, renames them all to `window N`,
and overwrites `frontmostWindowID`. A merge has to go through `strayWindowFileIDs(indexed:)` and preserve
the indexed windows' order, names, closed flags and frontmost. And `removeWindow` ignores its
snapshot-removal failure, so scanning on every clean launch can resurrect a window the user explicitly
deleted; the existing scan can do this only after index loss. That tradeoff has to be accepted
deliberately or paired with reporting the failed deletion; the extra scan is not behavior-neutral.
