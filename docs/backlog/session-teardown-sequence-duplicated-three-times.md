---
worth: later
where: agtermCore/Sources/agtermCore/AppStore.swift:450
added: 2026-08-09
---
# the per-session teardown sequence is written out verbatim in three places

Closing one session, deleting a workspace, and hard-finalizing a pending close each run the same eight
steps: the four surface teardowns, `teardownPaneOverlays()`, `discardHudBody()`,
`WatermarkStorage.removeRenderedText`, and dropping the id from recency.

- `AppStore.swift:450-457`, inline in `closeSession` on the removed session;
- `AppStore.swift:486-493`, inline per member in the workspace-delete loop;
- `AppStore+PendingClose.swift:415-422`, as `hardFinalizePendingSession`.

The third is already the extracted form, and `hardFinalizePendingWorkspace` (`:425`) is nothing but a loop
calling it. The other two predate it and were never pointed at it. The only textual difference is
`sessionRecency.remove(id)` at the first two sites against `removeFromRecency(id)` at the third, and
`removeFromRecency` (`AppStore.swift:436`) is a one-line wrapper over exactly that call, so all three are
behaviourally identical today.

The risk is drift, not present breakage. A new resource hung off `Session` has to be released in three
places, and missing one leaks a surface or leaves a rendered watermark PNG behind on one close path but not
the others. `discardHudBody` and the watermark cleanup were both added after this shape existed, which is
the pattern already repeating.

The fix is to route all three through one method and delete the two inline copies. Deferred rather than
done inline because it touches the close paths and their pending/undo interaction, which want their own
test pass rather than a drive-by.

Surfaced while reviewing discussion #406 (unify workspace and session into one tree node), which was
declined. The duplication exists independently of that proposal and does not argue for it.
